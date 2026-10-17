import Foundation
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

    @Test func undoRedoAndCheckpointsSurviveReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWDoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var doc = LensWorksPhotoDocument(photoID: "p1")
        let v = doc.addVersion(named: "A")
        try doc.perform(.setRaw(key: "exposure", value: 1), on: v)
        let cp = try doc.addCheckpoint(named: "good", to: v)
        try doc.perform(.setRaw(key: "exposure", value: 3), on: v)
        try doc.undo(v)
        let store = LensWorksDocumentStore(directory: dir)
        try store.save(doc)
        var reopened = try store.load()
        #expect(reopened == doc)
        try reopened.redo(v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 3)
        try reopened.restoreCheckpoint(cp, in: v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 1)
        try reopened.undo(v)
        #expect(reopened.versions[0].content.rawSettings["exposure"] == 3)
    }

    @Test func pruningKeepsCheckpointsAndReachableAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWDoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LensWorksDocumentStore(directory: dir)
        var doc = LensWorksPhotoDocument(photoID: "p1", maxUndoSteps: 2)
        let v = doc.addVersion(named: "A")
        let first = layer("one", asset: "a1"), second = layer("two", asset: "a2")
        try doc.perform(.addLayer(first), on: v)
        try doc.addCheckpoint(named: "pin", to: v)
        try doc.perform(.addLayer(second), on: v)
        try doc.perform(.removeLayer(first.id), on: v)
        for i in 0..<3 { try doc.perform(.setRaw(key: "k", value: Double(i)), on: v) }
        for id in ["a1", "a2", "orphan"] { try store.writeAsset(id, data: Data([1])) }
        // The checkpoint-pinned step is kept even though the limit is 2; the others are pruned oldest first.
        #expect(doc.versions[0].undo.count == 2 && doc.versions[0].checkpoints.count == 1)
        let removed = try store.collectUnreachableAssets(for: doc)
        #expect(removed == ["orphan"] && store.storedAssets() == ["a1", "a2"])

        try doc.addCheckpoint(named: "pin2", to: v)
        let report = doc.setMaxUndoSteps(1)
        #expect(report.warnings.count == 1)
        #expect(doc.versions[0].undo.count == 2)
    }

    @Test func schemaOneDocumentsUpgradeAndCommandsRoundtrip() throws {
        let v1 = #"{"photoID":"p","versions":[{"id":"\#(UUID().uuidString)","name":"A","content":{"rawSettings":{"x":1},"layers":[],"sourceReferences":[]},"undo":[],"redo":[],"checkpoints":[]}]}"#
        let doc = try JSONDecoder().decode(LensWorksPhotoDocument.self, from: Data(v1.utf8))
        #expect(doc.schema == 2 && doc.maxUndoSteps == 100 && doc.versions[0].content.rawSettings["x"] == 1)
        let l = layer("L", asset: "z")
        for command: LensWorksDocumentCommand in [.setRaw(key: "a", value: 1), .addLayer(l), .removeLayer(l.id), .addSourceReference("p@3")] {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(LensWorksDocumentCommand.self, from: data) == command)
        }
        #expect(throws: LensWorksDocumentError.unsupportedSchema(9)) {
            try JSONDecoder().decode(LensWorksPhotoDocument.self, from: Data(#"{"schema":9,"photoID":"p","versions":[]}"#.utf8))
        }
    }
}
