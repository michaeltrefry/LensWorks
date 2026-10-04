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
        let version = LensWorksWorkingVersion(id: UUID(), photoID: asset.id, catalogPath: catalogURL.path, originalPath: source.path, projectPath: project.path, name: "Working version")
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
        let previousCatalog = UserDefaults.standard.string(forKey: "LensWorks.catalogPath")
        defer { UserDefaults.standard.set(previousCatalog, forKey: "LensWorks.catalogPath") }
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
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
        let catalog = LensWorksCatalog()
        await catalog.connect(catalogURL.path, create: true)
        await catalog.importFolder(media.path)
        let asset = try #require(catalog.selectedAsset)
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let healthy = media.appendingPathComponent("Healthy.comp"), corrupt = media.appendingPathComponent("Corrupt.comp")
        let version = LensWorksWorkingVersion(id: UUID(), photoID: asset.id, catalogPath: try #require(catalog.catalogPath),
            originalPath: source.path, projectPath: healthy.path, name: "Healthy")
        try await ProjectStore.shared.save(snapshot, to: healthy, workingVersion: version)
        try await ProjectStore.shared.save(snapshot, to: corrupt, workingVersion: version)
        try FileManager.default.removeItem(at: corrupt.appendingPathComponent("LensWorks.json"))
        UserDefaults.standard.set([healthy.path, corrupt.path], forKey: "LensWorks.workingVersions")
        await catalog.connect(catalogURL.path)
        #expect(catalog.catalogPath != nil)
        #expect(catalog.assets.count == 1)
        #expect(catalog.selectedAsset?.id == asset.id)
        #expect(catalog.versions.count == 1)
        #expect(catalog.versions.first?.projectPath == healthy.path)
        #expect(catalog.error?.contains("Corrupt.comp") == true)
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
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
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

}
