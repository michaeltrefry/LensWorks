import AppKit
import Observation
import ImageIO

nonisolated enum LensWorksCatalogError: LocalizedError {
    case message(String)
    case importObservationTimeout(LWApplicationDtoImportStatus)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .importObservationTimeout(let status):
            "Import \(status.id) remains \(status.phase.rawValue) · added \(status.imported.value) · unchanged \(status.unchanged.value) · failed \(status.failed.value) · awaiting resources \(status.awaiting_resources.value) · pending previews \(status.pending_previews). Its source and operation identity are retained."
        }
    }
}

nonisolated struct LensWorksCatalogAsset: Decodable, Sendable, Identifiable {
    let sequence: Int64
    let id: String
    var originalPath: String
    let state: String
    let previewPath: String?
    var nativeOriginal: LWCatalogNativePath? = nil
    var key: LWCatalogEditsVariantKey? = nil
    var locationError: String? = nil
    var displayFilename: String? = nil
    var metadataRevision: Int64 = 0
    var origin = "native"
    var translationState = "native"
    var rating: Int64? = nil
    var photoID: String { key?.asset_id ?? id }
    enum CodingKeys: String, CodingKey {
        case sequence, id, state
        case originalPath = "original_path", previewPath = "preview_path"
    }
    var filename: String { displayFilename ?? URL(fileURLWithPath: originalPath).lastPathComponent }
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

#if DEBUG
nonisolated enum LensWorksCatalogCloseFaultPoint: Sendable, Equatable { case beforeSubmit, beforeDecode, beforeRelease }
nonisolated enum LensWorksPreviewDrainFaultPoint: Sendable, Equatable { case afterSubmit, beforeDecode, beforeRelease }
nonisolated enum LensWorksCatalogContinuationPoint: Sendable, Equatable { case groupRead, membershipIdentity, importMonitorTerminal, settingsStatus, catalogRecipeAdmission, catalogRecipeReply, originalResolved }
@MainActor private final class LensWorksImportMonitorReceipt { var complete = false }
#endif

/// Only this service file can mint proof after the native Close reply and job
/// release. The fixed pool must match both the session object and catalog token.
nonisolated struct LensWorksCheckedPreviewCatalogClose: Sendable {
    private let session: LWManagedSession
    private let catalog: String
    fileprivate init(session: LWManagedSession, catalog: String) { self.session = session; self.catalog = catalog }
    func matches(session: LWManagedSession, catalog: String) -> Bool { self.session === session && self.catalog == catalog }
}

/// The native client owns one managed worker session and retires it before a catalog switch.
actor LensWorksCatalogService {
    private var session: LWManagedSession?
    private var catalogToken: String?
    private var cursors: [Int64: String] = [:]
    private var previews: LensWorksPreviewStore?
    private var currentPath: String?
    private var creation: Task<LWManagedSession, any Error>?
    private var creationReceipt: Result<LWManagedSession, any Error>?
    private var switching = false
    private var closeInFlight = false
    private var catalogCloseJob: LWManagedJob?
    private var catalogCloseOutcome: Result<Void, any Error>?
    private var catalogCloseResult: LWManagedResult?
    private var catalogCloseIsStatusProbe = false
    private var retirementRequested = false
    private var nativeAdmissionInFlight = false
    private var catalogAdmissionAttempted = false
    #if DEBUG
    private let closeFault: (@Sendable (LensWorksCatalogCloseFaultPoint) throws -> Void)?
    #endif
    private var catalogClosed = false
    private var generation: UInt64 = 0
    private let configuration: LWManagedSessionConfig?
    private var rowLimit: UInt16 { min(100, configuration?.limits?.page_rows ?? 100) }
    #if DEBUG
    init(configuration: LWManagedSessionConfig? = nil, closeFault: (@Sendable (LensWorksCatalogCloseFaultPoint) throws -> Void)? = nil) { self.configuration = configuration; self.closeFault = closeFault }
    #else
    init(configuration: LWManagedSessionConfig? = nil) { self.configuration = configuration }
    #endif

    private func configured() throws -> LWManagedSessionConfig {
        if let configuration { return configuration }
        // Test hosts supply an explicit built fixture; production always uses signed bundle helpers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           let path = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"] {
            let native = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: path))
            let decode = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["LW_CATALOG_TEST_DECODE_WORKER"] ?? path))
            return LWManagedSessionConfig(worker_executable: native, decode_worker_executable: decode, cache_root: nil, original_roots: [], limits: nil, preview_policy: nil, preview_limits: nil)
        }
        return try LWManagedSessionConfig.installed(originalRoots: [])
    }
    /// Public/local-producer retirement shares a 60-second observation budget,
    /// followed by the existing 30-second global session shutdown. Pending startup
    /// returns immediately with its owned task retained; it is never awaited here.
    func beginRetirement() { retirementRequested = true; generation &+= 1 }
    func close(retirementTimeoutMilliseconds: UInt32 = 60000) async throws {
        guard retirementTimeoutMilliseconds > 0, retirementTimeoutMilliseconds <= 60000 else { throw LensWorksManagedError.protocolViolation("Catalog retirement observation exceeds 60 seconds.") }
        guard !closeInFlight else { throw LensWorksManagedError.native(code: "busy", message: "Catalog retirement is already being observed.") }
        retirementRequested = true
        closeInFlight = true; defer { closeInFlight = false }
        generation &+= 1
        let retirementDeadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(retirementTimeoutMilliseconds)))
        if creation != nil {
            guard let receipt = creationReceipt else { throw LensWorksManagedError.native(code: "draining", message: "Catalog startup is still owned. Retry checked retirement after its completion receipt arrives.") }
            self.creation = nil; creationReceipt = nil
            if session == nil { session = try receipt.get() }
        }
        if let previews { await previews.setAdmission(false); await previews.cancelAll() }
        guard !nativeAdmissionInFlight else { throw LensWorksManagedError.native(code: "draining", message: "Catalog admission is still owned. Its native completion must be observed before retirement.") }
        if let session {
            // A failed/lost Open reply can still own a native cleanup token. Recover it
            // through a bounded real Status job while the desktop relay is Ready.
            let needsStatus = catalogAdmissionAttempted && catalogToken == nil && !catalogClosed
            var skipCatalogRPC = false
            if needsStatus { skipCatalogRPC = try await session.status().phase != .ready }
            // Failed startup/transport has no usable catalog RPC relay. Its checked
            // global teardown remains the only authority; this is not a Closed receipt.
            while (!catalogClosed && !skipCatalogRPC) || catalogCloseJob != nil {
                if catalogCloseJob == nil {
                    catalogCloseOutcome = nil
                    catalogCloseIsStatusProbe = catalogToken == nil
                    if catalogCloseIsStatusProbe && !catalogAdmissionAttempted { catalogClosed = true; break }
                    #if DEBUG
                    try closeFault?(.beforeSubmit)
                    #endif
                    catalogCloseJob = try await session.submit(catalogCloseIsStatusProbe ? .Status : .Close(catalog: catalogToken!))
                }
                guard let job = catalogCloseJob else { throw LensWorksManagedError.protocolViolation("Catalog retirement authority was not retained.") }
                while try await job.status().phase == .pending {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < retirementDeadline else { throw LensWorksManagedError.native(code: "draining", message: "Catalog retirement is still running. Its job, session, and source authority are retained for retry.") }
                    try await Task.sleep(for: min(.milliseconds(25), ContinuousClock.now.duration(to: retirementDeadline)))
                }
                if catalogCloseOutcome == nil || catalogCloseResult != nil {
                    // Successful take is stored immediately. Decoder/copy faults retain
                    // these actual bytes and the taken job; retry never takes again.
                    if catalogCloseResult == nil { catalogCloseResult = try await job.takeResult() }
                    guard let result = catalogCloseResult else { throw LensWorksManagedError.protocolViolation("Catalog retirement lost its owned result.") }
                    do {
                        #if DEBUG
                        try closeFault?(.beforeDecode)
                        #endif
                        let reply = try await result.decode(LWApplicationReply.self)
                        switch reply {
                        case .Ok(.Status(let status)):
                            if catalogCloseIsStatusProbe, let token = status.catalog {
                                catalogToken = token
                            } else {
                                let failedAdmissionRetired = catalogCloseIsStatusProbe && catalogAdmissionAttempted && status.phase == .Failed && status.catalog == nil
                                guard (status.phase == .Closed && status.catalog == nil) || failedAdmissionRetired else { throw LensWorksManagedError.protocolViolation("Catalog retirement did not return a verified Closed status or completed failed-admission cleanup.") }
                                catalogClosed = true
                            }
                            catalogCloseOutcome = .success(())
                        case .Error(let fault): catalogCloseOutcome = .failure(LensWorksManagedError.native(code: fault.code.rawValue, message: fault.message))
                        default: throw LensWorksManagedError.protocolViolation("Catalog retirement returned an unexpected response.")
                        }
                        result.buffer.release(); catalogCloseResult = nil
                    } catch {
                        catalogCloseOutcome = .failure(error)
                        throw error
                    }
                }
                #if DEBUG
                try closeFault?(.beforeRelease)
                #endif
                try await job.close()
                catalogCloseJob = nil
                guard let outcome = catalogCloseOutcome else { throw LensWorksManagedError.protocolViolation("Catalog retirement lost its terminal outcome.") }
                catalogCloseOutcome = nil
                try outcome.get()
            }
            if let previews {
                let remaining = ContinuousClock.now.duration(to: retirementDeadline).components
                let milliseconds = remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
                guard milliseconds > 0 else { throw LensWorksManagedError.native(code: "draining", message: "Local preview retirement still needs observation. The closed catalog and session remain owned for retry.") }
                let timeout = UInt32(clamping: min(milliseconds, 60000))
                if catalogClosed {
                    guard catalogCloseJob == nil, let catalogToken else { throw LensWorksManagedError.protocolViolation("Closed preview cleanup lacks its released catalog-close job or exact token.") }
                    try await previews.drain(afterCheckedCatalogClose: LensWorksCheckedPreviewCatalogClose(session: session, catalog: catalogToken), timeoutMilliseconds: timeout)
                } else {
                    try await previews.drain(timeoutMilliseconds: timeout)
                }
            }
            try await session.close()
        }
        previews = nil
        session = nil; catalogToken = nil; currentPath = nil; cursors = [:]
        catalogClosed = false; catalogCloseOutcome = nil; catalogAdmissionAttempted = false; retirementRequested = false
    }
    func managedRequest(_ request: LWApplicationRequest) async throws -> LWApplicationResponse {
        try ordinaryAdmission()
        guard let session else { throw LensWorksManagedError.closed }
        return try await session.perform(request)
    }
    private func cast<Value: Sendable, Result: Sendable>(_ value: Value, as: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw LensWorksManagedError.protocolViolation("The catalog client expected a different result type.") }
        return result
    }
    func request<Result: Decodable & Sendable>(_ request: LensWorksCatalogRequest, as: Result.Type) async throws -> Result {
        if !["create", "open"].contains(request.op) { try ordinaryAdmission() }
        switch request.op {
        case "create", "open":
            try ordinaryAdmission()
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
            creationReceipt = nil
            let creating = Task {
                do { let owner = try await LWManagedSession.create(config: config); self.creationReceipt = .success(owner); return owner }
                catch { self.creationReceipt = .failure(error); throw error }
            }
            creation = creating
            LensWorksLaunchTrace.record("catalog.client.sessionCreate.begin")
            let owner = try await creating.value
            LensWorksLaunchTrace.record("catalog.client.sessionCreate.end")
            guard admittedGeneration == generation else {
                // A concurrent checked Quit/close owns retirement of this startup task.
                throw CancellationError()
            }
            creation = nil; creationReceipt = nil
            session = owner
            do {
                let native = try LWCatalogNativePath(fileURL: path)
                LensWorksLaunchTrace.record("catalog.client.open.begin", details: ["operation": request.op])
                nativeAdmissionInFlight = true; catalogAdmissionAttempted = true
                let opened: LWApplicationResponse
                do { opened = try await owner.perform(request.op == "create" ? .Create(path: native) : .OpenExisting(path: native)); nativeAdmissionInFlight = false }
                catch { nativeAdmissionInFlight = false; throw error }
                LensWorksLaunchTrace.record("catalog.client.open.end")
                guard case .Status(let status) = opened, let token = status.catalog else { throw LensWorksManagedError.protocolViolation("Catalog admission did not return a catalog identity.") }
                catalogToken = token // Cleanup authority remains owned even when admission was superseded.
                guard admittedGeneration == generation else { throw CancellationError() }
                try await ready(owner)
                guard admittedGeneration == generation, session === owner, !catalogClosed, catalogCloseJob == nil else { throw CancellationError() }
                LensWorksLaunchTrace.record("catalog.client.ready")
                let canonical = path.resolvingSymlinksInPath().standardizedFileURL.path
                currentPath = canonical
                guard let binaryLimit = Int(exactly: config.limits?.binary_bytes ?? UInt(16 * 1024 * 1024)) else { throw LensWorksManagedError.protocolViolation("Preview binary allowance exceeds native addressability.") }
                previews = LensWorksPreviewStore(session: owner, catalog: token, thumbnailEdge: config.preview_policy?.thumbnail.edge ?? 512, largeEdge: config.preview_policy?.large.edge ?? 1600, binaryLimit: binaryLimit)
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
            if let next {
                if cursors.count >= 64 { cursors.removeAll() }
                cursors[last] = next
            }
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
    private func ordinaryAdmission() throws {
        guard !retirementRequested, !closeInFlight, catalogCloseJob == nil, !catalogClosed else { throw LensWorksManagedError.native(code: "draining", message: "The catalog is retiring. Retry checked close before resuming catalog work.") }
    }
    func context() throws -> (LWManagedSession, String) {
        try ordinaryAdmission()
        guard let session, let catalogToken, !switching else { throw LensWorksManagedError.closed }
        return (session, catalogToken)
    }
    /// Read-only lifetime diagnostics remain available while ordinary mutation is fenced.
    func retirementAuthority() async throws -> (session: LWCatalogSessionHandle, catalog: String?, job: LWCatalogJobHandle?, resultTaken: Bool, verifiedClosed: Bool, state: LWManagedSessionStatus) {
        guard let session else { throw LensWorksManagedError.closed }
        return (session.handle, catalogToken, catalogCloseJob?.handle, catalogCloseResult != nil || catalogCloseOutcome != nil, catalogClosed, try await session.status())
    }
    func open(_ path: String, create: Bool) async throws -> LensWorksCatalogLocation {
        try await request(LensWorksCatalogRequest(op: create ? "create" : "open", catalog_path: path), as: LensWorksCatalogLocation.self)
    }
    #if DEBUG
    /// Test observation of catalog page fetches: how many were issued and the largest row limit requested.
    private(set) var browseCalls = 0
    private(set) var browseLimitHighWater: UInt16 = 0
    #endif
    func browse(options: LWApplicationBrowseOptions, cursor: String?) async throws -> LensWorksBrowserPage {
        let (owner, token) = try context()
        let limit = rowLimit
        #if DEBUG
        browseCalls += 1; browseLimitHighWater = max(browseLimitHighWater, limit)
        #endif
        guard case .Images(let rows, let next, let more, let complete, let scanned) = try await owner.perform(.Search(catalog: token, options: options, cursor: cursor, limit: limit)), rows.count <= 100 else {
            throw LensWorksManagedError.protocolViolation("Expected a bounded catalog image page.")
        }
        return LensWorksBrowserPage(catalog: token, rows: rows, next: next, hasMore: more, complete: complete, scanned: scanned)
    }
    func folders(parent: LWCatalogI64?, after: LWCatalogI64 = LWCatalogI64(0)) async throws -> LensWorksFolderPage {
        let (owner, token) = try context()
        guard case .Folders(let rows, let next) = try await owner.perform(.Folders(catalog: token, parent: parent, after: after, limit: rowLimit)), rows.count <= 100 else { throw LensWorksManagedError.protocolViolation("Expected a bounded folder page.") }
        return LensWorksFolderPage(rows: rows, next: next)
    }
    func organization(_ request: LWApplicationOrganizationRequest) async throws -> LWApplicationOrganizationResponse {
        let (owner, token) = try context()
        guard case .Organization(let result) = try await owner.perform(.Organization(catalog: token, request: request)) else { throw LensWorksManagedError.protocolViolation("Expected an organization response.") }
        return result
    }
    func settings(_ request: LWApplicationPreviewSettingsRequest) async throws -> LWApplicationPreviewSettingsStatus {
        let (owner, token) = try context()
        guard case .PreviewSettings(let result) = try await owner.perform(.PreviewSettings(catalog: token, request: request)) else { throw LensWorksManagedError.protocolViolation("Expected preview settings.") }
        return result
    }
    func beginImport(_ source: LWCatalogNativePath, resume: Bool) async throws -> LWApplicationDtoImportStatus {
        let (owner, token) = try context()
        let request: LWApplicationRequest = resume ? .ImportResume(catalog: token, source: source) : .ImportStart(catalog: token, source: source)
        guard case .Import(let status) = try await owner.perform(request), let status else { throw LensWorksManagedError.protocolViolation("Expected an owned import attempt.") }
        return status
    }
    func importStatus() async throws -> LWApplicationDtoImportStatus? {
        let (owner, token) = try context()
        guard case .Import(let status) = try await owner.perform(.ImportStatus(catalog: token)) else { throw LensWorksManagedError.protocolViolation("Expected import progress.") }
        return status
    }
    func cancelImport(_ id: String) async throws -> LWApplicationDtoImportStatus {
        let (owner, token) = try context()
        guard case .Import(let status) = try await owner.perform(.ImportCancel(catalog: token, import: id)), let status, status.id == id else { throw LensWorksManagedError.protocolViolation("The canceled import identity changed.") }
        return status
    }
    func resolve(_ asset: LensWorksCatalogAsset) async throws -> LensWorksCatalogAsset {
        let (owner, token) = try context()
        guard let key = asset.key else { return asset }
        let path = try await original(session: owner, catalog: token, key: key)
        var asset = asset
        asset.nativeOriginal = path
        asset.originalPath = (try? path.localFileURL().path) ?? asset.filename
        return asset
    }
    func preview(_ asset: LensWorksCatalogAsset, tier: LWApplicationDtoPreviewTier = .Thumbnail) async throws -> LensWorksPreview {
        try ordinaryAdmission()
        guard let previews, let key = asset.key else { throw LensWorksManagedError.closed }
        return try await previews.fetch(key, tier: tier)
    }
    func cancelPreviews() async { await previews?.cancelAll() } // Dedicated retirement cleanup.
    func cancelPreviews(catalog expected: String?) async {
        guard (try? ordinaryAdmission()) != nil, catalogToken == expected else { return }
        let owned = previews
        await owned?.cancelAll()
    }
    func drainPreviews(catalog expected: String?) async throws {
        try ordinaryAdmission()
        guard catalogToken == expected else { throw CancellationError() }
        let owned = previews
        try await owned?.drain()
    }
    @discardableResult func resumePreviews(catalog expected: String?) async -> Bool {
        guard (try? ordinaryAdmission()) != nil, catalogToken == expected, let owned = previews else { return false }
        return await owned.setAdmission(true)
    }
    @discardableResult func resumePreviews() async -> Bool {
        guard (try? ordinaryAdmission()) != nil, let owned = previews else { return false }
        return await owned.setAdmission(true)
    }
    func previewMetrics() async -> LensWorksPreviewMetrics { await previews?.metrics() ?? LensWorksPreviewMetrics() }
    #if DEBUG
    func setAdmittedPreviewFixture(_ fixture: (@Sendable (String) async -> Void)?) async throws {
        try ordinaryAdmission()
        guard let owned = previews else { throw LensWorksManagedError.closed }
        await owned.setAdmittedPreviewFixture(fixture)
    }
    func setPreviewDrainFixture(_ fixture: (@Sendable (LensWorksPreviewDrainFaultPoint) async throws -> Void)?) async throws {
        guard let owned = previews else { throw LensWorksManagedError.closed }
        await owned.setDrainFixture(fixture)
    }
    func setAdmittedPreviewBytesFixture(_ fixture: (@Sendable (UInt64) async -> Void)?) async throws {
        try ordinaryAdmission()
        guard let owned = previews else { throw LensWorksManagedError.closed }
        await owned.setAdmittedPreviewBytesFixture(fixture)
    }
    func previewDrainCustody() async throws -> (job: UInt64?, result: Bool, outcome: Bool, required: Bool, accepting: Bool) {
        guard let owned = previews else { throw LensWorksManagedError.closed }
        return await owned.drainCustody()
    }
    func observePreviewDrain(timeoutMilliseconds: UInt32) async throws {
        try ordinaryAdmission()
        guard let owned = previews else { throw LensWorksManagedError.closed }
        try await owned.drain(timeoutMilliseconds: timeoutMilliseconds)
    }
    #endif
    fileprivate func catalogVariants(catalog: String, asset: String, after: LWCatalogI64, limit: UInt16) async throws -> ([LWCatalogPair<LWCatalogI64, LWApplicationDtoVariant>], LWCatalogI64?) {
        let (owner, token) = try context()
        guard token == catalog else { throw CancellationError() }
        guard case .Variants(let rows, let next) = try await owner.perform(.Variants(catalog: token, asset_id: asset, after: after, limit: limit)),
              rows.count <= Int(limit), rows.allSatisfy({ $0.second.key.asset_id == asset }),
              Set(rows.map { $0.second.key.variant_id }).count == rows.count,
              rows.allSatisfy({ $0.first.value > after.value }),
              next == nil || (next == rows.last?.first && next!.value > after.value) else { throw LensWorksManagedError.protocolViolation("Expected a bounded catalog variant page.") }
        return (rows, next)
    }
    fileprivate func catalogVariantChange(catalog: String, request: LWApplicationRequest, source: LWApplicationDtoVariant, creating: Bool) async throws -> LWApplicationDtoVariant {
        let (owner, token) = try context()
        guard token == catalog else { throw CancellationError() }
        let ownedPreviews = previews
        guard case .Variant(let next) = try await owner.perform(request), next.key.asset_id == source.key.asset_id,
              creating ? next.key.variant_id != source.key.variant_id : next.key.variant_id == source.key.variant_id else {
            throw LensWorksManagedError.protocolViolation("Catalog recipe reply changed logical identity.")
        }
        guard creating || next.revision.value > source.revision.value else { throw LensWorksManagedError.protocolViolation("Catalog recipe revision did not advance.") }
        if !creating { await ownedPreviews?.invalidate(source.key) }
        return next
    }
    fileprivate func catalogImage(catalog: String, key: LWCatalogEditsVariantKey) async throws -> LWApplicationDtoGridImage {
        let (owner, token) = try context()
        guard token == catalog else { throw CancellationError() }
        guard case .Image(let row) = try await owner.perform(.Image(catalog: token, key: key)),
              row.key.asset_id == key.asset_id, row.key.variant_id == key.variant_id else {
            throw LensWorksManagedError.protocolViolation("Catalog image reply changed logical identity.")
        }
        return row
    }
    fileprivate func catalogRating(catalog: String, key: LWCatalogEditsVariantKey, value: UInt8) async throws -> LWApplicationOrganizationImageIdentity {
        let (owner, token) = try context()
        guard token == catalog, value <= 5 else { throw LensWorksCatalogError.message("Rating must be 0–5 in the current catalog.") }
        guard case .Organization(.Identity(let before)) = try await owner.perform(.Organization(catalog: token, request: .Identity(key: key))),
              before.key.asset_id == key.asset_id, before.key.variant_id == key.variant_id else {
            throw LensWorksManagedError.protocolViolation("Expected current catalog rating authority.")
        }
        guard case .Organization(.Changed(let revision)) = try await owner.perform(.Organization(catalog: token, request: .Apply(key: key, expected_revision: before.metadata_revision, operation: .Rating(value: value)))),
              revision.value > before.metadata_revision.value,
              case .Organization(.Identity(let after)) = try await owner.perform(.Organization(catalog: token, request: .Identity(key: key))),
              after.key.asset_id == key.asset_id, after.key.variant_id == key.variant_id, after.metadata_revision == revision else {
            throw LensWorksManagedError.protocolViolation("Expected committed catalog rating authority.")
        }
        return after
    }

    func variant(_ key: LWCatalogEditsVariantKey) async throws -> LWApplicationDtoVariant {
        let (owner, token) = try context()
        guard case .Variant(let variant) = try await owner.perform(.Variant(catalog: token, key: key)) else { throw LensWorksManagedError.protocolViolation("Expected edit authority.") }
        return variant
    }
    func setExposure(_ key: LWCatalogEditsVariantKey, value: Float) async throws -> LWApplicationDtoVariant {
        let (owner, token) = try context()
        let previous = try await variant(key)
        guard value.isFinite, case .V1(var settings) = previous.recipe else { throw LensWorksCatalogError.message("Exposure must be finite.") }
        settings.exposure_ev = LWCatalogFloat32(value)
        guard case .Variant(let next) = try await owner.perform(.SaveRecipe(catalog: token, key: key, expected_revision: previous.revision, recipe: .V1(settings))) else { throw LensWorksManagedError.protocolViolation("Expected saved edit authority.") }
        await previews?.invalidate(key)
        return next
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

nonisolated enum LensWorksCatalogRecipeAction: Sendable { case copy(String), exposure(Float), undo, redo }

nonisolated enum LensWorksCatalogControlAction: Sendable {
    case firstVariants
    case moreVariants(LWCatalogI64)
    case selectVariant(LWApplicationDtoVariant)
    case recipe(LensWorksCatalogRecipeAction)
    case rating(UInt8)
}

/// Immutable click-time authority for this selected catalog photo. This is not
/// document history or a general command registry.
nonisolated struct LensWorksCatalogControlAdmission: Sendable {
    fileprivate let scope: LensWorksCatalogScope
    fileprivate let image: String
    fileprivate let key: LWCatalogEditsVariantKey
    fileprivate let query: String
    fileprivate let selectionOwner: String
    fileprivate let selectionEpoch: UInt64
    fileprivate let page: LensWorksCatalogPageAuthority
    fileprivate let recipe: LWApplicationDtoVariant
    fileprivate let action: LensWorksCatalogControlAction
}

nonisolated struct LensWorksCatalogScope: Sendable {
    let epoch: UInt64
    let token: String?
    let path: String?
}

@MainActor @Observable
final class LensWorksCatalog {
    private(set) var catalogPath: String?
    private(set) var assets: [LensWorksCatalogAsset] = []
    private(set) var versions: [LensWorksWorkingVersion] = []
    var selectedPhotoID: String? { didSet { catalogSelectionEpoch &+= 1 } }
    private(set) var outputDirectory: String?
    private var busyOwner: UUID?
    var isBusy: Bool { busyOwner != nil }
    private(set) var closingRequested = false
    private(set) var closeInFlight = false
    private(set) var hasMore = false
    private(set) var pageStart: Int64 = 0
    private(set) var pagePublication: UInt64 = 0
    private(set) var staleCursorRestarts: UInt64 = 0
    private(set) var pageComplete = true
    private(set) var scanned: UInt32 = 0
    private(set) var catalogToken: String?
    private(set) var catalogEpoch: UInt64 = 0
    private(set) var catalogVariant: LWApplicationDtoVariant?
    private(set) var catalogVariants: [LWApplicationDtoVariant] = []
    private(set) var catalogVariantsNext: LWCatalogI64?
    @ObservationIgnored private var catalogVariantScope: LensWorksCatalogScope?
    private(set) var focusedCatalogVariant: LensWorksCatalogAsset?
    @ObservationIgnored private var focusedCatalogVariantScope: LensWorksCatalogScope?
    @ObservationIgnored private var folderEpoch: UInt64 = 0
    @ObservationIgnored private var groupEpoch: UInt64 = 0
    @ObservationIgnored private var outputEpoch: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var continuationFixture: (@Sendable (LensWorksCatalogContinuationPoint) async -> Void)?
    #endif
    private(set) var activeFolder: LWApplicationDtoFolder?
    private(set) var selectionCount: Int64 = 0
    private(set) var versionNext: String?
    private(set) var versionDiscoveryPending = false
    private(set) var versionsHighWater = 0
    private(set) var versionDiscoveryScanned = 0
    private(set) var isOrganizing = false
    var organizationCancelRequested = false
    private(set) var rowsHighWater = 0
    private(set) var folders: [LWApplicationDtoFolder] = []
    private(set) var folderParent: LWApplicationDtoFolder?
    private(set) var folderNext: LWCatalogI64?
    private(set) var groups: [LWApplicationOrganizationCollection] = []
    private(set) var groupNext: String?
    private(set) var placements: [String: LWApplicationOrganizationPlacement] = [:]
    private(set) var navigationHighWater = 0
    private(set) var importProgress: LWApplicationDtoImportStatus?
    private(set) var importSamples: [LWApplicationDtoImportStatus] = []
    private(set) var previewGeneration: UInt64 = 0
    private(set) var previewsSuspended = false
    private(set) var previewSettings: LWApplicationPreviewSettingsStatus?
    var showingCatalog = true
    var searchText = ""
    var recursive = true
    var selection: Set<String> = []
    var error: String?
    var status = "Open or create a catalog to begin."
    @ObservationIgnored let service: LensWorksCatalogService
    @ObservationIgnored let index: LensWorksCatalogIndex
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let migrateLegacy: Bool
    @ObservationIgnored private let rowLimit: UInt16
    @ObservationIgnored private var catalogSelectionEpoch: UInt64 = 0
    @ObservationIgnored private var selectionOwner = UUID().uuidString
    @ObservationIgnored private var queryEpoch: UInt64 = 0
    @ObservationIgnored private var queryOwner = UUID().uuidString
    @ObservationIgnored private var pageOrdinal: Int64 = 0
    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored private var importWaiters = 0
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var cursorWindow = LensWorksCursorWindow()
    @ObservationIgnored private var folderTrail: [LWApplicationDtoFolder] = []
    @ObservationIgnored private var groupAfter = ""
    @ObservationIgnored private var importMonitor: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var importMonitorFixtureReceipt: LensWorksImportMonitorReceipt?
    #endif
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var settingsPauseRequested = false
    @ObservationIgnored var lastClosedCatalogPath: String?
    @ObservationIgnored var catalogJourney: [[String: Any]] = []
    var isSettingsWorking: Bool { settingsTask != nil }
    @ObservationIgnored var browseOptions = LWApplicationBrowseOptions(text: nil, keyword: nil, keyword_direct: false, folder: nil, folder_recursive: true, collection: nil, date_from: nil, date_until: nil, camera_make: nil, camera: nil, lens: nil, format: nil, rating: nil, flag: nil, label: nil, only_conflicted: false, sort: .Sequence, direction: .Ascending)
    var hasPrevious: Bool { !cursorWindow.previous.isEmpty }
    var folderNavigationGeneration: UInt64 { folderEpoch }
    var navigationResidency: Int { folders.count + groups.count + placements.count + folderTrail.count }
    var cursorHistoryCount: Int { cursorWindow.previous.count }
    var currentCursor: String? { cursorWindow.current }
    var pageAuthority: LensWorksCatalogPageAuthority {
        LensWorksCatalogPageAuthority(catalogEpoch: catalogEpoch, queryEpoch: queryEpoch, publication: pagePublication, ordinal: pageOrdinal, current: cursorWindow.current, next: cursorWindow.next)
    }
    var nextCursor: String? { cursorWindow.next }
    var selectedAsset: LensWorksCatalogAsset? {
        if let shown = assets.first(where: { $0.id == selectedPhotoID }) { return shown }
        guard let scope = focusedCatalogVariantScope, scopeIsCurrent(scope), focusedCatalogVariant?.id == selectedPhotoID else { return nil }
        return focusedCatalogVariant
    }
    var selectedVersions: [LensWorksWorkingVersion] { versions.filter { $0.photoID == selectedAsset?.photoID && $0.sourceVariantID == (selectedAsset?.key?.variant_id ?? "master")  } }
    var isImporting: Bool { importProgress.map { [.Discovering, .Draining, .CancelRequested].contains($0.phase) } ?? false }
    init(configuration: LWManagedSessionConfig? = nil, index: LensWorksCatalogIndex = .shared, defaults: UserDefaults = .standard, migrateLegacy: Bool = false, catalogService: LensWorksCatalogService? = nil) {
        service = catalogService ?? LensWorksCatalogService(configuration: configuration)
        self.index = index; self.defaults = defaults; self.migrateLegacy = migrateLegacy
        rowLimit = min(100, configuration?.limits?.page_rows ?? 100)
    }
    private func beginBusy() -> UUID { let owner = UUID(); busyOwner = owner; return owner }
    private func finishBusy(_ owner: UUID) { if busyOwner == owner { busyOwner = nil } }
    func captureScope() -> LensWorksCatalogScope { LensWorksCatalogScope(epoch: catalogEpoch, token: catalogToken, path: catalogPath) }
    func scopeIsCurrent(_ scope: LensWorksCatalogScope) -> Bool { !closingRequested && scope.epoch == catalogEpoch && scope.token == catalogToken && scope.path == catalogPath }
    func checkScope(_ scope: LensWorksCatalogScope) throws { if !scopeIsCurrent(scope) { throw CancellationError() } }
    func admitCatalogWork() throws {
        guard !closingRequested else { throw LensWorksManagedError.native(code: "draining", message: "The catalog is retiring. Retry Close Catalog before starting another action.") }
    }
    var hasImportCheckpoint: Bool { checkpointKey.map { defaults.data(forKey: $0) != nil } ?? false }

    func openCatalog(create: Bool, window: NSWindow?) async {
        guard !closingRequested else { return }
        guard !isBusy else { return }
        let scope = captureScope()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = create
        panel.prompt = create ? "Create Catalog" : "Open Catalog"
        panel.message = create ? "Choose an empty folder for the catalog database and previews. Your photos stay in their existing folders." : "Choose an existing PhotoCatalog or LensWorks catalog folder."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        guard scopeIsCurrent(scope) else { return }
        await connect(url.path, create: create)
    }

    func connect(_ path: String, create: Bool = false) async {
        guard !closingRequested, !isBusy else { return }
        let busy = beginBusy(); defer { finishBusy(busy) }
        catalogEpoch &+= 1; folderEpoch &+= 1; groupEpoch &+= 1
        let epoch = catalogEpoch, previousSelection = selectionOwner, previousQuery = queryOwner, previousCatalog = catalogToken
        activeFolder = nil; searchText = ""; previewSettings = nil
        do {
            try await retireSettingsWork()
            guard !closingRequested, catalogEpoch == epoch else { return }
            try await index.clearSelection(owner: previousSelection)
            guard !closingRequested, catalogEpoch == epoch else { return }
            try await index.clearVisits(owner: previousQuery)
            guard !closingRequested, catalogEpoch == epoch else { return }
        } catch {
            guard !closingRequested, catalogEpoch == epoch else { return }
            self.error = "Previous browse ownership could not be retired. Retry without discarding its authority. " + error.localizedDescription
            return
        }
        selectionOwner = UUID().uuidString; queryOwner = UUID().uuidString; selectionCount = 0; selectionAnchor = nil
        catalogPath = nil; assets = []; versions = []; selectedPhotoID = nil
        hasMore = false; pageStart = 0; cursorWindow.reset()
        folders = []; groups = []; placements = [:]; folderTrail = []; folderParent = nil; folderNext = nil; groupNext = nil; catalogToken = nil; selection = []; importProgress = nil
        error = nil
        do {
            importMonitor?.cancel(); await service.cancelPreviews(catalog: previousCatalog)
            guard !closingRequested, catalogEpoch == epoch else { return }
            previewGeneration &+= 1
            let result = try await service.open(path, create: create)
            guard !closingRequested, catalogEpoch == epoch else { return }
            let (_, token) = try await service.context()
            guard !closingRequested, catalogEpoch == epoch else { return }
            catalogPath = result.catalog_path; catalogToken = token
            if migrateLegacy {
                let migrationErrors = await index.migrateLegacyDefaults(defaults: defaults)
                guard !closingRequested, catalogEpoch == epoch else { return }
                if !migrationErrors.isEmpty { self.error = migrationErrors.joined(separator: "\n") }
            }
            let settings = try await service.settings(.Status)
            guard !closingRequested, catalogEpoch == epoch else { return }
            previewSettings = settings; previewsSuspended = settings.relocation_pending
            if previewsSuspended {
                try await suspendPreviews()
                guard !closingRequested, catalogEpoch == epoch else { return }
            }
            if let outputDirectory {
                do { _ = try await LensWorksVersionStore.shared.canonicalPath(outputDirectory, outside: catalogPath) }
                catch {
                    guard !closingRequested, catalogEpoch == epoch else { return }
                    self.outputDirectory = nil
                    defaults.removeObject(forKey: "LensWorks.outputDirectory")
                    self.error = error.localizedDescription
                }
                guard !closingRequested, catalogEpoch == epoch else { return }
            }
            defaults.set(catalogPath, forKey: "LensWorks.catalogPath")
            browseOptions.folder = nil; browseOptions.collection = nil; browseOptions.text = nil
            try await refreshAssets()
            guard !closingRequested, catalogEpoch == epoch else { return }
            try await loadFolders()
            guard !closingRequested, catalogEpoch == epoch else { return }
            try await loadGroups()
            guard !closingRequested, catalogEpoch == epoch else { return }
            let progress = try await service.importStatus()
            guard !closingRequested, catalogEpoch == epoch else { return }
            importProgress = progress
            await refreshVersions()
            guard !closingRequested, catalogEpoch == epoch else { return }
            status = "Showing \(assets.count) photos"
        } catch {
            guard !closingRequested, catalogEpoch == epoch else { return }
            catalogPath = nil; assets = []; versions = []; selectedPhotoID = nil
            hasMore = false; pageStart = 0; cursorWindow.reset()
            folders = []; groups = []; placements = [:]; folderTrail = []; folderParent = nil; folderNext = nil; groupNext = nil; catalogToken = nil; selection = []; importProgress = nil
            self.error = error.localizedDescription
        }
    }

    func importFolder(window: NSWindow?) async {
        guard !closingRequested, catalogPath != nil, !isImporting else { return }
        let scope = captureScope()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Add Photos"; panel.message = "Register this folder and its subfolders. Original files stay in place."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard scopeIsCurrent(scope), response == .OK, let url = panel.url else { return }
        do { try await startImport(url.path) }
        catch { if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription } }
    }

    func importFolder(_ path: String) async {
        guard !closingRequested else { return }
        let scope = captureScope()
        do { try await startImport(path); try checkScope(scope); try await waitImport(terminal: true) }
        catch { if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription } }
    }

    private var checkpointKey: String? { catalogPath.map { "LensWorks.importSource." + $0 } }
    func startImport(_ path: String? = nil, resume: Bool = false) async throws {
        try admitCatalogWork()
        guard catalogPath != nil, !isImporting, !isBusy else { throw LensWorksCatalogError.message("Wait for the current catalog action to retire before starting another import.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let source: LWCatalogNativePath
        if let path { source = try LWCatalogNativePath(fileURL: URL(fileURLWithPath: path)) }
        else if let key = checkpointKey, let data = defaults.data(forKey: key) { source = try LWCatalogCodec.decode(LWCatalogNativePath.self, from: data) }
        else { throw LensWorksCatalogError.message("Choose the source folder to resume importing.") }
        let previous = importProgress?.id
        let epoch = catalogEpoch, path = catalogPath, token = catalogToken, checkpoint = checkpointKey
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var started: LWApplicationDtoImportStatus
        while true {
            guard !closingRequested, catalogEpoch == epoch, catalogPath == path, catalogToken == token else { throw CancellationError() }
            do { started = try await service.beginImport(source, resume: resume); break }
            catch LensWorksManagedError.native(let code, _) where code == "busy" && resume && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard !closingRequested, catalogEpoch == epoch, catalogPath == path, catalogToken == token else { throw CancellationError() }
        guard started.id != previous else { throw LensWorksManagedError.protocolViolation("An import restart reused its previous attempt identity.") }
        if let key = checkpoint { defaults.set(try LWCatalogCodec.encode(source), forKey: key) }
        importProgress = started; importSamples = [started]
        importMonitor?.cancel()
        let id = started.id
        let monitorScope = captureScope()
        #if DEBUG
        let receipt = LensWorksImportMonitorReceipt()
        importMonitorFixtureReceipt = receipt
        #endif
        importMonitor = Task { [weak self] in
            #if DEBUG
            defer { receipt.complete = true }
            #endif
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    guard let self, self.scopeIsCurrent(monitorScope), self.importProgress?.id == id, self.isImporting else { return }
                    let observed = try await self.service.importStatus()
                    try Task.checkCancellation()
                    #if DEBUG
                    if let next = observed, next.id == id, ![.Discovering, .Draining, .CancelRequested].contains(next.phase) {
                        // The actual decoded/released worker result is held only by an opt-in fixture.
                        await self.continuationFixture?(.importMonitorTerminal)
                    }
                    #endif
                    try Task.checkCancellation()
                    guard self.scopeIsCurrent(monitorScope), self.importProgress?.id == id, self.isImporting,
                          let next = observed, next.id == id else { return }
                    self.recordImport(next)
                    if !self.isImporting {
                        if self.importWaiters == 0 {
                            try Task.checkCancellation()
                            await self.refresh()
                        }
                        return
                    }
                } catch {
                    if !Task.isCancelled, let self, self.scopeIsCurrent(monitorScope), self.importProgress?.id == id, self.isImporting {
                        self.error = "Import progress could not be observed. The attempt and source are retained. " + error.localizedDescription
                    }
                    return
                }
            }
        }
    }
    #if DEBUG
    func finishImportMonitorFixture(timeoutMilliseconds: UInt32 = 60000) async throws {
        guard timeoutMilliseconds > 0, timeoutMilliseconds <= 60000 else { throw LensWorksCatalogError.message("Monitor fixture observation must stay within 60 seconds.") }
        // The receipt belongs to this actual task, even if a later import replaces the field.
        guard let receipt = importMonitorFixtureReceipt else { return }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        while !receipt.complete {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("The retained import monitor has not completed within its finite fixture observation.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #endif
    private func recordImport(_ next: LWApplicationDtoImportStatus) {
        importProgress = next
        if importSamples.count >= 64 { importSamples.removeFirst() }
        importSamples.append(next)
        status = "Import " + next.phase.rawValue + " · added " + String(next.imported.value) + " · failed " + String(next.failed.value) + " · previews " + String(next.pending_previews)
    }
    func waitImport(terminal: Bool, minimumImported: UInt64? = nil, phase: String? = nil, timeoutMilliseconds: UInt32 = 60000) async throws {
        try admitCatalogWork()
        guard let expected = importProgress?.id, timeoutMilliseconds > 0, timeoutMilliseconds <= 60000 else { throw LensWorksCatalogError.message("There is no owned import to observe.") }
        importWaiters += 1; defer { importWaiters -= 1 }
        let scope = captureScope()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        while true {
            try checkScope(scope)
            let observed = try await service.importStatus()
            try checkScope(scope)
            guard let next = observed, next.id == expected else { throw LensWorksManagedError.protocolViolation("Import progress belongs to a different attempt.") }
            recordImport(next)
            if !isImporting { importMonitor?.cancel() }
            if next.phase == .Failed { throw LensWorksCatalogError.message(next.error ?? "Import failed.") }
            if terminal ? !isImporting : ((minimumImported == nil || next.imported.value >= minimumImported!) && (phase == nil || next.phase.rawValue == phase)) {
                if terminal {
                    let parent = folderParent, groupsAfter = groupAfter
                    let navigation = folderEpoch, groupsNavigation = groupEpoch, refreshedQuery = queryEpoch &+ 1
                    try await refreshAssets(); try checkScope(scope)
                    guard folderEpoch == navigation, groupEpoch == groupsNavigation, queryEpoch == refreshedQuery else { throw CancellationError() }
                    try await loadFolders(parent: parent); try checkScope(scope)
                    guard folderEpoch == navigation &+ 1, groupEpoch == groupsNavigation, queryEpoch == refreshedQuery else { throw CancellationError() }
                    try await loadGroups(after: groupsAfter); try checkScope(scope)
                    guard importProgress?.id == expected else { throw CancellationError() }
                }
                return
            }
            guard ContinuousClock.now < deadline else {
                throw LensWorksCatalogError.importObservationTimeout(next)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func cancelImport() async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        guard isImporting, let id = importProgress?.id else { throw LensWorksCatalogError.message("The import already finished; no interruption was requested.") }
        let epoch = catalogEpoch, path = catalogPath, token = catalogToken
        let canceled = try await service.cancelImport(id)
        guard !closingRequested, catalogEpoch == epoch, catalogPath == path, catalogToken == token else { throw CancellationError() }
        recordImport(canceled)
        try await waitImport(terminal: true)
        guard !closingRequested, catalogEpoch == epoch, catalogPath == path, catalogToken == token, importProgress?.id == id else { throw CancellationError() }
        guard importProgress?.phase == .Canceled else { throw LensWorksCatalogError.message("The import completed before cancellation took effect.") }
    }
    private func refreshAssets() async throws {
        try Task.checkCancellation()
        try admitCatalogWork()
        queryEpoch &+= 1; previewGeneration &+= 1
        let epoch = catalogEpoch, query = queryEpoch, oldOwner = queryOwner
        // Retire one visible page and its cursor authorities as a single actor transition.
        // Disk-backed selection and the selected photo survive until fresh-page reconciliation.
        assets = []; selection = []; hasMore = false; pageStart = 0; pageComplete = false; scanned = 0
        cursorWindow.reset(); pageOrdinal = 0; selectionAnchor = nil
        try await index.clearVisits(owner: oldOwner)
        guard catalogEpoch == epoch, queryEpoch == query else { throw CancellationError() }
        queryOwner = UUID().uuidString
        let admittedOwner = queryOwner
        try await index.beginVisits(owner: admittedOwner)
        guard catalogEpoch == epoch, queryEpoch == query, queryOwner == admittedOwner else {
            try await index.clearVisits(owner: admittedOwner)
            throw CancellationError()
        }
        try await loadPage(cursor: nil)
    }
    private func loadPage(cursor: String?, window: LensWorksCursorWindow? = nil, ordinal requestedOrdinal: Int64? = nil) async throws {
        try Task.checkCancellation()
        try admitCatalogWork()
        guard catalogPath != nil else { return }
        let admittedEpoch = catalogEpoch, admittedQuery = queryEpoch
        let options = browseOptions, query = queryOwner, owner = selectionOwner, ordinal = requestedOrdinal ?? pageOrdinal, token = catalogToken
        let admittedWindow = window ?? cursorWindow
        previewGeneration &+= 1
        let admittedGeneration = previewGeneration
        await service.cancelPreviews(catalog: token)
        guard catalogEpoch == admittedEpoch, queryEpoch == admittedQuery, previewGeneration == admittedGeneration else { throw CancellationError() }
        let page = try await service.browse(options: options, cursor: cursor)
        try Task.checkCancellation()
        guard !page.hasMore || (page.next != nil && page.next != cursor) else { throw LensWorksManagedError.protocolViolation("A continuing page did not advance its cursor authority.") }
        guard previewGeneration == admittedGeneration, catalogEpoch == admittedEpoch, queryEpoch == admittedQuery else { throw CancellationError() }
        let admittedAssets = page.rows.map { row in
            LensWorksCatalogAsset(sequence: row.sequence.value, id: row.image_id, originalPath: row.filename, state: row.state,
                previewPath: nil, key: row.key, displayFilename: row.filename, metadataRevision: row.metadata_revision.value,
                origin: row.origin, translationState: row.translation_state, rating: row.rating?.value)
        }
        try await index.rememberPage(owner: query, page: ordinal, rows: admittedAssets.compactMap { row in row.key.map { LensWorksSelectedRow(imageID: row.id, key: $0) } })
        let (projected, count) = try await index.selectionProjection(owner: owner, images: admittedAssets.map(\.id))
        guard catalogEpoch == admittedEpoch, queryEpoch == admittedQuery, previewGeneration == admittedGeneration, queryOwner == query, selectionOwner == owner else { throw CancellationError() }
        catalogToken = page.catalog
        assets = admittedAssets; selection = projected; selectionCount = count
        rowsHighWater = max(rowsHighWater, assets.count)
        hasMore = page.hasMore; pageComplete = page.complete; scanned = page.scanned
        cursorWindow = admittedWindow; cursorWindow.current = cursor; cursorWindow.next = page.next
        pageOrdinal = ordinal; pagePublication &+= 1
        pageStart = assets.first?.sequence ?? 0
        if !assets.contains(where: { $0.id == selectedPhotoID }) { selectedPhotoID = assets.first?.id }
        await refreshVersions()
    }
    private func staleCursor(_ code: String, _ message: String) -> Bool {
        (code == "native" && (message.hasPrefix("search cursor stale after edits, relinks or index changes") || message.hasPrefix("cursor belongs to a different query or version"))) ||
        (code == "stale_session" && message == "search cursor belongs to another session")
    }
    func setBrowseOrder(sort: LWOrganizationSearchSort, direction: LWOrganizationSearchDirection) async {
        guard !closingRequested else { return }
        let epoch = catalogEpoch, query = queryEpoch &+ 1
        browseOptions.sort = sort; browseOptions.direction = direction
        do { try await refreshAssets() }
        catch { if !(error is CancellationError), epoch == catalogEpoch, query == queryEpoch { self.error = error.localizedDescription } }
    }
    func browse(folder: LWApplicationDtoFolder? = nil, collection: String? = nil, recursive: Bool = true, text: String? = nil) async throws {
        try admitCatalogWork()
        activeFolder = folder
        browseOptions.folder = folder?.id; browseOptions.collection = collection
        browseOptions.folder_recursive = recursive; browseOptions.text = text?.isEmpty == false ? text : nil
        self.recursive = recursive; searchText = text ?? ""
        showingCatalog = true
        try await refreshAssets()
    }
    func refresh() async {
        guard !Task.isCancelled, !closingRequested else { return }
        let scope = captureScope(), parent = folderParent
        let navigation = folderEpoch, groupsNavigation = groupEpoch, refreshedQuery = queryEpoch &+ 1
        do {
            try await refreshAssets(); try checkScope(scope)
            guard folderEpoch == navigation, groupEpoch == groupsNavigation, queryEpoch == refreshedQuery else { throw CancellationError() }
            try await loadFolders(parent: parent); try checkScope(scope)
            guard folderEpoch == navigation &+ 1, groupEpoch == groupsNavigation, queryEpoch == refreshedQuery else { throw CancellationError() }
            try await loadGroups(); try checkScope(scope)
        } catch { if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription } }
    }

    @discardableResult
    func nextPage() async -> Bool {
        guard !Task.isCancelled, !closingRequested, hasMore, !isBusy, cursorWindow.next != nil else { return false }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let ordinal = pageOrdinal, epoch = catalogEpoch, query = queryEpoch, publication = pagePublication
        var proposed = cursorWindow
        let cursor = proposed.advance()
        do {
            try await loadPage(cursor: cursor, window: proposed, ordinal: ordinal + 1)
            return catalogEpoch == epoch && queryEpoch == query && pagePublication != publication && pageOrdinal == ordinal + 1 && currentCursor == cursor
        } catch LensWorksManagedError.native(let code, let message) where staleCursor(code, message) {
            guard catalogEpoch == epoch, queryEpoch == query else { return false }
            let resetQuery = queryEpoch &+ 1
            do {
                try await refreshAssets()
                guard !closingRequested, catalogEpoch == epoch, queryEpoch == resetQuery else { return false }
                staleCursorRestarts &+= 1
                status = "Catalog changed; browsing restarted from the first page."
            } catch { if !(error is CancellationError), !closingRequested, catalogEpoch == epoch, queryEpoch == resetQuery { self.error = error.localizedDescription } }
        } catch {
            guard catalogEpoch == epoch, queryEpoch == query else { return false }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        return false
    }
    @discardableResult
    func previousPage() async -> Bool {
        guard !Task.isCancelled, !closingRequested, hasPrevious, !isBusy else { return false }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let ordinal = pageOrdinal, epoch = catalogEpoch, query = queryEpoch, publication = pagePublication
        var proposed = cursorWindow
        let cursor = proposed.retreat(), destination = max(0, ordinal - 1)
        do {
            try await loadPage(cursor: cursor, window: proposed, ordinal: destination)
            return catalogEpoch == epoch && queryEpoch == query && pagePublication != publication && pageOrdinal == destination && currentCursor == cursor
        } catch LensWorksManagedError.native(let code, let message) where staleCursor(code, message) {
            guard catalogEpoch == epoch, queryEpoch == query else { return false }
            let resetQuery = queryEpoch &+ 1
            do {
                try await refreshAssets()
                guard !closingRequested, catalogEpoch == epoch, queryEpoch == resetQuery else { return false }
                staleCursorRestarts &+= 1
                status = "Catalog changed; browsing restarted from the first page."
            } catch { if !(error is CancellationError), !closingRequested, catalogEpoch == epoch, queryEpoch == resetQuery { self.error = error.localizedDescription } }
        } catch {
            guard catalogEpoch == epoch, queryEpoch == query else { return false }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        return false
    }
    private func refreshSelectionProjection(owner: String, query: String, scope: LensWorksCatalogScope, generation: UInt64) async throws {
        let images = assets.map(\.id)
        let (visible, count) = try await index.selectionProjection(owner: owner, images: images)
        try checkScope(scope)
        guard owner == selectionOwner, query == queryOwner, generation == previewGeneration else { throw CancellationError() }
        selection = visible; selectionCount = count
    }

    func select(_ asset: LensWorksCatalogAsset, extending: Bool = false, range: Bool = false) async {
        guard !closingRequested, let key = asset.key, assets.contains(where: { $0.id == asset.id }) else { return }
        catalogSelectionEpoch &+= 1
        let scope = captureScope(), owner = selectionOwner, query = queryOwner, generation = previewGeneration
        do {
            if range, let anchor = selectionAnchor {
                try await index.selectRange(owner: owner, query: query, anchor: anchor, end: asset.id, replacing: !extending)
            } else {
                try await index.setSelection(owner: owner, rows: [LensWorksSelectedRow(imageID: asset.id, key: key)], replace: !extending, remove: extending && selection.contains(asset.id))
            }
            try checkScope(scope)
            guard owner == selectionOwner, query == queryOwner, generation == previewGeneration else { throw CancellationError() }
            if !range { selectionAnchor = asset.id }
            selectedPhotoID = asset.id
            try await refreshSelectionProjection(owner: owner, query: query, scope: scope, generation: generation)
            try checkScope(scope)
            await refreshVersions()
        } catch {
            guard !(error is CancellationError), scopeIsCurrent(scope), owner == selectionOwner, query == queryOwner, generation == previewGeneration else { return }
            try? await refreshSelectionProjection(owner: owner, query: query, scope: scope, generation: generation)
            if scopeIsCurrent(scope), owner == selectionOwner, query == queryOwner, generation == previewGeneration { self.error = error.localizedDescription }
        }
    }

    func selectCurrentPage() async {
        guard !closingRequested else { return }
        catalogSelectionEpoch &+= 1
        let scope = captureScope(), owner = selectionOwner, query = queryOwner, generation = previewGeneration
        let rows = assets.compactMap { row in row.key.map { LensWorksSelectedRow(imageID: row.id, key: $0) } }
        do {
            try await index.setSelection(owner: owner, rows: rows, replace: false)
            try checkScope(scope)
            guard owner == selectionOwner, query == queryOwner, generation == previewGeneration else { throw CancellationError() }
            try await refreshSelectionProjection(owner: owner, query: query, scope: scope, generation: generation)
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), owner == selectionOwner, query == queryOwner, generation == previewGeneration { self.error = error.localizedDescription } }
    }

    func clearSelection() async {
        guard !closingRequested else { return }
        catalogSelectionEpoch &+= 1
        let scope = captureScope(), owner = selectionOwner, query = queryOwner, generation = previewGeneration
        do {
            try await index.clearSelection(owner: owner); try checkScope(scope)
            guard owner == selectionOwner, query == queryOwner, generation == previewGeneration else { throw CancellationError() }
            selectionAnchor = nil
            try await refreshSelectionProjection(owner: owner, query: query, scope: scope, generation: generation)
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), owner == selectionOwner, query == queryOwner, generation == previewGeneration { self.error = error.localizedDescription } }
    }

    func moveSelection(_ delta: Int, range: Bool) async {
        guard !closingRequested, !assets.isEmpty else { return }
        let scope = captureScope(), query = queryOwner
        let position = assets.firstIndex { $0.id == selectedPhotoID } ?? 0
        let next = position + delta
        if next >= assets.count, hasMore {
            await nextPage()
            guard scopeIsCurrent(scope), queryOwner == query else { return }
            if let first = assets.first { await select(first, range: range) }
        } else if next < 0, hasPrevious {
            await previousPage()
            guard scopeIsCurrent(scope), queryOwner == query else { return }
            if let last = assets.last { await select(last, range: range) }
        } else if assets.indices.contains(next) { await select(assets[next], range: range) }
    }

    func loadFolders(parent: LWApplicationDtoFolder? = nil, after: LWCatalogI64 = LWCatalogI64(0)) async throws {
        try admitCatalogWork()
        folderEpoch &+= 1
        let admitted = folderEpoch, epoch = catalogEpoch
        let page = try await service.folders(parent: parent?.id, after: after)
        guard folderEpoch == admitted, catalogEpoch == epoch else { throw CancellationError() }
        if parent == nil { folderTrail = [] }
        else if parent?.id != folderParent?.id {
            if parent?.parent == folderParent?.id, let current = folderParent { folderTrail.append(current) }
            else if let found = folderTrail.firstIndex(where: { $0.id == parent?.id }) { folderTrail = Array(folderTrail.prefix(found)) }
            if folderTrail.count > 64 { folderTrail.removeFirst(folderTrail.count - 64) }
        }
        folders = page.rows; folderParent = parent; folderNext = page.next
        navigationHighWater = max(navigationHighWater, folders.count + groups.count + placements.count + folderTrail.count)
    }
    func enterFolder(_ folder: LWApplicationDtoFolder) async {
        guard !closingRequested else { return }
        let scope = captureScope(), navigation = folderEpoch &+ 1, recurse = recursive
        do {
            try await loadFolders(parent: folder); try checkScope(scope)
            guard folderEpoch == navigation else { throw CancellationError() }
            try await browse(folder: folder, recursive: recurse)
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), folderEpoch == navigation { self.error = error.localizedDescription } }
    }

    func upFolder() async {
        guard !closingRequested else { return }
        let scope = captureScope(), current = folderParent, recurse = recursive
        var navigation = folderEpoch
        do {
            let parent: LWApplicationDtoFolder?
            if let retained = folderTrail.last { parent = retained }
            else if let current, current.parent != nil {
                parent = try await folder(at: current.locator.parentPhysicalFolder())
                try checkScope(scope)
                navigation = folderEpoch // The resolver checked its own navigation lease.
            } else { parent = nil }
            try checkScope(scope)
            guard folderEpoch == navigation else { throw CancellationError() }
            navigation &+= 1
            try await loadFolders(parent: parent); try checkScope(scope)
            guard folderEpoch == navigation else { throw CancellationError() }
            try await browse(folder: parent, recursive: recurse)
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), folderEpoch == navigation { self.error = error.localizedDescription } }
    }

    func nextFolders() async {
        guard !closingRequested, let next = folderNext else { return }
        let scope = captureScope(), navigation = folderEpoch &+ 1, parent = folderParent
        do { try await loadFolders(parent: parent, after: next) }
        catch { if !(error is CancellationError), scopeIsCurrent(scope), folderEpoch == navigation { self.error = error.localizedDescription } }
    }

    func loadGroups(after: String = "") async throws {
        try admitCatalogWork()
        groupEpoch &+= 1
        let admitted = groupEpoch, scope = captureScope()
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token, groupEpoch == admitted else { throw CancellationError() }
        guard case .Organization(.Collections(let page)) = try await owner.perform(.Organization(catalog: token, request: .Collections(after: after, limit: rowLimit))), page.rows.count <= 100 else { throw LensWorksManagedError.protocolViolation("Expected a bounded virtual-folder page.") }
        try checkScope(scope)
        guard groupEpoch == admitted else { throw CancellationError() }
        var admittedPlacements: [String: LWApplicationOrganizationPlacement] = [:]
        for group in page.rows {
            guard case .Organization(.Placement(let placement)) = try await owner.perform(.Organization(catalog: token, request: .Placement(collection: group.id))) else { throw LensWorksManagedError.protocolViolation("Expected virtual-folder placement.") }
            try checkScope(scope)
            guard groupEpoch == admitted else { throw CancellationError() }
            admittedPlacements[group.id] = placement
        }
        groups = page.rows; groupAfter = after; groupNext = page.next; placements = admittedPlacements
        navigationHighWater = max(navigationHighWater, navigationResidency)
    }

    func nextGroups() async {
        guard !closingRequested, let next = groupNext else { return }
        let scope = captureScope(), navigation = groupEpoch &+ 1
        do { try await loadGroups(after: next) }
        catch { if !(error is CancellationError), scopeIsCurrent(scope), groupEpoch == navigation { self.error = error.localizedDescription } }
    }

    func group(named name: String) throws -> LWApplicationOrganizationCollection {
        let matching = groups.filter { $0.name == name }
        guard matching.count == 1, let group = matching.first else { throw LensWorksCatalogError.message("Choose one virtual folder from the current page; the name is missing or ambiguous.") }
        return group
    }
    func createGroup(_ name: String) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), after = groupAfter, navigation = groupEpoch
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        
        guard case .Organization(.CollectionCreated) = try await owner.perform(.Organization(catalog: token, request: .CreateCollection(name: name))) else { throw LensWorksManagedError.protocolViolation("Expected a created virtual-folder identity.") }
        try checkScope(scope)
        
        guard groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: after); try checkScope(scope)
    }

    private func currentGroup(_ id: String, owner: LWManagedSession, token: String) async throws -> LWApplicationOrganizationCollection {
        guard case .Organization(.Collection(let value)) = try await owner.perform(.Organization(catalog: token, request: .Collection(id: id))), let value else { throw LensWorksCatalogError.message("The virtual folder is no longer available.") }
        #if DEBUG
        await continuationFixture?(.groupRead)
        #endif
        return value
    }

    func renameGroup(_ group: LWApplicationOrganizationCollection, name: String) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), after = groupAfter, navigation = groupEpoch
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        let current = try await currentGroup(group.id, owner: owner, token: token)
        try checkScope(scope)
        _ = try await owner.perform(.Organization(catalog: token, request: .RenameCollection(id: current.id, expected_revision: current.revision, name: name)))
        try checkScope(scope)
        
        guard groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: after); try checkScope(scope)
    }

    func deleteGroup(_ group: LWApplicationOrganizationCollection) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), after = groupAfter, navigation = groupEpoch
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        let current = try await currentGroup(group.id, owner: owner, token: token)
        try checkScope(scope)
        _ = try await owner.perform(.Organization(catalog: token, request: .DeleteCollection(id: current.id, expected_revision: current.revision)))
        try checkScope(scope)
        if browseOptions.collection == group.id { try await browse(); try checkScope(scope) }
        guard groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: after); try checkScope(scope)
    }

    func placeGroup(_ group: LWApplicationOrganizationCollection, parent: String?) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), after = groupAfter, navigation = groupEpoch
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        let current = try await currentGroup(group.id, owner: owner, token: token)
        try checkScope(scope)
        _ = try await owner.perform(.Organization(catalog: token, request: .PlaceCollection(collection: current.id, expected_revision: current.revision, parent: parent, position: LWCatalogI64(0))))
        try checkScope(scope)
        
        guard groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: after); try checkScope(scope)
    }

    func captureCatalogControl(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant) throws -> LensWorksCatalogControlAdmission {
        try admitCatalogWork()
        guard !isBusy, let asset = selectedAsset, let key = asset.key, let current = currentCatalogVariant,
              current.key.asset_id == key.asset_id, current.key.variant_id == key.variant_id,
              expected.key.asset_id == key.asset_id, expected.key.variant_id == key.variant_id,
              expected.revision == current.revision, expected.recipe_digest == current.recipe_digest else { throw CancellationError() }
        switch action {
        case .recipe(.copy(let label)):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 1024 else { throw LensWorksCatalogError.message("Supply a nonempty catalog copy name of at most 1,024 UTF-8 bytes.") }
        case .recipe(.exposure(let value)):
            guard value.isFinite else { throw LensWorksCatalogError.message("Exposure must be finite.") }
        case .recipe(.undo):
            guard current.can_undo else { throw LensWorksCatalogError.message("This catalog recipe has no Undo step.") }
        case .recipe(.redo):
            guard current.can_redo else { throw LensWorksCatalogError.message("This catalog recipe has no Redo step.") }
        case .rating(let value):
            guard value <= 5 else { throw LensWorksCatalogError.message("Rating must be 0–5.") }
        case .selectVariant(let target):
            guard target.key.asset_id == key.asset_id,
                  catalogVariants.contains(where: { $0.key.asset_id == target.key.asset_id && $0.key.variant_id == target.key.variant_id && $0.revision == target.revision }) else { throw CancellationError() }
        case .moreVariants(let cursor):
            guard catalogVariantsNext == cursor else { throw CancellationError() }
        case .firstVariants: break
        }
        return LensWorksCatalogControlAdmission(scope: captureScope(), image: asset.id, key: key, query: queryOwner,
            selectionOwner: selectionOwner, selectionEpoch: catalogSelectionEpoch, page: pageAuthority, recipe: current, action: action)
    }
    func catalogControlIsCurrent(_ admission: LensWorksCatalogControlAdmission) -> Bool {
        guard scopeIsCurrent(admission.scope), selectedAsset?.id == admission.image,
              selectedAsset?.key?.asset_id == admission.key.asset_id, selectedAsset?.key?.variant_id == admission.key.variant_id,
              queryOwner == admission.query, selectionOwner == admission.selectionOwner,
              catalogSelectionEpoch == admission.selectionEpoch, pageAuthority == admission.page,
              let current = currentCatalogVariant, current.revision == admission.recipe.revision,
              current.recipe_digest == admission.recipe.recipe_digest else { return false }
        return true
    }
    func performCatalogControl(_ admission: LensWorksCatalogControlAdmission) async throws {
        try Task.checkCancellation(); try admitCatalogWork()
        guard catalogControlIsCurrent(admission) else { throw CancellationError() }
        switch admission.action {
        case .firstVariants: try await loadCatalogVariants()
        case .moreVariants(let cursor): try await loadCatalogVariants(after: cursor)
        case .selectVariant(let variant): try await selectCatalogVariant(variant)
        case .recipe(let action): _ = try await changeCatalogRecipe(action)
        case .rating(let value): try await setCatalogRating(value)
        }
    }

    private func checkCatalogSelection(_ scope: LensWorksCatalogScope, image: String, query: String) throws {
        try Task.checkCancellation(); try checkScope(scope)
        guard selectedPhotoID == image, queryOwner == query else { throw CancellationError() }
    }
    var currentCatalogVariant: LWApplicationDtoVariant? {
        guard let scope = catalogVariantScope, scopeIsCurrent(scope), let key = selectedAsset?.key,
              catalogVariant?.key.asset_id == key.asset_id, catalogVariant?.key.variant_id == key.variant_id else { return nil }
        return catalogVariant
    }
    func loadCatalogVariants(after: LWCatalogI64 = LWCatalogI64(0)) async throws {
        try admitCatalogWork()
        guard let asset = selectedAsset, let key = asset.key, let token = catalogToken else { return }
        let scope = captureScope(), query = queryOwner
        if after.value == 0 { catalogVariant = nil; catalogVariants = []; catalogVariantsNext = nil }
        let current = try await service.variant(key)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        let (rows, next) = try await service.catalogVariants(catalog: token, asset: key.asset_id, after: after, limit: rowLimit)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        let master: LWApplicationDtoVariant
        if key.variant_id == "master" { master = current }
        else { master = try await service.variant(LWCatalogEditsVariantKey(asset_id: key.asset_id, variant_id: "master")) }
        try checkCatalogSelection(scope, image: asset.id, query: query)
        guard current.key.asset_id == key.asset_id, current.key.variant_id == key.variant_id else { throw LensWorksManagedError.protocolViolation("Catalog recipe authority changed logical identity.") }
        guard master.key.asset_id == key.asset_id, master.key.variant_id == "master" else { throw LensWorksManagedError.protocolViolation("Catalog master authority changed logical identity.") }
        catalogVariantScope = scope; catalogVariant = current
        // The native page includes persisted recipes; the implicit master is a separate typed authority.
        catalogVariants = [master] + rows.map(\.second).filter { $0.key.variant_id != "master" }; catalogVariantsNext = next
    }
    func selectCatalogVariant(_ variant: LWApplicationDtoVariant) async throws {
        try admitCatalogWork()
        guard !isBusy, let asset = selectedAsset, asset.photoID == variant.key.asset_id, let token = catalogToken,
              catalogVariants.contains(where: { $0.key.asset_id == variant.key.asset_id && $0.key.variant_id == variant.key.variant_id && $0.revision == variant.revision }) else { throw CancellationError() }
        let scope = captureScope(), query = queryOwner, selectedOwner = selectionOwner
        let row = try await service.catalogImage(catalog: token, key: variant.key)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        let focus = LensWorksCatalogAsset(sequence: row.sequence.value, id: row.image_id, originalPath: row.filename, state: row.state,
            previewPath: nil, key: row.key, displayFilename: row.filename, metadataRevision: row.metadata_revision.value,
            origin: row.origin, translationState: row.translation_state, rating: row.rating?.value)
        try await index.setSelection(owner: selectedOwner, rows: [LensWorksSelectedRow(imageID: row.image_id, key: row.key)], replace: true, remove: false)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        guard selectedOwner == selectionOwner else { throw CancellationError() }
        focusedCatalogVariant = focus; focusedCatalogVariantScope = scope
        selectedPhotoID = row.image_id; selectionAnchor = row.image_id
        selection = assets.contains(where: { $0.id == row.image_id }) ? [row.image_id] : []; selectionCount = 1
        catalogVariant = nil; catalogVariants = []; catalogVariantsNext = nil
        await refreshVersions()
    }
    func changeCatalogRecipe(_ action: LensWorksCatalogRecipeAction) async throws -> LWApplicationDtoVariant {
        try admitCatalogWork()
        guard !isBusy, let source = currentCatalogVariant, let asset = selectedAsset, let token = catalogToken else { throw LensWorksCatalogError.message("Choose a current catalog recipe before editing.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), query = queryOwner
        #if DEBUG
        await continuationFixture?(.catalogRecipeAdmission)
        #endif
        try checkCatalogSelection(scope, image: asset.id, query: query)
        let request: LWApplicationRequest
        let creating: Bool
        switch action {
        case .copy(let label):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 1024 else { throw LensWorksCatalogError.message("Supply a nonempty catalog copy name of at most 1,024 UTF-8 bytes.") }
            request = .CreateVariant(catalog: token, key: source.key, expected_revision: source.revision, label: label); creating = true
        case .exposure(let value):
            guard value.isFinite, case .V1(var recipe) = source.recipe else { throw LensWorksCatalogError.message("Exposure must be finite.") }
            recipe.exposure_ev = LWCatalogFloat32(value)
            request = .SaveRecipe(catalog: token, key: source.key, expected_revision: source.revision, recipe: .V1(recipe)); creating = false
        case .undo:
            guard source.can_undo else { throw LensWorksCatalogError.message("This catalog recipe has no Undo step.") }
            request = .Undo(catalog: token, key: source.key, expected_revision: source.revision); creating = false
        case .redo:
            guard source.can_redo else { throw LensWorksCatalogError.message("This catalog recipe has no Redo step.") }
            request = .Redo(catalog: token, key: source.key, expected_revision: source.revision); creating = false
        }
        let next = try await service.catalogVariantChange(catalog: token, request: request, source: source, creating: creating)
        #if DEBUG
        await continuationFixture?(.catalogRecipeReply)
        #endif
        try checkCatalogSelection(scope, image: asset.id, query: query)
        let refreshQuery = queryEpoch &+ 1
        try await refreshAssets(); try checkScope(scope)
        guard queryEpoch == refreshQuery else { throw CancellationError() }
        if let shown = assets.first(where: { $0.key?.asset_id == next.key.asset_id && $0.key?.variant_id == next.key.variant_id }) { await select(shown) }
        else {
            // A copy need not belong to the current virtual group/page. Its exact
            // native row is focus authority; it is never appended to that grid.
            let row = try await service.catalogImage(catalog: token, key: next.key)
            try checkScope(scope)
            guard queryEpoch == refreshQuery else { throw CancellationError() }
            try await selectCreatedCatalogFocus(row, scope: scope, query: queryOwner)
        }
        try checkScope(scope)
        guard selectedAsset?.key?.asset_id == next.key.asset_id, selectedAsset?.key?.variant_id == next.key.variant_id else { throw CancellationError() }
        try await loadCatalogVariants()
        status = "Catalog recipe \(next.label) · revision \(next.revision.value)."
        return next
    }
    private func selectCreatedCatalogFocus(_ row: LWApplicationDtoGridImage, scope: LensWorksCatalogScope, query: String) async throws {
        let owner = selectionOwner, previous = selectedPhotoID
        try await index.setSelection(owner: owner, rows: [LensWorksSelectedRow(imageID: row.image_id, key: row.key)], replace: true, remove: false)
        try checkScope(scope)
        guard owner == selectionOwner, query == queryOwner, selectedPhotoID == previous else { throw CancellationError() }
        focusedCatalogVariant = LensWorksCatalogAsset(sequence: row.sequence.value, id: row.image_id, originalPath: row.filename, state: row.state,
            previewPath: nil, key: row.key, displayFilename: row.filename, metadataRevision: row.metadata_revision.value,
            origin: row.origin, translationState: row.translation_state, rating: row.rating?.value)
        focusedCatalogVariantScope = scope; selectedPhotoID = row.image_id
        selection = []; selectionCount = 1; selectionAnchor = row.image_id
        await refreshVersions()
    }
    func setCatalogRating(_ value: UInt8) async throws {
        try admitCatalogWork()
        guard !isBusy, let asset = selectedAsset, let key = asset.key, let token = catalogToken else { throw CancellationError() }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), query = queryOwner
        _ = try await service.catalogRating(catalog: token, key: key, value: value)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        // Query ordering/filter/cursors may change, but no pixel cache is invalidated.
        try await refreshAssets(); try checkScope(scope)
    }

    func setSelectedMembership(_ group: LWApplicationOrganizationCollection, remove: Bool = false) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); isOrganizing = true; organizationCancelRequested = false
        defer { if busyOwner == busy { isOrganizing = false }; finishBusy(busy) }
        let scope = captureScope(), selectedOwner = selectionOwner, query = queryOwner, afterGroups = groupAfter, navigation = groupEpoch
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token, selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
        if selectionCount == 0, let selectedAsset {
            await select(selectedAsset); try checkScope(scope)
            guard selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
        }
        let total = selectionCount
        guard total > 0 else { throw LensWorksCatalogError.message("Select photos to organize.") }
        var after = "", processed: Int64 = 0
        while true {
            try Task.checkCancellation(); try checkScope(scope)
            guard !organizationCancelRequested, selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
            let page = try await index.selection(owner: selectedOwner, after: after)
            try checkScope(scope)
            guard !organizationCancelRequested, selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
            if page.isEmpty { break }
            for row in page {
                guard case .Organization(.Identity(let identity)) = try await owner.perform(.Organization(catalog: token, request: .Identity(key: row.key))) else { throw LensWorksManagedError.protocolViolation("Expected current photo membership authority.") }
                #if DEBUG
                await continuationFixture?(.membershipIdentity)
                #endif
                try checkScope(scope)
                guard !organizationCancelRequested, selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
                let request: LWApplicationOrganizationRequest = remove ? .Apply(key: row.key, expected_revision: identity.metadata_revision, operation: .RemoveCollection(collection: group.id)) : .SetMember(identity: identity, collection: group.id, position: LWCatalogI64(0))
                _ = try await owner.perform(.Organization(catalog: token, request: request))
                try checkScope(scope)
                guard !organizationCancelRequested, selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
                processed += 1; status = "Organized \(processed) of \(total) selected photos."
            }
            after = page.last!.imageID
        }
        let refreshedQuery = queryEpoch &+ 1
        try await refreshAssets(); try checkScope(scope)
        guard queryEpoch == refreshedQuery, groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: afterGroups); try checkScope(scope)
    }

    func settings(_ request: LWApplicationPreviewSettingsRequest = .Status) async throws {
        try admitCatalogWork()
        let scope = captureScope()
        let (owner, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        if case .BeginRelocation = request {
            guard !isImporting else { throw LensWorksCatalogError.message("Finish or cancel the import before moving preview storage.") }
            try await suspendPreviews(); try checkScope(scope)
        }
        guard case .PreviewSettings(let next) = try await owner.perform(.PreviewSettings(catalog: token, request: request)) else {
            throw LensWorksManagedError.protocolViolation("Expected preview storage authority.")
        }
        try checkScope(scope)
        previewSettings = next
    }

    func suspendPreviews() async throws {
        try admitCatalogWork()
        let scope = captureScope()
        previewsSuspended = true; previewGeneration &+= 1
        try await service.drainPreviews(catalog: scope.token)
        try checkScope(scope)
    }
    func resumePreviews() async {
        guard !closingRequested, settingsTask == nil, previewSettings?.relocation_pending != true else { return }
        let scope = captureScope(), generation = previewGeneration
        guard await service.resumePreviews(catalog: scope.token) else { return }
        guard scopeIsCurrent(scope), previewGeneration == generation, settingsTask == nil, previewSettings?.relocation_pending != true else { return }
        previewsSuspended = false; previewGeneration &+= 1
    }

    func pauseSettingsWork() { settingsPauseRequested = true }
    func resumeSettingsWork() {
        guard !closingRequested else { return }
        guard settingsTask == nil else { return }
        settingsPauseRequested = false
        let epoch = catalogEpoch
        settingsTask = Task { [weak self] in
            defer { self?.settingsTask = nil }
            do {
                guard let self else { return }
                try await self.settings()
                #if DEBUG
                await self.continuationFixture?(.settingsStatus)
                #endif
                guard !Task.isCancelled, !self.closingRequested, self.catalogEpoch == epoch else { return }
                if let roots = self.previewSettings?.original_roots, roots.state == "stale", !roots.roots.isEmpty {
                    try await self.settings(.BeginOriginalRootReview(roots: roots.roots))
                }
                while !Task.isCancelled, !self.settingsPauseRequested, self.catalogEpoch == epoch, let state = self.previewSettings {
                    if let review = state.original_roots.review, state.original_roots.state == "reviewing" {
                        try await self.settings(.StepOriginalRootReview(review: review, directories: 32))
                    } else if state.relocation_pending, let tier = state.relocation_tier {
                        try await self.settings(.StepRelocation(tier: tier, objects: 32, bytes: LWCatalogU64(16 * 1024 * 1024)))
                    } else { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch { if !(error is CancellationError), self?.catalogEpoch == epoch { self?.error = error.localizedDescription } }
        }
    }

    func waitSettings(timeoutMilliseconds: UInt32 = 60_000) async throws {
        try admitCatalogWork()
        guard (1...60_000).contains(timeoutMilliseconds) else { throw LensWorksCatalogError.message("Settings wait must be bounded to 60 seconds.") }
        let epoch = catalogEpoch
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        while true {
            guard catalogEpoch == epoch else { throw CancellationError() }
            try await settings()
            guard !closingRequested, catalogEpoch == epoch else { throw CancellationError() }
            guard let state = previewSettings else { throw LensWorksManagedError.protocolViolation("Preview settings are unavailable.") }
            if !state.relocation_pending && state.original_roots.state != "reviewing" {
                await finishSettingsPause()
                guard !closingRequested, catalogEpoch == epoch else { throw CancellationError() }
                guard state.original_roots.state == "ready" else { throw LensWorksCatalogError.message("Original roots need a fresh review before preview storage can move.") }
                return
            }
            if let error { throw LensWorksCatalogError.message(error) }
            guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Preview maintenance remains pending; pause or resume it using its retained status.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func chooseOutput(window: NSWindow?) async {
        guard !closingRequested else { return }
        let scope = captureScope()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use Folder"; panel.message = "Choose the filesystem folder for your editable working versions."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard scopeIsCurrent(scope), response == .OK, let url = panel.url else { return }
        await setOutput(url.path)
    }

    func setOutput(_ path: String) async {
        guard !closingRequested else { return }
        outputEpoch &+= 1
        let scope = captureScope(), output = outputEpoch
        do {
            let canonical = try await LensWorksVersionStore.shared.canonicalPath(path, outside: scope.path)
            guard scopeIsCurrent(scope), outputEpoch == output else { return }
            outputDirectory = canonical
            defaults.set(canonical, forKey: "LensWorks.outputDirectory")
            await refreshVersions()
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), outputEpoch == output { self.error = error.localizedDescription } }
    }

    func resolveSelectedOriginal() async throws -> LensWorksCatalogAsset {
        guard !closingRequested, let selected = selectedAsset, let key = selected.key else { throw CancellationError() }
        let scope = captureScope(), page = pageAuthority, epoch = catalogSelectionEpoch, owner = selectionOwner
        let resolved = try await service.resolve(selected)
        #if DEBUG
        await continuationFixture?(.originalResolved)
        #endif
        try checkScope(scope)
        guard pageAuthority == page, catalogSelectionEpoch == epoch, selectionOwner == owner,
              let current = selectedAsset, current.id == selected.id,
              current.key?.asset_id == key.asset_id, current.key?.variant_id == key.variant_id,
              current.metadataRevision == selected.metadataRevision,
              resolved.id == selected.id, resolved.key?.asset_id == key.asset_id,
              resolved.key?.variant_id == key.variant_id else { throw CancellationError() }
        let original = try resolved.originalURL
        guard resolved.nativeOriginal != nil, resolved.originalPath == original.path else {
            throw LensWorksManagedError.protocolViolation("Resolved original did not retain its native location.")
        }
        // Publish only the admitted location; preserve the current row's recipe, revision and page.
        if let index = assets.firstIndex(where: { $0.id == current.id && $0.key?.asset_id == key.asset_id && $0.key?.variant_id == key.variant_id }) {
            assets[index].originalPath = resolved.originalPath
            assets[index].nativeOriginal = resolved.nativeOriginal
        } else if var focused = focusedCatalogVariant, focused.id == current.id,
                  focused.key?.asset_id == key.asset_id, focused.key?.variant_id == key.variant_id {
            focused.originalPath = resolved.originalPath
            focused.nativeOriginal = resolved.nativeOriginal
            focusedCatalogVariant = focused
        } else { throw CancellationError() }
        return resolved
    }

    func createWorkingVersion(workspace: ProjectWorkspace) async {
        guard !closingRequested, let selected = selectedAsset, let catalogPath, !isBusy, workspace.canSwitch else { return }
        let scope = captureScope(), selectedID = selected.id
        let busy = beginBusy(); defer { finishBusy(busy) }
        do {
            let asset = try await resolveSelectedOriginal()
            try checkScope(scope)
            guard selectedAsset?.id == selectedID else { throw CancellationError() }
            if outputDirectory == nil { await chooseOutput(window: workspace.window); try checkScope(scope) }
            guard let output = outputDirectory, selectedAsset?.id == selectedID else { return }
            _ = try await LensWorksVersionStore.shared.canonicalPath(output, outside: catalogPath)
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            let rasterTypes = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif"]
            guard rasterTypes.contains(URL(fileURLWithPath: asset.originalPath).pathExtension.lowercased()) else { error = "Live RAW editing is not available in this build."; return }
            let available = await LensWorksVersionStore.shared.sourceAvailable(asset.originalPath, native: asset.nativeOriginal)
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            guard available else { error = "The original photo is offline. Reconnect its location before creating a working version."; return }
            guard workspace.canSwitch else { error = "Finish the current edit before creating a working version."; return }
            let originalURL = try asset.originalURL
            let tab = workspace.addTab()
            await tab.session.importImages([originalURL])
            // This independently admitted document remains usable if catalog scope changed.
            // Its next source binding/save is admitted only under the original authority.
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            guard tab.session.document != nil else { error = tab.session.importError ?? "The photo could not be opened."; return }
            let id = UUID()
            let name = URL(fileURLWithPath: asset.originalPath).deletingPathExtension().lastPathComponent + " – Edit"
            let project = URL(fileURLWithPath: output).appendingPathComponent("\(name)-\(id.uuidString.prefix(8)).comp")
            tab.controller.workingVersion = LensWorksWorkingVersion(id: id, photoID: asset.photoID, catalogPath: catalogPath, originalPath: asset.originalPath, projectPath: project.path, name: name, originalNativePath: asset.nativeOriginal, originalVariantKey: asset.key)
            tab.session.projectURL = project
            let saved = await tab.controller.save()
            // An admitted save completes safely; stale catalog UI/defaults do not follow it.
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            guard saved else { error = "The working version could not be saved."; return }
            noteSaved(project); showingCatalog = false
            await refreshVersions()
        } catch { if !(error is CancellationError), scopeIsCurrent(scope), selectedAsset?.id == selectedID { self.error = error.localizedDescription } }
    }

    func openVersion(_ version: LensWorksWorkingVersion, workspace: ProjectWorkspace) async {
        guard !closingRequested, !isBusy, workspace.canSwitch else { return }
        let scope = captureScope()
        guard version.catalogPath == scope.path, let selected = selectedAsset,
              selected.photoID == version.photoID, (selected.key?.variant_id ?? "master") == version.sourceVariantID else { return }
        let busy = beginBusy(); defer { finishBusy(busy) }
        do { _ = try await resolveSelectedOriginal() }
        catch {
            if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription }
            return
        }
        let opened = await workspace.open(URL(fileURLWithPath: version.projectPath))
        guard scopeIsCurrent(scope), opened else { return }
        selectedPhotoID = assets.first { $0.photoID == version.photoID && $0.key?.variant_id == version.sourceVariantID }?.id
        showingCatalog = false
        defaults.set(version.projectPath, forKey: "LensWorks.lastWorkingVersion")
    }

    func noteSaved(_ project: URL) { defaults.set(project.path, forKey: "LensWorks.lastWorkingVersion") }
    func reconcileWorkingVersions() async {
        guard !closingRequested else { return }
        let scope = captureScope(), output = outputDirectory
        let errors = await index.migrateLegacyDefaults(defaults: defaults, retry: true)
        guard scopeIsCurrent(scope), outputDirectory == output else { return }
        if !errors.isEmpty { self.error = errors.joined(separator: "\n") }
        if let output {
            do {
                let discovery = try await index.discover(output, restart: true)
                guard scopeIsCurrent(scope), outputDirectory == output else { return }
                versionDiscoveryPending = discovery.hasMore; versionDiscoveryScanned = discovery.scanned
                if !discovery.errors.isEmpty { error = discovery.errors.joined(separator: "\n") }
            } catch { if !(error is CancellationError), scopeIsCurrent(scope), outputDirectory == output { self.error = error.localizedDescription } }
        }
        guard scopeIsCurrent(scope), outputDirectory == output else { return }
        await refreshVersions()
    }

    private func retireSettingsWork(cancel: Bool = true, timeoutMilliseconds: UInt32 = 30000) async throws {
        settingsPauseRequested = true
        if cancel { settingsTask?.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        while settingsTask != nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LensWorksManagedError.native(code: "draining", message: "Preview maintenance is still retiring. Its task and catalog owner remain retained for retry.") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func finishSettingsPause() async {
        let epoch = catalogEpoch
        do { try await retireSettingsWork(cancel: false) }
        catch { if !(error is CancellationError), !closingRequested, catalogEpoch == epoch { self.error = error.localizedDescription } }
    }

    func close(retirementTimeoutMilliseconds: UInt32 = 60000) async throws {
        guard !closeInFlight else { throw LensWorksManagedError.native(code: "busy", message: "Catalog retirement is already being observed.") }
        closingRequested = true
        closeInFlight = true; defer { closeInFlight = false }
        catalogEpoch &+= 1; folderEpoch &+= 1; groupEpoch &+= 1; previewGeneration &+= 1
        await service.beginRetirement()
        // Settings task retirement adds a separate, explicit 30-second observation bound.
        importMonitor?.cancel(); try await retireSettingsWork(); await service.cancelPreviews()
        try await service.close(retirementTimeoutMilliseconds: retirementTimeoutMilliseconds)
        lastClosedCatalogPath = catalogPath
        try await index.clearSelection(owner: selectionOwner); try await index.clearVisits(owner: queryOwner)
        catalogPath = nil; catalogToken = nil; assets = []; folders = []; groups = []; placements = [:]
        selection = []; selectedPhotoID = nil; cursorWindow.reset(); hasMore = false
        importProgress = nil; importSamples = []; importMonitor = nil
        busyOwner = nil; isOrganizing = false
        closingRequested = false
    }

    func thumbnail(_ asset: LensWorksCatalogAsset, tier: LWApplicationDtoPreviewTier = .Thumbnail) async throws -> LensWorksPreview {
        try admitCatalogWork()
        guard !previewsSuspended else { throw LensWorksCatalogError.message("Previews are paused for storage maintenance.") }
        let scope = captureScope(), generation = previewGeneration
        let preview = try await service.preview(asset, tier: tier)
        try checkScope(scope)
        guard previewGeneration == generation else { throw CancellationError() }
        return preview
    }

    func refreshVersions(after: String? = nil) async {
        guard !closingRequested else { return }
        let epoch = catalogEpoch, selected = selectedAsset, output = outputDirectory, catalog = catalogPath
        do {
            if let output {
                let discovery = try await index.discover(output)
                guard catalogEpoch == epoch, outputDirectory == output, selectedAsset?.id == selected?.id else { return }
                versionDiscoveryPending = discovery.hasMore; versionDiscoveryScanned = discovery.scanned
                if !discovery.errors.isEmpty { self.error = "Some working versions need reconciliation. Their files remain unchanged.\n" + discovery.errors.joined(separator: "\n") }
            }
            guard catalogEpoch == epoch, outputDirectory == output, selectedAsset?.id == selected?.id else { return }
            guard let catalog, let selected else { versions = []; versionNext = nil; return }
            let page = try await index.versions(catalog: catalog, photo: selected.photoID, variant: selected.key?.variant_id ?? "master", after: after)
            guard catalogEpoch == epoch, outputDirectory == output, selectedAsset?.id == selected.id else { return }
            versions = page.versions; versionNext = page.next; versionsHighWater = max(versionsHighWater, versions.count)
            if !page.errors.isEmpty { error = "Some working versions could not be read. Their files remain unchanged.\n" + page.errors.joined(separator: "\n") }
        } catch {
            if !(error is CancellationError), catalogEpoch == epoch, outputDirectory == output, selectedAsset?.id == selected?.id { self.error = error.localizedDescription }
        }
    }

    func restore(workspace: ProjectWorkspace) async {
        guard !closingRequested else { return }
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
        let startupEpoch = catalogEpoch
        outputDirectory = defaults.string(forKey: "LensWorks.outputDirectory")
        if let output = value("--lensworks-output") {
            LensWorksLaunchTrace.record("catalog.restore.setOutput.begin")
            await setOutput(output)
            LensWorksLaunchTrace.record("catalog.restore.setOutput.end")
        }
        guard !closingRequested, catalogEpoch == startupEpoch else { return }
        if let plan = value("--lensworks-catalog-plan") {
            do { try await executeCatalogPlan(plan) } catch { self.error = error.localizedDescription }
            await writeCatalogEvidence(value("--lensworks-evidence"), workspace: workspace)
            if arguments.contains("--lensworks-quit") { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
            return
        }
        let expectedOpenEpoch = catalogEpoch &+ ((value("--lensworks-catalog") != nil || defaults.string(forKey: "LensWorks.catalogPath") != nil) ? 1 : 0)
        if let path = value("--lensworks-catalog") {
            LensWorksLaunchTrace.record("catalog.restore.connect.begin")
            await connect(path, create: arguments.contains("--lensworks-create-catalog"))
            LensWorksLaunchTrace.record("catalog.restore.connect.end", details: ["connected": String(catalogPath != nil), "error": error ?? ""])
        } else if let path = defaults.string(forKey: "LensWorks.catalogPath") { await connect(path) }
        guard !closingRequested, catalogEpoch == expectedOpenEpoch else { return }
        let restorationEpoch = catalogEpoch
        if let folder = value("--lensworks-import") { await importFolder(folder) }
        guard !closingRequested, catalogEpoch == restorationEpoch else { return }
        if arguments.contains("--lensworks-create-version") { await createWorkingVersion(workspace: workspace) }
        else if let path = defaults.string(forKey: "LensWorks.lastWorkingVersion"), workspace.current.session.document == nil {
            let scope = captureScope()
            do {
                let project = URL(fileURLWithPath: path)
                let version = try await LensWorksVersionStore.shared.readIfExists(project)
                try checkScope(scope)
                if let version, version.catalogPath == scope.path {
                    let opened = await workspace.open(project)
                    try checkScope(scope)
                    if opened { selectedPhotoID = assets.first { $0.photoID == version.photoID && $0.key?.variant_id == version.sourceVariantID }?.id }
                }
            } catch { if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription } }
        }
        guard !closingRequested, catalogEpoch == restorationEpoch else { return }
        if let name = value("--lensworks-edit-name"), let layer = workspace.current.session.activeLayerID {
            workspace.current.session.renameLayer(layer, to: name)
            _ = await workspace.current.controller.save()
        }
        guard !closingRequested, catalogEpoch == restorationEpoch else { return }
        if let value = value("--lensworks-edit-opacity") {
            if let opacity = Double(value), opacity.isFinite, (0...1).contains(opacity), workspace.current.session.activeLayerID != nil {
                workspace.current.session.setLayerOpacity(opacity)
                _ = await workspace.current.controller.save()
            } else { error = "The layer opacity must be a number from 0 to 1, with a working version open." }
        }
        guard !closingRequested, catalogEpoch == restorationEpoch else { return }
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
