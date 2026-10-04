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
    var nativeOriginal: LWCatalogNativePath? = nil
    var key: LWCatalogEditsVariantKey? = nil
    var locationError: String? = nil
    enum CodingKeys: String, CodingKey {
        case sequence, id, state
        case originalPath = "original_path", previewPath = "preview_path"
    }
    var filename: String { URL(fileURLWithPath: originalPath).lastPathComponent }
    var originalURL: URL { get throws {
        if let nativeOriginal { return try nativeOriginal.localFileURL() }
        guard key == nil else { throw LensWorksCatalogError.message(locationError ?? "The original needs an explicit native location before editing.") }
        return URL(fileURLWithPath: originalPath)
    } }
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
    var has_more: Bool = false
}
nonisolated struct LensWorksImportReport: Decodable, Sendable {
    let imported: Int; let unchanged: Int; let failed: Int; let skipped: Int; let stopped: Bool
}

/// The native client owns one managed worker session and retires it before a catalog switch.
actor LensWorksCatalogService {
    private var session: LWManagedSession?
    private var catalogToken: String?
    private var cursors: [Int64: String] = [:]
    private var currentPath: String?
    private var creation: Task<LWManagedSession, any Error>?
    private var switching = false
    private var generation: UInt64 = 0
    private let configuration: LWManagedSessionConfig?
    init(configuration: LWManagedSessionConfig? = nil) { self.configuration = configuration }

    private func configured() throws -> LWManagedSessionConfig {
        if let configuration { return configuration }
        // Test hosts supply an explicit built fixture; production always uses signed bundle helpers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           let path = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"] {
            let native = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: path))
            return LWManagedSessionConfig(worker_executable: native, decode_worker_executable: native, cache_root: nil, original_roots: [], limits: nil, preview_policy: nil, preview_limits: nil)
        }
        return try LWManagedSessionConfig.installed(originalRoots: [])
    }
    func close() async throws {
        generation &+= 1
        if let creation {
            do { session = try await creation.value } catch { self.creation = nil; throw error }
            self.creation = nil
        }
        if let session { try await session.close() }
        session = nil; catalogToken = nil; currentPath = nil; cursors = [:]
    }
    func managedRequest(_ request: LWApplicationRequest) async throws -> LWApplicationResponse {
        guard let session else { throw LensWorksManagedError.closed }
        return try await session.perform(request)
    }
    private func cast<Value: Sendable, Result: Sendable>(_ value: Value, as: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw LensWorksManagedError.protocolViolation("The catalog client expected a different result type.") }
        return result
    }
    func request<Result: Decodable & Sendable>(_ request: LensWorksCatalogRequest, as: Result.Type) async throws -> Result {
        switch request.op {
        case "create", "open":
            guard !switching else { throw LensWorksManagedError.native(code: "busy", message: "A catalog switch is already running.") }
            switching = true; defer { switching = false }
            try await close()
            let admittedGeneration = generation
            let path = URL(fileURLWithPath: request.catalog_path)
            if request.op == "create", FileManager.default.fileExists(atPath: path.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty else { throw LensWorksCatalogError.message("Choose an empty folder for the new catalog.") }
                try FileManager.default.removeItem(at: path)
            }
            let config = try configured()
            let creating = Task { try await LWManagedSession.create(config: config) }
            creation = creating
            LensWorksLaunchTrace.record("catalog.client.sessionCreate.begin")
            let owner = try await creating.value
            LensWorksLaunchTrace.record("catalog.client.sessionCreate.end")
            guard admittedGeneration == generation else {
                // A concurrent checked Quit/close owns retirement of this startup task.
                throw CancellationError()
            }
            creation = nil
            session = owner
            do {
                let native = try LWCatalogNativePath(fileURL: path)
                LensWorksLaunchTrace.record("catalog.client.open.begin", details: ["operation": request.op])
                let opened = try await owner.perform(request.op == "create" ? .Create(path: native) : .OpenExisting(path: native))
                LensWorksLaunchTrace.record("catalog.client.open.end")
                guard case .Status(let status) = opened, let token = status.catalog else { throw LensWorksManagedError.protocolViolation("Catalog admission did not return a catalog identity.") }
                catalogToken = token
                try await ready(owner)
                LensWorksLaunchTrace.record("catalog.client.ready")
                let canonical = path.resolvingSymlinksInPath().standardizedFileURL.path
                currentPath = canonical
                return try cast(LensWorksCatalogLocation(catalog_path: canonical), as: Result.self)
            } catch { try? await close(); throw error }
        case "list":
            guard let session, let catalogToken, currentPath == URL(fileURLWithPath: request.catalog_path).resolvingSymlinksInPath().standardizedFileURL.path else { throw LensWorksManagedError.closed }
            let after = request.after ?? 0
            guard after == 0 || cursors[after] != nil else { throw LensWorksManagedError.protocolViolation("The catalog page cursor is no longer available.") }
            let response = try await session.perform(.Images(catalog: catalogToken, folder: nil, recursive: true, text: nil, cursor: cursors[after], limit: UInt16(min(100, max(1, request.limit ?? 100)))))
            guard case .Images(let rows, let next, let hasMore, _, _) = response else { throw LensWorksManagedError.protocolViolation("Expected a catalog image page.") }
            var assets: [LensWorksCatalogAsset] = []
            for row in rows {
                do {
                    let path = try await original(session: session, catalog: catalogToken, key: row.key)
                    let display = (try? path.localFileURL().path) ?? row.filename
                    assets.append(LensWorksCatalogAsset(sequence: row.sequence.value, id: row.key.asset_id, originalPath: display, state: row.state, previewPath: nil, nativeOriginal: path, key: row.key))
                } catch {
                    assets.append(LensWorksCatalogAsset(sequence: row.sequence.value, id: row.key.asset_id, originalPath: row.filename, state: row.state, previewPath: nil, key: row.key, locationError: error.localizedDescription))
                }
            }
            let last = rows.last?.sequence.value ?? after
            if let next { cursors[last] = next }
            return try cast(LensWorksCatalogPage(assets: assets, next_after: last, has_more: hasMore), as: Result.self)
        case "import":
            guard let session, let catalogToken, let source = request.source_path else { throw LensWorksManagedError.closed }
            let response = try await session.perform(.ImportStart(catalog: catalogToken, source: LWCatalogNativePath(fileURL: URL(fileURLWithPath: source))))
            guard case .Import(let started) = response, let started else { throw LensWorksManagedError.protocolViolation("Import did not return an owned operation.") }
            let state = try await withTaskCancellationHandler {
                var state = started
                while [.Discovering, .Draining, .CancelRequested].contains(state.phase) {
                    try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(25))
                    guard case .Import(let next) = try await session.perform(.ImportStatus(catalog: catalogToken)), let next, next.id == started.id else { throw LensWorksManagedError.protocolViolation("The active import identity changed.") }
                    state = next
                }
                return state
            } onCancel: {
                Task { _ = try? await session.perform(.ImportCancel(catalog: catalogToken, import: started.id)) }
            }
            if state.phase == .Failed { throw LensWorksCatalogError.message(state.error ?? "Photo import failed.") }
            let values = [state.imported.value, state.unchanged.value, state.failed.value, state.skipped.value]
            guard values.allSatisfy({ Int(exactly: $0) != nil }) else { throw LensWorksManagedError.protocolViolation("Import counters exceed the local presentation range.") }
            return try cast(LensWorksImportReport(imported: Int(values[0]), unchanged: Int(values[1]), failed: Int(values[2]), skipped: Int(values[3]), stopped: state.phase == .Canceled), as: Result.self)
        default: throw LensWorksManagedError.protocolViolation("Unknown native catalog operation.")
        }
    }
    private func ready(_ session: LWManagedSession) async throws {
        while true {
            guard case .Status(let state) = try await session.perform(.Status) else { throw LensWorksManagedError.protocolViolation("Expected catalog status.") }
            if state.phase == .Ready { return }
            if [.Failed, .Closed].contains(state.phase) { throw LensWorksCatalogError.message(state.message ?? "Catalog indexing failed.") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func original(session: LWManagedSession, catalog: String, key: LWCatalogEditsVariantKey) async throws -> LWCatalogNativePath {
        var response = try await session.perform(.Relink(catalog: catalog, request: .Original(key: key)))
        while true {
            guard case .Relink(.Operation(let operation)) = response, let operation else { throw LensWorksManagedError.protocolViolation("Expected an original-location operation.") }
            if case .Original(let original) = operation.result {
                switch original.status.current {
                case .Native(let path): return path
                case .LegacyUnix(let units): return .unixBytes(units)
                case .LegacyWindows(let units): return .windowsWide(units)
                case .Unspecified: throw LensWorksCatalogError.message("The original needs an explicit native location before editing.")
                }
            }
            if [.Failed, .Canceled].contains(operation.phase) { throw LensWorksCatalogError.message(operation.error ?? "The original location could not be observed.") }
            try await Task.sleep(for: .milliseconds(10))
            response = try await session.perform(.Relink(catalog: catalog, request: .Status(operation: operation.id)))
        }
    }
    func thumbnail(_ asset: LensWorksCatalogAsset) async -> Data? {
        guard let session, let catalogToken, let key = asset.key else { return nil }
        do {
            let response = try await session.perform(.Preview(catalog: catalogToken, key: key, tier: .Thumbnail, interactive: false, viewport: "filmstrip-" + asset.id, generation: LWCatalogU64(1), foreground: true, diagnostics: false))
            guard case .Preview(let initial) = response else { return nil }
            var status = initial
            while [.Queued, .CancelRequested].contains(status.state) {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(25))
                guard case .Preview(let next) = try await session.perform(.PreviewStatus(catalog: catalogToken, ticket: initial.ticket)) else { return nil }
                status = next
            }
            guard status.state == .Ready else { return nil }
            let job = try await session.preview(catalog: catalogToken, ticket: status.ticket, foreground: true)
            do {
                let result = try await job.wait(); defer { result.buffer.release() }
                let data = try await result.buffer.copy(maximumBytes: 8 * 1024 * 1024, expectedLength: result.length)
                try await job.close(); return data
            } catch { try? await job.close(); throw error }
        } catch { return nil }
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
            status = "Added \(report.imported), unchanged \(report.unchanged), skipped \(report.skipped), failed \(report.failed)" + (report.stopped ? ". Import canceled." : "")
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
        hasMore = page.has_more
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
        // RAW development remains a live source operation, never an import-time raster handoff.
        let rasterTypes = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif"]
        guard rasterTypes.contains(URL(fileURLWithPath: asset.originalPath).pathExtension.lowercased()) else {
            error = "Live RAW editing is not available in this build."
            return
        }
        guard await LensWorksVersionStore.shared.sourceAvailable(asset.originalPath, native: asset.nativeOriginal) else { error = "The original photo is offline. Reconnect its location before creating a working version."; return }
        guard workspace.canSwitch else { error = "Finish the current edit before creating a working version."; return }
        let originalURL: URL
        do { originalURL = try asset.originalURL } catch { self.error = error.localizedDescription; return }
        let tab = workspace.addTab()
        await tab.session.importImages([originalURL])
        guard tab.session.document != nil else { error = tab.session.importError ?? "The photo could not be opened."; return }
        let id = UUID()
        let name = URL(fileURLWithPath: asset.originalPath).deletingPathExtension().lastPathComponent + " – Edit"
        let project = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name)-\(id.uuidString.prefix(8)).comp")
        tab.controller.workingVersion = LensWorksWorkingVersion(id: id, photoID: asset.id, catalogPath: catalogPath, originalPath: asset.originalPath, projectPath: project.path, name: name, originalNativePath: asset.nativeOriginal)
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

    func close() async throws { try await service.close() }

    func thumbnail(_ asset: LensWorksCatalogAsset) async -> Data? { await service.thumbnail(asset) }

    func refreshVersions() async {
        let listing = await LensWorksVersionStore.shared.list(paths: UserDefaults.standard.stringArray(forKey: "LensWorks.workingVersions") ?? [], directory: outputDirectory)
        versions = listing.versions
        if !listing.errors.isEmpty {
            error = "Some working versions could not be read. Their files have been left unchanged.\n\n" + listing.errors.prefix(3).joined(separator: "\n\n")
        }
    }

    func restore(workspace: ProjectWorkspace) async {
        LensWorksLaunchTrace.record("catalog.restore.begin", details: ["alreadyRestored": String(restored)])
        guard !restored else { return }; restored = true
        defer { LensWorksLaunchTrace.record("catalog.restore.end", details: ["canceled": String(Task.isCancelled)]) }
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let explicitAutomation = arguments.contains { $0.hasPrefix("--lensworks-") }
        if !explicitAutomation, NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        outputDirectory = UserDefaults.standard.string(forKey: "LensWorks.outputDirectory")
        if let output = value("--lensworks-output") {
            LensWorksLaunchTrace.record("catalog.restore.setOutput.begin")
            await setOutput(output)
            LensWorksLaunchTrace.record("catalog.restore.setOutput.end")
        }
        if let path = value("--lensworks-catalog") {
            LensWorksLaunchTrace.record("catalog.restore.connect.begin")
            await connect(path, create: arguments.contains("--lensworks-create-catalog"))
            LensWorksLaunchTrace.record("catalog.restore.connect.end", details: ["connected": String(catalogPath != nil), "error": error ?? ""])
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
