import AppKit
import Observation
import ImageIO

nonisolated enum LensWorksCatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

nonisolated struct LensWorksCatalogAsset: Decodable, Sendable, Identifiable {
    let sequence: Int64
    let id: String
    let originalPath: String
    let state: String
    let previewPath: String?
    enum CodingKeys: String, CodingKey {
        case sequence, id, state
        case originalPath = "original_path", previewPath = "preview_path"
    }
    var filename: String { URL(fileURLWithPath: originalPath).lastPathComponent }
}

nonisolated struct LensWorksCatalogRequest: Encodable, Sendable {
    let version = 1
    let op: String
    let catalog_path: String
    var source_path: String? = nil
    var after: Int64? = nil
    var limit: Int? = nil
    var max_files: Int? = nil
}

nonisolated struct LensWorksCatalogReply<Result: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Result?
    let error: Failure?
    struct Failure: Decodable, Sendable { let code: String; let message: String }
}
nonisolated struct LensWorksCatalogLocation: Decodable, Sendable { let catalog_path: String }
nonisolated struct LensWorksCatalogPage: Decodable, Sendable {
    let assets: [LensWorksCatalogAsset]
    let next_after: Int64
}
nonisolated struct LensWorksImportReport: Decodable, Sendable {
    let imported: Int; let unchanged: Int; let failed: Int; let skipped: Int; let stopped: Bool
}

/// SQLite, scanning, metadata decoding and JSON run on a dedicated background executor.
actor LensWorksCatalogService {
    func request<Result: Decodable & Sendable>(_ request: LensWorksCatalogRequest, as: Result.Type) throws -> Result {
        let input = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let output = try input.withCString { bytes -> Data in
            guard let pointer = lw_catalog_request(bytes) else {
                throw LensWorksCatalogError.message("The catalog service returned no response.")
            }
            defer { lw_catalog_string_free(pointer) }
            return Data(String(cString: pointer).utf8)
        }
        let reply = try JSONDecoder().decode(LensWorksCatalogReply<Result>.self, from: output)
        guard reply.ok, let result = reply.result else {
            throw LensWorksCatalogError.message(reply.error?.message ?? "The catalog operation failed.")
        }
        return result
    }
}

@MainActor @Observable
final class LensWorksCatalog {
    private(set) var catalogPath: String?
    private(set) var assets: [LensWorksCatalogAsset] = []
    private(set) var versions: [LensWorksWorkingVersion] = []
    var selectedPhotoID: String?
    private(set) var outputDirectory: String?
    private(set) var isBusy = false
    private(set) var hasMore = false
    private(set) var pageStart: Int64 = 0
    @ObservationIgnored private var previousPages: [Int64] = []
    var hasPrevious: Bool { !previousPages.isEmpty }
    var error: String?
    var status = "Open or create a catalog to begin."
    @ObservationIgnored private let service = LensWorksCatalogService()
    @ObservationIgnored private var restored = false
    var selectedAsset: LensWorksCatalogAsset? { assets.first { $0.id == selectedPhotoID } }
    var selectedVersions: [LensWorksWorkingVersion] { versions.filter { $0.photoID == selectedPhotoID && $0.catalogPath == catalogPath } }

    func openCatalog(create: Bool, window: NSWindow?) async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = create
        panel.prompt = create ? "Create Catalog" : "Open Catalog"
        panel.message = create ? "Choose an empty folder for the catalog database and previews. Your photos stay in their existing folders." : "Choose an existing PhotoCatalog or LensWorks catalog folder."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        await connect(url.path, create: create)
    }

    func connect(_ path: String, create: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        // Clear the old identity before any operation can expose the new catalog.
        catalogPath = nil; assets = []; versions = []; selectedPhotoID = nil
        hasMore = false; pageStart = 0; previousPages = []
        error = nil
        do {
            let result = try await service.request(LensWorksCatalogRequest(op: create ? "create" : "open", catalog_path: path), as: LensWorksCatalogLocation.self)
            catalogPath = result.catalog_path
            if let outputDirectory {
                do { _ = try await LensWorksVersionStore.shared.canonicalPath(outputDirectory, outside: catalogPath) }
                catch {
                    self.outputDirectory = nil
                    UserDefaults.standard.removeObject(forKey: "LensWorks.outputDirectory")
                    self.error = error.localizedDescription
                }
            }
            UserDefaults.standard.set(catalogPath, forKey: "LensWorks.catalogPath")
            try await refreshAssets()
            await refreshVersions()
            status = "Showing \(assets.count) photos"
        } catch {
            catalogPath = nil; assets = []; versions = []; selectedPhotoID = nil
            hasMore = false; pageStart = 0; previousPages = []
            self.error = error.localizedDescription
        }
    }

    func importFolder(window: NSWindow?) async {
        guard catalogPath != nil, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Add Photos"; panel.message = "Register photos in this folder. Original files stay in place."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        await importFolder(url.path)
    }

    func importFolder(_ path: String) async {
        guard let catalogPath, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let report = try await service.request(LensWorksCatalogRequest(op: "import", catalog_path: catalogPath, source_path: path, max_files: 1000), as: LensWorksImportReport.self)
            try await refreshAssets()
            status = "Added \(report.imported), unchanged \(report.unchanged), skipped \(report.skipped), failed \(report.failed)" + (report.stopped ? ". Import stopped at the 1,000-file limit for this build." : "")
        } catch { self.error = error.localizedDescription }
    }

    private func refreshAssets() async throws {
        previousPages = []
        try await loadPage(after: 0)
    }

    private func loadPage(after: Int64) async throws {
        guard let catalogPath else { return }
        let page = try await service.request(LensWorksCatalogRequest(op: "list", catalog_path: catalogPath, after: after, limit: 101), as: LensWorksCatalogPage.self)
        // Keep a single bounded window, including on catalogs with millions of photos.
        assets = Array(page.assets.prefix(100))
        hasMore = page.assets.count > 100
        pageStart = after
        if !assets.contains(where: { $0.id == selectedPhotoID }) { selectedPhotoID = assets.first?.id }
    }

    func nextPage() async {
        guard hasMore, !isBusy, let last = assets.last else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let previous = pageStart
            try await loadPage(after: last.sequence)
            previousPages.append(previous)
        } catch { self.error = error.localizedDescription }
    }

    func previousPage() async {
        guard !isBusy, let previous = previousPages.last else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await loadPage(after: previous)
            previousPages.removeLast()
        } catch { self.error = error.localizedDescription }
    }

    func chooseOutput(window: NSWindow?) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use Folder"; panel.message = "Choose the filesystem folder for your editable working versions."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        await setOutput(url.path)
    }

    func setOutput(_ path: String) async {
        do {
            outputDirectory = try await LensWorksVersionStore.shared.canonicalPath(path, outside: catalogPath)
            UserDefaults.standard.set(outputDirectory, forKey: "LensWorks.outputDirectory")
            await refreshVersions()
        } catch { self.error = error.localizedDescription }
    }

    func createWorkingVersion(workspace: ProjectWorkspace) async {
        guard let asset = selectedAsset, let catalogPath, !isBusy, workspace.canSwitch else { return }
        isBusy = true; defer { isBusy = false }
        if outputDirectory == nil { await chooseOutput(window: workspace.window) }
        guard let outputDirectory else { return }
        do { _ = try await LensWorksVersionStore.shared.canonicalPath(outputDirectory, outside: catalogPath) }
        catch { self.error = error.localizedDescription; return }
        // RAW remains for the live-input slice. S01 must never silently develop it on import.
        let rasterTypes = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif"]
        guard rasterTypes.contains(URL(fileURLWithPath: asset.originalPath).pathExtension.lowercased()) else {
            error = "Live RAW editing is not available in this build."
            return
        }
        guard await LensWorksVersionStore.shared.sourceAvailable(asset.originalPath) else { error = "The original photo is offline. Reconnect its location before creating a working version."; return }
        guard workspace.canSwitch else { error = "Finish the current edit before creating a working version."; return }
        let tab = workspace.addTab()
        await tab.session.importImages([URL(fileURLWithPath: asset.originalPath)])
        guard tab.session.document != nil else { error = tab.session.importError ?? "The photo could not be opened."; return }
        let id = UUID()
        let name = URL(fileURLWithPath: asset.originalPath).deletingPathExtension().lastPathComponent + " – Edit"
        let project = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name)-\(id.uuidString.prefix(8)).comp")
        tab.controller.workingVersion = LensWorksWorkingVersion(id: id, photoID: asset.id, catalogPath: catalogPath, originalPath: asset.originalPath, projectPath: project.path, name: name)
        tab.session.projectURL = project
        guard await tab.controller.save() else { error = "The working version could not be saved."; return }
        noteSaved(project)
        await refreshVersions()
    }

    func openVersion(_ version: LensWorksWorkingVersion, workspace: ProjectWorkspace) async {
        guard !isBusy, workspace.canSwitch else { return }
        isBusy = true; defer { isBusy = false }
        if await workspace.open(URL(fileURLWithPath: version.projectPath)) {
            selectedPhotoID = version.photoID
            UserDefaults.standard.set(version.projectPath, forKey: "LensWorks.lastWorkingVersion")
        }
    }

    func noteSaved(_ project: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "LensWorks.workingVersions") ?? []
        if !paths.contains(project.path) { paths.append(project.path) }
        UserDefaults.standard.set(paths, forKey: "LensWorks.workingVersions")
        UserDefaults.standard.set(project.path, forKey: "LensWorks.lastWorkingVersion")
    }

    func refreshVersions() async {
        let listing = await LensWorksVersionStore.shared.list(paths: UserDefaults.standard.stringArray(forKey: "LensWorks.workingVersions") ?? [], directory: outputDirectory)
        versions = listing.versions
        if !listing.errors.isEmpty {
            error = "Some working versions could not be read. Their files have been left unchanged.\n\n" + listing.errors.prefix(3).joined(separator: "\n\n")
        }
    }

    func restore(workspace: ProjectWorkspace) async {
        guard !restored else { return }; restored = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let explicitAutomation = arguments.contains { $0.hasPrefix("--lensworks-") }
        if !explicitAutomation, NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        outputDirectory = UserDefaults.standard.string(forKey: "LensWorks.outputDirectory")
        if let output = value("--lensworks-output") { await setOutput(output) }
        if let path = value("--lensworks-catalog") {
            await connect(path, create: arguments.contains("--lensworks-create-catalog"))
        } else if let path = UserDefaults.standard.string(forKey: "LensWorks.catalogPath") { await connect(path) }
        if let folder = value("--lensworks-import") { await importFolder(folder) }
        if arguments.contains("--lensworks-create-version") { await createWorkingVersion(workspace: workspace) }
        else if let path = UserDefaults.standard.string(forKey: "LensWorks.lastWorkingVersion"), workspace.current.session.document == nil {
            do {
                let project = URL(fileURLWithPath: path)
                if let version = try await LensWorksVersionStore.shared.readIfExists(project), version.catalogPath == catalogPath {
                    _ = await workspace.open(project)
                    selectedPhotoID = version.photoID
                }
            } catch { self.error = error.localizedDescription }
        }
        if let name = value("--lensworks-edit-name"), let layer = workspace.current.session.activeLayerID {
            workspace.current.session.renameLayer(layer, to: name)
            _ = await workspace.current.controller.save()
        }
        if let value = value("--lensworks-edit-opacity") {
            if let opacity = Double(value), opacity.isFinite, (0...1).contains(opacity), workspace.current.session.activeLayerID != nil {
                workspace.current.session.setLayerOpacity(opacity)
                _ = await workspace.current.controller.save()
            } else { error = "The layer opacity must be a number from 0 to 1, with a working version open." }
        }
        if let path = value("--lensworks-evidence") {
            let session = workspace.current.session
            let evidence: [String: Any] = ["catalogPath": catalogPath ?? "", "assetCount": assets.count,
                "versionID": workspace.current.controller.workingVersion?.id.uuidString ?? "", "photoID": workspace.current.controller.workingVersion?.photoID ?? "",
                "sourcePath": workspace.current.controller.workingVersion?.originalPath ?? "", "projectPath": session.projectURL?.path ?? "",
                "documentID": session.document?.id.uuidString ?? "", "layerIDs": session.document?.layers.map { $0.id.uuidString } ?? [],
                "layerNames": session.document?.layers.map(\.name) ?? [], "layerOpacities": session.document?.layers.map(\.opacity) ?? [], "modified": session.isModified, "error": error ?? ""]
            do { try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
        if arguments.contains("--lensworks-quit") {
            // Let this Swift task release the main actor before AppKit waits for the asynchronous quit reply.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }
}
