import AppKit
import Testing
@testable import Compositor

@MainActor
struct LensWorksVersionRestoreTests {
    private func image(_ color: CGColor) throws -> ImportedImage {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Layer")
    }

    private func save(_ controller: ProjectController, to file: URL) async throws {
        controller.agentRequest = ProjectAgentRequest()
        let saved = await controller.save(to: file)
        try #require(saved, Comment(rawValue: controller.agentRequest?.failure ?? "Save failed"))
    }

    private func open(_ controller: ProjectController, from file: URL) async throws {
        controller.agentRequest = ProjectAgentRequest()
        let opened = await controller.open(file)
        try #require(opened, Comment(rawValue: controller.agentRequest?.failure ?? "Open failed"))
    }

    @Test func undoAndCheckpointRestoreChangeTheCanvasAndRetainAssets() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p1", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        let first = session.document?.layers.count ?? 0

        try controller.captureLensWorksComposition(in: version)
        try controller.addLensWorksCheckpoint(named: "one", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions.first?.checkpoints.first?.id)
        session.insert(try image(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
        #expect(session.document?.layers.count == first + 1)
        try controller.captureLensWorksComposition(in: version)

        try controller.undoLensWorksVersion(version)
        #expect(session.document?.layers.count == first)
        try controller.redoLensWorksVersion(version)
        #expect(session.document?.layers.count == first + 1)
        try controller.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(session.document?.layers.count == first)

        let reachable = try #require(controller.lensWorksDocument).reachableAssets
        #expect(!reachable.isEmpty && reachable.allSatisfy { controller.lensWorksDocumentAssets[$0] != nil })
    }
    @Test func newNamedVersionCapturesTheVisibleComposition() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count
        try controller.addLensWorksVersion(named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        #expect(controller.lensWorksDocument?.selectedVersionID == second)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        #expect(session.document?.layers.count == (count ?? 0) - 1)
        try controller.selectLensWorksVersion(second)
        #expect(session.document?.layers.count == count)
        #expect(session.document?.width == 32 && session.document?.height == 24)
    }

    @Test func dirtySwitchRefusesWithoutChangingCanvasUndoOrModifiedState() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0.5, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        controller.lensWorksDocumentModified = false
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let revision = session.history.currentRevision, undo = session.history.undoCount
        let count = session.document?.layers.count
        #expect(throws: LensWorksCommandRefusal.self) { try controller.selectLensWorksVersion(second) }
        #expect(controller.selectedLensWorksVersionID == first)
        #expect(session.document?.layers.count == count && session.history.currentRevision == revision)
        #expect(session.history.undoCount == undo && session.isModified)
        session.undo()
        #expect(session.document?.layers.count == (count ?? 0) - 1)
    }

    @Test(arguments: ["undo", "redo", "checkpoint"])
    func dirtyHistoryReplacementKeepsEditsAndUndo(action: String) throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        try controller.addLensWorksCheckpoint(named: "start", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[0].checkpoints[0].id)
        session.insert(try image(CGColor(gray: 0.5, alpha: 1)))
        try controller.captureLensWorksComposition(in: version)
        if action == "redo" { try controller.undoLensWorksVersion(version) }
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count, revision = session.history.currentRevision
        let document = controller.lensWorksDocument
        #expect(throws: LensWorksCommandRefusal.self) {
            switch action {
            case "undo": try controller.undoLensWorksVersion(version)
            case "redo": try controller.redoLensWorksVersion(version)
            default: try controller.restoreLensWorksCheckpoint(checkpoint, in: version)
            }
        }
        #expect(controller.lensWorksDocument == document)
        #expect(session.document?.layers.count == count && session.history.currentRevision == revision)
        session.undo()
        #expect(session.document?.layers.count == (count ?? 0) - 1)
    }

    @Test func invalidStoredCompositionCannotReplaceTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        controller.lensWorksDocument?.versions[1].content.layerGraph?.composition?.width = 0
        let revision = session.history.currentRevision
        #expect(throws: ProjectError.self) { try controller.selectLensWorksVersion(second) }
        #expect(controller.selectedLensWorksVersionID == first)
        #expect(session.document?.width == 32 && session.history.currentRevision == revision)
    }

    @Test func savedCanvasEditsSurviveVersionSwitchAndReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        controller.recordsRecentProjects = false; controller.sharesWorkingVersions = false
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count
        try await save(controller, to: file)
        try controller.selectLensWorksVersion(second)
        #expect(session.document?.layers.count == (count ?? 0) - 1)
        #expect(controller.lensWorksDocumentModified)
        try controller.selectLensWorksVersion(first)
        #expect(session.document?.layers.count == count)
        try await save(controller, to: file)
        let reopened = ProjectController(session: EditorSession())
        reopened.recordsRecentProjects = false; reopened.sharesWorkingVersions = false
        try await open(reopened, from: file)
        #expect(reopened.selectedLensWorksVersionID == first)
        #expect(reopened.session.document?.layers.count == count)
        try reopened.selectLensWorksVersion(second)
        #expect(reopened.session.document?.layers.count == (count ?? 0) - 1)
        try reopened.selectLensWorksVersion(first)
        #expect(reopened.session.document?.layers.count == count)
    }

    @Test func completeCompositionRestoresAcrossUndoCheckpointAndPackage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("composition-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let guide = CanvasGuide(id: UUID(), axis: .horizontal, position: 12)
        session.document?.resolution = 144; session.document?.guides = [guide]
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        try controller.addLensWorksCheckpoint(named: "small", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[0].checkpoints[0].id)
        let old = try #require(session.document)
        session.document = CanvasDocument(id: old.id, width: 64, height: 48, layers: old.layers, resolution: 300)
        try controller.captureLensWorksComposition(in: version)
        try controller.undoLensWorksVersion(version)
        #expect(session.document?.width == 32 && session.document?.height == 24)
        #expect(session.document?.resolution == 144 && session.document?.guides == [guide])
        try controller.redoLensWorksVersion(version)
        #expect(session.document?.width == 64 && session.document?.height == 48)
        #expect(session.document?.resolution == 300 && session.document?.guides == [])
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: snapshot.manifest, images: snapshot.images,
            lensWorksDocument: controller.lensWorksDocument, lensWorksDocumentAssets: controller.lensWorksDocumentAssets), to: file)
        let reopened = try await ProjectStore.shared.load(from: file)
        let restored = ProjectController(session: EditorSession())
        restored.session.installProject(reopened, from: file)
        restored.lensWorksDocument = reopened.lensWorksDocument
        restored.lensWorksDocumentAssets = reopened.lensWorksDocumentAssets
        try restored.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(restored.session.document?.width == 32 && restored.session.document?.height == 24)
        #expect(restored.session.document?.resolution == 144 && restored.session.document?.guides == [guide])
    }
    @Test(arguments: [false, true])
    func liveRawVersionsKeepExactSamplesSettingsAndSourceAcrossReopen(tiled: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("raw-versions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let directory = try #require(temporary.physicalFileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.dng")
        try ProceduralDNG.write(to: original, width: 32, height: 24)
        let originalBytes = try Data(contentsOf: original)
        let file = directory.appendingPathComponent("versions.comp")
        // A real original and decoder authority exercise the normal save's
        // mandatory full-resolution QuickLook development, not a fake RAW cache.
        let (source, decoded) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: original), rawHint: true)
        let range = LWFloatRange(x: 0, y: 0, width: decoded.width, height: decoded.height)
        let tile = try decoded.read(range)
        let surface = try LWLinearSurface(width: decoded.width, height: decoded.height,
            pixels: Array(tile.surface.pixels), maximumBytes: 1024 * 1024)
        let image = tiled ? try ImportedImage(plane: decoded, name: "RAW") : try ImportedImage(linear: surface, name: "RAW")
        let session = EditorSession()
        session.createDocument(width: decoded.width, height: decoded.height)
        session.insert(image)
        let layerID = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == layerID })
        session.document?.layers[index].liveSource = source
        let controller = ProjectController(session: session)
        controller.recordsRecentProjects = false; controller.sharesWorkingVersions = false
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        let initial = try #require(controller.lensWorksDocument?.versions[0].content.layerGraph)
        #expect(initial.layers.first { $0.id == layerID }?.liveSourceFile != nil)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        // Alter the native live RAW graph, rather than the legacy scalar test-only dictionary.
        session.document?.layers[index].liveSource?.settings.exposure = 1.5
        try controller.captureLensWorksComposition(in: second)
        try controller.addLensWorksCheckpoint(named: "bright", to: second)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[1].checkpoints.first?.id)
        try await save(controller, to: file)
        let stored = try await ProjectStore.shared.load(from: file)
        let rasterOnly = ProjectManifest(documentID: UUID(), width: decoded.width, height: decoded.height, activeLayerID: nil, layers: [])
        let historical = ProjectSnapshot(manifest: rasterOnly, images: [:], lensWorksDocument: stored.lensWorksDocument,
            lensWorksDocumentAssets: stored.lensWorksDocumentAssets, lensWorksDocumentPlanes: stored.lensWorksDocumentPlanes)
        let authority = try LWSourceDestinationAuthority(historical)
        #expect(throws: ProjectError.self) { try authority.validate(original) }
        #expect(throws: ProjectError.self) { try authority.validate(directory) }
        let exporter = ProjectController(session: EditorSession())
        exporter.session.installProject(ProjectSnapshot(manifest: rasterOnly, images: [:]), from: file)
        exporter.lensWorksDocument = stored.lensWorksDocument
        exporter.lensWorksDocumentAssets = stored.lensWorksDocumentAssets
        exporter.lensWorksDocumentPlanes = stored.lensWorksDocumentPlanes
        await #expect(throws: ProjectError.self) { try await exporter.exportPNG(to: original) }
        await #expect(throws: ProjectError.self) { try await exporter.exportJPEG(to: original, options: JPEGOptions()) }
        #expect(try Data(contentsOf: original) == originalBytes)
        let reopened = ProjectController(session: EditorSession())
        reopened.recordsRecentProjects = false; reopened.sharesWorkingVersions = false
        try await open(reopened, from: file)
        func exposure() -> Double? { reopened.session.document?.layers.first { $0.id == layerID }?.liveSource?.settings.exposure }
        #expect(exposure() == 1.5)
        try reopened.selectLensWorksVersion(first)
        #expect(exposure() == 0)
        try reopened.selectLensWorksVersion(second)
        #expect(exposure() == 1.5)
        try reopened.undoLensWorksVersion(second)
        #expect(exposure() == 0)
        try reopened.redoLensWorksVersion(second)
        #expect(exposure() == 1.5)
        try reopened.restoreLensWorksCheckpoint(checkpoint, in: second)
        #expect(exposure() == 1.5)
        let restored = try #require(reopened.session.document?.layers.first { $0.id == layerID }?.asset)
        if let plane = restored.linearPlane {
            let tile = try plane.read(range)
            for i in surface.pixels.indices { for channel in 0..<4 { #expect(tile.surface.pixels[i][channel].bitPattern == surface.pixels[i][channel].bitPattern) } }
        } else {
            let samples = try #require(restored.linear)
            for i in surface.pixels.indices { for channel in 0..<4 { #expect(samples.pixels[i][channel].bitPattern == surface.pixels[i][channel].bitPattern) } }
        }
        #expect(try Data(contentsOf: original) == originalBytes)
    }

}
