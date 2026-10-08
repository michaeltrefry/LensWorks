import Foundation
import CoreGraphics
import ImageIO

nonisolated struct LensWorksBrowserPage: Sendable {
    let catalog: String
    let rows: [LWApplicationDtoGridImage]
    let next: String?
    let hasMore: Bool
    let complete: Bool
    let scanned: UInt32
}
nonisolated struct LensWorksFolderPage: Sendable {
    let rows: [LWApplicationDtoFolder]
    let next: LWCatalogI64?
}

/// A bounded observation of an actually admitted page and its query owner.
nonisolated struct LensWorksCatalogPageAuthority: Equatable, Sendable {
    let catalogEpoch: UInt64
    let queryEpoch: UInt64
    let publication: UInt64
    let ordinal: Int64
    let current: String?
    let next: String?
}

/// Only cursor authorities are retained; previous pages never retain image rows.
nonisolated struct LensWorksCursorWindow: Sendable {
    static let capacity = 64
    private(set) var previous: [String?] = []
    var current: String?
    var next: String?
    mutating func reset() { previous = []; current = nil; next = nil }
    mutating func advance() -> String? {
        previous.append(current)
        if previous.count > Self.capacity { previous.removeFirst() }
        current = next
        return current
    }
    mutating func retreat() -> String? { current = previous.removeLast(); return current }
}

nonisolated struct LensWorksPreviewMetrics: Codable, Sendable {
    var active = 0
    var activeHighWater = 0
    var pending = 0
    var pendingHighWater = 0
    var cacheEntries = 0
    var cacheBytes = 0
    var cacheEntriesHighWater = 0
    var cacheBytesHighWater = 0
    var completed = 0
    var canceled = 0
}

nonisolated struct LensWorksPreviewSample: Codable, Sendable {
    let x: Int
    let y: Int
    let rgba: [UInt8]
}

/// Immutable decoded pixels; ImageIO decoding and color conversion occur off the UI actor.
nonisolated final class LensWorksPreview: @unchecked Sendable {
    let image: CGImage
    let data: Data
    let status: LWApplicationDtoPreviewStatus
    let width: Int
    let height: Int
    let samples: [LensWorksPreviewSample]
    let colorSpace = "srgb"
    let alpha = "opaque"
    let cost: Int
    init(copying value: LensWorksPreview, status: LWApplicationDtoPreviewStatus) {
        self.image = value.image; self.data = value.data; self.status = status
        self.width = value.width; self.height = value.height; self.samples = value.samples; self.cost = value.cost
    }
    init(data: Data, status: LWApplicationDtoPreviewStatus, edge: UInt32, binaryLimit: Int) throws {
        guard data.count <= binaryLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, edge > 0, edge <= 8192, width <= Int(edge), height <= Int(edge),
              width * height * 4 <= 256 * 1024 * 1024,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == width, image.height == height,
              let color = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LensWorksManagedError.protocolViolation("Preview header exceeds the decoded pixel allowance.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { throw LensWorksManagedError.protocolViolation("Preview pixels could not be decoded.") }
        let columns = width >= height ? 3 : 2
        let rows = width >= height ? 2 : 3
        self.samples = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let x = min(width - 1, (2 * column + 1) * width / (2 * columns))
                let y = min(height - 1, (2 * row + 1) * height / (2 * rows))
                let index = (y * width + x) * 4
                return LensWorksPreviewSample(x: x, y: y, rgba: Array(pixels[index..<(index + 4)]))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let displayed = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: color,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw LensWorksManagedError.protocolViolation("Decoded sRGB preview storage could not be admitted.")
        }
        self.data = data; self.status = status; self.image = displayed
        self.width = width; self.height = height
        self.cost = data.count + displayed.bytesPerRow * displayed.height
    }
}

/// Four reusable viewports, finite queued work, and a decoded-pixel LRU independent of catalog size.
actor LensWorksPreviewStore {
    private enum Retry: Error { case staleAuthority }
    static let maximumActive = 4
    static let maximumPending = 200
    static let maximumEntries = 64
    static let maximumBytes = 32 * 1024 * 1024
    private let session: LWManagedSession
    private let catalog: String
    private let thumbnailEdge: UInt32
    private let largeEdge: UInt32
    private let binaryLimit: Int
    private var freeSlots = Array(0..<4)
    private var accepting = true
    private var drainRequired = false
    private var drainInFlight = false
    private var drainJob: LWManagedJob?
    private var drainResult: LWManagedResult?
    private var drainOutcome: Result<Bool, any Error>?
    private var generations = [UInt64](repeating: 0, count: 4)
    private var waiting: [(UUID, CheckedContinuation<Int, any Error>)] = []
    private var tasks: [UUID: Task<LensWorksPreview, any Error>] = [:]
    private var cached: [String: LensWorksPreview] = [:]
    private var recency: [String] = []
    private var totals = LensWorksPreviewMetrics()
    #if DEBUG
    // Nil normally; holds a real admitted ticket before its bytes retire the native slot.
    private var admittedPreviewFixture: (@Sendable (String) async -> Void)?
    func setAdmittedPreviewFixture(_ fixture: (@Sendable (String) async -> Void)?) { admittedPreviewFixture = fixture }
    private var admittedPreviewBytesFixture: (@Sendable (UInt64) async -> Void)?
    func setAdmittedPreviewBytesFixture(_ fixture: (@Sendable (UInt64) async -> Void)?) { admittedPreviewBytesFixture = fixture }
    private var drainFixture: (@Sendable (LensWorksPreviewDrainFaultPoint) async throws -> Void)?
    func setDrainFixture(_ fixture: (@Sendable (LensWorksPreviewDrainFaultPoint) async throws -> Void)?) { drainFixture = fixture }
    func drainCustody() -> (job: UInt64?, result: Bool, outcome: Bool, required: Bool, accepting: Bool) {
        (drainJob?.handle.value, drainResult != nil, drainOutcome != nil, drainRequired, accepting)
    }
    #endif
    init(session: LWManagedSession, catalog: String, thumbnailEdge: UInt32 = 512, largeEdge: UInt32 = 1600, binaryLimit: Int = 16 * 1024 * 1024) {
        self.session = session; self.catalog = catalog; self.thumbnailEdge = thumbnailEdge; self.largeEdge = largeEdge; self.binaryLimit = binaryLimit
    }

    func metrics() -> LensWorksPreviewMetrics { totals }
    func fetch(_ key: LWCatalogEditsVariantKey, tier: LWApplicationDtoPreviewTier = .Thumbnail) async throws -> LensWorksPreview {
        guard accepting else { throw LensWorksCatalogError.message("Previews are paused for storage maintenance.") }
        guard tasks.count < Self.maximumPending else { throw LensWorksManagedError.resourceLimit("Thumbnail work is waiting for a viewport.") }
        let id = UUID()
        let task = Task {
            do { return try await render(key, tier: tier, id: id) }
            catch Retry.staleAuthority { try Task.checkCancellation(); return try await render(key, tier: tier, id: id) }
        }
        tasks[id] = task
        defer { tasks[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func acquire(_ id: UUID) async throws -> Int {
        try Task.checkCancellation()
        if !freeSlots.isEmpty {
            totals.active += 1; totals.activeHighWater = max(totals.activeHighWater, totals.active)
            return freeSlots.removeLast()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation)); totals.pending = waiting.count
                totals.pendingHighWater = max(totals.pendingHighWater, waiting.count)
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiting.remove(at: index); totals.pending = waiting.count
        waiter.1.resume(throwing: CancellationError())
    }
    private func release(_ slot: Int) {
        if !waiting.isEmpty {
            let waiter = waiting.removeFirst(); totals.pending = waiting.count
            waiter.1.resume(returning: slot)
        } else { freeSlots.append(slot); totals.active -= 1 }
    }
    @discardableResult func setAdmission(_ enabled: Bool) -> Bool {
        guard !enabled || (!drainRequired && !drainInFlight && drainJob == nil) else { return false }
        accepting = enabled
        return true
    }
    func drain(timeoutMilliseconds: UInt32 = 30000) async throws {
        try await drain(checkedClose: nil, timeoutMilliseconds: timeoutMilliseconds)
    }
    func drain(afterCheckedCatalogClose proof: LensWorksCheckedPreviewCatalogClose, timeoutMilliseconds: UInt32) async throws {
        guard proof.matches(session: session, catalog: catalog) else { throw LensWorksManagedError.protocolViolation("Preview retirement has a different checked catalog-close authority.") }
        try await drain(checkedClose: proof, timeoutMilliseconds: timeoutMilliseconds)
    }
    private func checkDrainDeadline(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Native preview consumers are still retiring. Their status job and catalog remain owned for checked retry.") }
    }
    private func drain(checkedClose: LensWorksCheckedPreviewCatalogClose?, timeoutMilliseconds: UInt32) async throws {
        guard timeoutMilliseconds > 0, timeoutMilliseconds <= 60000 else { throw LensWorksManagedError.protocolViolation("Preview retirement observation exceeds 60 seconds.") }
        guard !drainInFlight else { throw LensWorksManagedError.native(code: "busy", message: "Preview retirement is already being observed.") }
        drainInFlight = true; defer { drainInFlight = false }
        accepting = false
        drainRequired = true
        cancelAll()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        while !tasks.isEmpty {
            try checkDrainDeadline(deadline)
            try await Task.sleep(for: min(.milliseconds(25), ContinuousClock.now.duration(to: deadline)))
        }
        if checkedClose != nil {
            // The same native catalog already returned checked Closed. Do not
            // query its retired token; release any previously owned status job.
            if let job = drainJob {
                try checkDrainDeadline(deadline)
                if try await job.status().phase == .pending { try await job.cancel() }
                while true {
                    try checkDrainDeadline(deadline)
                    let status = try await job.status()
                    try checkDrainDeadline(deadline)
                    if status.phase != .pending { break }
                    try await Task.sleep(for: min(.milliseconds(25), ContinuousClock.now.duration(to: deadline)))
                }
                drainResult?.buffer.release(); drainResult = nil
                try checkDrainDeadline(deadline)
                try await job.close()
                drainJob = nil; drainOutcome = nil
                try checkDrainDeadline(deadline)
            }
            try checkDrainDeadline(deadline)
            drainRequired = false
            return
        }
        while true {
            try checkDrainDeadline(deadline)
            if drainJob == nil {
                drainOutcome = nil
                drainJob = try await session.submit(.PreviewSettings(catalog: catalog, request: .Status))
                #if DEBUG
                if let drainFixture { try await drainFixture(.afterSubmit) }
                #endif
            }
            guard let job = drainJob else { throw LensWorksManagedError.protocolViolation("Preview retirement lost its status job.") }
            while true {
                try checkDrainDeadline(deadline)
                let status = try await job.status()
                try checkDrainDeadline(deadline)
                if status.phase != .pending { break }
                try await Task.sleep(for: min(.milliseconds(25), ContinuousClock.now.duration(to: deadline)))
            }
            if drainOutcome == nil {
                if drainResult == nil {
                    try checkDrainDeadline(deadline)
                    drainResult = try await job.takeResult()
                }
                guard let result = drainResult else { throw LensWorksManagedError.protocolViolation("Preview retirement lost its taken status result.") }
                #if DEBUG
                if let drainFixture { try await drainFixture(.beforeDecode) }
                #endif
                try checkDrainDeadline(deadline)
                let reply = try await result.decode(LWApplicationReply.self)
                try checkDrainDeadline(deadline)
                switch reply {
                case .Ok(.PreviewSettings(let status)): drainOutcome = .success(status.previews_drained)
                case .Error(let fault): drainOutcome = .failure(LensWorksManagedError.native(code: fault.code.rawValue, message: fault.message))
                default: throw LensWorksManagedError.protocolViolation("Expected native preview retirement status.")
                }
                result.buffer.release(); drainResult = nil
            }
            #if DEBUG
            if let drainFixture { try await drainFixture(.beforeRelease) }
            #endif
            try checkDrainDeadline(deadline)
            try await job.close()
            drainJob = nil
            guard let outcome = drainOutcome else { throw LensWorksManagedError.protocolViolation("Preview retirement lost its decoded status.") }
            drainOutcome = nil
            try checkDrainDeadline(deadline)
            if try outcome.get() { drainRequired = false; return }
            try await Task.sleep(for: min(.milliseconds(25), ContinuousClock.now.duration(to: deadline)))
        }
    }
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        let waiters = waiting; waiting = []; totals.pending = 0
        for (_, waiter) in waiters { waiter.resume(throwing: CancellationError()) }
    }
    func invalidate(_ key: LWCatalogEditsVariantKey) {
        let prefix = key.asset_id + "/" + key.variant_id + "/"
        for cacheKey in recency.filter({ $0.hasPrefix(prefix) }) {
            if let value = cached.removeValue(forKey: cacheKey) { totals.cacheBytes -= value.cost }
            recency.removeAll { $0 == cacheKey }
        }
        totals.cacheEntries = cached.count
    }
    private func render(_ key: LWCatalogEditsVariantKey, tier: LWApplicationDtoPreviewTier, id: UUID) async throws -> LensWorksPreview {
        let slot = try await acquire(id)
        defer { release(slot) }
        try Task.checkCancellation()
        guard case .Variant(let authority) = try await session.perform(.Variant(catalog: catalog, key: key)) else {
            throw LensWorksManagedError.protocolViolation("Expected thumbnail edit authority.")
        }
        generations[slot] &+= 1
        let generation = LWCatalogU64(generations[slot])
        let viewport = "native-catalog-" + String(slot)
        let owner = session, token = catalog
        var ticket: String?
        do {
            guard case .Preview(var status) = try await owner.perform(.Preview(catalog: token, key: key,
                tier: tier, interactive: false, viewport: viewport, generation: generation, foreground: true, diagnostics: true)) else {
                throw LensWorksManagedError.protocolViolation("Expected thumbnail progress.")
            }
            ticket = status.ticket
            #if DEBUG
            if let admittedPreviewFixture { await admittedPreviewFixture(status.ticket) }
            #endif
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while [.Queued, .CancelRequested].contains(status.state) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Thumbnail generation is still pending. Retry to request it again.") }
                try await Task.sleep(for: .milliseconds(25))
                guard case .Preview(let next) = try await owner.perform(.PreviewStatus(catalog: token, ticket: status.ticket)), next.ticket == status.ticket else {
                    throw LensWorksManagedError.protocolViolation("Thumbnail ticket identity changed.")
                }
                status = next
            }
            if status.state == .Stale || (status.state == .Ready && (status.revision != authority.revision || status.recipe_digest != authority.recipe_digest)) { throw Retry.staleAuthority }
            guard status.state == .Ready, status.revision == authority.revision, status.recipe_digest == authority.recipe_digest else {
                throw LensWorksCatalogError.message(status.message ?? "Thumbnail " + status.state.rawValue + ".")
            }
            let cacheKey = key.asset_id + "/" + key.variant_id + "/" + tier.rawValue + "/" + String(status.revision.value) + "/" + status.recipe_digest + "/" + (status.diagnostic?.expected_key_digest ?? UUID().uuidString)
            if let cached = cached[cacheKey] {
                try Task.checkCancellation()
                _ = try await owner.perform(.ReleaseViewport(catalog: token, viewport: viewport, generation: generation))
                recency.removeAll { $0 == cacheKey }; recency.append(cacheKey)
                return LensWorksPreview(copying: cached, status: status)
            }
            let job = try await owner.preview(catalog: token, ticket: status.ticket, foreground: true)
            let value: LensWorksPreview
            do {
                #if DEBUG
                // The real bytes job is already owned. This gate cannot mint a
                // ticket, native read, result or retirement observation.
                if let admittedPreviewBytesFixture { await admittedPreviewBytesFixture(job.handle.value) }
                #endif
                let result = try await job.wait(); defer { result.buffer.release() }
                let data = try await result.buffer.copy(maximumBytes: binaryLimit, expectedLength: result.length)
                let captured = status, edge = tier == .Thumbnail ? thumbnailEdge : largeEdge, bytes = binaryLimit
                value = try await Task.detached(priority: .utility) { try LensWorksPreview(data: data, status: captured, edge: edge, binaryLimit: bytes) }.value
                try await job.close()
            } catch { try? await Task.detached { try await job.close() }.value; throw error }
            try Task.checkCancellation()
            _ = try await owner.perform(.ReleaseViewport(catalog: token, viewport: viewport, generation: generation))
            if let replaced = cached.removeValue(forKey: cacheKey) { totals.cacheBytes -= replaced.cost }
            recency.removeAll { $0 == cacheKey }
            while cached.count >= Self.maximumEntries || totals.cacheBytes + value.cost > Self.maximumBytes {
                guard !recency.isEmpty else { break }
                let old = recency.removeFirst()
                if let oldValue = cached.removeValue(forKey: old) { totals.cacheBytes -= oldValue.cost }
            }
            if value.cost <= Self.maximumBytes {
                cached[cacheKey] = value; recency.append(cacheKey); totals.cacheBytes += value.cost
            }
            totals.cacheEntries = cached.count
            totals.cacheEntriesHighWater = max(totals.cacheEntriesHighWater, cached.count)
            totals.cacheBytesHighWater = max(totals.cacheBytesHighWater, totals.cacheBytes)
            totals.completed += 1
            return value
        } catch {
            let admittedTicket = ticket
            await Task.detached {
                if let admittedTicket { _ = try? await owner.perform(.CancelPreview(catalog: token, ticket: admittedTicket)) }
                _ = try? await owner.perform(.ReleaseViewport(catalog: token, viewport: viewport, generation: generation))
            }.value
            if error is CancellationError { totals.canceled += 1 }
            throw error
        }
    }
}
