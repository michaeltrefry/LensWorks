import Foundation
import Observation

/// Whether a catalog original's full-resolution bytes can be read right now. Retained
/// previews keep browsing and organization available either way; they never stand in
/// for the original in editing, recipe changes or exports.
nonisolated enum LensWorksOriginalAvailability {
    /// Only an observed, readable current location admits full-resolution work.
    static func isAvailable(_ status: LWCatalogStorageStorageStatus) -> Bool {
        ["available_unverified", "online_unverified"].contains(status.state)
    }
    static func headline(_ status: LWCatalogStorageStorageStatus) -> String {
        switch status.state {
        case "available_unverified", "online_unverified": "Original available"
        case "offline": "Original offline"
        case "missing": "Original missing"
        case "ambiguous": "Original location ambiguous"
        case "indeterminate": "Original availability unknown"
        case "identity_unavailable", "unregistered": "Original needs relinking"
        default: "Original unavailable"
        }
    }
    /// The explanation shown on every control that needs the full-resolution original.
    static func reason(_ status: LWCatalogStorageStorageStatus) -> String? {
        guard !isAvailable(status) else { return nil }
        return headline(status) + ": " + status.detail + ". Browsing and organizing use retained previews; reconnect the drive or use Locate Original… to relink it."
    }
}

nonisolated enum LensWorksRelinkPaths {
    /// Display labels never become the authority submitted for an existing path.
    static func label(_ path: LWCatalogNativePath) -> String {
        switch path {
        case .windowsWide(let units): return String(decoding: units, as: UTF16.self)
        case .unixBytes(let bytes):
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            return "Path with non-UTF-8 bytes: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
    static func label(_ reference: LWCatalogStoragePathReference) -> String {
        switch reference {
        case .Native(let path): return label(path)
        case .LegacyUnix(let bytes): return label(.unixBytes(bytes))
        case .LegacyWindows(let units): return label(.windowsWide(units))
        case .Unspecified(let bytes): return "Unspecified path encoding: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
    /// An old folder path typed by the user: the prefix whose originals moved.
    static func entered(_ value: String, windows: Bool) throws -> LWCatalogStoragePathReference {
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 8192 else { throw LensWorksCatalogError.message("Enter a complete original folder path.") }
        if !windows {
            guard value.hasPrefix("/") else { throw LensWorksCatalogError.message("macOS and Linux paths must start with /.") }
            return .LegacyUnix(Array(value.utf8))
        }
        guard value.range(of: #"^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)"#, options: .regularExpression) != nil else {
            throw LensWorksCatalogError.message("Enter an absolute Windows drive or network path.")
        }
        return .LegacyWindows(Array(value.utf16))
    }
    static func identity(_ basis: String) -> String {
        switch basis {
        case "catalog_fingerprint": "Matches the catalog’s original fingerprint"
        case "retained_original_digest": "Matches a retained complete original digest"
        case "user_confirmed_fence": "Matches a previously confirmed association"
        case "unverified": "No retained original digest; association needs review"
        default: "Identity evidence: " + basis
        }
    }
    static func status(_ value: String) -> String {
        switch value {
        case "matched": "Match"
        case "mismatch": "Mismatch"
        case "ambiguous": "Ambiguous"
        case "missing": "Missing"
        case "unverified": "Needs confirmation"
        case "user_confirmed": "Confirmed"
        case "excluded": "Excluded"
        case "unavailable": "Unavailable"
        case "historical": "Historical"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func status(_ value: LWCatalogStorageMatchStatus) -> String {
        switch value {
        case .Matched: "Match"
        case .Mismatch: "Mismatch"
        case .Ambiguous: "Ambiguous"
        case .Missing: "Missing"
        case .Unverified: "Needs confirmation"
        case .UserConfirmed: "Confirmed"
        case .Excluded: "Excluded"
        case .Unavailable: "Unavailable"
        case .Historical: "Historical"
        }
    }
}

extension LensWorksCatalogService {
    func relink(_ request: LWApplicationRelinkRequest) async throws -> LWApplicationRelinkResponse {
        let (owner, token) = try context()
        guard case .Relink(let response) = try await owner.perform(.Relink(catalog: token, request: request)) else {
            throw LensWorksManagedError.protocolViolation("Expected a relink response.")
        }
        return response
    }
}

/// Native Locate Originals: the engine's saved relink review. Catalog associations
/// change only through an explicit reviewed Apply, published in one engine transaction
/// (all rows or none) and reversed by that review's single Undo. Originals never move.
@MainActor @Observable
final class LensWorksRelinkReview {
    @ObservationIgnored weak var catalog: LensWorksCatalog?
    private(set) var operation: LWApplicationRelinkOperation?
    private(set) var plan: LWApplicationRelinkPlan?
    private(set) var items: [LWApplicationRelinkItem] = []
    private(set) var itemsNext: LWCatalogI64?
    private(set) var itemsStart = LWCatalogI64(0)
    private(set) var rules: [LWApplicationRelinkRuleRow] = []
    private(set) var rulesNext: LWApplicationRelinkRuleCursor?
    private(set) var plans: [LWApplicationRelinkPlan] = []
    private(set) var plansNext: String?
    private(set) var sources: [Int64: [LWApplicationRelinkSource]] = [:]
    private(set) var sourcesNext: [Int64: LWCatalogI64] = [:]
    private(set) var mounts: LWApplicationRelinkMounts?
    private(set) var original: LWApplicationRelinkOriginal?
    /// The most recently applied review in this session, offered as one Undo step.
    private(set) var lastApplied: LWApplicationRelinkPlan?
    private(set) var admitting = false
    @ObservationIgnored private var epoch: UInt64 = 0
    static let pageLimit: UInt64 = 20
    static let batchRows: UInt64 = 64
    static let acknowledgement = "no_retained_original_digest"

    static func terminal(_ operation: LWApplicationRelinkOperation) -> Bool {
        !operation.write_hold && [.Complete, .Canceled, .Failed].contains(operation.phase)
    }
    /// A storage operation is admitted or running. Catalog writes may be held.
    var isRunning: Bool { admitting || operation.map { !Self.terminal($0) } == true }
    var writeHold: Bool { operation?.write_hold == true }

    func reset() {
        epoch &+= 1
        operation = nil; plan = nil; items = []; itemsNext = nil; itemsStart = LWCatalogI64(0)
        rules = []; rulesNext = nil; plans = []; plansNext = nil; sources = [:]; sourcesNext = [:]
        mounts = nil; original = nil; lastApplied = nil; admitting = false
    }

    private func owner() throws -> (LensWorksCatalog, LensWorksCatalogScope, UInt64) {
        guard let catalog else { throw LensWorksManagedError.closed }
        try catalog.admitCatalogWork()
        guard catalog.catalogToken != nil else { throw LensWorksCatalogError.message("Open a catalog first.") }
        return (catalog, catalog.captureScope(), epoch)
    }
    private func check(_ catalog: LensWorksCatalog, _ scope: LensWorksCatalogScope, _ admitted: UInt64) throws {
        try catalog.checkScope(scope)
        guard admitted == epoch else { throw CancellationError() }
    }
    private func read(_ request: LWApplicationRelinkRequest) async throws -> LWApplicationRelinkResponse {
        let (catalog, scope, admitted) = try owner()
        let response = try await catalog.service.relink(request)
        try check(catalog, scope, admitted)
        return response
    }

    // MARK: Reviews

    /// Creates a saved review for a moved folder (recursive), one original, or a reconnected volume,
    /// then prepares it so its matches, mismatches and ambiguity can be inspected.
    @discardableResult
    func begin(_ scope: LWApplicationRelinkScope, prepare: Bool = true) async throws -> LWApplicationRelinkPlan {
        guard !isRunning else { throw LensWorksCatalogError.message("Wait for the current storage operation to finish.") }
        guard case .Plan(let created) = try await read(.Begin(scope: scope)) else { throw LensWorksManagedError.protocolViolation("Expected a relink review.") }
        try await publish(created)
        if prepare, ["preparing", "checking"].contains(created.state) { try await self.prepare() }
        return plan ?? created
    }
    func beginFolder(from: LWCatalogStoragePathReference, destinations: [LWCatalogNativePath]) async throws {
        guard !destinations.isEmpty, destinations.count <= 32 else { throw LensWorksCatalogError.message("Choose one to 32 destination folders.") }
        try await begin(.Prefix(from: from, destinations: destinations))
    }
    func beginOriginal(assetID: String, destinations: [LWCatalogNativePath]) async throws {
        guard !destinations.isEmpty, destinations.count <= 32 else { throw LensWorksCatalogError.message("Choose one to 32 candidate files.") }
        try await begin(.Asset(asset_id: assetID, destinations: destinations))
    }
    func beginVolume(logicalVolume: String, mountToken: String) async throws {
        try await begin(.Volume(logical_volume: logicalVolume, mount_token: mountToken))
    }
    func openPlan(_ id: String) async throws {
        guard case .Plan(let value) = try await read(.Plan(plan: id)) else { throw LensWorksManagedError.protocolViolation("Expected a saved relink review.") }
        try await publish(value)
    }
    func prepare() async throws {
        let plan = try requirePlan()
        let done = try await run(.Prepare(plan: plan.id, revision: plan.revision, batch_rows: LWCatalogU64(Self.batchRows)))
        try await adopt(done)
    }
    /// Revises the review: new candidates for an original or metadata source (empty excludes
    /// it), or a nested folder mapping. The revised review is prepared again.
    func revise(_ changes: [LWApplicationRelinkOverride]) async throws {
        let plan = try requirePlan()
        let done = try await run(.Revise(plan: plan.id, revision: plan.revision, changes: changes))
        try await adopt(done)
        if let next = self.plan, ["preparing", "checking"].contains(next.state) { try await prepare() }
    }
    func confirm() async throws {
        let plan = try requirePlan()
        guard let token = plan.confirmation_token else { throw LensWorksCatalogError.message("This review has no associations awaiting confirmation.") }
        let done = try await run(.Confirm(plan: plan.id, revision: plan.revision, token: token, acknowledgement: Self.acknowledgement))
        try await adopt(done)
    }
    /// Publishes every reviewed association in one engine transaction. Originals stay on disk.
    func apply() async throws {
        if let reason = applyUnavailableReason { throw LensWorksCatalogError.message(reason) }
        let plan = try requirePlan()
        let done = try await run(.Apply(plan: plan.id, revision: plan.revision))
        try await adopt(done)
        lastApplied = self.plan
        await catalog?.relinkChanged()
    }
    /// Reverses one applied review as a single step, after the engine validates its lineage.
    func undo(_ target: LWApplicationRelinkPlan? = nil) async throws {
        guard let plan = target ?? lastApplied ?? self.plan, plan.state == "applied" else { throw LensWorksCatalogError.message("Only an applied relink review can be undone.") }
        let done = try await run(.Undo(plan: plan.id, revision: plan.revision))
        try await adopt(done)
        if lastApplied?.id == plan.id { lastApplied = nil }
        await catalog?.relinkChanged()
    }
    var applyUnavailableReason: String? {
        guard let plan else { return "Create or open a relink review first." }
        if isRunning { return "Wait for the current storage operation to finish." }
        if !plan.summary_complete { return "This older review has no complete counts. Create a fresh review with these mappings before applying." }
        if plan.state == "applied" { return "This review is already applied. Undo it to restore the previous locations." }
        if plan.state != "ready" { return "Prepare this review before applying it." }
        if plan.total.value == plan.excluded.value { return "Every original in this review is excluded; there is nothing to apply." }
        if plan.unverified.value > 0 { return "Confirm or change the \(plan.unverified.value) association(s) without a retained original digest before applying." }
        if plan.unresolved.value > 0 || plan.unresolved_sources.value > 0 {
            return "\(plan.unresolved.value) original(s) and \(plan.unresolved_sources.value) metadata source(s) have no verified match (missing, mismatched or ambiguous). Choose a candidate or exclude them; nothing changes until every row is resolved."
        }
        return nil
    }

    // MARK: Observation

    @discardableResult
    func observeOriginal(_ key: LWCatalogEditsVariantKey) async throws -> LWApplicationRelinkOriginal {
        let done = try await run(.Original(key: key))
        guard case .Original(let value) = done.result, value.key.asset_id == key.asset_id, value.key.variant_id == key.variant_id else {
            throw LensWorksManagedError.protocolViolation("Expected the selected original's status.")
        }
        original = value
        return value
    }
    func observeMounts() async throws {
        let done = try await run(.Mounts)
        guard case .Mounts(let value) = done.result else { throw LensWorksManagedError.protocolViolation("Expected connected storage.") }
        mounts = value
    }
    /// Recovers the engine's current storage operation after this view lost track of it.
    func recoverStatus() async throws {
        guard case .Operation(let value) = try await read(.Status(operation: nil)) else { throw LensWorksManagedError.protocolViolation("Expected a storage operation status.") }
        operation = value
    }
    func cancel() async throws {
        guard let current = operation, !Self.terminal(current) else { return }
        guard case .Operation(let value) = try await read(.Cancel(operation: current.id)) else { throw LensWorksManagedError.protocolViolation("Expected a storage operation status.") }
        if let value, value.id == current.id { operation = value }
    }

    // MARK: Pages

    func loadItems(after: LWCatalogI64 = LWCatalogI64(0)) async throws {
        let plan = try requirePlan()
        guard case .Items(let rows, let next) = try await read(.Items(plan: plan.id, revision: plan.revision, after: after, limit: LWCatalogU64(Self.pageLimit))),
              rows.count <= Int(Self.pageLimit) else { throw LensWorksManagedError.protocolViolation("Expected a bounded relink item page.") }
        guard self.plan?.id == plan.id, self.plan?.revision == plan.revision else { throw CancellationError() }
        items = rows; itemsNext = next; itemsStart = after
    }
    func nextItems() async throws { if let next = itemsNext { try await loadItems(after: next) } }
    func loadSources(sequence: LWCatalogI64, after: LWCatalogI64 = LWCatalogI64(0)) async throws {
        let plan = try requirePlan()
        guard case .Sources(let rows, let next) = try await read(.Sources(plan: plan.id, revision: plan.revision, sequence: sequence, after: after, limit: LWCatalogU64(Self.pageLimit))),
              rows.count <= Int(Self.pageLimit) else { throw LensWorksManagedError.protocolViolation("Expected a bounded metadata source page.") }
        guard self.plan?.id == plan.id, self.plan?.revision == plan.revision else { throw CancellationError() }
        sources[sequence.value] = rows; sourcesNext[sequence.value] = next
    }
    func loadRules(after: LWApplicationRelinkRuleCursor? = nil) async throws {
        let plan = try requirePlan()
        guard case .Rules(let rows, let next, _) = try await read(.Rules(plan: plan.id, revision: plan.revision, after: after, limit: LWCatalogU64(Self.pageLimit))),
              rows.count <= Int(Self.pageLimit) else { throw LensWorksManagedError.protocolViolation("Expected a bounded relink rule page.") }
        guard self.plan?.id == plan.id, self.plan?.revision == plan.revision else { throw CancellationError() }
        rules = rows; rulesNext = next
    }
    func loadPlans(after: String = "") async throws {
        guard case .Plans(let rows, let next) = try await read(.Plans(after: after, limit: LWCatalogU64(Self.pageLimit))),
              rows.count <= Int(Self.pageLimit) else { throw LensWorksManagedError.protocolViolation("Expected a bounded saved review page.") }
        plans = rows; plansNext = next
    }

    // MARK: Operation custody

    private func requirePlan() throws -> LWApplicationRelinkPlan {
        guard let plan else { throw LensWorksCatalogError.message("Create or open a relink review first.") }
        return plan
    }
    /// Starts one storage operation and observes it to its terminal status. A canceled or
    /// failed operation throws; a commit that won a concurrent cancel is reported complete.
    private func run(_ request: LWApplicationRelinkRequest) async throws -> LWApplicationRelinkOperation {
        guard !isRunning else { throw LensWorksCatalogError.message("Wait for the current storage operation to finish.") }
        admitting = true
        defer { admitting = false }
        let (catalog, scope, admitted) = try owner()
        guard case .Operation(let started?) = try await catalog.service.relink(request) else { throw LensWorksManagedError.protocolViolation("The storage operation was not admitted.") }
        try check(catalog, scope, admitted)
        operation = started
        var current = started
        while !Self.terminal(current) {
            try await Task.sleep(for: .milliseconds(10))
            guard case .Operation(let next?) = try await catalog.service.relink(.Status(operation: started.id)), next.id == started.id else {
                throw LensWorksManagedError.protocolViolation("The storage operation identity changed.")
            }
            try check(catalog, scope, admitted)
            current = next; operation = next
        }
        switch current.phase {
        case .Failed: throw LensWorksCatalogError.message(current.error ?? "The storage operation failed. No catalog association changed.")
        case .Canceled: throw LensWorksCatalogError.message("The storage operation was canceled. No catalog association changed.")
        default: return current
        }
    }
    private func adopt(_ done: LWApplicationRelinkOperation) async throws {
        if case .Plan(let value) = done.result { try await publish(value) }
        else if let value = done.plan { try await publish(value) }
    }
    private func publish(_ value: LWApplicationRelinkPlan) async throws {
        plan = value; items = []; itemsNext = nil; itemsStart = LWCatalogI64(0); sources = [:]; sourcesNext = [:]; rules = []; rulesNext = nil
        if value.state != "preparing" {
            try await loadItems()
            try await loadRules()
        }
    }
}
