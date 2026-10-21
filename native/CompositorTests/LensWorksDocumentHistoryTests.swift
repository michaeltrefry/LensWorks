import Foundation
import CoreGraphics
import Testing
@testable import Compositor

struct LensWorksDocumentHistoryTests {
    private func layer(_ name: String, asset: String? = nil) -> LensWorksVersionContent.Layer {
        .init(id: UUID(), name: name, assetID: asset)
    }

    @Test func duplicatedVersionsAreIndependent() throws {
        var doc = LensWorksPhotoDocument(photoID: "p1")
        let a = doc.addVersion(named: "A")
        try doc.perform(.setRaw(key: "exposure", value: 1), on: a)
        let b = try doc.duplicateVersion(a, named: "B")
        try doc.perform(.setRaw(key: "exposure", value: 2), on: b)
        try doc.perform(.addLayer(layer("L")), on: b)
        let versionA = doc.versions.first { $0.id == a }!
        #expect(versionA.content.rawSettings["exposure"] == 1 && versionA.content.layers.isEmpty && versionA.undo.count == 1)
        #expect(doc.versions.first { $0.id == b }!.undo.count == 2)
    }

    @Test func undoRedoAndCheckpointsSurviveReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWDoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var doc = LensWorksPhotoDocument(photoID: "p1")
        let v = doc.addVersion(named: "A")
        try doc.perform(.setRaw(key: "exposure", value: 1), on: v)
        let cp = try doc.addCheckpoint(named: "good", to: v)
        try doc.perform(.setRaw(key: "exposure", value: 3), on: v)
        try doc.undo(v)
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: doc), to: dir)
        var reopened = try #require(try await ProjectStore.shared.load(from: dir).lensWorksDocument)
        #expect(reopened == doc)
        try reopened.redo(v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 3)
        try reopened.restoreCheckpoint(cp, in: v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 1)
        try reopened.undo(v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 3)
    }

    @Test func projectPackagePersistsDocumentHistoryAndAssets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LWProject-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = LensWorksPhotoDocument(photoID: "p1", maxUndoSteps: 2)
        let version = document.addVersion(named: "A")
        try document.perform(.addLayer(layer("retained", asset: "asset")), on: version)
        _ = try document.addCheckpoint(named: "pin", to: version)
        try document.perform(.setRaw(key: "exposure", value: 2), on: version)
        try document.undo(version)
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: document,
            lensWorksDocumentAssets: ["asset": Data([1, 2, 3])])
        try await ProjectStore.shared.save(snapshot, to: directory)
        let reopened = try await ProjectStore.shared.load(from: directory)
        #expect(reopened.lensWorksDocument == document && reopened.lensWorksDocumentAssets["asset"] == Data([1, 2, 3]))
        var restored = try #require(reopened.lensWorksDocument)
        _ = try restored.redo(version)
        #expect(restored.versions[0].content.rawSettings["exposure"] == 2)
    }

    @Test func pruningKeepsCheckpointsAndReachableAssets() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWDoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var doc = LensWorksPhotoDocument(photoID: "p1", maxUndoSteps: 2)
        let v = doc.addVersion(named: "A")
        let first = layer("one", asset: "a1"), second = layer("two", asset: "a2")
        let orphan = layer("obsolete", asset: "orphan")
        try doc.perform(.addLayer(orphan), on: v)
        let seed = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: seed, images: [:], lensWorksDocument: doc,
            lensWorksDocumentAssets: ["orphan": Data([1])]), to: dir)
        try doc.perform(.removeLayer(orphan.id), on: v)
        try doc.perform(.addLayer(first), on: v)
        try doc.addCheckpoint(named: "pin", to: v)
        try doc.perform(.addLayer(second), on: v)
        try doc.perform(.removeLayer(first.id), on: v)
        for i in 0..<3 { try doc.perform(.setRaw(key: "k", value: Double(i)), on: v) }
        let assets = Dictionary(uniqueKeysWithValues: ["a1", "a2", "orphan"].map { ($0, Data([1])) })
        // The checkpoint-pinned step is kept even though the limit is 2; the others are pruned oldest first.
        #expect(doc.versions[0].undo.count == 2 && doc.versions[0].checkpoints.count == 1)
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: doc,
            lensWorksDocumentAssets: assets), to: dir)
        let reopened = try await ProjectStore.shared.load(from: dir)
        #expect(Set(reopened.lensWorksDocumentAssets.keys) == ["a1", "a2"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("LensWorksDocument/assets").path)) == ["a1", "a2"])

        try doc.addCheckpoint(named: "pin2", to: v)
        let report = doc.setMaxUndoSteps(1)
        #expect(report.warnings.count == 1)
        #expect(doc.versions[0].undo.count == 2)
    }

    @Test func missingReachableAssetFailsWithoutReplacingThePreviousPackage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LWAtomic-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        var document = LensWorksPhotoDocument(photoID: "p")
        let version = document.addVersion(named: "A")
        try document.perform(.addLayer(layer("kept", asset: "kept")), on: version)
        let original = ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: document,
            lensWorksDocumentAssets: ["kept": Data([1, 2, 3])])
        try await ProjectStore.shared.save(original, to: file)
        let broken = ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: document)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(broken, to: file) }
        let reopened = try await ProjectStore.shared.load(from: file)
        #expect(reopened.lensWorksDocument == document)
        #expect(reopened.lensWorksDocumentAssets["kept"] == Data([1, 2, 3]))
    }

    @Test func redoPrunesAfterLimitIsLoweredWithPendingRedo() throws {
        var doc = LensWorksPhotoDocument(photoID: "p1")
        let version = doc.addVersion(named: "A")
        for value in 0..<5 { try doc.perform(.setRaw(key: "exposure", value: Double(value)), on: version) }
        for _ in 0..<5 { try doc.undo(version) }
        #expect(doc.versions[0].undo.isEmpty && doc.versions[0].redo.count == 5)
        _ = doc.setMaxUndoSteps(1)
        for _ in 0..<5 { _ = try doc.redo(version) }
        #expect(doc.versions[0].undo.count == 1)
    }

    @Test func legacySourceReferencesRejectEmptyPhotoIDs() throws {
        for legacy in ["", "@"] {
            #expect(throws: LensWorksDocumentError.invalidSourceReference) {
                try LensWorksSourceReference(legacyValue: legacy)
            }
            #expect(throws: LensWorksDocumentError.invalidSourceReference) {
                try JSONDecoder().decode(LensWorksVersionContent.self, from: Data(("{\"sourceReferences\":[\"" + legacy + "\"]}").utf8))
            }
        }
        var document = LensWorksPhotoDocument(photoID: "p")
        let version = document.addVersion(named: "A")
        #expect(throws: LensWorksDocumentError.invalidSourceReference) {
            try document.perform(.addSourceReference(""), on: version)
        }
        #expect(throws: LensWorksDocumentError.invalidSourceReference) {
            try document.perform(.addSourceReferenceRecord(.init(photoID: "")), on: version)
        }
    }

    @Test func packageSaveRejectsTooManyLensWorksAssets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LWProject-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: [])
        let assets = Dictionary(uniqueKeysWithValues: (0...10_000).map { ("asset-\($0)", Data([0])) })
        var document = LensWorksPhotoDocument(photoID: "p")
        let version = document.addVersion(named: "A")
        document.versions[0].content.layers = assets.keys.map { layer($0, asset: $0) }
        #expect(document.versions[0].id == version)
        let snapshot = ProjectSnapshot(manifest: manifest, images: [:], lensWorksDocument: document,
            lensWorksDocumentAssets: assets)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(snapshot, to: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: [1, 2]) func genuinelyLegacyPayloadsOmitNewFields(schema: Int) throws {
        // Deliberately authored old shape, not relabeled output of today's encoder.
        let graph = schema == 2 ? #", "layerGraph":{"layers":[]}"# : ""
        let fixture = """
        {"schema":\(schema),"photoID":"legacy","versions":[{
          "id":"11111111-1111-1111-1111-111111111111","name":"Legacy",
          "content":{"rawSettings":{"exposure":1},"layers":[],"sourceReferences":["p@3"]\(graph)},
          "undo":[],"redo":[],"checkpoints":[]
        }]}
        """
        let upgraded = try JSONDecoder().decode(LensWorksPhotoDocument.self, from: Data(fixture.utf8))
        #expect(upgraded.schema == 3 && upgraded.maxUndoSteps == 100)
        #expect(upgraded.selectedVersionID == nil)
        #expect(upgraded.versions[0].content.rawSettings["exposure"] == 1)
        #expect(upgraded.versions[0].content.sourceReferences == [.init(photoID: "p", revision: "3")])
        #expect(upgraded.versions[0].content.layerGraph?.composition == nil)
        #expect(try JSONDecoder().decode(LensWorksPhotoDocument.self, from: JSONEncoder().encode(upgraded)) == upgraded)
    }

    @Test(arguments: [1, 2]) func legacySchemasUpgradeAndCommandsRoundtripThroughHistory(schema: Int) throws {
        let legacyLayer = layer("L", asset: "z")
        let graph = LensWorksLayerGraph(layers: [ProjectLayerRecord(id: UUID(), name: "Live", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)), imageFile: nil)])
        let commands: [LensWorksDocumentCommand] = [
            .setRaw(key: "a", value: 1), .addLayer(legacyLayer), .removeLayer(legacyLayer.id), .addSourceReference("p@3"),
            .addSourceReferenceRecord(.init(photoID: "p", revision: "4", assetID: "source")), .replaceLayerGraph(graph),
            .replaceLiveSource(layerID: graph.layers[0].id, source: nil)
        ]
        var original = LensWorksPhotoDocument(photoID: "p")
        let version = original.addVersion(named: "A")
        for command in commands { try original.perform(command, on: version) }
        for _ in 0..<2 { try original.undo(version) }
        _ = try original.addCheckpoint(named: "checkpoint", to: version)
        var fixture = try JSONEncoder().encode(original)
        fixture = Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: #""schema":3"#, with: "\"schema\":\(schema)").utf8)
        let upgraded = try JSONDecoder().decode(LensWorksPhotoDocument.self, from: fixture)
        #expect(upgraded.schema == 3 && upgraded.maxUndoSteps == 100)
        #expect(upgraded.versions[0].undo.map(\.command) == original.versions[0].undo.map(\.command))
        #expect(upgraded.versions[0].redo.map(\.command) == original.versions[0].redo.map(\.command))
        #expect(upgraded.versions[0].checkpoints == original.versions[0].checkpoints)
        let roundtrip = try JSONDecoder().decode(LensWorksPhotoDocument.self, from: JSONEncoder().encode(upgraded))
        #expect(roundtrip == upgraded)
        #expect(throws: LensWorksDocumentError.unsupportedSchema(9)) {
            try JSONDecoder().decode(LensWorksPhotoDocument.self, from: Data(#"{"schema":9,"photoID":"p","versions":[]}"#.utf8))
        }
    }
}
