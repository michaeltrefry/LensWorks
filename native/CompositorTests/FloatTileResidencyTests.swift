import Testing
import Foundation
import CoreGraphics
import Metal
@testable import Compositor

@_silgen_name("proc_rlimit_control") private func lwProcRlimitControl(_ pid: pid_t, _ flavor: Int32, _ arg: UnsafeMutableRawPointer?) -> Int32

/// The process's physical footprint (what the system charges it for memory, including Core Graphics and
/// Core Image allocations no working set sees), and its peak over an interval.
enum Footprint {
    static func current() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    /// Starts a new interval; false when the system does not allow it (the caller then samples).
    static func resetInterval() -> Bool {
        lwProcRlimitControl(getpid(), 4 /* RLIMIT_FOOTPRINT_INTERVAL */, UnsafeMutableRawPointer(bitPattern: 1 /* FOOTPRINT_INTERVAL_RESET */)) == 0
    }
    static func intervalPeak() -> Int? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(info.ri_interval_max_phys_footprint) : nil
    }
    /// Peak footprint growth over `body`: the interval peak where available, otherwise the highest of
    /// the samples `body` takes through `sample`.
    static func growth(_ body: (_ sample: () -> Void) throws -> Void) rethrows -> Int {
        let base = current(), interval = resetInterval()
        var sampled = base
        try body { sampled = max(sampled, current()) }
        let peak = interval ? max(intervalPeak() ?? sampled, sampled) : sampled
        return max(0, peak - base)
    }
}

/// A float image whose pixels are generated when Core Graphics asks for them: a document of any
/// size can be built without allocating its pixels. Pixels are produced a row span at a time (straight
/// values, premultiplied here) and copied out with one memcpy per request.
nonisolated final class ProceduralImage: @unchecked Sendable {
    /// Fills `count` straight pixels of row `y` starting at column `x`.
    typealias Row = @Sendable (_ y: Int, _ x: Int, _ count: Int, _ into: UnsafeMutablePointer<SIMD4<Float>>) -> Void
    let width: Int, height: Int
    let row: Row
    private init(width: Int, height: Int, row: @escaping Row) {
        self.width = width; self.height = height; self.row = row
    }
    static func make(width: Int, height: Int, pixel: @escaping @Sendable (Int, Int) -> SIMD4<Float>) -> CGImage {
        make(width: width, height: height) { y, x, count, into in for i in 0..<count { into[i] = pixel(x + i, y) } }
    }
    static func make(width: Int, height: Int, row: @escaping Row) -> CGImage {
        let owner = Unmanaged.passRetained(ProceduralImage(width: width, height: height, row: row))
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, output, position, count in
                let me = Unmanaged<ProceduralImage>.fromOpaque(info!).takeUnretainedValue()
                let start = Int(position) / 16, end = (Int(position) + count + 15) / 16
                var pixels = [SIMD4<Float>](repeating: .zero, count: end - start)
                pixels.withUnsafeMutableBufferPointer { buffer in
                    var p = start
                    while p < end {
                        let y = p / me.width, x = p % me.width, n = min(me.width - x, end - p)
                        let span = buffer.baseAddress!.advanced(by: p - start)
                        me.row(y, x, n, span)
                        for i in 0..<n { let v = span[i]; span[i] = SIMD4(v.x * v.w, v.y * v.w, v.z * v.w, v.w) }
                        p += n
                    }
                    output.copyMemory(from: UnsafeRawPointer(buffer.baseAddress!).advanced(by: Int(position) - start * 16), byteCount: count)
                }
                return count
            }, releaseInfo: { info in Unmanaged<ProceduralImage>.fromOpaque(info!).release() })
        let provider = CGDataProvider(directInfo: owner.toOpaque(), size: off_t(width * height * 16), callbacks: &callbacks)!
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

nonisolated final class LWLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    /// Applies `change` and returns the new value.
    @discardableResult func update(_ change: (Value) -> Value) -> Value { lock.withLock { value = change(value); return value } }
}

@MainActor struct FloatTileResidencyTests {
    static let contract = try! RendererContract.load()

    // MARK: Fixtures

    private func layer(id: UUID = UUID(), _ name: String, at origin: CGPoint, _ image: CGImage, mode: LayerBlendMode = .normal,
                       opacity: Double = 1, rotation: CGFloat = 0) -> ProjectLayerRecord {
        var record = ProjectLayerRecord(id: id, name: name, isVisible: true,
            transform: LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height), rotation: rotation),
            imageFile: id.uuidString + ".png")
        record.blendMode = mode; record.opacity = opacity
        return record
    }
    private func adjustment(_ name: String, _ adjustment: LayerAdjustment, width: Int, height: Int) -> ProjectLayerRecord {
        var record = ProjectLayerRecord(id: UUID(), name: name, isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: nil)
        record.adjustment = adjustment
        return record
    }
    static func pattern(_ seed: Int, alpha: Float = 1) -> @Sendable (Int, Int) -> SIMD4<Float> {
        { x, y in
            let r = Float((x * 7 + y * 3 + seed) % 97) / 30           // up to 3.2: HDR
            let g = Float((x + y * 5 + seed * 11) % 89) / 70 - 0.35    // down to -0.35: out of gamut
            let b = Float((x * 13 + seed) % 61) / 61
            let a = alpha < 1 ? alpha * (0.4 + 0.6 * Float((x / 9 + y / 7) % 5) / 4) : 1
            return SIMD4(r, g, b, a)
        }
    }
    /// `pattern` a row span at a time, with the moduli stepped instead of recomputed.
    static func patternRow(_ seed: Int, alpha: Float = 1) -> ProceduralImage.Row {
        { y, x, count, into in
            var r = (x * 7 + y * 3 + seed) % 97, g = (x + y * 5 + seed * 11) % 89, b = (x * 13 + seed) % 61
            var column = x % 9, band = (x / 9 + y / 7) % 5
            for i in 0..<count {
                let a: Float = alpha < 1 ? alpha * (0.4 + 0.6 * Float(band) / 4) : 1
                into[i] = SIMD4(Float(r) / 30, Float(g) / 70 - 0.35, Float(b) / 61, a)
                r += 7; if r >= 97 { r -= 97 }
                g += 1; if g >= 89 { g -= 89 }
                b += 13; if b >= 61 { b -= 61 }
                column += 1; if column == 9 { column = 0; band += 1; if band == 5 { band = 0 } }
            }
        }
    }
    func image(_ w: Int, _ h: Int, seed: Int, alpha: Float = 1) -> CGImage {
        ProceduralImage.make(width: w, height: h, row: Self.patternRow(seed, alpha: alpha))
    }
    private func maskAsset(_ w: Int, _ h: Int) throws -> ImportedImage {
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.1, alpha: 1)] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return try LayerMask.asset(from: try #require(context.makeImage()))
    }
    /// One document identity per test, so successive snapshots are edits of the same document.
    private let documentID = UUID()
    private func snapshot(_ width: Int, _ height: Int, _ layers: [ProjectLayerRecord], images: [UUID: CGImage],
                          masks: [UUID: ImportedImage] = [:], document: UUID? = nil) -> ProjectSnapshot {
        ProjectSnapshot(manifest: ProjectManifest(documentID: document ?? documentID, width: width, height: height, activeLayerID: layers.first?.id, layers: layers),
            images: images.mapValues { ImportedImage(image: $0, thumbnail: $0, name: "fixture") }, masks: masks)
    }
    private func whole(_ snapshot: ProjectSnapshot, workingSet: LWFloatWorkingSet) throws -> [SIMD4<Float>] {
        let workspace = try LWFloatWorkspace(workingSet: workingSet)
        let plane = try LWFloatCompositor.renderPlane(snapshot, workspace: workspace)
        var pixels = [SIMD4<Float>](repeating: .zero, count: plane.width * plane.height)
        try plane.forEachTile { range in
            let tile = try plane.read(range: range)
            for (i, p) in tile.surface.pixels.enumerated() { pixels[(range.y + i / range.width) * plane.width + range.x + i % range.width] = p }
        }
        return pixels
    }
    private func worst(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
        zip(a, b).reduce(0.0) { worst, pair in
            (0..<4).reduce(worst) { max($0, Double(abs(pair.0[$1] - pair.1[$1])) / max(1, Double(abs(pair.1[$1])))) }
        }
    }

    // MARK: Tile versus full-frame parity

    /// Every blend mode at document level: a rotated, partly transparent layer over an HDR base,
    /// evaluated in tile blocks against the whole frame.
    @Test(arguments: LayerBlendMode.allCases)
    func documentTilesMatchWholeFrameForBlendMode(_ mode: LayerBlendMode) throws {
        let set = try LWFloatWorkingSet(limit: 384 * 1024 * 1024)
        // 5×2 tiles: two evaluation blocks side by side, with the rotated layer across their seam.
        let base = image(1100, 400, seed: 1), top = image(520, 300, seed: 2, alpha: 0.8)
        let b = layer("Base", at: .zero, base), t = layer("Top", at: CGPoint(x: 300.25, y: 40), top, mode: mode, opacity: 0.85, rotation: 17)
        let doc = snapshot(1100, 400, [b, t], images: [b.id: base, t.id: top])
        let expected = try whole(doc, workingSet: set)
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let made = try tiles.surface(LWFloatRange(x: 0, y: 0, width: 1100, height: 400), plan: tiles.plan(doc))
        #expect(tiles.evaluatedTiles == 10)
        let error = worst(made.pixels, expected)
        #expect(error <= Self.contract.document_region_parity_relative, "\(mode): worst \(error)")
    }

    @Test(arguments: ["masks", "gaussian", "motion", "effects"])
    func documentTilesMatchWholeFrameForLayerGraph(_ scenario: String) throws {
        let set = try LWFloatWorkingSet(limit: 384 * 1024 * 1024)
        let w = 1100, h = 900
        let base = image(w, h, seed: 3), top = image(640, 480, seed: 4, alpha: 0.9), clip = image(500, 500, seed: 5)
        let b = layer("Base", at: .zero, base)
        var t = layer("Top", at: CGPoint(x: 230, y: 170), top, mode: .screen, opacity: 0.9, rotation: -9)
        var c = layer("Clipped", at: CGPoint(x: 300, y: 200), clip, mode: .multiply)
        let folder = ProjectLayerRecord(id: UUID(), name: "Folder", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: w, height: h)), imageFile: nil, isGroup: true, opacity: 0.8)
        var layers = [b], masks: [UUID: ImportedImage] = [:]
        switch scenario {
        case "masks":
            t.maskFile = "top.mask"; masks[t.id] = try maskAsset(640, 480)
            c.maskSourceID = t.id
            var f = folder; f.maskFile = "folder.mask"; masks[f.id] = try maskAsset(w, h)
            t.parentID = f.id; c.parentID = f.id
            var noise = LayerAdjustment(kind: .addNoise); noise.noiseAmount = 12; noise.noiseSeed = 99
            layers += [f, t, c, adjustment("Noise", noise, width: w, height: h)]
        case "gaussian":
            var blur = LayerAdjustment(kind: .gaussianBlur); blur.blurRadius = 6
            layers += [t, adjustment("Blur", blur, width: w, height: h)]
        case "motion":
            var blur = LayerAdjustment(kind: .motionBlur); blur.motionDistance = 40; blur.motionAngle = 30
            layers += [t, adjustment("Motion", blur, width: w, height: h)]
        default:
            t.effects = LayerEffects(shadow: ShadowEffect())
            layers += [t]
        }
        let doc = snapshot(w, h, layers, images: [b.id: base, t.id: top, c.id: clip], masks: masks)
        let expected = try whole(doc, workingSet: set)
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let made = try tiles.surface(LWFloatRange(x: 0, y: 0, width: w, height: h), plan: tiles.plan(doc))
        let spatial = scenario == "gaussian" || scenario == "motion"
        let bound = spatial ? Self.contract.document_region_spatial_relative : Self.contract.document_region_parity_relative
        let error = worst(made.pixels, expected)
        #expect(error <= bound, "\(scenario): worst \(error)")
        print("S09 layer graph \(scenario): worst \(error)")
        if spatial { #expect(LWDocumentTileRenderer.halo(doc.manifest.layers) > 0) }
    }

    // MARK: Invalidation

    @Test func sourceRecipeAndLayerChangesInvalidateOnlyAffectedTiles() throws {
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024)
        let side = LWDocumentTileRenderer.tileSide, w = side * 4, h = side * 4
        let baseImage = image(w, h, seed: 7), aImage = image(200, 200, seed: 8), bImage = image(300, 300, seed: 9, alpha: 0.7)
        let base = layer("Base", at: .zero, baseImage)
        var a = layer("A", at: CGPoint(x: 20, y: 20), aImage, mode: .multiply)
        let b = layer("B", at: CGPoint(x: 600, y: 600), bImage, mode: .overlay)
        var exposure = LayerAdjustment(kind: .exposure); exposure.exposure = ExposureSettings(exposure: 0.5, offset: 0, gamma: 1)
        var adjust = adjustment("Exposure", exposure, width: w, height: h)
        var images = [base.id: baseImage, a.id: aImage, b.id: bImage]
        let everything = LWFloatRange(x: 0, y: 0, width: w, height: h)
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        func check(_ layers: [ProjectLayerRecord], cachedAfterPlan: Int, evaluatedAfter: Int) throws {
            let doc = snapshot(w, h, layers, images: images)
            let plan = try tiles.plan(doc)
            #expect(tiles.cachedKeys.count == cachedAfterPlan)
            let made = try tiles.surface(everything, plan: plan)
            #expect(tiles.evaluatedTiles == evaluatedAfter)
            #expect(worst(made.pixels, try whole(doc, workingSet: set)) <= Self.contract.document_region_parity_relative)
        }
        try check([base, a, b], cachedAfterPlan: 0, evaluatedAfter: 16)
        // Nothing changed: every tile is reused.
        try check([base, a, b], cachedAfterPlan: 16, evaluatedAfter: 16)
        // Layer change (opacity) inside one tile.
        a.opacity = 0.5
        try check([base, a, b], cachedAfterPlan: 15, evaluatedAfter: 17)
        // Source change: B's pixels are replaced; only B's four tiles go.
        images[b.id] = image(300, 300, seed: 10, alpha: 0.7)
        try check([base, a, b], cachedAfterPlan: 12, evaluatedAfter: 21)
        // Moving A drops its old tile and the tile it lands in.
        a.transform.origin = CGPoint(x: 20, y: side * 3 + 20)
        try check([base, a, b], cachedAfterPlan: 14, evaluatedAfter: 23)
        // A global recipe (an adjustment layer over the whole document) reaches every tile.
        try check([base, a, b, adjust], cachedAfterPlan: 0, evaluatedAfter: 39)
        adjust.adjustment?.exposure = ExposureSettings(exposure: 1, offset: 0, gamma: 1)
        try check([base, a, b, adjust], cachedAfterPlan: 0, evaluatedAfter: 55)
        try check([base, a, b, adjust], cachedAfterPlan: 16, evaluatedAfter: 55)
        tiles.purge()
        #expect(tiles.residentBytes == 0)
    }

    // MARK: Stale completions

    @Test func olderRenderFinishingAfterANewerRequestIsDiscarded() async throws {
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024)
        let side = LWDocumentTileRenderer.tileSide, w = side * 4, h = side * 4
        let baseImage = image(w, h, seed: 12), aImage = image(200, 200, seed: 13)
        let base = layer("Base", at: .zero, baseImage)
        var a = layer("A", at: CGPoint(x: 10, y: 10), aImage, mode: .difference)
        let images = [base.id: baseImage, a.id: aImage]
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let before = set.retainedBytes
        let old = try tiles.plan(snapshot(w, h, [base, a], images: images))
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        tiles.beforePublish = { plan in
            if plan.generation == old.generation { started.signal(); release.wait() }
        }
        // Tile (0,0) changes between the requests; tile (3,3) does not.
        let request = LWFloatRange(x: 0, y: 0, width: w, height: h)
        var pending: Task<[LWDocumentTileRenderer.Tile], Error>? = .detached { try tiles.tiles(covering: request, plan: old) }
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        a.opacity = 0.3
        let newer = try tiles.plan(snapshot(w, h, [base, a], images: images))
        #expect(!tiles.isCurrent(old) && tiles.isCurrent(newer))
        try withTiles(); pending = nil
        func withTiles() throws {
            let fresh = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: side, height: side), plan: newer)
            release.signal()
            let stale = try waitDetached(pending!)
            #expect(tiles.discardedCompletions == 1)
            // The cache holds the newer render for the changed tile, and accepted the unchanged ones.
            #expect(tiles.cachedKeys.count == 16)
            let evaluated = tiles.evaluatedTiles
            let cached = try tiles.tiles(covering: request, plan: newer)
            #expect(tiles.evaluatedTiles == evaluated)
            #expect(cached[0].pixels == fresh[0].pixels)
            #expect(stale[0].pixels != fresh[0].pixels)
            #expect(cached[15].pixels == stale[15].pixels)
            // Discarded work leaves no residency behind.
            #expect(tiles.residentBytes == 16 * LWDocumentTileRenderer.tileBytes)
        }
        // Returned tiles carry their own charge; once they are released only the cache remains, and then nothing.
        #expect(set.retainedBytes - before == 16 * LWDocumentTileRenderer.tileBytes)
        tiles.purge()
        #expect(set.retainedBytes == before)
    }

    private func waitDetached<T: Sendable>(_ task: Task<T, Error>) throws -> T {
        let done = DispatchSemaphore(value: 0), box = LWLockedBox<Result<T, Error>?>(nil)
        Task.detached { let r = await task.result; box.update { _ in r }; done.signal() }
        done.wait()
        return try box.update { $0 }!.get()
    }

    // MARK: Large-document residency

    /// The analytic composite of the large-document fixture at one document pixel.
    private static func largeExpected(_ x: Int, _ y: Int) -> SIMD4<Double> {
        let t = pattern(22)(x, y), b = pattern(21)(x, y)
        let blended = ReferenceBlend.pixel(.multiply, top: SIMD4(t.x, t.y, t.z, t.w * 0.75), bottom: b)
        return SIMD4(blended.x * 2.0.squareRoot(), blended.y * 2.0.squareRoot(), blended.z * 2.0.squareRoot(), blended.w)
    }
    private func largeDocument(rotation: CGFloat = 0) -> ProjectSnapshot {
        let large = Self.contract.large_document, w = large.width, h = large.height
        let baseImage = image(w, h, seed: 21), topImage = image(w, h, seed: 22, alpha: 1)
        let base = layer("Base", at: .zero, baseImage), top = layer("Top", at: .zero, topImage, mode: .multiply, opacity: 0.75, rotation: rotation)
        var exposure = LayerAdjustment(kind: .exposure); exposure.exposure = ExposureSettings(exposure: 0.5, offset: 0, gamma: 1)
        return snapshot(w, h, [base, top, adjustment("Exposure", exposure, width: w, height: h)], images: [base.id: baseImage, top.id: topImage])
    }

    @Test func largeDocumentStaysWithinDeclaredResidency() throws {
        let large = Self.contract.large_document
        #expect(LWDocumentTileRenderer.defaultBudgetBytes == Self.contract.tile_cache_budget_bytes)
        let set = try LWFloatWorkingSet(limit: LWFloatWorkingSet.maximumBytes)
        let w = large.width, h = large.height
        let doc = largeDocument()
        let tiles = try LWDocumentTileRenderer(budgetBytes: large.cache_budget_bytes, workingSet: set)
        set.resetPeak()
        let plan = try tiles.plan(doc)
        let side = LWDocumentTileRenderer.tileSide, columns = (w + side - 1) / side, rows = (h + side - 1) / side
        // 24 tiles of the top row reaching the right edge, 12 tiles of the left column reaching the (partial) bottom
        // row, then 12 tiles of the diagonal one at a time: 48 tiles through a 32-tile cache.
        var regions = [LWFloatRange(x: w - 24 * side, y: 0, width: 24 * side, height: side),
                       LWFloatRange(x: 0, y: (rows - 12) * side, width: side, height: h - (rows - 12) * side)]
        regions += (0..<12).map { LWFloatRange(x: $0 * side, y: $0 * side, width: side, height: side) }
        var checked = 0
        let growth = try Footprint.growth { sample in
            for region in regions {
                // Streamed as the canvas assembles a view: a caller never holds more than one block of uncached tiles.
                try tiles.forEachTile(covering: region, plan: plan) { tile in
                    sample()
                    #expect(tiles.residentBytes <= large.cache_budget_bytes)
                    // Spot-check samples against the analytic composite.
                    for (dx, dy) in [(0, 0), (tile.range.width - 1, tile.range.height - 1), (101, 37)] {
                        let x = tile.range.x + dx, y = tile.range.y + dy, expected = Self.largeExpected(x, y)
                        let actual = tile.pixels[dy * tile.range.width + dx]
                        for c in 0..<4 { #expect(abs(Double(actual[c]) - expected[c]) <= 1e-4 * max(1, abs(expected[c])), "(\(x),\(y)) channel \(c)") }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 48 * 3)
        #expect(columns == 64 && rows == 48)
        #expect(tiles.evictionCount > 0)
        #expect(tiles.peakResidentBytes <= large.cache_budget_bytes)
        #expect(set.peakRetainedBytes <= large.peak_working_set_bytes, "peak working set \(set.peakRetainedBytes)")
        #expect(growth <= large.peak_footprint_growth_bytes, "footprint grew \(growth) bytes")
        print("S09 large document: peak working set \(set.peakRetainedBytes) bytes, footprint growth \(growth) bytes, peak cache \(tiles.peakResidentBytes) bytes, \(tiles.evictionCount) evictions, \(tiles.evaluatedTiles) tiles evaluated")
        tiles.purge()
        #expect(tiles.residentBytes == 0)
    }

    /// Zoomed out over a large part of the large document, the canvas view is built from reduced tiles: residency
    /// stays at the declared bound although the region is 4.2 MP (past the region the old canvas would assemble from a
    /// 32 MiB cache, where it
    /// rendered the whole 199 MP frame instead).
    @Test func zoomedOutViewOfTheLargeDocumentStaysWithinResidency() throws {
        let large = Self.contract.large_document
        let set = try LWFloatWorkingSet(limit: LWFloatWorkingSet.maximumBytes)
        let tiles = try LWDocumentTileRenderer(budgetBytes: large.cache_budget_bytes, workingSet: set)
        let plan = try tiles.plan(largeDocument())
        let visible = LWFloatRange(x: 4096, y: 2048, width: 2048, height: 2048)
        set.resetPeak()
        var view: LWDocumentTileRenderer.View?
        let growth = try Footprint.growth { sample in
            view = try tiles.view(visible, scale: 1.0 / 8, plan: plan)
            sample()
        }
        let made = try #require(view)
        #expect(LWDocumentTileRenderer.frameBudgetBytes == Self.contract.canvas_frame_budget_bytes)
        #expect(made.level == 3)
        #expect(made.region == LWFloatRange(x: 512, y: 256, width: 256, height: 256))
        #expect(set.peakRetainedBytes <= large.peak_working_set_bytes, "peak working set \(set.peakRetainedBytes)")
        #expect(growth <= large.peak_footprint_growth_bytes, "footprint grew \(growth) bytes")
        // Only reduced tiles stay resident; the level-0 tiles they were built from are not kept.
        #expect(tiles.cachedKeys.allSatisfy { $0.level == 3 })
        // Each level-3 sample is the premultiplied mean of the 8×8 document pixels under it.
        made.data.withUnsafeBytes { raw in
            let halves = raw.bindMemory(to: Float16.self)
            for (vx, vy) in [(0, 0), (171, 133), (255, 255)] {
                var sum = SIMD4<Double>.zero
                let dx = (made.region.x + vx) * 8, dy = (made.region.y + vy) * 8
                for y in dy..<dy + 8 { for x in dx..<dx + 8 {
                    let e = Self.largeExpected(x, y); sum += SIMD4(e.x * e.w, e.y * e.w, e.z * e.w, e.w)
                } }
                sum /= 64
                for c in 0..<4 {
                    let actual = Double(halves[(vy * made.region.width + vx) * 4 + c])
                    #expect(abs(actual - sum[c]) <= 2e-3 * max(1, abs(sum[c])), "view (\(vx),\(vy)) channel \(c): \(actual) vs \(sum[c])")
                }
            }
        }
        print("S09 zoomed-out view: level \(made.level), peak working set \(set.peakRetainedBytes) bytes, footprint growth \(growth) bytes, \(tiles.evaluatedTiles) tiles evaluated")
        view = nil
        tiles.purge()
    }

    /// A full-size layer rotated over the large document: each tile's placement reads only the part of the layer
    /// that reaches it, charged to the working set, so residency stays bounded.
    @Test func rotatedFullSizeLayerOnTheLargeDocumentStaysWithinResidency() throws {
        let large = Self.contract.large_document
        let set = try LWFloatWorkingSet(limit: LWFloatWorkingSet.maximumBytes)
        let tiles = try LWDocumentTileRenderer(budgetBytes: large.cache_budget_bytes, workingSet: set)
        let plan = try tiles.plan(largeDocument(rotation: 7))
        set.resetPeak()
        var count = 0
        let growth = try Footprint.growth { sample in
            // A band through the middle of the document, where the rotated layer covers every tile.
            try tiles.forEachTile(covering: LWFloatRange(x: 6144, y: 6144, width: 2048, height: 512), plan: plan) { tile in
                sample(); count += 1
                #expect(tile.pixels.allSatisfy { p in (0..<4).allSatisfy { p[$0].isFinite } })
            }
        }
        #expect(count == 16)
        #expect(set.peakRetainedBytes <= large.peak_working_set_bytes, "peak working set \(set.peakRetainedBytes)")
        #expect(growth <= large.peak_footprint_growth_bytes, "footprint grew \(growth) bytes")
        print("S09 rotated large layer: peak working set \(set.peakRetainedBytes) bytes, footprint growth \(growth) bytes")
        tiles.purge()
    }

    // MARK: Pyramid

    /// A reduced level is the repeated 2× premultiplied box reduction of the full-resolution document, and
    /// a layer change invalidates the reduced tiles above it like the full-resolution ones.
    @Test func reducedLevelsMatchBoxReductionAndFollowInvalidation() throws {
        let set = try LWFloatWorkingSet(limit: 384 * 1024 * 1024)
        let w = 1100, h = 900
        let base = image(w, h, seed: 31), topImage = image(200, 150, seed: 32, alpha: 0.7)
        let b = layer("Base", at: .zero, base)
        var t = layer("Top", at: CGPoint(x: 20.5, y: 30), topImage, mode: .overlay, opacity: 0.8, rotation: 11)
        func doc() -> ProjectSnapshot { snapshot(w, h, [b, t], images: [b.id: base, t.id: topImage]) }
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        for level in 1...2 {
            let first = doc()
            let plan = try tiles.plan(first)
            let expected = try whole(first, workingSet: set)
            let (rw, rh, reduced) = LWDocumentTileRenderer.reduce(expected, width: w, height: h, times: level)
            let made = try tiles.surface(LWFloatRange(x: 0, y: 0, width: rw, height: rh), level: level, plan: plan)
            let straight = reduced.map { $0.w > 0 ? SIMD4($0.x / $0.w, $0.y / $0.w, $0.z / $0.w, $0.w) : .zero }
            #expect(worst(made.pixels, straight) <= Self.contract.document_region_parity_relative, "level \(level)")
        }
        // Level 1 is 3×2 tiles; the top layer reaches only the top-left one.
        let plan = try tiles.plan(doc())
        _ = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: 550, height: 450), level: 1, plan: plan)
        let level1 = tiles.cachedKeys.filter { $0.level == 1 }
        #expect(level1.count == 6)
        t.opacity = 0.4
        _ = try tiles.plan(doc())
        #expect(tiles.cachedKeys.filter { $0.level == 1 }.count == 5)
        #expect(!tiles.cachedKeys.contains(plan.key(level: 1, column: 0, row: 0)))
    }

    /// The canvas level for a zoom is the coarsest at least as fine as the display.
    @Test func viewLevelFollowsZoom() {
        #expect(LWDocumentTileRenderer.level(forScale: 1, levels: 7) == 0)
        #expect(LWDocumentTileRenderer.level(forScale: 2, levels: 7) == 0)
        #expect(LWDocumentTileRenderer.level(forScale: 0.6, levels: 7) == 0)
        #expect(LWDocumentTileRenderer.level(forScale: 0.5, levels: 7) == 1)
        #expect(LWDocumentTileRenderer.level(forScale: 0.3, levels: 7) == 1)
        #expect(LWDocumentTileRenderer.level(forScale: 1.0 / 16, levels: 7) == 4)
        #expect(LWDocumentTileRenderer.level(forScale: 1.0 / 1000, levels: 7) == 6)
    }

    // MARK: Shared cache

    /// Two documents interleaved in one cache (two tabs): neither evicts, invalidates or discards the
    /// other's tiles, and closing one releases only its own.
    @Test func documentsSharingTheCacheKeepTheirOwnTiles() async throws {
        let set = try LWFloatWorkingSet(limit: 256 * 1024 * 1024)
        let side = LWDocumentTileRenderer.tileSide, w = side * 2, h = side * 2
        let imageA = image(w, h, seed: 41), imageB = image(w, h, seed: 42)
        let a = layer("A", at: .zero, imageA), b = layer("B", at: .zero, imageB)
        let docA = snapshot(w, h, [a], images: [a.id: imageA], document: UUID()), docB = snapshot(w, h, [b], images: [b.id: imageB], document: UUID())
        let idA = docA.manifest.documentID, idB = docB.manifest.documentID
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let everything = LWFloatRange(x: 0, y: 0, width: w, height: h)
        // A's evaluation of the same tile coordinates is held before publishing while B plans and renders.
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        tiles.beforePublish = { plan in if plan.document == idA { started.signal(); release.wait() } }
        let planA = try tiles.plan(docA)
        let pendingA = Task.detached { try tiles.tiles(covering: everything, plan: planA) }
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        _ = try tiles.tiles(covering: everything, plan: try tiles.plan(docB))
        release.signal()
        let fromA = try await pendingA.value
        tiles.beforePublish = nil
        #expect(tiles.discardedCompletions == 0)
        #expect(tiles.isCurrent(planA))
        #expect(tiles.cachedKeys(of: idA).count == 4)
        #expect(tiles.cachedKeys(of: idB).count == 4)
        // Re-planning A after B leaves both caches whole; nothing is evaluated again.
        let evaluated = tiles.evaluatedTiles
        let againA = try tiles.tiles(covering: everything, plan: try tiles.plan(docA))
        _ = try tiles.tiles(covering: everything, plan: try tiles.plan(docB))
        #expect(tiles.evaluatedTiles == evaluated)
        #expect(againA.map(\.pixels) == fromA.map(\.pixels))
        // Closing B's tab releases B only.
        tiles.purge(document: idB)
        #expect(tiles.cachedKeys(of: idB).isEmpty)
        #expect(tiles.cachedKeys(of: idA).count == 4)
        tiles.purge()
    }

    /// The cache gives tiles back when another consumer of the working set (an export, a RAW decode) needs
    /// the bytes, instead of refusing it.
    @Test func otherConsumersReclaimCacheResidency() throws {
        let mib = 1024 * 1024
        let set = try LWFloatWorkingSet(limit: 128 * mib)
        let side = LWDocumentTileRenderer.tileSide, w = side * 8, h = side * 5
        let base = image(w, h, seed: 51), record = layer("Base", at: .zero, base)
        let tiles = try LWDocumentTileRenderer(budgetBytes: 40 * mib, workingSet: set)
        _ = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: w, height: h), plan: tiles.plan(snapshot(w, h, [record], images: [record.id: base])))
        #expect(tiles.residentBytes == 40 * mib)
        #expect(set.retainedBytes == 40 * mib)
        // An export admission that only fits once the cache gives back at least 32 MiB.
        let export = try set.reserve(120 * mib)
        #expect(tiles.residentBytes <= 8 * mib)
        #expect(tiles.reclaimedBytes >= 32 * mib)
        withExtendedLifetime(export) {}
        tiles.purge()
    }

    /// Plans are ordered by request: a snapshot whose fingerprinting finishes after a newer request's
    /// cannot become the latest plan or invalidate the newer plan's tiles.
    @Test func aPlanFinishingLateCannotDisplaceANewerOne() async throws {
        let set = try LWFloatWorkingSet(limit: 128 * 1024 * 1024)
        let side = LWDocumentTileRenderer.tileSide, w = side * 2, h = side * 2
        let base = image(w, h, seed: 61)
        var record = layer("Base", at: .zero, base)
        let id = UUID()
        func doc() -> ProjectSnapshot {
            ProjectSnapshot(manifest: ProjectManifest(documentID: id, width: w, height: h, activeLayerID: record.id, layers: [record]),
                images: [record.id: ImportedImage(image: base, thumbnail: base, name: "fixture")], masks: [:])
        }
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let older = doc()
        record.opacity = 0.5
        let newer = doc()
        let fingerprinted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        // The first plan requested is held while it fingerprints.
        let calls = LWLockedBox(0)
        tiles.beforeFingerprint = { if calls.update({ $0 + 1 }) == 1 { fingerprinted.signal(); release.wait() } }
        let pending = Task.detached { try tiles.plan(older) }
        await withCheckedContinuation { done in DispatchQueue.global().async { fingerprinted.wait(); done.resume() } }
        let current = try tiles.plan(newer)
        _ = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: w, height: h), plan: current)
        release.signal()
        let late = try await pending.value
        #expect(late.generation < current.generation)
        #expect(tiles.isCurrent(current) && !tiles.isCurrent(late))
        #expect(tiles.cachedKeys.count == 4)
        // The late plan's work is discarded rather than published over the newer tiles.
        _ = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: w, height: h), plan: late)
        #expect(tiles.discardedCompletions == 4)
        tiles.purge()
    }

    @Test func textureCacheStaysWithinDeclaredBudget() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        #expect(renderer.textureBudgetBytes == Self.contract.texture_budget_bytes)
        let saved = renderer.textureBudgetBytes
        defer { renderer.textureBudgetBytes = saved }
        let budget = Self.contract.large_document.texture_budget_bytes
        renderer.textureBudgetBytes = budget
        let side = 2048
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // 64 distinct 16 MiB textures: 1 GiB requested.
        let images = (0..<64).compactMap { _ in context.makeImage() }
        #expect(images.count == 64)
        for image in images {
            #expect(renderer.image(image) != nil)
            #expect(renderer.residentTextureBytes <= budget)
        }
        #expect(renderer.cachedLevels(of: images[0]).isEmpty)
        #expect(renderer.cachedLevels(of: images[63]) == [0])
        renderer.endFrame()
    }

    /// Stroke textures count against the budget too, and ones no frame is drawing any more are evicted
    /// for it: only what the current frame draws can hold the cache above its budget.
    @Test func strokeTexturesAreEvictedToTheTextureBudget() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let saved = renderer.textureBudgetBytes
        defer { renderer.textureBudgetBytes = saved; renderer.endFrame() }
        let side = 2048, strokeBytes = side * side * 4
        renderer.textureBudgetBytes = strokeBytes * 2
        var sessions: [EditorSession] = []
        for _ in 0..<4 {
            let session = EditorSession()
            session.createDocument(width: side, height: side)
            session.addBlankLayer()
            sessions.append(session)
            let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false,
                settings: BrushSettings(diameter: 40, hardness: 0, red: 1), canvas: CGSize(width: side, height: side), useGPU: true)
            #expect(renderer.image(stroke, base: nil) != nil)
            #expect(renderer.residentTextureBytes <= renderer.textureBudgetBytes, "\(renderer.residentTextureBytes) bytes resident")
            renderer.endFrame()
        }
    }
}
