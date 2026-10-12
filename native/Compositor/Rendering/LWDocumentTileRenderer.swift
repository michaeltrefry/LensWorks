import Foundation
import CoreGraphics
import CryptoKit

/// Full-resolution document evaluation over a fixed tile grid, with a byte-bounded tile cache.
///
/// - Evaluation: `LWFloatCompositor.renderPlane(_:region:workspace:)` restricted to the missing
///   tiles of a request (in blocks of at most `blockTiles`×`blockTiles`), widened by the
///   document's spatial `halo` out to the tile grid and cropped back. Peak scratch is therefore set by the block, not
///   by the document, and a document never has to be resident whole.
/// - Residency: every cached tile is charged to the shared working set; the cache never retains
///   more than `budgetBytes` and evicts least-recently-used tiles beyond it.
/// - Invalidation: each tile's fingerprint covers the source, recipe and layer state (record,
///   pixel identity, mask identity, ancestors and clipping sources) of every layer whose footprint
///   reaches that tile, plus the layer order. A new `plan` drops exactly the tiles whose
///   fingerprint changed; untouched tiles stay cached.
/// - Stale completions: a finished evaluation publishes a tile only if the latest plan still
///   requires that tile's fingerprint. Work started for a superseded plan is discarded.
nonisolated final class LWDocumentTileRenderer: @unchecked Sendable {
    static let tileSide = LWFloatPlane.tileSide
    /// Declared cache residency for the interactive canvas (RENDERER_PRECISION_CONTRACT.json).
    static let defaultBudgetBytes = 256 * 1024 * 1024
    /// One evaluation covers at most this many tiles on a side (1024 × 1024 px at 256 px tiles).
    static let blockTiles = 4
    static var tileBytes: Int { tileSide * tileSide * MemoryLayout<SIMD4<Float>>.stride }

    struct TileKey: Hashable, Sendable { let column: Int; let row: Int }

    /// One request's view of the document: its tile fingerprints and the snapshot that produced them.
    struct Plan: @unchecked Sendable {
        let generation: UInt64
        let snapshot: ProjectSnapshot
        let width: Int
        let height: Int
        let columns: Int
        let rows: Int
        let halo: Int
        let fingerprints: [Data]
        /// Pixel owners whose identity enters a fingerprint, retained so it cannot be reused.
        fileprivate let dependencies: [AnyObject]
        func fingerprint(_ key: TileKey) -> Data { fingerprints[key.row * columns + key.column] }
        func range(_ key: TileKey) -> LWFloatRange {
            LWFloatPlane.range(index: key.row * columns + key.column, width: width, height: height)
        }
        func keys(covering region: LWFloatRange) throws -> [TileKey] {
            _ = try region.validate(frameWidth: width, frameHeight: height)
            let side = LWDocumentTileRenderer.tileSide
            return (region.y / side...(region.y + region.height - 1) / side).flatMap { row in
                (region.x / side...(region.x + region.width - 1) / side).map { TileKey(column: $0, row: row) }
            }
        }
    }

    struct Tile: Sendable {
        let key: TileKey
        let range: LWFloatRange
        let pixels: [SIMD4<Float>]
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
    private var latest: Plan?
    private var generation: UInt64 = 0
    private var clock: UInt64 = 0
    private var resident = 0
    private var peak = 0
    private var evicted = 0
    private var discarded = 0
    private var evaluated = 0
    /// Test seam: runs after a block is evaluated and before its tiles are published.
    var beforePublish: ((Plan) -> Void)?

    init(budgetBytes: Int = defaultBudgetBytes, workingSet: LWFloatWorkingSet = .sourceGraphs) throws {
        guard budgetBytes >= Self.tileBytes, budgetBytes <= workingSet.limit else { throw ProjectError.tooLarge }
        self.budgetBytes = budgetBytes; self.workingSet = workingSet
    }

    var residentBytes: Int { lock.withLock { resident } }
    var peakResidentBytes: Int { lock.withLock { peak } }
    var evictionCount: Int { lock.withLock { evicted } }
    var discardedCompletions: Int { lock.withLock { discarded } }
    var evaluatedTiles: Int { lock.withLock { evaluated } }
    var cachedKeys: Set<TileKey> { lock.withLock { Set(entries.keys) } }
    func resetPeak() { lock.withLock { peak = resident } }
    func isCurrent(_ plan: Plan) -> Bool { lock.withLock { latest?.generation == plan.generation } }

    // MARK: Planning and invalidation

    /// Fingerprints the document and makes it the latest request. Cached tiles whose inputs
    /// changed are released now; the rest survive.
    func plan(_ snapshot: ProjectSnapshot) throws -> Plan {
        let made = try Self.fingerprints(snapshot)
        return lock.withLock {
            generation += 1
            let plan = Plan(generation: generation, snapshot: snapshot, width: made.width, height: made.height,
                columns: made.columns, rows: made.rows, halo: made.halo, fingerprints: made.fingerprints, dependencies: made.dependencies)
            latest = plan
            for (key, entry) in entries where key.column >= plan.columns || key.row >= plan.rows || entry.fingerprint != plan.fingerprint(key) {
                remove(key)
            }
            return plan
        }
    }

    /// Releases every cached tile (memory pressure, document close).
    func purge() { lock.withLock { for key in Array(entries.keys) { remove(key) } } }

    private func remove(_ key: TileKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        resident -= entry.lease.bytes
    }

    // MARK: Evaluation

    /// Every tile covering `region` at full resolution: cached where the fingerprint matches,
    /// evaluated otherwise. Returned tiles are those of `plan`, whether or not they were published.
    func tiles(covering region: LWFloatRange, plan: Plan) throws -> [Tile] {
        let keys = try plan.keys(covering: region)
        var found: [TileKey: [SIMD4<Float>]] = [:]
        lock.withLock {
            clock += 1
            for key in keys {
                if let entry = entries[key], entry.fingerprint == plan.fingerprint(key) { entry.used = clock; found[key] = entry.pixels }
            }
        }
        let missing = keys.filter { found[$0] == nil }
        // Blocks of the tile grid, each evaluated once for all of its missing tiles.
        let blocks = Dictionary(grouping: missing) { TileKey(column: $0.column / Self.blockTiles, row: $0.row / Self.blockTiles) }
        for block in blocks.keys.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            try Task.checkCancellation()
            let made = try evaluate(blocks[block]!, plan: plan)
            for (key, pixels) in made { found[key] = pixels }
        }
        return keys.map { Tile(key: $0, range: plan.range($0), pixels: found[$0]!) }
    }

    /// The document's samples for `region`, assembled from tiles.
    func surface(_ region: LWFloatRange, plan: Plan) throws -> LWLinearSurface {
        let bytes = try region.validate(frameWidth: plan.width, frameHeight: plan.height)
        var pixels = [SIMD4<Float>](repeating: .zero, count: bytes / 16)
        for tile in try tiles(covering: region, plan: plan) {
            let left = max(region.x, tile.range.x), right = min(region.x + region.width, tile.range.x + tile.range.width)
            let top = max(region.y, tile.range.y), bottom = min(region.y + region.height, tile.range.y + tile.range.height)
            for y in top..<bottom {
                let source = (y - tile.range.y) * tile.range.width + left - tile.range.x
                let target = (y - region.y) * region.width + left - region.x
                pixels.replaceSubrange(target..<(target + right - left), with: tile.pixels[source..<(source + right - left)])
            }
        }
        return try LWLinearSurface(width: region.width, height: region.height, pixels: pixels, maximumBytes: bytes)
    }

    private func evaluate(_ keys: [TileKey], plan: Plan) throws -> [TileKey: [SIMD4<Float>]] {
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
            for key in keys { publish(key, pixels: made[key]!, plan: plan) }
        }
        return made
    }

    /// Caller holds `lock`.
    private func publish(_ key: TileKey, pixels: [SIMD4<Float>], plan: Plan) {
        let fingerprint = plan.fingerprint(key)
        guard let latest, key.column < latest.columns, key.row < latest.rows, latest.fingerprint(key) == fingerprint else {
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
        guard resident + bytes <= budgetBytes, let lease = try? workingSet.reserve(bytes) else { return }
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
        let width: Int, height: Int, columns: Int, rows: Int, halo: Int
        let fingerprints: [Data]
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
        return Fingerprints(width: width, height: height, columns: columns, rows: rows, halo: halo,
            fingerprints: result, dependencies: dependencies)
    }
}
