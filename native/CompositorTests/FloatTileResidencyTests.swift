import Testing
import Foundation
import CoreGraphics
import Metal
@testable import Compositor

/// A float image whose pixels are generated when Core Graphics asks for them: a document of any
/// size can be built without allocating its pixels.
nonisolated final class ProceduralImage: @unchecked Sendable {
    let width: Int, height: Int
    let pixel: @Sendable (Int, Int) -> SIMD4<Float>
    private init(width: Int, height: Int, pixel: @escaping @Sendable (Int, Int) -> SIMD4<Float>) {
        self.width = width; self.height = height; self.pixel = pixel
    }
    static func make(width: Int, height: Int, pixel: @escaping @Sendable (Int, Int) -> SIMD4<Float>) -> CGImage {
        let owner = Unmanaged.passRetained(ProceduralImage(width: width, height: height, pixel: pixel))
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, output, position, count in
                let me = Unmanaged<ProceduralImage>.fromOpaque(info!).takeUnretainedValue()
                var done = 0, at = Int(position)
                while done < count {
                    let index = at / 16, offset = at % 16
                    let p = me.pixel(index % me.width, index / me.width)
                    var value = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                    let take = min(16 - offset, count - done)
                    withUnsafeBytes(of: &value) { output.advanced(by: done).copyMemory(from: $0.baseAddress!.advanced(by: offset), byteCount: take) }
                    done += take; at += take
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
    private static func pattern(_ seed: Int, alpha: Float = 1) -> @Sendable (Int, Int) -> SIMD4<Float> {
        { x, y in
            let r = Float((x * 7 + y * 3 + seed) % 97) / 30           // up to 3.2: HDR
            let g = Float((x + y * 5 + seed * 11) % 89) / 70 - 0.35    // down to -0.35: out of gamut
            let b = Float((x * 13 + seed) % 61) / 61
            let a = alpha < 1 ? alpha * (0.4 + 0.6 * Float((x / 9 + y / 7) % 5) / 4) : 1
            return SIMD4(r, g, b, a)
        }
    }
    private func image(_ w: Int, _ h: Int, seed: Int, alpha: Float = 1) -> CGImage {
        ProceduralImage.make(width: w, height: h, pixel: Self.pattern(seed, alpha: alpha))
    }
    private func maskAsset(_ w: Int, _ h: Int) throws -> ImportedImage {
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.1, alpha: 1)] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return try LayerMask.asset(from: try #require(context.makeImage()))
    }
    private func snapshot(_ width: Int, _ height: Int, _ layers: [ProjectLayerRecord], images: [UUID: CGImage],
                          masks: [UUID: ImportedImage] = [:]) -> ProjectSnapshot {
        ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: layers.first?.id, layers: layers),
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
        let base = image(1100, 900, seed: 1), top = image(700, 520, seed: 2, alpha: 0.8)
        let b = layer("Base", at: .zero, base), t = layer("Top", at: CGPoint(x: 200.25, y: 150), top, mode: mode, opacity: 0.85, rotation: 17)
        let doc = snapshot(1100, 900, [b, t], images: [b.id: base, t.id: top])
        let expected = try whole(doc, workingSet: set)
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: set)
        let made = try tiles.surface(LWFloatRange(x: 0, y: 0, width: 1100, height: 900), plan: tiles.plan(doc))
        #expect(tiles.evaluatedTiles == 20)
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
        let pending = Task.detached { try tiles.tiles(covering: request, plan: old) }
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        a.opacity = 0.3
        let newer = try tiles.plan(snapshot(w, h, [base, a], images: images))
        #expect(!tiles.isCurrent(old) && tiles.isCurrent(newer))
        let fresh = try tiles.tiles(covering: LWFloatRange(x: 0, y: 0, width: side, height: side), plan: newer)
        release.signal()
        let stale = try await pending.value
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
        tiles.purge()
        #expect(set.retainedBytes == before)
    }

    // MARK: Large-document residency

    @Test func largeDocumentStaysWithinDeclaredResidency() throws {
        let large = Self.contract.large_document
        #expect(LWDocumentTileRenderer.defaultBudgetBytes == Self.contract.tile_cache_budget_bytes)
        let set = try LWFloatWorkingSet(limit: LWFloatWorkingSet.maximumBytes)
        let w = large.width, h = large.height
        let baseImage = image(w, h, seed: 21), topImage = image(w, h, seed: 22, alpha: 1)
        let base = layer("Base", at: .zero, baseImage), top = layer("Top", at: .zero, topImage, mode: .multiply, opacity: 0.75)
        var exposure = LayerAdjustment(kind: .exposure); exposure.exposure = ExposureSettings(exposure: 0.5, offset: 0, gamma: 1)
        let doc = snapshot(w, h, [base, top, adjustment("Exposure", exposure, width: w, height: h)], images: [base.id: baseImage, top.id: topImage])
        let tiles = try LWDocumentTileRenderer(budgetBytes: large.cache_budget_bytes, workingSet: set)
        set.resetPeak()
        let plan = try tiles.plan(doc)
        let side = LWDocumentTileRenderer.tileSide, columns = (w + side - 1) / side, rows = (h + side - 1) / side
        // A full row and a full column of the grid, then the diagonal one tile at a time.
        var regions = [LWFloatRange(x: 0, y: 0, width: w, height: side), LWFloatRange(x: w - side, y: 0, width: side, height: h)]
        regions += (0..<min(columns, rows)).map { LWFloatRange(x: $0 * side, y: $0 * side, width: side, height: min(side, h - $0 * side)) }
        var checked = 0
        for region in regions {
            for tile in try tiles.tiles(covering: region, plan: plan) {
                #expect(tiles.residentBytes <= large.cache_budget_bytes)
                // Spot-check samples against the analytic composite.
                for (dx, dy) in [(0, 0), (tile.range.width - 1, tile.range.height - 1), (101, 37)] {
                    let x = tile.range.x + dx, y = tile.range.y + dy
                    let t = Self.pattern(22)(x, y), b = Self.pattern(21)(x, y)
                    let blended = ReferenceBlend.pixel(.multiply, top: SIMD4(t.x, t.y, t.z, t.w * 0.75), bottom: b)
                    let expected = SIMD4(blended.x * 2.0.squareRoot(), blended.y * 2.0.squareRoot(), blended.z * 2.0.squareRoot(), blended.w)
                    let actual = tile.pixels[dy * tile.range.width + dx]
                    for c in 0..<4 { #expect(abs(Double(actual[c]) - expected[c]) <= 1e-4 * max(1, abs(expected[c])), "(\(x),\(y)) channel \(c)") }
                    checked += 1
                }
            }
        }
        #expect(checked == (columns + rows + min(columns, rows)) * 3)
        #expect(tiles.evictionCount > 0)
        #expect(tiles.peakResidentBytes <= large.cache_budget_bytes)
        #expect(set.peakRetainedBytes <= large.peak_working_set_bytes, "peak working set \(set.peakRetainedBytes)")
        print("S09 large document: peak working set \(set.peakRetainedBytes) bytes, peak cache \(tiles.peakResidentBytes) bytes, \(tiles.evictionCount) evictions, \(tiles.evaluatedTiles) tiles evaluated")
        tiles.purge()
        #expect(tiles.residentBytes == 0)
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
}
