import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct LensWorksCatalogTests {
    @Test func originalCannotBeUsedAsProjectOrExportDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksProtection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        let catalog = root.appendingPathComponent("Catalog.comp")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let version = LensWorksWorkingVersion(id: UUID(), photoID: UUID().uuidString, catalogPath: catalog.path, originalPath: source.path, projectPath: root.appendingPathComponent("edit.comp").path, name: "Edit")
        #expect(throws: (any Error).self) { try version.validateDestination(source) }
        #expect(throws: (any Error).self) { try version.validateDestination(root) }
        #expect(throws: (any Error).self) { try version.validateDestination(catalog) }
        #expect(throws: (any Error).self) { try version.validateDestination(catalog.appendingPathComponent("previews/export.png")) }
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: (any Error).self) { try version.validateDestination(alias) }
        let hardLink = root.appendingPathComponent("hardlink.png")
        try FileManager.default.linkItem(at: source, to: hardLink)
        #expect(throws: (any Error).self) { try version.validateDestination(hardLink) }
        let project = root.appendingPathComponent("edit.comp")
        try version.validateDestination(project)
        let embeddedOriginal = LensWorksWorkingVersion(id: UUID(), photoID: UUID().uuidString, catalogPath: catalog.path,
            originalPath: project.appendingPathComponent("LensWorks.json").path, projectPath: project.path, name: "Edit")
        #expect(throws: (any Error).self) { try embeddedOriginal.validateDestination(project) }
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
    }

    @Test func interruptedSemanticRebuildReopensCommittedBatchesWithoutChangingCatalogOrDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticRecovery-\(UUID())")
        let media = root.appendingPathComponent("Photos"), catalogURL = root.appendingPathComponent("Catalog")
        let support = root.appendingPathComponent("ApplicationSupport")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let total = LensWorksSemanticIndex.batchSize * 2 + 1
        for i in 0..<total {
            try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent("Original-\(i).png"))
        }
        let service = LensWorksCatalogService()
        _ = try await service.request(LensWorksCatalogRequest(op: "create", catalog_path: catalogURL.path), as: LensWorksCatalogLocation.self)
        let imported = try await service.request(LensWorksCatalogRequest(op: "import", catalog_path: catalogURL.path, source_path: media.path, max_files: 1000), as: LensWorksImportReport.self)
        #expect(imported.imported == total)
        let page = try await service.request(LensWorksCatalogRequest(op: "list", catalog_path: catalogURL.path), as: LensWorksCatalogPage.self)
        #expect(page.assets.count == total)
        let asset = try #require(page.assets.first)
        let session = EditorSession()
        await session.importImages([URL(fileURLWithPath: asset.originalPath)])
        let layerID = try #require(session.activeLayerID)
        session.renameLayer(layerID, to: "Irreplaceable edit")
        session.setLayerOpacity(0.6)
        let snapshot = try #require(session.projectSnapshot())
        let project = root.appendingPathComponent("Working version.comp")
        let workingVersion = LensWorksWorkingVersion(id: UUID(), photoID: asset.photoID, catalogPath: catalogURL.path,
            originalPath: asset.originalPath, projectPath: project.path, name: "Preserved version")
        try await ProjectStore.shared.save(snapshot, to: project, workingVersion: workingVersion)
        try await service.close() // freeze durable catalog bytes, excluding a live connection's WAL bookkeeping

        // Compare every original, catalog database/sidecar and project asset byte-for-byte, not
        // just a synthetic marker. Only the rebuildable application-support index may change.
        func protectedFiles() throws -> [String: Data] {
            var files: [String: Data] = [:]
            // Relative enumeration avoids macOS's /var versus /private/var URL aliases.
            let entries = try #require(FileManager.default.enumerator(atPath: root.path))
            for case let path as String in entries {
                if path == "ApplicationSupport" { entries.skipDescendants(); continue }
                let file = root.appendingPathComponent(path)
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files[path] = try Data(contentsOf: file)
                }
            }
            return files
        }
        let before = try protectedFiles()
        func expectProtectedFilesUnchanged() throws {
            let after = try protectedFiles()
            for path in Set(before.keys).union(after.keys).sorted() {
                #expect(after[path] == before[path], "Protected file changed: \(path)")
            }
        }
        let indexURL = LensWorksSemanticSearch.indexURL(forCatalog: catalogURL.path, in: support)
        let indexVersion = LWSemanticIndexVersion(imageProvider: "img", textProvider: "txt", space: "fixture", dimension: 4,
            assets: ["fixture@1"], source: "preview", recipe: "recovery")
        let image = try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([0, 0, 0]))
        let candidates = page.assets.map { asset in LWSemanticCandidate(id: asset.id, stamp: "r1") { image } }
        let embedder = FixtureEmbedder()
        weak var interruptedIndex: LensWorksSemanticIndex?
        func interruptAfterFirstCommit() async throws {
            let index = LensWorksSemanticIndex(url: indexURL)
            interruptedIndex = index
            try await index.adopt(indexVersion)
            let started = AsyncStream<Void>.makeStream()
            var interrupted = candidates
            let blocked = candidates[LensWorksSemanticIndex.batchSize]
            interrupted[LensWorksSemanticIndex.batchSize] = LWSemanticCandidate(id: blocked.id, stamp: blocked.stamp) {
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
                return image
            }
            let task = Task {
                defer { started.continuation.finish() }
                return try await index.sync(interrupted, embedder: embedder)
            }
            var iterator = started.stream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                _ = try await task.value // surface an early sync failure instead of hanging
                Issue.record("The rebuild ended before reaching its second batch")
                return
            }
            #expect(try await index.count() == LensWorksSemanticIndex.batchSize)
            task.cancel()
            let partial = try await task.value
            #expect(partial.cancelled && partial.embedded == LensWorksSemanticIndex.batchSize)
            started.continuation.finish()
        }
        try await interruptAfterFirstCommit()
        #expect(interruptedIndex == nil, "the interrupted actor and SQLite connection are closed before reopening")
        try expectProtectedFilesUnchanged()
        let reopened = LensWorksSemanticIndex(url: indexURL)
        #expect(try await reopened.adopt(indexVersion) == false)
        #expect(try await reopened.count() == LensWorksSemanticIndex.batchSize)
        let resumed = try await reopened.sync(candidates, embedder: embedder)
        #expect(resumed.upToDate == LensWorksSemanticIndex.batchSize && resumed.embedded == total - LensWorksSemanticIndex.batchSize)
        #expect(embedder.imageCalls == total, "committed vectors are not recomputed after reopening")
        #expect(Set(try await reopened.search("beach", limit: total, embedder: embedder).map(\.id)) == Set(page.assets.map(\.id)))
        await reopened.deleteIndexFiles()
        try await reopened.adopt(indexVersion)
        #expect(try await reopened.sync(candidates, embedder: embedder).embedded == total)
        try expectProtectedFilesUnchanged() // interruption, recovery and full index deletion preserve every protected byte
        let reopenedService = LensWorksCatalogService()
        _ = try await reopenedService.request(LensWorksCatalogRequest(op: "open", catalog_path: catalogURL.path), as: LensWorksCatalogLocation.self)
        let later = try await reopenedService.request(LensWorksCatalogRequest(op: "list", catalog_path: catalogURL.path), as: LensWorksCatalogPage.self)
        #expect(Set(later.assets.map(\.id)) == Set(page.assets.map(\.id)))
        try await reopenedService.close()
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(project))
        let recovered = try #require(workspace.current.controller.workingVersion)
        #expect(recovered.id == workingVersion.id && recovered.photoID == workingVersion.photoID)
        #expect(recovered.catalogPath == workingVersion.catalogPath && recovered.originalPath == workingVersion.originalPath)
        #expect(recovered.projectPath == workingVersion.projectPath && recovered.name == workingVersion.name)
        #expect(workspace.current.session.document?.id == session.document?.id)
        #expect(workspace.current.session.document?.layers.first?.id == layerID)
        #expect(workspace.current.session.document?.layers.first?.name == "Irreplaceable edit")
        #expect(workspace.current.session.document?.layers.first?.opacity == 0.6)
    }

    @Test func realCatalogWorkingVersionRetainsSourceAndLayersAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksCatalogTests-\(UUID())")
        let media = root.appendingPathComponent("Photos")
        let catalogURL = root.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = media.appendingPathComponent("Original.png")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let service = LensWorksCatalogService()
        _ = try await service.request(LensWorksCatalogRequest(op: "create", catalog_path: catalogURL.path), as: LensWorksCatalogLocation.self)
        let imported = try await service.request(LensWorksCatalogRequest(op: "import", catalog_path: catalogURL.path, source_path: media.path, max_files: 1000), as: LensWorksImportReport.self)
        #expect(imported.imported == 1)
        let page = try await service.request(LensWorksCatalogRequest(op: "list", catalog_path: catalogURL.path), as: LensWorksCatalogPage.self)
        let asset = try #require(page.assets.first)
        #expect(URL(fileURLWithPath: asset.originalPath).resolvingSymlinksInPath() == source.resolvingSymlinksInPath())
        let session = EditorSession()
        await session.importImages([source])
        let layerID = try #require(session.activeLayerID)
        session.renameLayer(layerID, to: "Edited catalog layer")
        session.setLayerOpacity(0.6)
        let snapshot = try #require(session.projectSnapshot())
        let project = media.appendingPathComponent("Working version.comp")
        let version = LensWorksWorkingVersion(id: UUID(), photoID: asset.photoID, catalogPath: catalogURL.path, originalPath: source.path, projectPath: project.path, name: "Working version")
        try await ProjectStore.shared.save(snapshot, to: project, workingVersion: version)
        let beforeManifest = try Data(contentsOf: project.appendingPathComponent("manifest.json"))
        let beforeIdentity = try Data(contentsOf: project.appendingPathComponent("LensWorks.json"))
        let invalidVersion = LensWorksWorkingVersion(id: UUID(), photoID: "", catalogPath: catalogURL.path,
            originalPath: source.path, projectPath: project.path, name: "Invalid")
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(snapshot, to: project, workingVersion: invalidVersion)
        }
        #expect(try Data(contentsOf: project.appendingPathComponent("manifest.json")) == beforeManifest)
        #expect(try Data(contentsOf: project.appendingPathComponent("LensWorks.json")) == beforeIdentity)
        let beforeDigest = try ProjectDigest.compute(for: project)
        var renamedVersion = version
        renamedVersion.name = "Renamed working version"
        try await ProjectStore.shared.save(snapshot, to: project, workingVersion: renamedVersion)
        #expect(try Data(contentsOf: project.appendingPathComponent("manifest.json")) == beforeManifest)
        #expect(try ProjectDigest.compute(for: project) != beforeDigest)
        let reopened = ProjectWorkspace()
        #expect(await reopened.open(project))
        let recovered = try #require(reopened.current.controller.workingVersion)
        #expect(recovered.id == version.id)
        #expect(recovered.name == "Renamed working version")
        #expect(recovered.photoID == asset.id)
        #expect(recovered.originalPath == source.path)
        #expect(reopened.current.session.document?.id == session.document?.id)
        #expect(reopened.current.session.document?.layers.first?.id == layerID)
        #expect(reopened.current.session.document?.layers.first?.name == "Edited catalog layer")
        #expect(reopened.current.session.document?.layers.first?.opacity == 0.6)
        #expect(try Data(contentsOf: source) == original)
        _ = try await service.request(LensWorksCatalogRequest(op: "open", catalog_path: catalogURL.path), as: LensWorksCatalogLocation.self)
        let later = try await service.request(LensWorksCatalogRequest(op: "list", catalog_path: catalogURL.path), as: LensWorksCatalogPage.self)
        #expect(later.assets.first?.id == asset.id)
        try FileManager.default.removeItem(at: project.appendingPathComponent("LensWorks.json"))
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: project) }
    }

    @Test func failedCatalogSwitchCannotRetainPhotosFromPreviousCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksSwitch-\(UUID())")
        let media = root.appendingPathComponent("Photos"), catalogURL = root.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent("Source.png"))
        let previousCatalog = LensWorksUserState.defaults.string(forKey: "LensWorks.catalogPath")
        defer { LensWorksUserState.defaults.set(previousCatalog, forKey: "LensWorks.catalogPath") }
        let catalog = LensWorksCatalog()
        await catalog.connect(catalogURL.path, create: true)
        await catalog.importFolder(media.path)
        #expect(catalog.assets.count == 1)
        #expect(catalog.selectedAsset != nil)
        await catalog.connect(root.appendingPathComponent("Missing Catalog").path)
        #expect(catalog.catalogPath == nil)
        #expect(catalog.assets.isEmpty)
        #expect(catalog.versions.isEmpty)
        #expect(catalog.selectedPhotoID == nil)
        #expect(!catalog.hasMore && !catalog.hasPrevious)
        #expect(catalog.error != nil)
    }


    @Test func corruptVersionDoesNotHideCatalogOrHealthyVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksRecovery-\(UUID())")
        let media = root.appendingPathComponent("Photos"), catalogURL = root.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = media.appendingPathComponent("Source.png")
        try FileManager.default.copyItem(at: fixture, to: source)
        let keys = ["LensWorks.catalogPath", "LensWorks.workingVersions"]
        let previous = keys.map { LensWorksUserState.defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { LensWorksUserState.defaults.set(value, forKey: key) } }
        let catalog = LensWorksCatalog()
        await catalog.connect(catalogURL.path, create: true)
        await catalog.importFolder(media.path)
        let asset = try #require(catalog.selectedAsset)
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let healthy = media.appendingPathComponent("Healthy.comp"), corrupt = media.appendingPathComponent("Corrupt.comp")
        let version = LensWorksWorkingVersion(id: UUID(), photoID: asset.photoID, catalogPath: try #require(catalog.catalogPath),
            originalPath: source.path, projectPath: healthy.path, name: "Healthy")
        try await ProjectStore.shared.save(snapshot, to: healthy, workingVersion: version)
        try await ProjectStore.shared.save(snapshot, to: corrupt, workingVersion: version)
        try FileManager.default.removeItem(at: corrupt.appendingPathComponent("LensWorks.json"))
        LensWorksUserState.defaults.set([healthy.path, corrupt.path], forKey: "LensWorks.workingVersions")
        await catalog.reconcileWorkingVersions()
        #expect(catalog.error?.contains("Corrupt.comp") == true)
        #expect(LensWorksUserState.defaults.stringArray(forKey: "LensWorks.workingVersions")?.contains(corrupt.path) == true)
        await catalog.connect(catalogURL.path)
        #expect(catalog.catalogPath != nil)
        #expect(catalog.assets.count == 1)
        #expect(catalog.selectedAsset?.id == asset.id)
        #expect(catalog.versions.count == 1)
        #expect(catalog.versions.first?.projectPath == healthy.path)
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: corrupt) }
    }


    @Test func workingVersionFolderMustRemainOutsideCatalogManagedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksOutputProtection-\(UUID())")
        let catalog = root.appendingPathComponent("Catalog"), media = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await LensWorksVersionStore.shared.canonicalPath(catalog.path, outside: catalog.path)
        }
        await #expect(throws: (any Error).self) {
            try await LensWorksVersionStore.shared.canonicalPath(catalog.appendingPathComponent("previews").path, outside: catalog.path)
        }
        let alias = root.appendingPathComponent("CatalogAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: catalog)
        await #expect(throws: (any Error).self) {
            try await LensWorksVersionStore.shared.canonicalPath(alias.path, outside: catalog.path)
        }
        #expect(try await LensWorksVersionStore.shared.canonicalPath(media.path, outside: catalog.path) == media.resolvingSymlinksInPath().path)
    }


    @Test func saveAsCreatesIndependentVersionAndPreservesOriginalProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksSaveAs-\(UUID())")
        let catalog = root.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = root.appendingPathComponent("Source.png")
        try FileManager.default.copyItem(at: fixture, to: source)
        let sourceBytes = try Data(contentsOf: source)
        let keys = ["LensWorks.workingVersions", "LensWorks.lastWorkingVersion"]
        let previous = keys.map { LensWorksUserState.defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { LensWorksUserState.defaults.set(value, forKey: key) } }
        let session = EditorSession()
        await session.importImages([source])
        let layer = try #require(session.activeLayerID)
        session.renameLayer(layer, to: "Original version layer")
        let first = root.appendingPathComponent("First.comp"), second = root.appendingPathComponent("Second.comp")
        let version = LensWorksWorkingVersion(id: UUID(), photoID: UUID().uuidString, catalogPath: catalog.path,
            originalPath: source.path, projectPath: first.path, name: "First")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: first, workingVersion: version)
        let firstManifest = try Data(contentsOf: first.appendingPathComponent("manifest.json"))
        let firstIdentity = try Data(contentsOf: first.appendingPathComponent("LensWorks.json"))
        let editing = EditorSession()
        let controller = ProjectController(session: editing)
        #expect(await controller.open(first))
        #expect(await controller.save(asNew: true, to: second))
        let secondVersion = try #require(controller.workingVersion)
        #expect(secondVersion.id != version.id)
        #expect(secondVersion.photoID == version.photoID)
        #expect(secondVersion.originalPath == source.path)
        editing.renameLayer(layer, to: "Independent second layer")
        editing.setLayerOpacity(0.4)
        #expect(await controller.save())
        #expect(controller.workingVersion?.id == secondVersion.id)
        #expect(try Data(contentsOf: first.appendingPathComponent("manifest.json")) == firstManifest)
        #expect(try Data(contentsOf: first.appendingPathComponent("LensWorks.json")) == firstIdentity)
        let firstLoaded = try await ProjectStore.shared.load(from: first), secondLoaded = try await ProjectStore.shared.load(from: second)
        #expect(firstLoaded.manifest.layers.first?.name == "Original version layer")
        #expect(secondLoaded.manifest.layers.first?.name == "Independent second layer")
        #expect(secondLoaded.manifest.layers.first?.opacity == 0.4)
        let listing = await LensWorksVersionStore.shared.list(paths: [first.path, second.path], directory: nil)
        #expect(listing.errors.isEmpty)
        #expect(Set(listing.versions.map(\.id)).count == 2)
        #expect(try Data(contentsOf: source) == sourceBytes)
    }


    @Test func firstAndRepeatedSavesKeepWorkingVersionIdentityAndName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensWorksFreshSave-\(UUID())")
        let catalog = root.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = root.appendingPathComponent("Source.png")
        try FileManager.default.copyItem(at: fixture, to: source)
        let keys = ["LensWorks.workingVersions", "LensWorks.lastWorkingVersion"]
        let previous = keys.map { LensWorksUserState.defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { LensWorksUserState.defaults.set(value, forKey: key) } }
        let session = EditorSession()
        await session.importImages([source])
        let layer = try #require(session.activeLayerID)
        let controller = ProjectController(session: session)
        let project = root.appendingPathComponent("Source – Edit.comp")
        let version = LensWorksWorkingVersion(id: UUID(), photoID: UUID().uuidString, catalogPath: catalog.path,
            originalPath: source.path, projectPath: project.path, name: "Source – Edit")
        controller.workingVersion = version
        session.projectURL = project
        #expect(await controller.save())
        #expect(controller.workingVersion?.id == version.id)
        #expect(controller.workingVersion?.name == version.name)
        session.renameLayer(layer, to: "First ordinary edit")
        #expect(await controller.save())
        #expect(controller.workingVersion?.id == version.id)
        #expect(controller.workingVersion?.name == version.name)
        session.setLayerOpacity(0.6)
        #expect(await controller.save())
        let persisted = try #require(try await LensWorksVersionStore.shared.read(project))
        #expect(persisted.id == version.id)
        #expect(persisted.name == version.name)
    }

}
