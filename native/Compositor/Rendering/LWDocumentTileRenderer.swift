import Foundation
import CoreGraphics
import CryptoKit

/// Full-resolution document evaluation over a fixed tile grid, a reduced-resolution pyramid built
/// from it, and one byte-bounded tile cache shared by every open document.
///
/// - Evaluation: `LWFloatCompositor.renderPlane(_:region:workspace:)` restricted to the missing
///   tiles of a request (in blocks of at most `blockTiles`×`blockTiles`), widened by the
///   document's spatial `halo` out to the tile grid and cropped back. Peak scratch is therefore set
///   by the block, not by the document, and a document never has to be resident whole.
/// - Pyramid: a level-k tile is 256×256 samples of the document reduced 2^k times. It is built by
///   repeated 2× box reduction (premultiplied) of the full-resolution tiles under it, one
///   evaluation block at a time; those full-resolution tiles are not kept, only the reduced tile is.
///   `view` picks the level for a zoom, so a zoomed-out view of any document costs the screen's
///   pixels, never the document's.
/// - Residency: every cached tile is charged to the working set; the cache never retains more than
///   `budgetBytes`, evicts least-recently-used tiles beyond it, and gives tiles back whenever
///   another consumer of the working set needs the bytes (`LWFloatReclaimable`).
/// - Invalidation: each level-0 tile's fingerprint covers the source, recipe and layer state
///   (record, pixel identity, mask identity, ancestors and clipping sources) of every layer whose
///   footprint reaches that tile, plus the layer order; a level-k tile's fingerprint is the hash of
///   its four level-(k-1) children. A new `plan` drops exactly that document's tiles whose
///   fingerprint changed; untouched tiles, and every other document's tiles, stay cached.
/// - Stale completions: a finished evaluation publishes a tile only if its document's latest plan
///   still requires that tile's fingerprint. Plans are ordered by when `plan` was called, so a
///   snapshot fingerprinted late can never displace a newer one.
nonisolated final class LWDocumentTileRenderer: LWFloatReclaimable, @unchecked Sendable {
    static let tileSide = LWFloatPlane.tileSide
    /// Declared cache residency for the interactive canvas (RENDERER_PRECISION_CONTRACT.json).
    static let defaultBudgetBytes = 256 * 1024 * 1024
    /// Declared bound on one assembled canvas view (premultiplied half float, 8 bytes a sample).
    static let frameBudgetBytes = 128 * 1024 * 1024
    /// One evaluation covers at most this many tiles on a side (1024 × 1024 px at 256 px tiles).
    static let blockTiles = 4
    /// Coarsest pyramid level. Level-0 tiles are 256 px, so up to level 8 every 2× step stays aligned
    /// to the full-resolution tile grid.
    static let maxLevel = 8
    static var tileBytes: Int { tileSide * tileSide * MemoryLayout<SIMD4<Float>>.stride }

    struct TileKey: Hashable, Sendable {
        let document: UUID
        let level: Int
        let column: Int
        let row: Int
    }

    /// One level of the pyramid: its sample extent, tile grid and tile fingerprints.
    struct Grid: Sendable {
        let width: Int, height: Int, columns: Int, rows: Int
        let fingerprints: [Data]
    }

    /// One request's view of a document: its tile fingerprints and the snapshot that produced them.
    struct Plan: @unchecked Sendable {
        let generation: UInt64
        let document: UUID
        let snapshot: ProjectSnapshot
        let halo: Int
        let levels: [Grid]
        /// Pixel owners whose identity enters a fingerprint, retained so it cannot be reused.
        fileprivate let dependencies: [AnyObject]
        var width: Int { levels[0].width }
        var height: Int { levels[0].height }
        var columns: Int { levels[0].columns }
        var rows: Int { levels[0].rows }
        func key(level: Int = 0, column: Int, row: Int) -> TileKey { TileKey(document: document, level: level, column: column, row: row) }
        func contains(_ key: TileKey) -> Bool {
            key.document == document && key.level >= 0 && key.level < levels.count
                && key.column >= 0 && key.row >= 0 && key.column < levels[key.level].columns && key.row < levels[key.level].rows
        }
        func fingerprint(_ key: TileKey) -> Data { levels[key.level].fingerprints[key.row * levels[key.level].columns + key.column] }
        /// The tile's samples in its level's coordinates.
        func range(_ key: TileKey) -> LWFloatRange {
            let grid = levels[key.level], side = LWDocumentTileRenderer.tileSide
            let x = key.column * side, y = key.row * side
            return LWFloatRange(x: x, y: y, width: min(side, grid.width - x), height: min(side, grid.height - y))
        }
        func keys(covering region: LWFloatRange, level: Int = 0) throws -> [TileKey] {
            guard level >= 0, level < levels.count else { throw ProjectError.invalid }
            let grid = levels[level]
            _ = try region.validate(frameWidth: grid.width, frameHeight: grid.height)
            let side = LWDocumentTileRenderer.tileSide
            return (region.y / side...(region.y + region.height - 1) / side).flatMap { row in
                (region.x / side...(region.x + region.width - 1) / side).map { key(level: level, column: $0, row: row) }
            }
        }
    }

    struct Tile: Sendable {
        let key: TileKey
        let range: LWFloatRange
        let pixels: [SIMD4<Float>]
        /// The working-set charge for `pixels` while they are not (only) held by the cache.
        fileprivate let charge: LWFloatWorkingSet.Lease?
    }

    /// One assembled canvas view: premultiplied extended-linear half-float samples of `region` at `level`.
    struct View: @unchecked Sendable {
        let level: Int
        let region: LWFloatRange
        let data: Data
        let charge: LWFloatWorkingSet.Lease
        var scale: Int { 1 << level }
    }

    private final class Entry {
        let fingerprint: Data
        let pixels: [SIMD4<Float>]
        let lease: LWFloatWorkingSet.Lease
        let dependencies: [AnyObject]
        var used: UInt64
        init(fingerprint: Data, pixels: [SIMD4<Float>], lease: LWFloatWorkingSet.Lease, dependencies: [AnyObject], used: UInt64) {
            self.fingerprint = fingerprint; self.pixels = pixels; self.lease = lease; self.dependencies = dependencies; self.used = used
        }
    }

    let budgetBytes: Int
    let workingSet: LWFloatWorkingSet
    private let lock = NSLock()
    private var entries: [TileKey: Entry] = [:]
    private var latest: [UUID: Plan] = [:]
    private var issued: UInt64 = 0
    private var clock: UInt64 = 0
    private var resident = 0
    private var peak = 0
    private var evicted = 0
    private var reclaimed = 0
    private var discarded = 0
    private var evaluated = 0
    /// Test seam: runs after a block is evaluated and before its tiles are published.
    var beforePublish: ((Plan) -> Void)?
    /// Test seam: runs as a plan starts fingerprinting (which takes time on a large document).
    var beforeFingerprint: (() -> Void)?

    init(budgetBytes: Int = defaultBudgetBytes, workingSet: LWFloatWorkingSet = .sourceGraphs) throws {
        guard budgetBytes >= Self.tileBytes, budgetBytes <= workingSet.limit else { throw ProjectError.tooLarge }
        self.budgetBytes = budgetBytes; self.workingSet = workingSet
        workingSet.register(self)
    }

    var residentBytes: Int { lock.withLock { resident } }
    var peakResidentBytes: Int { lock.withLock { peak } }
    var evictionCount: Int { lock.withLock { evicted } }
    /// Bytes given back to other working-set consumers.
    var reclaimedBytes: Int { lock.withLock { reclaimed } }
    var discardedCompletions: Int { lock.withLock { discarded } }
    var evaluatedTiles: Int { lock.withLock { evaluated } }
    var cachedKeys: Set<TileKey> { lock.withLock { Set(entries.keys) } }
    func cachedKeys(of document: UUID) -> Set<TileKey> { lock.withLock { Set(entries.keys.filter { $0.document == document }) } }
    func resetPeak() { lock.withLock { peak = resident } }
    func isCurrent(_ plan: Plan) -> Bool { lock.withLock { latest[plan.document]?.generation == plan.generation } }

    // MARK: Planning and invalidation

    /// Fingerprints the document and makes it that document's latest request, unless a plan of the
    /// same document requested after this one is already installed. Cached tiles whose inputs
    /// changed are released now; the rest survive.
    func plan(_ snapshot: ProjectSnapshot) throws -> Plan {
        // The order of requests is fixed before fingerprinting, which may take a while.
        let ticket = lock.withLock { issued += 1; return issued }
        beforeFingerprint?()
        let made = try Self.fingerprints(snapshot)
        let document = snapshot.manifest.documentID
        return lock.withLock {
            let plan = Plan(generation: ticket, document: document, snapshot: snapshot, halo: made.halo,
                levels: made.levels, dependencies: made.dependencies)
            if let current = latest[document], current.generation > ticket { return plan }
            latest[document] = plan
            for (key, entry) in entries where key.document == document && (!plan.contains(key) || entry.fingerprint != plan.fingerprint(key)) {
                remove(key)
            }
            return plan
        }
    }

    /// Releases every cached tile (memory pressure).
    func purge() { lock.withLock { for key in Array(entries.keys) { remove(key) } } }

    /// Releases one document's tiles and its latest plan (document close); other documents keep theirs.
    func purge(document: UUID) {
        lock.withLock {
            for key in entries.keys where key.document == document { remove(key) }
            latest[document] = nil
        }
    }

    /// `LWFloatReclaimable`: least-recently-used tiles go until `bytes` are free.
    func reclaim(bytes: Int) {
        lock.withLock {
            var freed = 0
            while freed < bytes, let victim = entries.min(by: { $0.value.used < $1.value.used })?.key {
                freed += entries[victim]?.lease.bytes ?? 0
                remove(victim); evicted += 1
            }
            reclaimed += freed
        }
    }

    private func remove(_ key: TileKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        resident -= entry.lease.bytes
    }

    // MARK: Evaluation

    /// Every tile of `level` covering `region` (in that level's coordinates), in row-major order:
    /// cached where the fingerprint matches, evaluated otherwise. Returned tiles are those of `plan`,
    /// whether or not they were published.
    func tiles(covering region: LWFloatRange, level: Int = 0, plan: Plan) throws -> [Tile] {
        var found: [TileKey: Tile] = [:]
        try forEachTile(covering: region, level: level, plan: plan) { found[$0.key] = $0 }
        return try plan.keys(covering: region, level: level).map { found[$0]! }
    }

    /// Streams the tiles covering `region`, so a caller assembling them never holds more than one
    /// evaluation block of uncached tiles at a time.
    func forEachTile(covering region: LWFloatRange, level: Int = 0, plan: Plan, _ body: (Tile) throws -> Void) throws {
        let keys = try plan.keys(covering: region, level: level)
        var missing: [TileKey] = []
        for key in keys {
            if let pixels = cached(key, plan: plan) { try body(Tile(key: key, range: plan.range(key), pixels: pixels, charge: nil)) }
            else { missing.append(key) }
        }
        if level == 0 {
            // Blocks of the tile grid, each evaluated once for all of its missing tiles.
            for block in Self.blocks(missing) {
                try Task.checkCancellation()
                let (made, charge) = try evaluate(block, plan: plan, publish: true)
                for key in block { try body(Tile(key: key, range: plan.range(key), pixels: made[key]!, charge: charge)) }
            }
        } else {
            for key in missing {
                try Task.checkCancellation()
                let (pixels, charge) = try reduced(key, plan: plan)
                lock.withLock { publish(key, pixels: pixels, plan: plan) }
                try body(Tile(key: key, range: plan.range(key), pixels: pixels, charge: charge))
            }
        }
    }

    /// The document's samples for `region` of `level`, assembled from tiles.
    func surface(_ region: LWFloatRange, level: Int = 0, plan: Plan) throws -> LWLinearSurface {
        guard level >= 0, level < plan.levels.count else { throw ProjectError.invalid }
        let bytes = try region.validate(frameWidth: plan.levels[level].width, frameHeight: plan.levels[level].height)
        let charge = try workingSet.reserve(bytes)
        defer { withExtendedLifetime(charge) {} }
        var pixels = [SIMD4<Float>](repeating: .zero, count: bytes / 16)
        try forEachTile(covering: region, level: level, plan: plan) { tile in
            Self.copy(tile, into: region) { target, source, count in
                pixels.replaceSubrange(target..<(target + count), with: tile.pixels[source..<(source + count)])
            }
        }
        return try LWLinearSurface(width: region.width, height: region.height, pixels: pixels, maximumBytes: bytes)
    }

    /// The pyramid level for `scale` display pixels per document pixel: the coarsest level whose
    /// resolution is still at least the display's.
    static func level(forScale scale: Double, levels: Int) -> Int {
        guard scale.isFinite, scale > 0, levels > 0 else { return 0 }
        return min(levels - 1, max(0, Int((log2(1 / scale) + 1e-9).rounded(.down))))
    }

    /// The canvas view of `visible` (document pixels, top row first) at `scale` display pixels per
    /// document pixel. The level is the one `scale` calls for, made coarser until the assembled view
    /// fits `frameBudgetBytes`; the whole document is never evaluated or held at once.
    func view(_ visible: LWFloatRange, scale: Double, plan: Plan) throws -> View {
        _ = try visible.validate(frameWidth: plan.width, frameHeight: plan.height)
        var level = Self.level(forScale: scale, levels: plan.levels.count), region = visible
        while true {
            let f = 1 << level, grid = plan.levels[level]
            let x = visible.x / f, y = visible.y / f
            region = LWFloatRange(x: x, y: y, width: min(grid.width, (visible.x + visible.width + f - 1) / f) - x,
                height: min(grid.height, (visible.y + visible.height + f - 1) / f) - y)
            if region.width * region.height * 8 <= Self.frameBudgetBytes || level == plan.levels.count - 1 { break }
            level += 1
        }
        let bytes = region.width * region.height * 8
        guard bytes <= Self.frameBudgetBytes else { throw ProjectError.tooLarge }
        let charge = try workingSet.reserve(bytes)
        var data = Data(count: bytes)
        try data.withUnsafeMutableBytes { raw in
            let halves = raw.bindMemory(to: Float16.self)
            try forEachTile(covering: region, level: level, plan: plan) { tile in
                Self.copy(tile, into: region) { target, source, count in
                    for i in 0..<count {
                        let p = tile.pixels[source + i], o = (target + i) * 4
                        for c in 0..<3 { halves[o + c] = Float16(max(-65504, min(65504, p[c] * p.w))) }
                        halves[o + 3] = Float16(p.w)
                    }
                }
            }
        }
        return View(level: level, region: region, data: data, charge: charge)
    }

    /// Calls `body(target, source, count)` for each row of `tile` inside `region`, as sample indices.
    private static func copy(_ tile: Tile, into region: LWFloatRange, _ body: (Int, Int, Int) -> Void) {
        let left = max(region.x, tile.range.x), right = min(region.x + region.width, tile.range.x + tile.range.width)
        let top = max(region.y, tile.range.y), bottom = min(region.y + region.height, tile.range.y + tile.range.height)
        guard left < right, top < bottom else { return }
        for y in top..<bottom {
            body((y - region.y) * region.width + left - region.x, (y - tile.range.y) * tile.range.width + left - tile.range.x, right - left)
        }
    }

    private func cached(_ key: TileKey, plan: Plan) -> [SIMD4<Float>]? {
        lock.withLock {
            clock += 1
            guard let entry = entries[key], entry.fingerprint == plan.fingerprint(key) else { return nil }
            entry.used = clock; return entry.pixels
        }
    }

    private static func blocks(_ keys: [TileKey]) -> [[TileKey]] {
        let grouped = Dictionary(grouping: keys) { TileKey(document: $0.document, level: $0.level, column: $0.column / blockTiles, row: $0.row / blockTiles) }
        return grouped.keys.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map { grouped[$0]! }
    }

    /// Level-0 tiles of one block. The returned pixels are charged to the working set until the
    /// returned lease is released, whether or not the cache also holds them.
    private func evaluate(_ keys: [TileKey], plan: Plan, publish: Bool) throws -> ([TileKey: [SIMD4<Float>]], LWFloatWorkingSet.Lease) {
        let ranges = keys.map(plan.range)
        let left = ranges.map(\.x).min()!, top = ranges.map(\.y).min()!
        let right = ranges.map { $0.x + $0.width }.max()!, bottom = ranges.map { $0.y + $0.height }.max()!
        let covered = LWFloatRange(x: left, y: top, width: right - left, height: bottom - top)
        // Widened by the halo, then out to the tile grid: every placement range inside the region is then the
        // same document rectangle the whole-frame evaluation draws, so pointwise stages agree bit for bit.
        let widened = try covered.expanded(halo: plan.halo, frameWidth: plan.width, frameHeight: plan.height)
        let side = Self.tileSide
        let gx = widened.x / side * side, gy = widened.y / side * side
        let region = LWFloatRange(x: gx, y: gy,
            width: min(plan.width, (widened.x + widened.width + side - 1) / side * side) - gx,
            height: min(plan.height, (widened.y + widened.height + side - 1) / side * side) - gy)
        let charge = try workingSet.reserve(ranges.reduce(0) { $0 + $1.width * $1.height * 16 })
        var made: [TileKey: [SIMD4<Float>]] = [:]
        try autoreleasepool {
            let workspace = try LWFloatWorkspace(workingSet: workingSet)
            do {
                let plane = try LWFloatCompositor.renderPlane(plan.snapshot, region: region, workspace: workspace)
                for (key, range) in zip(keys, ranges) {
                    let tile = try plane.read(LWFloatRange(x: range.x - region.x, y: range.y - region.y, width: range.width, height: range.height))
                    made[key] = Array(tile.surface.pixels)
                }
            }
            withExtendedLifetime(workspace) {}
        }
        beforePublish?(plan)
        lock.withLock {
            evaluated += keys.count
            if publish { for key in keys { self.publish(key, pixels: made[key]!, plan: plan) } }
        }
        return (made, charge)
    }

    /// A level-k tile from the level-0 tiles under it, one evaluation block at a time: each level-0
    /// tile is reduced 2× k times (premultiplied box filter, the odd last sample of an edge kept
    /// alone) straight into the output. Level-0 tiles evaluated for it are not published.
    private func reduced(_ key: TileKey, plan: Plan) throws -> ([SIMD4<Float>], LWFloatWorkingSet.Lease) {
        let k = key.level, range = plan.range(key)
        let x0 = range.x << k, y0 = range.y << k
        let full = LWFloatRange(x: x0, y: y0, width: min(plan.width, (range.x + range.width) << k) - x0,
            height: min(plan.height, (range.y + range.height) << k) - y0)
        // Output plus one tile of reduction scratch.
        let charge = try workingSet.reserve(range.width * range.height * 16 + Self.tileBytes)
        var output = [SIMD4<Float>](repeating: .zero, count: range.width * range.height)
        for block in Self.blocks(try plan.keys(covering: full, level: 0)) {
            try Task.checkCancellation()
            var pixels: [TileKey: [SIMD4<Float>]] = [:], missing: [TileKey] = []
            for child in block { if let cached = cached(child, plan: plan) { pixels[child] = cached } else { missing.append(child) } }
            var blockCharge: LWFloatWorkingSet.Lease?
            if !missing.isEmpty {
                let (made, lease) = try evaluate(missing, plan: plan, publish: false)
                pixels.merge(made) { a, _ in a }; blockCharge = lease
            }
            for child in block {
                let source = plan.range(child)
                let (w, h, samples) = Self.reduce(pixels[child]!, width: source.width, height: source.height, times: k)
                let ox = (source.x - x0) >> k, oy = (source.y - y0) >> k
                for y in 0..<h {
                    output.replaceSubrange((oy + y) * range.width + ox..<(oy + y) * range.width + ox + w, with: samples[y * w..<y * w + w])
                }
            }
            withExtendedLifetime(blockCharge) {}
        }
        for i in output.indices {
            let p = output[i]
            output[i] = p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w) : .zero
        }
        return (output, charge)
    }

    /// Straight samples in, premultiplied samples reduced 2× `times` times out.
    @_optimize(speed) static func reduce(_ straight: [SIMD4<Float>], width: Int, height: Int, times: Int) -> (Int, Int, [SIMD4<Float>]) {
        var w = width, h = height
        var samples = straight.map { SIMD4($0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w) }
        for _ in 0..<times {
            let nw = (w + 1) / 2, nh = (h + 1) / 2
            var next = [SIMD4<Float>](repeating: .zero, count: nw * nh)
            for y in 0..<nh { for x in 0..<nw {
                var sum = SIMD4<Float>.zero, count: Float = 0
                for sy in 2 * y..<min(h, 2 * y + 2) { for sx in 2 * x..<min(w, 2 * x + 2) { sum += samples[sy * w + sx]; count += 1 } }
                next[y * nw + x] = sum / count
            } }
            samples = next; w = nw; h = nh
        }
        return (w, h, samples)
    }

    /// Caller holds `lock`.
    private func publish(_ key: TileKey, pixels: [SIMD4<Float>], plan: Plan) {
        let fingerprint = plan.fingerprint(key)
        guard let latest = latest[key.document], latest.contains(key), latest.fingerprint(key) == fingerprint else {
            discarded += 1; return
        }
        clock += 1
        if let existing = entries[key], existing.fingerprint == fingerprint { existing.used = clock; return }
        remove(key)
        let bytes = pixels.count * MemoryLayout<SIMD4<Float>>.stride
        // Make room inside the budget before charging the new tile.
        while resident + bytes > budgetBytes, let victim = entries.min(by: { $0.value.used < $1.value.used })?.key {
            remove(victim); evicted += 1
        }
        // This lock is held: the cache must not be asked to reclaim from itself.
        guard resident + bytes <= budgetBytes, let lease = try? workingSet.reserve(bytes, reclaim: false) else { return }
        entries[key] = Entry(fingerprint: fingerprint, pixels: pixels, lease: lease, dependencies: latest.dependencies, used: clock)
        resident += bytes; peak = max(peak, resident)
    }

    // MARK: Fingerprints

    /// Pixels a spatial adjustment reads beyond its output. Core Image's Gaussian kernel is
    /// truncated near 3σ and CIMotionBlur reaches its radius along the motion; both bounds are
    /// widened so a tile's whole dependency lies inside the evaluated region.
    static func halo(_ layers: [ProjectLayerRecord]) -> Int {
        let visible = Set(LayerHierarchy.visibleLayers(layers).map(\.id))
        var total = 0.0
        for layer in layers where visible.contains(layer.id) {
            guard let adjustment = layer.adjustment else { continue }
            switch adjustment.kind {
            case .gaussianBlur: total += 4 * adjustment.gaussianRadius + 4
            case .motionBlur: total += 2 * adjustment.resolvedMotionDistance * PixelFilter.motionRadiusPerPixel + 16
            default: break
            }
        }
        return Int(min(Double(DocumentLimits.maxSide), total.rounded(.up)))
    }

    private struct Fingerprints {
        let halo: Int
        let levels: [Grid]
        let dependencies: [AnyObject]
    }

    private static func fingerprints(_ snapshot: ProjectSnapshot) throws -> Fingerprints {
        let manifest = snapshot.manifest, width = manifest.width, height = manifest.height
        try LWFloatPlane.validateExtent(width: width, height: height)
        let side = tileSide, columns = (width + side - 1) / side, rows = (height + side - 1) / side
        let halo = halo(manifest.layers)
        let records = Dictionary(manifest.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var dependencies: [AnyObject] = []
        func identity(_ asset: ImportedImage?) -> String {
            guard let asset else { return "none" }
            if let plane = asset.linearPlane { return "plane:" + plane.manifest.id.uuidString }
            dependencies.append(asset.image)
            return "image:\(UInt(bitPattern: ObjectIdentifier(asset.image)))"
        }
        // One layer's own state: record (transform, blend, opacity, visibility, adjustment,
        // effects, live source recipe), its pixels and its mask.
        var own: [UUID: Data] = [:]
        for record in manifest.layers {
            var hash = SHA256()
            hash.update(data: try encoder.encode(record))
            hash.update(data: Data(identity(snapshot.images[record.id]).utf8))
            hash.update(data: Data(identity(record.maskFile == nil ? nil : snapshot.masks[record.id]).utf8))
            own[record.id] = Data(hash.finalize())
        }
        // Plus what reaches it from elsewhere: enclosing folders and clipping sources.
        var full: [UUID: Data] = [:]
        func composite(_ id: UUID, depth: Int = 0) throws -> Data {
            if let known = full[id] { return known }
            guard depth < 512, let record = records[id], let mine = own[id] else { throw ProjectError.invalid }
            var hash = SHA256(); hash.update(data: mine)
            if let parent = record.parentID { hash.update(data: try composite(parent, depth: depth + 1)) }
            if let source = record.maskSourceID { hash.update(data: try composite(source, depth: depth + 1)) }
            let made = Data(hash.finalize()); full[id] = made; return made
        }
        // Where each layer can change pixels; nil is the whole document.
        func footprint(_ record: ProjectLayerRecord) -> CGRect? {
            if record.adjustment != nil || record.effects?.visible.isEmpty == false { return nil }
            if record.isGroup == true { return .null }
            let t = record.transform
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(t.point)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            // One pixel of resampling margin on every side.
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -2, dy: -2)
        }
        let painted = try manifest.layers.enumerated().map { index, record in (index, try composite(record.id), footprint(record)) }
        var prefix = SHA256()
        prefix.update(data: Data("lw-tile-v1 \(width)x\(height) halo \(halo) layers \(manifest.layers.count)".utf8))
        let documentPrefix = prefix
        var result: [Data] = []; result.reserveCapacity(columns * rows)
        for row in 0..<rows { for column in 0..<columns {
            let range = LWFloatPlane.range(index: row * columns + column, width: width, height: height)
            let reach = CGRect(x: range.x, y: range.y, width: range.width, height: range.height).insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo))
            var hash = documentPrefix
            for (index, key, area) in painted where area.map({ !$0.isNull && $0.intersects(reach) }) ?? true {
                withUnsafeBytes(of: index) { hash.update(bufferPointer: $0) }
                hash.update(data: key)
            }
            result.append(Data(hash.finalize()))
        } }
        // The pyramid: each coarser tile hashes its (up to) four children.
        var levels = [Grid(width: width, height: height, columns: columns, rows: rows, fingerprints: result)]
        while levels.count <= maxLevel, levels.last!.columns > 1 || levels.last!.rows > 1 {
            let finer = levels.last!, level = levels.count
            let w = (width + (1 << level) - 1) >> level, h = (height + (1 << level) - 1) >> level
            let c = (w + side - 1) / side, r = (h + side - 1) / side
            var made: [Data] = []; made.reserveCapacity(c * r)
            for row in 0..<r { for column in 0..<c {
                var hash = SHA256()
                hash.update(data: Data("lw-tile-level \(level)".utf8))
                for cy in 2 * row..<min(finer.rows, 2 * row + 2) { for cx in 2 * column..<min(finer.columns, 2 * column + 2) {
                    hash.update(data: finer.fingerprints[cy * finer.columns + cx])
                } }
                made.append(Data(hash.finalize()))
            } }
            levels.append(Grid(width: w, height: h, columns: c, rows: r, fingerprints: made))
        }
        return Fingerprints(halo: halo, levels: levels, dependencies: dependencies)
    }
}
