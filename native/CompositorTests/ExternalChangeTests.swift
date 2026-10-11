import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// A project that something else writes while it is open: the document follows the package on disk, and only
/// when the package really changed.
@MainActor
struct ExternalChangeTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorExternalChangeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A saved two-layer project: an imported image below a blank layer.
    private func savedProject(in root: URL) async throws -> URL {
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        session.renameLayer(try #require(session.activeLayerID), to: "Base")
        session.addBlankLayer()
        let url = root.appendingPathComponent("Watched.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        return url
    }

    /// Opens the project the way the app does, so the watch is armed and the digest remembered.
    private func opened(_ url: URL) async throws -> ProjectController {
        let controller = ProjectController(session: EditorSession())
        #expect(await controller.open(url))
        return controller
    }

    /// Rewrites the package the way another app would: the same store, a different layer name.
    private func renameFirstLayerOnDisk(_ url: URL, to name: String) async throws {
        var snapshot = try await ProjectStore.shared.load(from: url)
        var layer = snapshot.manifest.layers[0]
        layer = ProjectLayerRecord(id: layer.id, name: name, isVisible: layer.isVisible, transform: layer.transform,
            imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity,
            blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID,
            adjustment: layer.adjustment, maskPlacement: layer.maskPlacement, maskLinked: layer.maskLinked, shape: layer.shape,
            effects: layer.effects, text: layer.text)
        snapshot = ProjectSnapshot(manifest: ProjectManifest(resolution: snapshot.manifest.resolution, documentID: snapshot.manifest.documentID,
            width: snapshot.manifest.width, height: snapshot.manifest.height, activeLayerID: snapshot.manifest.activeLayerID,
            layers: [layer] + snapshot.manifest.layers.dropFirst(), guides: snapshot.manifest.guides), images: snapshot.images, masks: snapshot.masks,
            workingVersion: snapshot.workingVersion)
        try await ProjectStore.shared.save(snapshot, to: url)
    }

    /// Waits for a condition the watcher reaches on its own. Returns as soon as it holds; the long limit only
    /// bounds a real failure, so a loaded host (parallel tests, CI builds) cannot fail a correct run.
    private func eventually(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(900)) }

    /// A catalog relink re-points an open working version at its original's new location. A reload of
    /// the package written elsewhere (still recording the old location) keeps the relinked location,
    /// so the Save As/export guard keeps protecting the original where it now is.
    @Test func relinkedOriginalSurvivesReloadOfPackageWrittenElsewhere() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        let url = root.appendingPathComponent("Version.comp")
        let relinked = root.appendingPathComponent("New Drive/photo.png")
        try FileManager.default.createDirectory(at: relinked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try ImageImportTests().fixture(.png), to: relinked)
        let version = LensWorksWorkingVersion(id: UUID(), photoID: "photo", catalogPath: root.appendingPathComponent("Demo.catalog").path,
            originalPath: root.appendingPathComponent("Old Drive/photo.png").path, projectPath: url.path, name: "Version")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url, workingVersion: version)
        let controller = try await opened(url)
        #expect(controller.workingVersion?.id == version.id)
        let native = try LWCatalogNativePath(fileURL: relinked)
        controller.relinkOriginal(path: relinked.path, native: native)
        #expect(controller.workingVersion?.id == version.id && controller.workingVersion?.originalPath == relinked.path)
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        #expect(await eventually { controller.externalChanges.reloadCount == 1 })
        #expect(controller.session.document?.layers.first?.name == "Renamed elsewhere")
        let reloaded = try #require(controller.workingVersion)
        #expect(reloaded.id == version.id && reloaded.originalPath == relinked.path && reloaded.originalNativePath == native)
        #expect(throws: (any Error).self) { try reloaded.validateDestination(relinked) }
    }

    @Test func digestFollowsContentNotMetadata() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let manifest = url.appendingPathComponent("manifest.json")
        let before = try ProjectDigest.compute(for: url)
        // Touched, and rewritten with the same bytes: what sync clients do.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: manifest.path)
        try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
        #expect(try ProjectDigest.compute(for: url) == before)
        // A real change to the manifest, then a real change to a layer's pixels.
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        let renamed = try ProjectDigest.compute(for: url)
        #expect(renamed != before)
        let images = url.appendingPathComponent("images")
        let png = try #require(try FileManager.default.contentsOfDirectory(atPath: images.path).first { $0.hasSuffix(".png") })
        let other = try Data(contentsOf: try ImageImportTests().fixture(.jpeg))
        try other.write(to: images.appendingPathComponent(png), options: .atomic)
        #expect(try ProjectDigest.compute(for: url) != renamed)
    }

    @Test func reloadKeepsViewportSelectionAndFoldersButNotHistory() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let session = EditorSession()
        session.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let size = try #require(session.document?.size)
        session.viewport.viewSize = CGSize(width: 800, height: 600)
        session.viewport.setZoom(3, anchoredAt: .zero, documentSize: size)
        let active = try #require(session.document?.layers.first?.id)
        session.activeLayerID = active
        session.renameLayer(active, to: "Edited here")
        #expect(session.isModified && session.canUndo)
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        session.reloadProject(try await ProjectStore.shared.load(from: url))
        #expect(session.document?.layers.first?.name == "Renamed elsewhere")
        #expect(session.viewport.zoom == 3)
        #expect(session.activeLayerID == active)
        #expect(!session.isModified)
        #expect(!session.canUndo)
        #expect(session.projectURL == url)
    }

    @Test func writingThePackageElsewhereReloadsTheOpenProject() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        #expect(await eventually { controller.externalChanges.reloadCount == 1 })
        #expect(controller.session.document?.layers.first?.name == "Renamed elsewhere")
        #expect(!controller.session.isModified)
        // The manifest rewritten in place, as a script would do it, is seen too.
        let manifest = url.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "Renamed elsewhere", with: "Renamed again")
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(await eventually { controller.externalChanges.reloadCount == 2 })
        #expect(controller.session.document?.layers.first?.name == "Renamed again")
    }

    @Test func ourOwnSaveAndMetadataTouchesDoNotReload() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let session = controller.session
        let active = try #require(session.document?.layers.first?.id)
        session.renameLayer(active, to: "Saved by us")
        #expect(await controller.save())
        await settle()
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(session.document?.layers.first?.name == "Saved by us")
        #expect(!session.isModified)
        let manifest = url.appendingPathComponent("manifest.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: manifest.path)
        try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
        await settle()
        #expect(controller.externalChanges.reloadCount == 0)
    }

    @Test func halfWrittenPackagesAreIgnoredUntilTheyLoad() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let manifest = url.appendingPathComponent("manifest.json")
        let good = try Data(contentsOf: manifest)
        try Data("{ \"format\": \"com.compositor.project\", \"version\": 9, \"layers\": [".utf8).write(to: manifest, options: .atomic)
        #expect(await eventually { controller.externalChanges.checksCompleted >= 1 })
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(controller.session.document?.layers.count == 2)
        let fixed = try #require(String(data: good, encoding: .utf8)).replacingOccurrences(of: "\"Base\"", with: "\"Finished\"")
        try fixed.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(await eventually { controller.externalChanges.reloadCount == 1 })
        #expect(controller.session.document?.layers.contains { $0.name == "Finished" } == true)
    }

    @Test func unsavedWorkIsNeverReplacedWithoutAsking() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await savedProject(in: root)
        let controller = try await opened(url)
        let session = controller.session
        let active = try #require(session.document?.layers.first?.id)
        session.renameLayer(active, to: "Unsaved here")
        try await renameFirstLayerOnDisk(url, to: "Renamed elsewhere")
        #expect(await eventually { controller.externalChanges.checksCompleted >= 1 })
        // No window to ask in, so the question waits and the document keeps the unsaved edit.
        #expect(controller.externalChanges.reloadCount == 0)
        #expect(controller.externalChanges.pending)
        #expect(session.document?.layers.first?.name == "Unsaved here")
        #expect(session.isModified)
    }
}
