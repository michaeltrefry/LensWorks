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
    var flag = "unflagged"
    var label = ""
    var photoID: String { key?.asset_id ?? id }
    /// Compact rating/flag/label text shown on the grid cell and exposed to accessibility.
    var organizationSummary: String {
        var parts: [String] = []
        if let rating, rating > 0 { parts.append(String(repeating: "★", count: Int(min(rating, 5)))) }
        if flag != "unflagged" { parts.append(flag.capitalized) }
        if !label.isEmpty { parts.append(label) }
        return parts.joined(separator: " · ")
    }
    /// The summary with an explicit 0 rating spelled out, so it is never mistaken for no rating.
    var organizationAccessibility: String {
        guard rating == 0 else { return organizationSummary }
        return organizationSummary.isEmpty ? "Rating 0" : "Rating 0 · " + organizationSummary
    }
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
nonisolated enum LensWorksCatalogContinuationPoint: Sendable, Equatable { case groupRead, membershipIdentity, organizationApplied, importMonitorTerminal, settingsStatus, catalogRecipeAdmission, catalogRecipeReply, originalResolved }
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
    /// Test fault before an original-availability observation reaches the worker.
    private var originalObservationFixture: (@Sendable (LWCatalogEditsVariantKey) async throws -> Void)?
    func setOriginalObservationFixture(_ fixture: (@Sendable (LWCatalogEditsVariantKey) async throws -> Void)?) { originalObservationFixture = fixture }
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
    #if DEBUG
    /// Test observation of bounded organization list fetches (keywords, collections, members).
    private(set) var organizationListCalls = 0
    private(set) var organizationListLimitHighWater: UInt16 = 0
    #endif
    #if DEBUG
    /// Test observation of every organization request sent to the worker.
    private(set) var organizationRequests = 0
    #endif
    /// One state snapshot per photo (at most one page), in key order.
    func organizationStates(_ keys: [LWCatalogEditsVariantKey], keywords: [LensWorksKeywordTarget] = [], collection: String? = nil) async throws -> [LWApplicationOrganizationImageState] {
        guard !keys.isEmpty, keys.count <= 100 else { throw LensWorksManagedError.resourceLimit("Organization state reads are one page at a time.") }
        guard case .States(let states) = try await organization(.States(keys: keys, keywords: keywords.map(\.wire), collection: collection)), states.count == keys.count,
              zip(states, keys).allSatisfy({ $0.identity.key.asset_id == $1.asset_id && $0.identity.key.variant_id == $1.variant_id }) else {
            throw LensWorksManagedError.protocolViolation("Expected one organization state per photo.")
        }
        return states
    }
    func organization(_ request: LWApplicationOrganizationRequest) async throws -> LWApplicationOrganizationResponse {
        let (owner, token) = try context()
        #if DEBUG
        organizationRequests += 1
        switch request {
        case .Keywords(_, _, _, let limit), .Collections(_, let limit), .Members(_, _, let limit):
            organizationListCalls += 1; organizationListLimitHighWater = max(organizationListLimitHighWater, limit)
        default: break
        }
        #endif
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
        switch try await observedOriginal(session: session, catalog: catalog, key: key).status.current {
        case .Native(let path): return path
        case .LegacyUnix(let units): return .unixBytes(units)
        case .LegacyWindows(let units): return .windowsWide(units)
        case .Unspecified: throw LensWorksCatalogError.message("The original needs an explicit native location before editing.")
        }
    }
    private func observedOriginal(session: LWManagedSession, catalog: String, key: LWCatalogEditsVariantKey) async throws -> LWApplicationRelinkOriginal {
        var response = try await session.perform(.Relink(catalog: catalog, request: .Original(key: key)))
        while true {
            guard case .Relink(.Operation(let operation)) = response, let operation else { throw LensWorksManagedError.protocolViolation("Expected an original-location operation.") }
            if case .Original(let original) = operation.result {
                guard original.key.asset_id == key.asset_id, original.key.variant_id == key.variant_id else {
                    throw LensWorksManagedError.protocolViolation("Expected the requested original's status.")
                }
                return original
            }
            if [.Failed, .Canceled].contains(operation.phase) { throw LensWorksCatalogError.message(operation.error ?? "The original location could not be observed.") }
            try await Task.sleep(for: .milliseconds(10))
            response = try await session.perform(.Relink(catalog: catalog, request: .Status(operation: operation.id)))
        }
    }
    /// The original's availability observed now, independent of any open Locate Originals review.
    func observeOriginal(_ key: LWCatalogEditsVariantKey) async throws -> LWApplicationRelinkOriginal {
        let (owner, token) = try context()
        #if DEBUG
        try await originalObservationFixture?(key)
        #endif
        return try await observedOriginal(session: owner, catalog: token, key: key)
    }
    /// The original's current native location, for documents opened from it.
    func originalLocation(_ key: LWCatalogEditsVariantKey) async throws -> LWCatalogNativePath {
        let (owner, token) = try context()
        return try await original(session: owner, catalog: token, key: key)
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

/// Who made the recipe changes a catalog copy's Undo and Redo would step over, newest last. The engine keeps the
/// recipe history itself and records no author, so LensWorks keeps this beside it (in its index, across launches),
/// tied to the exact revision and recipe it describes. A step it has no record of is the person's.
nonisolated struct LensWorksRecipeOrigins: Sendable, Equatable {
    static let limit = 256
    var undo: [LensWorksCommandOrigin] = []
    var redo: [LensWorksCommandOrigin] = []
    init() {}
    init(undo: String, redo: String) {
        self.undo = undo.map { $0 == "a" ? .agent : .user }; self.redo = redo.map { $0 == "a" ? .agent : .user }
    }
    var encodedUndo: String { String(undo.suffix(Self.limit).map { $0 == .agent ? "a" : "u" }) }
    var encodedRedo: String { String(redo.suffix(Self.limit).map { $0 == .agent ? "a" : "u" }) }
    /// The history after `origin` made `action`, which left the copy able to undo and redo as given.
    func recording(_ action: LensWorksCatalogRecipeAction, by origin: LensWorksCommandOrigin, canUndo: Bool, canRedo: Bool) -> Self {
        var next = self
        switch action {
        case .copy: break
        case .exposure: next.undo.append(origin)
        case .undo: next.redo.append(next.undo.popLast() ?? .user)
        case .redo: next.undo.append(next.redo.popLast() ?? .user)
        }
        // The engine's own answer bounds the record: it never names a step the engine does not have (a save leaves
        // nothing to redo).
        if !canUndo { next.undo = [] }
        if !canRedo { next.redo = [] }
        return next
    }
}

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

/// A keyword term of one kind: what a state read reports and a step replays against.
nonisolated struct LensWorksKeywordTarget: Sendable, Hashable, Codable {
    let kind: LWOrganizationKeywordKind
    let path: [String]
    init(_ path: [String], kind: LWOrganizationKeywordKind = .Hierarchical) { self.kind = kind; self.path = path }
    init(_ keyword: LWApplicationOrganizationKeyword) { self.init(keyword.path, kind: keyword.kind) }
    var wire: LWApplicationOrganizationKeywordTarget { LWApplicationOrganizationKeywordTarget(kind: kind, path: path) }
    /// This term or one nested under it (flat keywords have no nesting).
    func covers(_ other: LensWorksKeywordTarget) -> Bool {
        kind == other.kind && (kind == .Flat ? other.path == path : other.path.starts(with: path))
    }
    func validate() throws {
        guard !path.isEmpty, path.count <= 64, kind != .Flat || path.count == 1,
              path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && ($0.contains("|") == false || kind == .Flat) && !$0.contains("\0") }) else {
            throw LensWorksCatalogError.message("A keyword needs 1–64 nonempty levels without “|” (flat keywords have one).")
        }
    }
}

/// One organization change applied to the selected photos as a single undoable step.
nonisolated enum LensWorksOrganizationChange: Sendable, Equatable {
    case rating(UInt8)
    case flag(LWOrganizationFlag)
    /// An empty label removes `xmp:Label`.
    case label(String)
    case addKeyword([String], kind: LWOrganizationKeywordKind = .Hierarchical)
    case removeKeyword([String], kind: LWOrganizationKeywordKind = .Hierarchical)
    case addCollection(String)
    case removeCollection(String)
    var operation: LWOrganizationOperation {
        switch self {
        case .rating(let value): .Rating(value: value)
        case .flag(let value): .Flag(value: value)
        case .label(let value): value.isEmpty ? .RestoreLabel(value: nil) : .Label(value: value)
        case .addKeyword(let path, let kind): .AddKeyword(kind: kind, path: path)
        case .removeKeyword(let path, let kind): .RemoveKeyword(kind: kind, path: path)
        case .addCollection(let id): .AddCollection(collection: id)
        case .removeCollection(let id): .RemoveCollection(collection: id)
        }
    }
    var title: String {
        switch self {
        case .rating(let value): value == 0 ? "Clear Rating" : "Rating \(value)"
        case .flag(let value): "Flag " + value.rawValue.capitalized
        case .label(let value): value.isEmpty ? "Clear Label" : "Label " + value
        case .addKeyword(let path, _): "Add Keyword " + path.joined(separator: " > ")
        case .removeKeyword(let path, _): "Remove Keyword " + path.joined(separator: " > ")
        case .addCollection: "Add to Virtual Folder"
        case .removeCollection: "Remove from Virtual Folder"
        }
    }
    var keywordTargets: [LensWorksKeywordTarget] {
        switch self {
        case .addKeyword(let path, let kind), .removeKeyword(let path, let kind): [LensWorksKeywordTarget(path, kind: kind)]
        default: []
        }
    }
    var collection: String? {
        switch self {
        case .addCollection(let id), .removeCollection(let id): id
        default: nil
        }
    }
    /// The exact inverse for one photo, from its state read just before the write.
    func inverse(from state: LWApplicationOrganizationImageState) -> LensWorksOrganizationEdit {
        switch self {
        case .rating: LensWorksOrganizationEdit([.RestoreRating(value: state.rating)])
        case .flag: LensWorksOrganizationEdit([.RestoreFlag(value: state.flag)])
        case .label: LensWorksOrganizationEdit([.RestoreLabel(value: state.label)])
        case .addKeyword(let path, let kind): LensWorksOrganizationEdit([.RemoveKeyword(kind: kind, path: path)])
        case .removeKeyword(let path, let kind): LensWorksOrganizationEdit([.AddKeyword(kind: kind, path: path)])
        case .addCollection(let id): LensWorksOrganizationEdit([.RemoveCollection(collection: id)])
        case .removeCollection(let id): LensWorksOrganizationEdit([.AddCollection(collection: id)], position: state.position?.value ?? 0)
        }
    }
    func validate() throws {
        switch self {
        case .rating(let value): guard value <= 5 else { throw LensWorksCatalogError.message("Rating must be 0–5.") }
        case .label(let value): guard value.utf8.count <= 1024, !value.contains("\0") else { throw LensWorksCatalogError.message("Labels are at most 1,024 UTF-8 bytes.") }
        case .addKeyword(let path, let kind), .removeKeyword(let path, let kind): try LensWorksKeywordTarget(path, kind: kind).validate()
        case .flag, .addCollection, .removeCollection: break
        }
    }
}

/// The recorded forward or inverse effect on one photo: compare-and-set operations
/// applied in order, plus the ordered virtual-folder position an AddCollection restores.
nonisolated struct LensWorksOrganizationEdit: Codable, Sendable {
    var operations: [LWOrganizationOperation]
    var position: Int64?
    init(_ operations: [LWOrganizationOperation], position: Int64? = nil) { self.operations = operations; self.position = position }
}

/// A recorded keyword-dictionary edit. Keywords are addressed by kind and path, so
/// a replay finds whichever identity currently holds that path.
nonisolated enum LensWorksKeywordEdit: Codable, Sendable {
    case create(LensWorksKeywordTarget)
    case delete(LensWorksKeywordTarget)
    case addSynonym(LensWorksKeywordTarget, String)
    case removeSynonym(LensWorksKeywordTarget, String)
}

extension LWApplicationOrganizationImageState {
    /// Whether the photo already holds the state an operation sets.
    func holds(_ operation: LWOrganizationOperation) -> Bool {
        switch operation {
        case .Rating(let value): rating.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } == Double(value)
        case .RestoreRating(let value): rating == value
        case .Label(let value): label == value
        case .RestoreLabel(let value): label == value
        case .Flag(let value): effective_flag == value
        case .RestoreFlag(let value): flag == value
        case .AddKeyword(let kind, let path): keywords.contains { $0.kind == kind && $0.path == path }
        case .RemoveKeyword(let kind, let path): !keywords.contains { $0.kind == kind && $0.path == path }
        case .MoveKeyword(let from, _): !keywords.contains { $0.kind == .Hierarchical && $0.path.starts(with: from) }
        case .AddCollection: member == true
        case .RemoveCollection: member == false
        }
    }
    func holds(_ edit: LensWorksOrganizationEdit) -> Bool {
        edit.operations.allSatisfy(holds) && (edit.position == nil || position?.value == edit.position)
    }
}

/// One photo to write, with the state read whose revision the write compares against.
nonisolated struct LensWorksOrganizationItem: Sendable {
    let row: LensWorksSelectedRow
    let state: LWApplicationOrganizationImageState
}
nonisolated struct LensWorksOrganizationOutcome: Sendable {
    var changed: Int64 = 0
    var recorded: Int64 = 0
    var skipped: [String] = []
    var skippedCount: Int64 = 0
    var keptKeywords: [String] = []
    mutating func skip(_ image: String) { skippedCount += 1; if skipped.count < 100 { skipped.append(image) } }
}

/// An undoable organization step; its per-photo and dictionary records live in the
/// disk-backed index. `keywords`/`collection` are what a replay's state read covers.
nonisolated struct LensWorksOrganizationStep: Sendable, Equatable {
    let id: Int64
    let title: String
    let photos: Int64
    var keywords: [LensWorksKeywordTarget] = []
    var collection: String? = nil
    var dictionary: Int64 = 0
    /// Who made the step: an agent's is titled “(Agent)”, and an agent undoes and redoes only its own.
    var origin = LensWorksCommandOrigin.user
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
    /// A catalog scope ending (connect, close) cancels a running Merge to HDR….
    private(set) var catalogEpoch: UInt64 = 0 { didSet { hdrMerge?.cancel() } }
    /// The running Merge to HDR…; its Cancel command and the end of the catalog scope cancel it.
    var hdrMerge: Task<LensWorksHDRMergeOutcome, Error>?
    /// True once the merged DNG is being added to the catalog, when the merge can no longer be cancelled.
    var hdrMergeAdmitting = false
    #if DEBUG
    /// Opt-in test observation of a merge after its DNG is in place and before the catalog import.
    @ObservationIgnored var hdrMergeWrittenFixture: ((URL) async throws -> Void)?
    #endif
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
    /// Only the latest working-version listing publishes; an earlier one finishing later would show a stale list.
    @ObservationIgnored private var versionRefreshGeneration: UInt64 = 0
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
    private(set) var keywords: [LWApplicationOrganizationKeyword] = []
    private(set) var keywordParent: LWApplicationOrganizationKeyword?
    private(set) var keywordNext: LWCatalogI64?
    @ObservationIgnored private var keywordTrail: [LWApplicationOrganizationKeyword] = []
    @ObservationIgnored private var keywordEpoch: UInt64 = 0
    /// The recorded recipe-history origins of the copy shown, with the revision and recipe they describe.
    private(set) var catalogRecipeOrigins: (key: LWCatalogEditsVariantKey, revision: LWCatalogI64, digest: String, origins: LensWorksRecipeOrigins)?
    private(set) var organizationUndo: [LensWorksOrganizationStep] = []
    private(set) var organizationRedo: [LensWorksOrganizationStep] = []
    @ObservationIgnored private var organizationStepID: Int64 = 0
    static let organizationHistoryLimit = 50
    /// Active metadata filters, combined with folder, virtual folder and text scope.
    var filterSummary: [String] {
        var parts: [String] = []
        if let rating = browseOptions.rating { parts.append("Rating = \(rating)") }
        if let flag = browseOptions.flag { parts.append("Flag: " + flag.rawValue.capitalized) }
        if let label = browseOptions.label { parts.append("Label: " + label) }
        if browseOptions.keyword != nil { parts.append("Keyword: " + (filterKeywordName ?? "selected")) }
        return parts
    }
    @ObservationIgnored private(set) var filterKeywordName: String?
    @ObservationIgnored private var filterKeyword: LensWorksKeywordTarget?
    private(set) var keywordKind: LWOrganizationKeywordKind = .Hierarchical
    /// Photos (first 100 image ids, and the total) the last change or replay left
    /// unchanged because they changed after being read; keywords a delete kept in use.
    private(set) var organizationSkipped: [String] = []
    private(set) var organizationSkippedCount: Int64 = 0
    private(set) var organizationKeptKeywords: [String] = []
    @ObservationIgnored private var organizationHistoryEpoch: UInt64 = 0
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
    /// Locate Originals review and storage-operation custody for this catalog.
    @ObservationIgnored let relink = LensWorksRelinkReview()
    /// Observed original availability, by catalog photo (shared by its logical copies).
    private(set) var originalStatuses: [String: LWCatalogStorageStorageStatus] = [:]
    /// Why the latest observation of a photo's original failed; its availability stays unknown.
    private(set) var originalObservationErrors: [String: String] = [:]
    /// Editor workspaces whose open working versions follow applied and undone relinks.
    @ObservationIgnored private var editorWorkspaces: [LensWorksWeakWorkspace] = []
    @ObservationIgnored private var storageObservers: LensWorksStorageObservers?
    @ObservationIgnored let index: LensWorksCatalogIndex
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let migrateLegacy: Bool
    @ObservationIgnored private let rowLimit: UInt16
    @ObservationIgnored private var catalogSelectionEpoch: UInt64 = 0
    @ObservationIgnored private var selectionOwner = UUID().uuidString
    /// The selection a catalog command (Merge to HDR…) reads, captured at admission.
    var selectionOwnerForCommands: String { selectionOwner }
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
    var navigationResidency: Int { folders.count + groups.count + placements.count + folderTrail.count + keywords.count + keywordTrail.count }
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
    init(configuration: LWManagedSessionConfig? = nil, index: LensWorksCatalogIndex = .shared, defaults: UserDefaults = LensWorksUserState.defaults, migrateLegacy: Bool = false, catalogService: LensWorksCatalogService? = nil) {
        service = catalogService ?? LensWorksCatalogService(configuration: configuration)
        self.index = index; self.defaults = defaults; self.migrateLegacy = migrateLegacy
        rowLimit = min(100, configuration?.limits?.page_rows ?? 100)
        relink.catalog = self
        storageObservers = LensWorksStorageObservers { [weak self] in self?.forgetOriginalAvailability() }
    }
    func beginBusy() -> UUID { let owner = UUID(); busyOwner = owner; return owner }
    func finishBusy(_ owner: UUID) { if busyOwner == owner { busyOwner = nil } }
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
        relink.reset(); forgetOriginalAvailability()
        hasMore = false; pageStart = 0; cursorWindow.reset()
        folders = []; groups = []; placements = [:]; folderTrail = []; folderParent = nil; folderNext = nil; groupNext = nil; catalogToken = nil; selection = []; importProgress = nil
        keywords = []; keywordParent = nil; keywordNext = nil; keywordTrail = []; keywordEpoch &+= 1
        browseOptions.rating = nil; browseOptions.flag = nil; browseOptions.label = nil; browseOptions.keyword = nil; filterKeywordName = nil; filterKeyword = nil; keywordKind = .Hierarchical
        await resetOrganizationHistory()
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
            try await loadKeywords()
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
    /// `path` is a folder, walked recursively, or one regular file, imported alone (its folder is
    /// not walked). `remember: false` leaves the folder-import resume source as it was.
    func startImport(_ path: String? = nil, resume: Bool = false, remember: Bool = true) async throws {
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
        if remember, let key = checkpoint { defaults.set(try LWCatalogCodec.encode(source), forKey: key) }
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
    /// Imports exactly one file through the engine's single-file import route and selects its
    /// catalog photo. Nothing else in the file's folder is imported, the folder-import resume
    /// source is not replaced, and the browse scope, filters and search text are left alone.
    func importOriginal(_ url: URL) async throws -> LensWorksCatalogAsset {
        let scope = captureScope()
        try await startImport(url.path, remember: false)
        try checkScope(scope)
        // A large original's previews can outlast one 60-second observation window.
        var windows = 1
        while true {
            do { try await waitImport(terminal: true); break }
            catch LensWorksCatalogError.importObservationTimeout where windows < 10 { windows += 1; try checkScope(scope) }
        }
        try checkScope(scope)
        guard let row = try await recentCatalogRow(original: url) else {
            throw LensWorksCatalogError.message("“\(url.lastPathComponent)” was written but the catalog did not add it" + (importProgress?.error.map { ": " + $0 } ?? "."))
        }
        try checkScope(scope)
        if let shown = assets.first(where: { $0.id == row.image_id }) { await select(shown) }
        else { try await selectCreatedCatalogFocus(row, scope: scope, query: queryOwner) }
        try checkScope(scope)
        guard let asset = selectedAsset, asset.id == row.image_id else { throw CancellationError() }
        return asset
    }
    /// The catalog photo whose original is the file at `url`, searched newest first without
    /// touching the browse state. A photo is identified by its original's location, never by its
    /// file name alone: the same name can exist in another cataloged folder.
    func recentCatalogRow(original url: URL) async throws -> LWApplicationDtoGridImage? {
        try admitCatalogWork()
        let scope = captureScope(), name = url.lastPathComponent
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let options = LWApplicationBrowseOptions(text: nil, keyword: nil, keyword_direct: false, folder: nil, folder_recursive: true, collection: nil, date_from: nil, date_until: nil, camera_make: nil, camera: nil, lens: nil, format: nil, rating: nil, flag: nil, label: nil, only_conflicted: false, sort: .Sequence, direction: .Descending)
        var cursor: String?
        for _ in 0..<64 {
            let page = try await service.browse(options: options, cursor: cursor)
            try checkScope(scope)
            for row in page.rows where URL(fileURLWithPath: row.filename).lastPathComponent == name {
                let location = try await service.originalLocation(row.key).localFileURL()
                try checkScope(scope)
                if location.resolvingSymlinksInPath().standardizedFileURL.path == target { return row }
            }
            guard page.hasMore, let next = page.next, next != cursor else { return nil }
            cursor = next
        }
        return nil
    }
    /// The source photos a merged HDR photo is linked to in this catalog; empty for any other photo.
    func hdrMergeSources(of asset: LensWorksCatalogAsset) async throws -> [LensWorksDerivedSource] {
        guard let catalogPath else { return [] }
        return try await index.sources(catalog: catalogPath, image: asset.id)
    }
    /// Follows a merged HDR photo's link: its source photos become the catalog selection.
    func selectHDRMergeSources(of asset: LensWorksCatalogAsset) async throws {
        try admitCatalogWork()
        let scope = captureScope(), owner = selectionOwner, query = queryOwner, generation = previewGeneration
        let sources = try await hdrMergeSources(of: asset)
        try checkScope(scope)
        guard !sources.isEmpty else { throw LensWorksCatalogError.message("“\(asset.filename)” has no recorded HDR merge sources in this catalog.") }
        catalogSelectionEpoch &+= 1
        try await index.setSelection(owner: owner, rows: sources.map(\.row), replace: true)
        try checkScope(scope)
        guard owner == selectionOwner, query == queryOwner, generation == previewGeneration else { throw CancellationError() }
        selectionAnchor = nil
        if let shown = assets.first(where: { row in sources.contains { $0.imageID == row.id } }) { selectedPhotoID = shown.id }
        try await refreshSelectionProjection(owner: owner, query: query, scope: scope, generation: generation)
        status = "Selected the \(sources.count) source photos of \(asset.filename)."
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
                origin: row.origin, translationState: row.translation_state, rating: row.rating?.value, flag: row.flag, label: row.label)
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
        forgetOriginalAvailability() // A drive may have connected or disconnected; re-observe on demand.
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
        guard case .Collections(let page) = try await service.organization(.Collections(after: after, limit: rowLimit)), page.rows.count <= 100 else { throw LensWorksManagedError.protocolViolation("Expected a bounded virtual-folder page.") }
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

    /// Who made the recipe change Undo (or Redo) would step over on the current copy; nil when there is none or it
    /// was not recorded, which reads as the person's.
    func recipeHistoryOrigin(redo: Bool) -> LensWorksCommandOrigin? {
        guard let current = currentCatalogVariant, let recorded = catalogRecipeOrigins, recorded.revision == current.revision,
              recorded.digest == current.recipe_digest, recorded.key.asset_id == current.key.asset_id, recorded.key.variant_id == current.key.variant_id,
              redo ? current.can_redo : current.can_undo else { return nil }
        return redo ? recorded.origins.redo.last : recorded.origins.undo.last
    }
    /// The rule document and organize history follow: an agent steps only over its own recipe changes.
    static func recipeOwnershipRefusal(redo: Bool) -> LensWorksCatalogError {
        .message(redo ? "The next catalog recipe change to redo is the person’s own: an agent redoes only its own."
                      : "The last catalog recipe change is the person’s own: an agent undoes only its own.")
    }
    func captureCatalogControl(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant, origin: LensWorksCommandOrigin = .user) throws -> LensWorksCatalogControlAdmission {
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
            try requireFullResolutionOriginal(asset)
        case .recipe(.undo):
            guard current.can_undo else { throw LensWorksCatalogError.message("This catalog recipe has no Undo step.") }
            guard origin != .agent || recipeHistoryOrigin(redo: false) == .agent else { throw Self.recipeOwnershipRefusal(redo: false) }
            try requireFullResolutionOriginal(asset)
        case .recipe(.redo):
            guard current.can_redo else { throw LensWorksCatalogError.message("This catalog recipe has no Redo step.") }
            guard origin != .agent || recipeHistoryOrigin(redo: true) == .agent else { throw Self.recipeOwnershipRefusal(redo: true) }
            try requireFullResolutionOriginal(asset)
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
    func performCatalogControl(_ admission: LensWorksCatalogControlAdmission, origin: LensWorksCommandOrigin = .user) async throws {
        try Task.checkCancellation(); try admitCatalogWork()
        guard catalogControlIsCurrent(admission) else { throw CancellationError() }
        switch admission.action {
        case .firstVariants: try await loadCatalogVariants()
        case .moreVariants(let cursor): try await loadCatalogVariants(after: cursor)
        case .selectVariant(let variant): try await selectCatalogVariant(variant)
        case .recipe(let action): _ = try await changeCatalogRecipe(action, origin: origin)
        case .rating(let value): try await setCatalogRating(value, origin: origin)
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
        // Who made this copy's recipe history, as recorded for exactly this revision and recipe.
        let origins = try? await index.recipeOrigins(catalog: scope.path ?? "", key: current.key, revision: current.revision.value, digest: current.recipe_digest)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        catalogRecipeOrigins = origins.map { (current.key, current.revision, current.recipe_digest, $0) }
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
            origin: row.origin, translationState: row.translation_state, rating: row.rating?.value, flag: row.flag, label: row.label)
        try await index.setSelection(owner: selectedOwner, rows: [LensWorksSelectedRow(imageID: row.image_id, key: row.key)], replace: true, remove: false)
        try checkCatalogSelection(scope, image: asset.id, query: query)
        guard selectedOwner == selectionOwner else { throw CancellationError() }
        focusedCatalogVariant = focus; focusedCatalogVariantScope = scope
        selectedPhotoID = row.image_id; selectionAnchor = row.image_id
        selection = assets.contains(where: { $0.id == row.image_id }) ? [row.image_id] : []; selectionCount = 1
        catalogVariant = nil; catalogVariants = []; catalogVariantsNext = nil
        await refreshVersions()
    }
    func changeCatalogRecipe(_ action: LensWorksCatalogRecipeAction, origin: LensWorksCommandOrigin = .user) async throws -> LWApplicationDtoVariant {
        try admitCatalogWork()
        guard !isBusy, let source = currentCatalogVariant, let asset = selectedAsset, let token = catalogToken, let catalog = catalogPath else { throw LensWorksCatalogError.message("Choose a current catalog recipe before editing.") }
        let busy = beginBusy(); defer { finishBusy(busy) }
        let scope = captureScope(), query = queryOwner
        // Read from the index, not the copy shown: what is recorded for exactly the revision this change is made on.
        let recorded = try await index.recipeOrigins(catalog: catalog, key: source.key, revision: source.revision.value, digest: source.recipe_digest) ?? LensWorksRecipeOrigins()
        try checkCatalogSelection(scope, image: asset.id, query: query)
        if origin == .agent {
            if case .undo = action, recorded.undo.last != .agent { throw Self.recipeOwnershipRefusal(redo: false) }
            if case .redo = action, recorded.redo.last != .agent { throw Self.recipeOwnershipRefusal(redo: true) }
        }
        if case .copy = action {} else {
            // Recipe edits, Undo and Redo render the full-resolution original: observe it now.
            try await requireFreshOriginal(asset)
            try checkCatalogSelection(scope, image: asset.id, query: query)
        }
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
        // A new copy starts with nothing recorded. Every accepted change is a new revision and one history step in
        // the engine, a save that leaves the recipe as it was included.
        if !creating, next.revision != source.revision {
            let origins = recorded.recording(action, by: origin, canUndo: next.can_undo, canRedo: next.can_redo)
            try? await index.setRecipeOrigins(origins, catalog: catalog, key: next.key, revision: next.revision.value, digest: next.recipe_digest)
        }
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
        status = origin.historyName("Catalog recipe \(next.label) · revision \(next.revision.value).")
        return next
    }
    private func selectCreatedCatalogFocus(_ row: LWApplicationDtoGridImage, scope: LensWorksCatalogScope, query: String) async throws {
        let owner = selectionOwner, previous = selectedPhotoID
        try await index.setSelection(owner: owner, rows: [LensWorksSelectedRow(imageID: row.image_id, key: row.key)], replace: true, remove: false)
        try checkScope(scope)
        guard owner == selectionOwner, query == queryOwner, selectedPhotoID == previous else { throw CancellationError() }
        focusedCatalogVariant = LensWorksCatalogAsset(sequence: row.sequence.value, id: row.image_id, originalPath: row.filename, state: row.state,
            previewPath: nil, key: row.key, displayFilename: row.filename, metadataRevision: row.metadata_revision.value,
            origin: row.origin, translationState: row.translation_state, rating: row.rating?.value, flag: row.flag, label: row.label)
        focusedCatalogVariantScope = scope; selectedPhotoID = row.image_id
        selection = []; selectionCount = 1; selectionAnchor = row.image_id
        await refreshVersions()
    }
    func setCatalogRating(_ value: UInt8, origin: LensWorksCommandOrigin = .user) async throws {
        try admitCatalogWork()
        guard !isBusy, let asset = selectedAsset, let key = asset.key else { throw CancellationError() }
        // The explicitly selected photo, independent of any wider grid selection.
        try await organize(.rating(value), rows: [LensWorksSelectedRow(imageID: asset.id, key: key)], origin: origin)
    }

    func setSelectedMembership(_ group: LWApplicationOrganizationCollection, remove: Bool = false, origin: LensWorksCommandOrigin = .user) async throws {
        let scope = captureScope(), afterGroups = groupAfter, navigation = groupEpoch
        try await organize(remove ? .removeCollection(group.id) : .addCollection(group.id), origin: origin)
        try checkScope(scope)
        guard groupEpoch == navigation else { throw CancellationError() }
        try await loadGroups(after: afterGroups); try checkScope(scope)
    }

    /// Apply one change to every selected photo (or the focused photo when nothing is
    /// selected), paging the disk-backed selection. Each page is one state read, the
    /// exact per-photo inverses are recorded before anything is written, and the write
    /// is one sealed batch job compare-and-set against the revisions that read reported.
    /// The whole change is one undoable step.
    func organize(_ change: LensWorksOrganizationChange, rows explicit: [LensWorksSelectedRow]? = nil, origin: LensWorksCommandOrigin = .user) async throws {
        try admitCatalogWork()
        try change.validate()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); isOrganizing = true; organizationCancelRequested = false
        defer { if busyOwner == busy { isOrganizing = false }; finishBusy(busy) }
        let scope = captureScope(), selectedOwner = selectionOwner, query = queryOwner, history = organizationHistoryEpoch
        let (_, token) = try await service.context()
        try checkScope(scope)
        guard token == scope.token else { throw CancellationError() }
        if explicit == nil, selectionCount == 0, let selectedAsset {
            await select(selectedAsset); try checkScope(scope)
            guard selectedOwner == selectionOwner, query == queryOwner else { throw CancellationError() }
        }
        let total = explicit.map { Int64($0.count) } ?? selectionCount
        guard total > 0 else { throw LensWorksCatalogError.message("Select photos to organize.") }
        let current = { [unowned self] in
            try Task.checkCancellation(); try self.checkScope(scope)
            guard !self.organizationCancelRequested, selectedOwner == self.selectionOwner, query == self.queryOwner else { throw CancellationError() }
        }
        let step = nextOrganizationStep()
        var after = "", processed: Int64 = 0, outcome = LensWorksOrganizationOutcome()
        var failure: (any Error)?
        do {
            while true {
                try current()
                let page: [LensWorksSelectedRow]
                if let explicit { page = after.isEmpty ? explicit : [] }
                else { page = try await index.selection(owner: selectedOwner, after: after) }
                try current()
                if page.isEmpty { break }
                try await organizePage(change, rows: page, step: step, outcome: &outcome, admitted: current)
                processed += Int64(page.count); status = "Organized \(processed) of \(total) selected photos."
                after = page.last!.imageID
            }
        } catch { failure = error }
        // Even a partially applied change stays undoable as recorded.
        await pushOrganizationStep(LensWorksOrganizationStep(id: step, title: origin.historyName(change.title), photos: outcome.recorded, keywords: change.keywordTargets, collection: change.collection, origin: origin), history: history, scope: scope)
        if let failure { throw failure }
        try checkScope(scope)
        let refreshedQuery = queryEpoch &+ 1
        try await refreshAssets(); try checkScope(scope)
        guard queryEpoch == refreshedQuery else { throw CancellationError() }
        report(change.title + " · \(outcome.changed) of \(total) photos changed", outcome)
    }

    private func organizePage(_ change: LensWorksOrganizationChange, rows: [LensWorksSelectedRow], step: Int64, outcome: inout LensWorksOrganizationOutcome, admitted: () throws -> Void) async throws {
        let states = try await service.organizationStates(rows.map(\.key), keywords: change.keywordTargets, collection: change.collection)
        try admitted()
        let forward = LensWorksOrganizationEdit([change.operation])
        let encoded = try LWCatalogCodec.encode(forward)
        var records: [LensWorksOrganizationRecord] = [], pending: [LensWorksOrganizationItem] = []
        // A photo already in the requested state is neither written nor recorded.
        for (row, state) in zip(rows, states) where !state.holds(forward) {
            records.append(LensWorksOrganizationRecord(row: row, forward: encoded, inverse: try LWCatalogCodec.encode(change.inverse(from: state))))
            pending.append(LensWorksOrganizationItem(row: row, state: state))
        }
        guard !records.isEmpty else { return }
        // Recorded before writing: a change that commits is never left without its inverse,
        // even when its reply is lost. A record whose write never landed replays as a no-op.
        try await index.recordOrganization(step: step, records: records)
        outcome.recorded += Int64(records.count)
        do {
            #if DEBUG
            await continuationFixture?(.membershipIdentity)
            #endif
            try admitted()
        } catch {
            // Nothing was sent for this page, so it leaves no undo record.
            try? await index.forgetOrganization(step: step, images: records.map(\.row.imageID))
            outcome.recorded -= Int64(records.count)
            throw error
        }
        let failed = try await apply(forward, to: pending, admitted: admitted)
        #if DEBUG
        await continuationFixture?(.organizationApplied)
        #endif
        if !failed.isEmpty {
            try await index.forgetOrganization(step: step, images: failed)
            outcome.recorded -= Int64(failed.count)
            failed.forEach { outcome.skip($0) }
        }
        outcome.changed += Int64(pending.count - failed.count)
    }

    /// Writes one edit to photos, each compare-and-set against the revision of its state
    /// read: a sealed batch job when one operation is shared by several photos, otherwise
    /// ordered single writes. Returns the photos whose write found them changed since.
    private func apply(_ edit: LensWorksOrganizationEdit, to items: [LensWorksOrganizationItem], admitted: () throws -> Void) async throws -> [String] {
        if items.count > 1, edit.operations.count == 1, edit.position == nil {
            return try await applyBatch(edit.operations[0], items: items, admitted: admitted)
        }
        var failed: [String] = []
        for item in items {
            try admitted()
            do { try await applyEdit(edit, key: item.row.key, state: item.state) }
            catch let error where Self.isStale(error) { failed.append(item.row.imageID) }
        }
        return failed
    }

    private func applyBatch(_ operation: LWOrganizationOperation, items: [LensWorksOrganizationItem], admitted: () throws -> Void) async throws -> [String] {
        guard case .Job(let job) = try await service.organization(.Begin(operation: operation)) else { throw LensWorksManagedError.protocolViolation("Expected an organization batch job.") }
        do {
            let batch = items.map { LWApplicationOrganizationBatchItem(key: $0.row.key, expected_revision: $0.state.identity.metadata_revision) }
            guard case .Job = try await service.organization(.Append(job: job.id, items: batch)),
                  case .Job = try await service.organization(.Seal(job: job.id)) else { throw LensWorksManagedError.protocolViolation("Expected a sealed organization batch.") }
            var failed: [String] = []
            while true {
                try admitted()
                guard case .Job(let progress) = try await service.organization(.Run(job: job.id, limit: rowLimit)) else { throw LensWorksManagedError.protocolViolation("Expected organization batch progress.") }
                if progress.state == "complete" { break }
                if progress.state != "paused" { continue }
                // A photo changed since its state read pauses the job; skip and report it.
                guard case .Items(let page) = try await service.organization(.Items(job: job.id, after: LWCatalogI64(0), limit: rowLimit)) else { throw LensWorksManagedError.protocolViolation("Expected organization batch items.") }
                let failing = page.rows.filter { $0.status == "failed" }
                guard !failing.isEmpty else { throw LensWorksManagedError.protocolViolation("A paused organization batch reported no failed photo.") }
                for item in failing {
                    guard case .Job = try await service.organization(.Review(job: job.id, key: item.key, new_revision: nil)) else { throw LensWorksManagedError.protocolViolation("Expected a reviewed organization batch.") }
                    failed.append(item.image_id)
                }
            }
            return failed
        } catch {
            _ = try? await service.organization(.Cancel(job: job.id))
            throw error
        }
    }

    /// Ordered compare-and-set writes for one photo, starting from its state-read revision.
    private func applyEdit(_ edit: LensWorksOrganizationEdit, key: LWCatalogEditsVariantKey, state: LWApplicationOrganizationImageState) async throws {
        var identity = state.identity
        for operation in edit.operations {
            let request: LWApplicationOrganizationRequest
            if case .AddCollection(let collection) = operation, let position = edit.position {
                // Ordered virtual folders keep their explicit position authority.
                request = .SetMember(identity: identity, collection: collection, position: LWCatalogI64(position))
            } else {
                request = .Apply(key: key, expected_revision: identity.metadata_revision, operation: operation)
            }
            guard case .Changed(let revision) = try await service.organization(request), revision.value > identity.metadata_revision.value else {
                throw LensWorksManagedError.protocolViolation("Expected a committed organization revision.")
            }
            identity.metadata_revision = revision
        }
    }

    /// A compare-and-set write rejected because the photo changed after it was read.
    nonisolated static func isStale(_ error: any Error) -> Bool {
        if case LensWorksManagedError.native(_, let message) = error { return message.contains("changed") }
        return false
    }

    func undoOrganization(origin: LensWorksCommandOrigin = .user) async throws { try await replayOrganization(undo: true, origin: origin) }
    func redoOrganization(origin: LensWorksCommandOrigin = .user) async throws { try await replayOrganization(undo: false, origin: origin) }

    /// Replays a recorded step. Each photo is read first: one already in the target state
    /// is left alone, one that no longer holds the state the step left (changed by a
    /// later edit or a sidecar re-import) is skipped and reported, and the rest are
    /// written compare-and-set against that read's revision.
    private func replayOrganization(undo: Bool, origin: LensWorksCommandOrigin) async throws {
        try admitCatalogWork()
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        guard let step = undo ? organizationUndo.last : organizationRedo.last else {
            throw LensWorksCatalogError.message(undo ? "There is no organization change to undo." : "There is no organization change to redo.")
        }
        // The rule document history follows: an agent steps only over its own steps, never the person's.
        guard origin != .agent || step.origin == .agent else {
            throw LensWorksCatalogError.message(undo ? "The last organization change is the person’s own: an agent undoes only its own."
                                                    : "The next organization change to redo is the person’s own: an agent redoes only its own.")
        }
        let busy = beginBusy(); isOrganizing = true; organizationCancelRequested = false
        defer { if busyOwner == busy { isOrganizing = false }; finishBusy(busy) }
        let scope = captureScope(), history = organizationHistoryEpoch
        let current = { [unowned self] in
            try Task.checkCancellation(); try self.checkScope(scope)
            guard !self.organizationCancelRequested else { throw CancellationError() }
        }
        var outcome = LensWorksOrganizationOutcome()
        try await replay(step, undo: undo, outcome: &outcome, admitted: current)
        guard organizationHistoryEpoch == history else { throw CancellationError() }
        if undo { organizationUndo.removeLast(); organizationRedo.append(step) }
        else { organizationRedo.removeLast(); organizationUndo.append(step) }
        try await refreshAfterKeywordChange(step, scope: scope)
        let refreshedQuery = queryEpoch &+ 1
        try await refreshAssets(); try checkScope(scope)
        guard queryEpoch == refreshedQuery else { throw CancellationError() }
        report((undo ? "Undid " : "Redid ") + step.title, outcome)
    }

    private func replay(_ step: LensWorksOrganizationStep, undo: Bool, outcome: inout LensWorksOrganizationOutcome, admitted: () throws -> Void) async throws {
        // Forward: dictionary phase 0, photos, phase 1. Undo runs the inverses in reverse.
        try await replayDictionary(step, phase: undo ? 1 : 0, undo: undo, outcome: &outcome, admitted: admitted)
        var after = "", processed: Int64 = 0
        while true {
            try admitted()
            let page = try await index.organizationRecords(step: step.id, after: after)
            try admitted()
            if page.isEmpty { break }
            let states = try await service.organizationStates(page.map(\.row.key), keywords: step.keywords, collection: step.collection)
            try admitted()
            var groups: [(data: Data, edit: LensWorksOrganizationEdit, items: [LensWorksOrganizationItem])] = []
            for (record, state) in zip(page, states) {
                let data = undo ? record.inverse : record.forward
                let target = try LWCatalogCodec.decode(LensWorksOrganizationEdit.self, from: data)
                let source = try LWCatalogCodec.decode(LensWorksOrganizationEdit.self, from: undo ? record.forward : record.inverse)
                if state.holds(target) { continue }
                guard state.holds(source) else { outcome.skip(record.row.imageID); continue }
                let item = LensWorksOrganizationItem(row: record.row, state: state)
                if let index = groups.firstIndex(where: { $0.data == data }) { groups[index].items.append(item) }
                else { groups.append((data, target, [item])) }
            }
            for group in groups {
                let failed = try await apply(group.edit, to: group.items, admitted: admitted)
                failed.forEach { outcome.skip($0) }
                outcome.changed += Int64(group.items.count - failed.count)
            }
            processed += Int64(page.count)
            status = (undo ? "Undoing " : "Redoing ") + step.title + " · \(processed) of \(step.photos)"
            after = page.last!.row.imageID
        }
        try await replayDictionary(step, phase: undo ? 0 : 1, undo: undo, outcome: &outcome, admitted: admitted)
    }

    /// Phase 0 runs forward in ascending order (parents before children); phase 1
    /// (removals) forward in descending order; undo reverses each direction.
    private func replayDictionary(_ step: LensWorksOrganizationStep, phase: Int32, undo: Bool, outcome: inout LensWorksOrganizationOutcome, admitted: () throws -> Void) async throws {
        guard step.dictionary > 0 else { return }
        let descending = phase == 0 ? undo : !undo
        var after: Int64?
        while true {
            try admitted()
            let page = try await index.dictionaryRecords(step: step.id, phase: phase, after: after, descending: descending)
            if page.isEmpty { break }
            for record in page {
                for edit in try LWCatalogCodec.decode([LensWorksKeywordEdit].self, from: undo ? record.inverse : record.forward) {
                    try admitted()
                    if case .delete(let target) = edit, try await !performKeywordEdit(edit) {
                        outcome.keptKeywords.append(target.path.joined(separator: " > "))
                    } else if case .delete = edit {
                    } else {
                        _ = try await performKeywordEdit(edit)
                    }
                }
            }
            after = page.last!.ordinal
        }
    }

    private func findKeyword(_ target: LensWorksKeywordTarget) async throws -> LWApplicationOrganizationKeyword? {
        guard case .Keyword(let found) = try await service.organization(.FindKeyword(kind: target.kind, path: target.path)) else {
            throw LensWorksManagedError.protocolViolation("Expected a keyword lookup.")
        }
        guard found.map({ $0.kind == target.kind && $0.path == target.path }) ?? true else { throw LensWorksManagedError.protocolViolation("Keyword lookup changed identity.") }
        return found
    }

    /// Returns false when a keyword to delete is still in use (members or children), so it is kept.
    private func performKeywordEdit(_ edit: LensWorksKeywordEdit) async throws -> Bool {
        switch edit {
        case .create(let target):
            guard case .KeywordCreated = try await service.organization(.CreateKeyword(kind: target.kind, path: target.path)) else { throw LensWorksManagedError.protocolViolation("Expected a created keyword identity.") }
        case .delete(let target):
            guard let keyword = try await findKeyword(target) else { return true }
            do {
                guard case .Acknowledged = try await service.organization(.DeleteKeyword(id: keyword.id)) else { throw LensWorksManagedError.protocolViolation("Expected a deleted keyword.") }
            } catch {
                if try await findKeyword(target) != nil { return false }
            }
        case .addSynonym(let target, let synonym):
            guard let keyword = try await findKeyword(target) else { throw LensWorksCatalogError.message("Keyword " + target.path.joined(separator: " > ") + " no longer exists.") }
            do { _ = try await service.organization(.AddSynonym(keyword: keyword.id, synonym: synonym)) }
            catch LensWorksManagedError.native(_, let message) where message.contains("already exists") { }
        case .removeSynonym(let target, let synonym):
            guard let keyword = try await findKeyword(target) else { return true }
            do { _ = try await service.organization(.RemoveSynonym(keyword: keyword.id, synonym: synonym)) }
            catch LensWorksManagedError.native(_, let message) where message.contains("not found") { }
        }
        return true
    }

    private func nextOrganizationStep() -> Int64 { organizationStepID &+= 1; return organizationStepID }

    /// A catalog close or switch resets history, so a step that finishes afterwards is
    /// dropped instead of being appended to another scope's history.
    private func pushOrganizationStep(_ step: LensWorksOrganizationStep, history: UInt64, scope: LensWorksCatalogScope) async {
        guard step.photos > 0 || step.dictionary > 0, organizationHistoryEpoch == history, scopeIsCurrent(scope) else {
            try? await index.discardOrganization(steps: [step.id]); return
        }
        if !organizationRedo.isEmpty { try? await index.discardOrganization(steps: organizationRedo.map(\.id)); organizationRedo = [] }
        organizationUndo.append(step)
        if organizationUndo.count > Self.organizationHistoryLimit {
            let dropped = organizationUndo.removeFirst()
            try? await index.discardOrganization(steps: [dropped.id])
        }
    }

    private func report(_ title: String, _ outcome: LensWorksOrganizationOutcome) {
        organizationSkipped = outcome.skipped; organizationSkippedCount = outcome.skippedCount; organizationKeptKeywords = outcome.keptKeywords
        var text = title + "."
        if outcome.skippedCount > 0 {
            text += " \(outcome.skippedCount) photo\(outcome.skippedCount == 1 ? " was" : "s were") left unchanged because \(outcome.skippedCount == 1 ? "it" : "they") changed since."
        }
        if !outcome.keptKeywords.isEmpty { text += " Kept keywords still in use: " + outcome.keptKeywords.prefix(5).joined(separator: ", ") + "." }
        status = text
    }

    private func resetOrganizationHistory() async {
        organizationHistoryEpoch &+= 1
        let steps = (organizationUndo + organizationRedo).map(\.id)
        organizationUndo = []; organizationRedo = []
        organizationSkipped = []; organizationSkippedCount = 0; organizationKeptKeywords = []
        if !steps.isEmpty { try? await index.discardOrganization(steps: steps) }
    }

    // MARK: Keyword dictionary edits (each one undoable step)

    /// Rename a keyword in place; nested keywords and every photo holding them follow.
    func renameKeyword(_ keyword: LWApplicationOrganizationKeyword, to name: String, origin: LensWorksCommandOrigin = .user) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await relocateKeyword(keyword, to: Array(keyword.path.dropLast()) + [name], title: "Rename Keyword " + keyword.name + " to " + name, origin: origin)
    }
    /// Move a hierarchical keyword (and everything nested under it) under another parent, or to the top level.
    func moveKeyword(_ keyword: LWApplicationOrganizationKeyword, under parent: [String], origin: LensWorksCommandOrigin = .user) async throws {
        guard keyword.kind == .Hierarchical else { throw LensWorksCatalogError.message("Flat keywords have no parent.") }
        try await relocateKeyword(keyword, to: parent + [keyword.name], title: "Move Keyword " + keyword.name + (parent.isEmpty ? " to Top Level" : " under " + parent.joined(separator: " > ")), origin: origin)
    }
    func relocateKeyword(_ keyword: LWApplicationOrganizationKeyword, to path: [String], title: String, origin: LensWorksCommandOrigin = .user) async throws {
        try admitCatalogWork()
        let from = LensWorksKeywordTarget(keyword), to = LensWorksKeywordTarget(path, kind: keyword.kind)
        try to.validate()
        guard from != to, !(from.kind == .Hierarchical && to.path.starts(with: from.path)) else {
            throw LensWorksCatalogError.message("A keyword cannot move onto itself or into a keyword nested under it.")
        }
        try await keywordStep(title, keywords: [from, to], origin: origin) { [unowned self] step, admitted in
            let dictionary = try await recordKeywordTree(from, step: step, relocating: to, admitted: admitted)
            let photos = try await recordKeywordPhotos(keyword, targets: [from, to], step: step, admitted: admitted) { state in
                let terms = state.keywords.map { LensWorksKeywordTarget($0.path, kind: $0.kind) }
                let old = terms.filter { from.covers($0) }
                guard !old.isEmpty else { return nil }
                let held = Set(terms.filter { to.covers($0) && !from.covers($0) }.map(\.path))
                var added: [[String]] = []
                for term in old {
                    let moved = to.path + term.path.dropFirst(from.path.count)
                    if !held.contains(moved), !added.contains(moved) { added.append(moved) }
                }
                let forward: [LWOrganizationOperation] = from.kind == .Hierarchical && added.count == old.count
                    ? [.MoveKeyword(from: from.path, to: to.path)]
                    : old.map { .RemoveKeyword(kind: from.kind, path: $0.path) } + added.map { .AddKeyword(kind: from.kind, path: $0) }
                let inverse: [LWOrganizationOperation] = added.map { .RemoveKeyword(kind: from.kind, path: $0) } + old.map { .AddKeyword(kind: from.kind, path: $0.path) }
                return (LensWorksOrganizationEdit(forward), LensWorksOrganizationEdit(inverse))
            }
            return (photos, dictionary)
        }
    }
    /// Delete a keyword and everything nested under it, removing them from every photo.
    func deleteKeyword(_ keyword: LWApplicationOrganizationKeyword, origin: LensWorksCommandOrigin = .user) async throws {
        try admitCatalogWork()
        let target = LensWorksKeywordTarget(keyword)
        try await keywordStep("Delete Keyword " + keyword.path.joined(separator: " > "), keywords: [target], origin: origin) { [unowned self] step, admitted in
            let dictionary = try await recordKeywordTree(target, step: step, relocating: nil, admitted: admitted)
            let photos = try await recordKeywordPhotos(keyword, targets: [target], step: step, admitted: admitted) { state in
                let old = state.keywords.map { LensWorksKeywordTarget($0.path, kind: $0.kind) }.filter { target.covers($0) }
                guard !old.isEmpty else { return nil }
                return (LensWorksOrganizationEdit(old.map { .RemoveKeyword(kind: $0.kind, path: $0.path) }), LensWorksOrganizationEdit(old.map { .AddKeyword(kind: $0.kind, path: $0.path) }))
            }
            return (photos, dictionary)
        }
    }
    func addKeywordSynonym(_ keyword: LWApplicationOrganizationKeyword, _ synonym: String, origin: LensWorksCommandOrigin = .user) async throws {
        try admitCatalogWork()
        let synonym = synonym.trimmingCharacters(in: .whitespacesAndNewlines), target = LensWorksKeywordTarget(keyword)
        guard !synonym.isEmpty, synonym.utf8.count <= 1024, !synonym.contains("\0") else { throw LensWorksCatalogError.message("A synonym needs 1–1,024 UTF-8 bytes.") }
        try await keywordStep("Add Synonym " + synonym, keywords: [], origin: origin) { [unowned self] step, _ in
            guard try await !keywordSynonyms(keyword).contains(synonym) else { throw LensWorksCatalogError.message("“" + synonym + "” is already a synonym of " + keyword.name + ".") }
            try await index.recordDictionary(step: step, records: [LensWorksDictionaryRecord(ordinal: 0, phase: 0, forward: try LWCatalogCodec.encode([LensWorksKeywordEdit.addSynonym(target, synonym)]), inverse: try LWCatalogCodec.encode([LensWorksKeywordEdit.removeSynonym(target, synonym)]))])
            return (0, 1)
        }
    }
    /// Every synonym of one keyword, read one bounded page at a time.
    func keywordSynonyms(_ keyword: LWApplicationOrganizationKeyword) async throws -> [String] {
        var after = "", synonyms: [String] = []
        while true {
            guard case .Synonyms(let page) = try await service.organization(.Synonyms(keyword: keyword.id, after: after, limit: rowLimit)), page.rows.count <= 100 else {
                throw LensWorksManagedError.protocolViolation("Expected a bounded synonym page.")
            }
            synonyms += page.rows.map(\.synonym)
            guard let next = page.next, next > after else { return synonyms }
            after = next
        }
    }

    /// Records, then runs, one keyword dictionary step as a single undoable change.
    private func keywordStep(_ title: String, keywords: [LensWorksKeywordTarget], origin: LensWorksCommandOrigin = .user, build: (Int64, () throws -> Void) async throws -> (photos: Int64, dictionary: Int64)) async throws {
        guard !isBusy else { throw LensWorksCatalogError.message("A catalog action is already running.") }
        let busy = beginBusy(); isOrganizing = true; organizationCancelRequested = false
        defer { if busyOwner == busy { isOrganizing = false }; finishBusy(busy) }
        let scope = captureScope(), history = organizationHistoryEpoch
        let current = { [unowned self] in
            try Task.checkCancellation(); try self.checkScope(scope)
            guard !self.organizationCancelRequested else { throw CancellationError() }
        }
        let id = nextOrganizationStep()
        let built: (photos: Int64, dictionary: Int64)
        do { built = try await build(id, current) } catch { try? await index.discardOrganization(steps: [id]); throw error }
        let step = LensWorksOrganizationStep(id: id, title: origin.historyName(title), photos: built.photos, keywords: keywords, dictionary: built.dictionary, origin: origin)
        var outcome = LensWorksOrganizationOutcome(), failure: (any Error)?
        do { try await replay(step, undo: false, outcome: &outcome, admitted: current) } catch { failure = error }
        await pushOrganizationStep(step, history: history, scope: scope)
        if let failure { throw failure }
        try await refreshAfterKeywordChange(step, scope: scope)
        try await refreshAssets(); try checkScope(scope)
        report(title, outcome)
    }

    /// The keyword browser and keyword filter follow a dictionary change: a level or
    /// filter whose keyword no longer exists falls back to the top level / no filter.
    private func refreshAfterKeywordChange(_ step: LensWorksOrganizationStep, scope: LensWorksCatalogScope) async throws {
        guard step.dictionary > 0 else { return }
        try checkScope(scope)
        if let filter = filterKeyword {
            if let found = try await findKeyword(filter) { browseOptions.keyword = found.id }
            else { browseOptions.keyword = nil; filterKeyword = nil; filterKeywordName = nil }
        }
        var parent = keywordParent
        if let current = parent { parent = try await findKeyword(LensWorksKeywordTarget(current)) }
        try checkScope(scope)
        try await loadKeywords(parent: parent)
    }

    /// Records the dictionary side of relocating or deleting a keyword: every keyword at
    /// or under it (breadth first) is deleted after the photos move (phase 1, children
    /// first), and when relocating each is first created at its new path with its
    /// synonyms (phase 0). Each record's inverse restores the exact prior dictionary.
    private func recordKeywordTree(_ root: LensWorksKeywordTarget, step: Int64, relocating destination: LensWorksKeywordTarget?, admitted: () throws -> Void) async throws -> Int64 {
        guard let first = try await findKeyword(root) else { throw LensWorksCatalogError.message("Keyword " + root.path.joined(separator: " > ") + " no longer exists.") }
        var frontier = [first], ordinal: Int64 = 0, records: [LensWorksDictionaryRecord] = [], count: Int64 = 0
        func flush() async throws { if !records.isEmpty { try await index.recordDictionary(step: step, records: records); count += Int64(records.count); records = [] } }
        while !frontier.isEmpty {
            try admitted()
            let node = frontier.removeFirst(), path = LensWorksKeywordTarget(node)
            let synonyms = try await keywordSynonyms(node)
            ordinal += 1
            records.append(LensWorksDictionaryRecord(ordinal: ordinal, phase: 1, forward: try LWCatalogCodec.encode([LensWorksKeywordEdit.delete(path)]),
                inverse: try LWCatalogCodec.encode([LensWorksKeywordEdit.create(path)] + synonyms.map { LensWorksKeywordEdit.addSynonym(path, $0) })))
            if let destination {
                let moved = LensWorksKeywordTarget(destination.path + node.path.dropFirst(root.path.count), kind: root.kind)
                let existing = try await findKeyword(moved)
                var present: [String] = []
                if let existing { present = try await keywordSynonyms(existing) }
                let carried = synonyms.filter { !present.contains($0) }
                records.append(LensWorksDictionaryRecord(ordinal: ordinal, phase: 0,
                    forward: try LWCatalogCodec.encode([LensWorksKeywordEdit.create(moved)] + carried.map { LensWorksKeywordEdit.addSynonym(moved, $0) }),
                    inverse: try LWCatalogCodec.encode(carried.map { LensWorksKeywordEdit.removeSynonym(moved, $0) } + (existing == nil ? [LensWorksKeywordEdit.delete(moved)] : []))))
            }
            if records.count >= 98 { try await flush() }
            guard root.kind == .Hierarchical else { continue }
            var after = LWCatalogI64(0)
            while true {
                try admitted()
                guard case .Keywords(let page) = try await service.organization(.Keywords(kind: root.kind, parent: node.id, after: after, limit: rowLimit)), page.rows.count <= 100 else {
                    throw LensWorksManagedError.protocolViolation("Expected a bounded keyword page.")
                }
                frontier += page.rows
                guard let next = page.next, next.value > after.value else { break }
                after = next
            }
        }
        try await flush()
        return count
    }

    /// Collects every photo holding a keyword or one nested under it (a paged keyword
    /// browse into private disk-backed rows), then reads each page's state and records
    /// the per-photo edits `edits` returns. Returns the number of photos recorded.
    private func recordKeywordPhotos(_ keyword: LWApplicationOrganizationKeyword, targets: [LensWorksKeywordTarget], step: Int64, admitted: () throws -> Void,
                                     edits: (LWApplicationOrganizationImageState) -> (LensWorksOrganizationEdit, LensWorksOrganizationEdit)?) async throws -> Int64 {
        let owner = "organization-keyword-\(step)-" + UUID().uuidString
        do {
            let recorded = try await recordKeywordPhotos(keyword, owner: owner, targets: targets, step: step, admitted: admitted, edits: edits)
            try await index.clearSelection(owner: owner)
            return recorded
        } catch {
            try? await index.clearSelection(owner: owner)
            throw error
        }
    }
    private func recordKeywordPhotos(_ keyword: LWApplicationOrganizationKeyword, owner: String, targets: [LensWorksKeywordTarget], step: Int64, admitted: () throws -> Void,
                                     edits: (LWApplicationOrganizationImageState) -> (LensWorksOrganizationEdit, LensWorksOrganizationEdit)?) async throws -> Int64 {
        let options = LWApplicationBrowseOptions(text: nil, keyword: keyword.id, keyword_direct: false, folder: nil, folder_recursive: true, collection: nil, date_from: nil, date_until: nil, camera_make: nil, camera: nil, lens: nil, format: nil, rating: nil, flag: nil, label: nil, only_conflicted: false, sort: .Sequence, direction: .Ascending)
        var cursor: String?
        repeat {
            try admitted()
            let page = try await service.browse(options: options, cursor: cursor)
            let rows = page.rows.map { LensWorksSelectedRow(imageID: $0.image_id, key: $0.key) }
            if !rows.isEmpty { try await index.setSelection(owner: owner, rows: rows, replace: false) }
            guard page.hasMore, let next = page.next, next != cursor else { break }
            cursor = next
        } while true
        var after = "", recorded: Int64 = 0
        while true {
            try admitted()
            let page = try await index.selection(owner: owner, after: after)
            if page.isEmpty { break }
            let states = try await service.organizationStates(page.map(\.key), keywords: targets)
            var records: [LensWorksOrganizationRecord] = []
            for (row, state) in zip(page, states) {
                guard let (forward, inverse) = edits(state) else { continue }
                records.append(LensWorksOrganizationRecord(row: row, forward: try LWCatalogCodec.encode(forward), inverse: try LWCatalogCodec.encode(inverse)))
            }
            if !records.isEmpty { try await index.recordOrganization(step: step, records: records); recorded += Int64(records.count) }
            after = page.last!.imageID
        }
        return recorded
    }

    // MARK: Keywords and metadata filters

    func setKeywordKind(_ kind: LWOrganizationKeywordKind) async throws {
        guard kind != keywordKind else { return }
        keywordKind = kind; keywordParent = nil; keywordTrail = []
        try await loadKeywords()
    }
    func loadKeywords(parent: LWApplicationOrganizationKeyword? = nil, after: LWCatalogI64 = LWCatalogI64(0)) async throws {
        try admitCatalogWork()
        keywordEpoch &+= 1
        let admitted = keywordEpoch, scope = captureScope(), kind = parent?.kind ?? keywordKind
        guard case .Keywords(let page) = try await service.organization(.Keywords(kind: kind, parent: parent?.id, after: after, limit: rowLimit)), page.rows.count <= 100,
              page.rows.allSatisfy({ $0.parent?.value == parent?.id.value && $0.kind == kind }) else {
            throw LensWorksManagedError.protocolViolation("Expected a bounded keyword page.")
        }
        try checkScope(scope)
        guard keywordEpoch == admitted else { throw CancellationError() }
        if parent == nil { keywordTrail = [] }
        else if parent?.id.value != keywordParent?.id.value {
            if let found = keywordTrail.firstIndex(where: { $0.id.value == parent?.id.value }) { keywordTrail = Array(keywordTrail.prefix(found)) }
            else if let current = keywordParent, parent?.parent?.value == current.id.value { keywordTrail.append(current) }
            if keywordTrail.count > 64 { keywordTrail.removeFirst(keywordTrail.count - 64) }
        }
        keywordKind = kind
        keywords = page.rows; keywordParent = parent; keywordNext = page.next
        navigationHighWater = max(navigationHighWater, navigationResidency)
    }
    func enterKeyword(_ keyword: LWApplicationOrganizationKeyword) async throws { try await loadKeywords(parent: keyword) }
    func upKeyword() async throws { try await loadKeywords(parent: keywordParent == nil ? nil : keywordTrail.last) }
    func nextKeywords() async throws {
        guard let next = keywordNext else { return }
        try await loadKeywords(parent: keywordParent, after: next)
    }
    /// Accepts “People/Ada” or “People > Ada”; the new keyword nests under the current level.
    static func keywordPath(_ text: String) -> [String] {
        text.replacingOccurrences(of: ">", with: "/").split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func createKeyword(_ text: String) async throws {
        try admitCatalogWork()
        let target = keywordKind == .Flat
            ? LensWorksKeywordTarget([text.trimmingCharacters(in: .whitespacesAndNewlines)], kind: .Flat)
            : LensWorksKeywordTarget((keywordParent?.path ?? []) + Self.keywordPath(text))
        try target.validate()
        let scope = captureScope()
        guard case .KeywordCreated = try await service.organization(.CreateKeyword(kind: target.kind, path: target.path)) else {
            throw LensWorksManagedError.protocolViolation("Expected a created keyword identity.")
        }
        try checkScope(scope)
        try await loadKeywords(parent: keywordParent)
    }

    /// Combine one more metadata filter with the current scope and restart from the first page.
    func setFilters(rating: UInt8?? = .none, flag: LWOrganizationFlag?? = .none, label: String?? = .none, keyword: LWApplicationOrganizationKeyword?? = .none) async throws {
        try admitCatalogWork()
        if let rating { guard rating.map({ $0 <= 5 }) ?? true else { throw LensWorksCatalogError.message("Rating must be 0–5.") }; browseOptions.rating = rating }
        if let flag { browseOptions.flag = flag }
        if let label { browseOptions.label = label }
        if let keyword {
            browseOptions.keyword = keyword?.id; browseOptions.keyword_direct = false
            filterKeywordName = keyword?.path.joined(separator: " > "); filterKeyword = keyword.map { LensWorksKeywordTarget($0) }
        }
        showingCatalog = true
        try await refreshAssets()
    }
    func clearFilters() async throws {
        try await setFilters(rating: .some(nil), flag: .some(nil), label: .some(nil), keyword: .some(nil))
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

    /// `admitted` is what an agent's request was checked against (the original it may read and the folder it may
    /// write into): with it, the folder chooser never opens and nothing is read or written anywhere else.
    func createWorkingVersion(workspace: ProjectWorkspace, admitted: (original: String, output: String)? = nil) async {
        guard !closingRequested, let selected = selectedAsset, let catalogPath, !isBusy, workspace.canSwitch else { return }
        let scope = captureScope(), selectedID = selected.id
        let sourceEpoch = catalogSelectionEpoch, sourceQuery = queryOwner, sourcePage = pageAuthority, sourceOwner = selectionOwner
        let busy = beginBusy(); defer { finishBusy(busy) }
        do {
            track(workspace)
            // A cached observation may predate an unmount: observe now and refuse unless readable.
            try await requireFreshOriginal(selected)
            try checkScope(scope)
            guard selectedAsset?.id == selectedID else { throw CancellationError() }
            let asset = try await resolveSelectedOriginal()
            try checkScope(scope)
            guard selectedAsset?.id == selectedID else { throw CancellationError() }
            if let admitted {
                guard outputDirectory == admitted.output, try asset.originalURL.path == admitted.original else {
                    error = "The photo’s original or the working-versions folder changed after the request was checked: nothing was opened."; return
                }
            } else if outputDirectory == nil { await chooseOutput(window: workspace.window); try checkScope(scope) }
            guard let output = outputDirectory, selectedAsset?.id == selectedID else { return }
            _ = try await LensWorksVersionStore.shared.canonicalPath(output, outside: catalogPath)
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            let rasterTypes = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif"]
            let isRasterOriginal = rasterTypes.contains(URL(fileURLWithPath: asset.originalPath).pathExtension.lowercased())
            guard try isRasterOriginal || RawImporter.matches(asset.originalURL) else { error = "The original format is not supported by an admitted editor decoder."; return }
            let available = await LensWorksVersionStore.shared.sourceAvailable(asset.originalPath, native: asset.nativeOriginal)
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            guard available else { error = "The original photo is offline. Reconnect its location before creating a working version."; return }
            guard workspace.canSwitch else { error = "Finish the current edit before creating a working version."; return }
            let originalURL = try asset.originalURL
            var capturedSourceAuthority: Data?
            if RawImporter.matches(originalURL) {
                guard let key = asset.key else { throw LensWorksManagedError.protocolViolation("Missing native RAW variant authority.") }
                let recipe = try await service.variant(key)
                try checkScope(scope)
                guard catalogSelectionEpoch == sourceEpoch, queryOwner == sourceQuery,
                    pageAuthority == sourcePage, selectionOwner == sourceOwner, selectedAsset?.id == selectedID,
                    selectedAsset?.metadataRevision == asset.metadataRevision else { throw CancellationError() }
                let authority = LWSourceCatalogAuthority(key:key, metadataRevision:asset.metadataRevision, variant:recipe)
                try authority.validate()
                let encodedAuthority=try LWSourceMetadataStorage.encode(authority,maximumBytes:1024*1024,catalogCodec:true)
                capturedSourceAuthority=try encodedAuthority.copyData(ownedBy:encodedAuthority.owner)
            }
            let tab = workspace.addTab()
            await tab.session.importImages([originalURL])
            // This independently admitted document remains usable if catalog scope changed.
            // Its next source binding/save is admitted only under the original authority.
            try checkScope(scope)
            guard outputDirectory == output, selectedAsset?.id == selectedID else { throw CancellationError() }
            guard tab.session.document != nil else { error = tab.session.importError ?? "The photo could not be opened."; return }
            if let layer = tab.session.activeLayer, var node = layer.liveSource,
                let index = tab.session.document?.layers.firstIndex(where:{ $0.id == layer.id }) {
                // Captured native full-key/metadata CAS remains separate from document history.
                guard catalogSelectionEpoch == sourceEpoch, queryOwner == sourceQuery,
                    pageAuthority == sourcePage, selectionOwner == sourceOwner, selectedAsset?.metadataRevision == asset.metadataRevision,
                    let capturedSourceAuthority else { throw CancellationError() }
                try node.admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(capturedSourceAuthority.count,2),256))
                node.catalogAuthority = capturedSourceAuthority
                tab.session.document?.layers[index].liveSource = node
            }
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
        track(workspace)
        let resolved: LensWorksCatalogAsset
        do { resolved = try await resolveSelectedOriginal() }
        catch {
            if !(error is CancellationError), scopeIsCurrent(scope) { self.error = error.localizedDescription }
            return
        }
        // The document carries its own full-resolution layers, so it opens with its original offline.
        let opened = await workspace.open(URL(fileURLWithPath: version.projectPath))
        guard scopeIsCurrent(scope), opened else { return }
        // A relinked original keeps the version's identity; its next save records the current location.
        if let current = workspace.current.controller.workingVersion, current.id == version.id, current.photoID == resolved.photoID {
            workspace.current.controller.relinkOriginal(path: resolved.originalPath, native: resolved.nativeOriginal)
        }
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
        relink.reset(); forgetOriginalAvailability()
        keywords = []; keywordParent = nil; keywordNext = nil; keywordTrail = []
        await resetOrganizationHistory()
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
        versionRefreshGeneration &+= 1
        let epoch = catalogEpoch, selected = selectedAsset, output = outputDirectory, catalog = catalogPath, generation = versionRefreshGeneration
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
            guard catalogEpoch == epoch, outputDirectory == output, selectedAsset?.id == selected.id, versionRefreshGeneration == generation else { return }
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

// MARK: Offline originals and relinking
extension LensWorksCatalog {
    func originalStatus(_ asset: LensWorksCatalogAsset) -> LWCatalogStorageStorageStatus? { originalStatuses[asset.photoID] }
    /// Why full-resolution work on the selected photo is unavailable; nil only when its
    /// original was observed readable. Unknown availability is never treated as available.
    var selectedOriginalUnavailableReason: String? {
        guard let asset = selectedAsset else { return nil }
        return originalUnavailableReason(asset)
    }
    func originalUnavailableReason(_ asset: LensWorksCatalogAsset) -> String? {
        if let status = originalStatus(asset) { return LensWorksOriginalAvailability.reason(status) }
        if let failure = originalObservationErrors[asset.photoID] {
            return "Original availability could not be checked: \(failure). Full-resolution work stays disabled until the original is observed; LensWorks keeps retrying."
        }
        return LensWorksOriginalAvailability.checking
    }
    func requireFullResolutionOriginal(_ asset: LensWorksCatalogAsset) throws {
        if let reason = originalUnavailableReason(asset) { throw LensWorksCatalogError.message(reason) }
    }
    /// Observes the asset's original now (not from cache) and refuses unless it is readable.
    func requireFreshOriginal(_ asset: LensWorksCatalogAsset) async throws {
        guard let key = asset.key else { throw LensWorksCatalogError.message("This photo has no catalog original to observe.") }
        guard !relink.isRunning else { throw LensWorksCatalogError.message("Wait for the current storage operation to finish.") }
        let scope = captureScope()
        do {
            let value = try await service.observeOriginal(key)
            try checkScope(scope)
            originalStatuses[key.asset_id] = value.status; originalObservationErrors[key.asset_id] = nil
        } catch {
            if !(error is CancellationError), scopeIsCurrent(scope) {
                originalStatuses[key.asset_id] = nil; originalObservationErrors[key.asset_id] = error.localizedDescription
            }
            throw error is CancellationError ? error : LensWorksCatalogError.message(originalUnavailableReason(asset) ?? error.localizedDescription)
        }
        try requireFullResolutionOriginal(asset)
    }
    /// Observes the selected photo's original location. A failure is recorded so the photo's
    /// availability reads as unknown-with-error (gated actions stay disabled) and is retried.
    func observeSelectedOriginal() async {
        guard !closingRequested, let asset = selectedAsset, let key = asset.key, !relink.isRunning else { return }
        let scope = captureScope()
        do {
            let value = try await service.observeOriginal(key)
            try checkScope(scope)
            originalStatuses[key.asset_id] = value.status; originalObservationErrors[key.asset_id] = nil
        } catch {
            guard !(error is CancellationError), scopeIsCurrent(scope) else { return }
            originalStatuses[key.asset_id] = nil; originalObservationErrors[key.asset_id] = error.localizedDescription
        }
    }
    /// A volume mounted, unmounted or was renamed: every cached observation may be stale.
    func forgetOriginalAvailability() { originalStatuses = [:]; originalObservationErrors = [:] }
    func track(_ workspace: ProjectWorkspace) {
        editorWorkspaces.removeAll { $0.value == nil || $0.value === workspace }
        editorWorkspaces.append(LensWorksWeakWorkspace(value: workspace))
    }
    /// After an applied or undone relink: availability is re-observed, browse rows, folders and
    /// working versions refresh, and open working versions follow their original's current
    /// location. Photo, copy and version identities are unchanged.
    func relinkChanged() async {
        forgetOriginalAvailability()
        await refresh()
        await relinkOpenWorkingVersions()
        await observeSelectedOriginal()
    }
    private func relinkOpenWorkingVersions() async {
        guard let catalogPath else { return }
        let scope = captureScope()
        for workspace in editorWorkspaces.compactMap(\.value) {
            for tab in workspace.tabs {
                guard let version = tab.controller.workingVersion, version.catalogPath == catalogPath else { continue }
                let key = version.originalVariantKey ?? LWCatalogEditsVariantKey(asset_id: version.photoID, variant_id: "master")
                guard let native = try? await service.originalLocation(key), scopeIsCurrent(scope),
                      let path = try? native.localFileURL().path,
                      tab.controller.workingVersion?.id == version.id else { continue }
                tab.controller.relinkOriginal(path: path, native: native)
            }
        }
    }
}

struct LensWorksWeakWorkspace { weak var value: ProjectWorkspace? }

/// Volume mount, unmount and rename notifications, which invalidate cached original availability.
final class LensWorksStorageObservers {
    private var tokens: [NSObjectProtocol] = []
    init(_ changed: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { changed() } })
        }
    }
    deinit { tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
}
