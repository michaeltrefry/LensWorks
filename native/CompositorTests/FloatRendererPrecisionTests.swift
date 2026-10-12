import Testing
import Foundation
import CoreGraphics
import CoreImage
import Metal
import QuartzCore
@testable import Compositor

/// The declared renderer tolerances and bounds (RENDERER_PRECISION_CONTRACT.json at the repository root).
struct RendererContract: Decodable {
    struct Large: Decodable {
        let width: Int, height: Int
        let cache_budget_bytes: Int, peak_working_set_bytes: Int, texture_budget_bytes: Int
    }
    let blend_reference_relative: Double
    let blend_core_image_in_range_abs: Double
    let tile_parity_pointwise_abs: Double
    let document_region_parity_relative: Double
    let document_region_spatial_relative: Double
    let display_conversion_relative: Double
    let tile_cache_budget_bytes: Int
    let texture_budget_bytes: Int
    let large_document: Large
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: repository.appendingPathComponent("RENDERER_PRECISION_CONTRACT.json")))
    }
}

/// An independent float64 transcription of the declared blend semantics (see LWFloatBlend).
enum ReferenceBlend {
    typealias V = SIMD3<Double>
    static func enc(_ x: Double) -> Double { let a = abs(x), y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055; return x < 0 ? -y : y }
    static func dec(_ x: Double) -> Double { let a = abs(x), y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4); return x < 0 ? -y : y }
    static func sep(_ m: LayerBlendMode, _ b: Double, _ s: Double) -> Double {
        let lo = min(0, b, s), hi = max(1, b, s)
        func burn(_ b: Double, _ s: Double) -> Double { b >= 1 ? b : s <= 0 ? lo : max(lo, 1 - (1 - b) / s) }
        func dodge(_ b: Double, _ s: Double) -> Double { b <= 0 ? b : s >= 1 ? hi : min(hi, b / (1 - s)) }
        func hard(_ b: Double, _ s: Double) -> Double { s <= 0.5 ? b * 2 * s : b + (2 * s - 1) - b * (2 * s - 1) }
        switch m {
        case .normal: return s
        case .darken: return min(b, s)
        case .lighten: return max(b, s)
        case .multiply: return b * s
        case .screen: return b + s - b * s
        case .colorBurn: return burn(b, s)
        case .colorDodge: return dodge(b, s)
        case .linearBurn: return max(lo, b + s - 1)
        case .linearDodge: return min(hi, b + s)
        case .hardLight: return hard(b, s)
        case .overlay: return hard(s, b)
        case .softLight:
            if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
            return b + (2 * s - 1) * ((b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()) - b)
        case .vividLight: return s <= 0.5 ? burn(b, 2 * s) : dodge(b, 2 * s - 1)
        case .linearLight: return min(hi, max(lo, b + 2 * s - 1))
        case .pinLight: return s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1)
        case .hardMix: return b + s >= 1 ? hi : lo
        case .difference: return abs(b - s)
        case .exclusion: return b + s - 2 * b * s
        case .subtract: return max(lo, b - s)
        case .divide: return s > 0 ? min(hi, b / s) : (b > 0 ? hi : b < 0 ? lo : 0)
        case .hue, .saturation, .color, .luminosity: fatalError()
        }
    }
    static func lum(_ c: V) -> Double { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }
    static func clip(_ c: V, _ lo: Double, _ hi: Double) -> V {
        let l = lum(c), n = c.min(), x = c.max(); var r = c
        if n < lo, l > lo { r = V(repeating: l) + (r - V(repeating: l)) * (l - lo) / (l - n) }
        if x > hi, l < hi { r = V(repeating: l) + (r - V(repeating: l)) * (hi - l) / (x - l) }
        return r
    }
    static func setLum(_ c: V, _ l: Double, _ lo: Double, _ hi: Double) -> V { clip(c + V(repeating: l - lum(c)), lo, hi) }
    static func setSat(_ c: V, _ s: Double) -> V { let n = c.min(), x = c.max(); return x > n ? (c - V(repeating: n)) * s / (x - n) : .zero }
    static func mix(_ m: LayerBlendMode, _ b: V, _ s: V) -> V {
        let lo = min(0, b.min(), s.min()), hi = max(1, b.max(), s.max())
        switch m {
        case .hue: return setLum(setSat(s, b.max() - b.min()), lum(b), lo, hi)
        case .saturation: return setLum(setSat(b, s.max() - s.min()), lum(b), lo, hi)
        case .color: return setLum(s, lum(b), lo, hi)
        case .luminosity: return setLum(b, lum(s), lo, hi)
        default: return V(sep(m, b.x, s.x), sep(m, b.y, s.y), sep(m, b.z, s.z))
        }
    }
    static func pixel(_ m: LayerBlendMode, top t: SIMD4<Float>, bottom u: SIMD4<Float>) -> SIMD4<Double> {
        let a = Double(t.w), b = Double(u.w), ao = a + b * (1 - a)
        if a <= 0 && b <= 0 { return .zero }
        if a <= 0 { return SIMD4(Double(u.x), Double(u.y), Double(u.z), b) }
        if b <= 0 || (m == .normal && a >= 1) { return SIMD4(Double(t.x), Double(t.y), Double(t.z), a) }
        let cs = V(enc(Double(t.x)), enc(Double(t.y)), enc(Double(t.z))), cb = V(enc(Double(u.x)), enc(Double(u.y)), enc(Double(u.z)))
        let co = (cs * (a * (1 - b)) + mix(m, cb, cs) * (a * b) + cb * ((1 - a) * b)) / ao
        return SIMD4(dec(co.x), dec(co.y), dec(co.z), ao)
    }
}

/// Deterministic straight samples spanning HDR, negative, transparent, partial and opaque alpha.
enum PrecisionFixture {
    static func samples(_ count: Int, seed: UInt64, inRange: Bool = false) -> [SIMD4<Float>] {
        var state = seed &* 0x9e3779b97f4a7c15 | 1
        func next() -> Float { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Float(state >> 40) / Float(1 << 24) }
        let alphas: [Float] = [1, 1, 0.75, 0.5, 0.2, 0.01, 0]
        return (0..<count).map { i in
            let a = alphas[i % alphas.count]
            if inRange { return SIMD4(next(), next(), next(), i % 3 == 0 ? 1 : next()) }
            // HDR up to 6, negatives down to -0.5, and plain in-range values.
            func channel() -> Float { let r = next(); return r < 0.3 ? 1 + r * 16 : r < 0.45 ? -(r - 0.3) * 3.3 : r }
            return SIMD4(channel(), channel(), channel(), a)
        }
    }
    static func plane(_ width: Int, _ height: Int, seed: UInt64, workspace: LWFloatWorkspace) throws -> (LWFloatPlane, LWLinearSurface) {
        let values = samples(width * height, seed: seed)
        let surface = try LWLinearSurface(width: width, height: height, pixels: values, maximumBytes: width * height * 16)
        return (try LWFloatCompositor.from(surface, workspace: workspace), surface)
    }
}

@MainActor struct FloatRendererPrecisionTests {
    static let contract = try! RendererContract.load()

    private func relative(_ actual: Float, _ expected: Double) -> Double { abs(Double(actual) - expected) / max(1, abs(expected)) }

    /// Every mode, on HDR, negative, transparent and partially transparent straight samples, against the
    /// float64 reference. The comparison is per straight channel, so color under partial alpha counts.
    @Test(arguments: LayerBlendMode.allCases)
    func blendModePreservesExtendedRangeAndAlphaSemantics(_ mode: LayerBlendMode) throws {
        let n = 4096, top = PrecisionFixture.samples(n, seed: 11), bottom = PrecisionFixture.samples(n, seed: 23)
        let a = try LWLinearSurface(width: 64, height: 64, pixels: top, maximumBytes: n * 16)
        let b = try LWLinearSurface(width: 64, height: 64, pixels: bottom, maximumBytes: n * 16)
        let made = try LWFloatCompositor.blend(a, over: b, mode: mode)
        var worst = 0.0, outside = 0
        for i in 0..<n {
            let e = ReferenceBlend.pixel(mode, top: top[i], bottom: bottom[i]), p = made.pixels[i]
            for c in 0..<4 { worst = max(worst, relative(p[c], e[c])) }
            if (0..<3).contains(where: { p[$0] > 1.001 || p[$0] < -0.001 }) { outside += 1 }
            // Single-pixel scalar path agrees with the buffer path exactly.
            #expect(LWFloatBlend.pixel(mode, top: top[i], bottom: bottom[i]) == p)
        }
        #expect(worst <= Self.contract.blend_reference_relative, "\(mode): worst relative error \(worst)")
        // No mode clamps the frame to [0, 1].
        #expect(outside > n / 10, "\(mode): only \(outside) results outside [0, 1]")
        // Alpha follows source-over for every mode.
        for i in 0..<n { #expect(abs(made.pixels[i].w - (top[i].w + bottom[i].w * (1 - top[i].w))) <= 1e-6) }
    }

    @Test func blendSemanticsAreNotClampedAtDisplayRange() throws {
        func one(_ mode: LayerBlendMode, _ t: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> { LWFloatBlend.pixel(mode, top: t, bottom: b) }
        let enc = ReferenceBlend.enc, dec = ReferenceBlend.dec
        // Multiply of HDR operands is the product in encoded space, far above 1.
        let m = one(.multiply, SIMD4(4, 0.5, -0.25, 1), SIMD4(3, 0.5, 0.5, 1))
        #expect(abs(Double(m.x) - dec(enc(4) * enc(3))) < 1e-4 && m.x > 10)
        #expect(m.z < 0)
        // Darken keeps the negative operand; Lighten keeps HDR.
        #expect(abs(one(.darken, SIMD4(-0.2, 0.3, 0.3, 1), SIMD4(0.1, 0.3, 0.3, 1)).x + 0.2) < 1e-6)
        #expect(abs(one(.lighten, SIMD4(0.2, 0.3, 0.3, 1), SIMD4(5, 0.3, 0.3, 1)).x - 5) < 5e-6)
        // Linear Dodge saturates at the operands' range, never at 1.
        #expect(one(.linearDodge, SIMD4(2.5, 0.2, 0.2, 1), SIMD4(0.6, 0.2, 0.2, 1)).x >= 2.5 - 1e-5)
        // Color Dodge with a black source is the identity even over an HDR backdrop.
        #expect(abs(one(.colorDodge, SIMD4(0, 0, 0, 1), SIMD4(3, 2, 1.5, 1)).x - 3) < 1e-4)
        // Normal over a transparent backdrop and a transparent source over anything are exact.
        let hdr = SIMD4<Float>(7.25, -0.125, 0.3, 0.4)
        #expect(one(.multiply, hdr, SIMD4(1, 1, 1, 0)) == hdr)
        #expect(one(.screen, SIMD4(9, 9, 9, 0), hdr) == hdr)
        #expect(one(.normal, SIMD4(3, -1, 2, 1), hdr) == SIMD4(3, -1, 2, 1))
    }

    /// In range the kernel is the Core Image definition the float compositor used before this change.
    @Test(arguments: LayerBlendMode.allCases)
    func blendModeMatchesCoreImageInsideDisplayRange(_ mode: LayerBlendMode) throws {
        let n = 2048, top = PrecisionFixture.samples(n, seed: 5, inRange: true), bottom = PrecisionFixture.samples(n, seed: 9, inRange: true)
        let name = mode == .normal ? "CISourceOverCompositing" : (GPUBlend.filterName(mode) ?? mode.coreImageFilter!)
        let lin = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB)), enc = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
        func image(_ p: [SIMD4<Float>]) -> CIImage {
            let pre = p.map { SIMD4($0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w) }
            return CIImage(bitmapData: pre.withUnsafeBytes { Data($0) }, bytesPerRow: n * 16, size: CGSize(width: n, height: 1), format: .RGBAf, colorSpace: lin)
        }
        let filter = try #require(CIFilter(name: name))
        filter.setValue(image(top), forKey: kCIInputImageKey); filter.setValue(image(bottom), forKey: kCIInputBackgroundImageKey)
        let context = CIContext(options: [.workingColorSpace: enc, .outputColorSpace: lin, .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        out.withUnsafeMutableBytes { context.render(try! #require(filter.outputImage), toBitmap: $0.baseAddress!, rowBytes: n * 16,
            bounds: CGRect(x: 0, y: 0, width: n, height: 1), format: .RGBAf, colorSpace: lin) }
        var worst: Float = 0
        for i in 0..<n {
            let p = LWFloatBlend.pixel(mode, top: top[i], bottom: bottom[i]), a = out[i].w
            guard a > 0.05 else { continue } // Below that, unpremultiplying Core Image's output amplifies its rounding.
            let ci = SIMD4(out[i].x / a, out[i].y / a, out[i].z / a, a)
            for c in 0..<4 { worst = max(worst, abs(p[c] - ci[c])) }
        }
        #expect(Double(worst) <= Self.contract.blend_core_image_in_range_abs, "\(mode): worst \(worst)")
    }

    /// Tiled blending of range-backed planes against one whole-frame evaluation, for every mode.
    @Test(arguments: LayerBlendMode.allCases)
    func tiledBlendMatchesWholeFrame(_ mode: LayerBlendMode) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 256 * 1024 * 1024))
        let (topPlane, top) = try PrecisionFixture.plane(601, 389, seed: 3, workspace: workspace)
        let (bottomPlane, bottom) = try PrecisionFixture.plane(601, 389, seed: 4, workspace: workspace)
        let whole = try LWFloatCompositor.blend(top, over: bottom, mode: mode)
        let tiled = try LWFloatCompositor.blend(topPlane, over: bottomPlane, mode: mode, workspace: workspace)
        var worst: Float = 0
        try tiled.forEachTile { range in
            let tile = try tiled.read(range: range)
            for (i, p) in tile.surface.pixels.enumerated() {
                let e = whole.pixels[(range.y + i / range.width) * 601 + range.x + i % range.width]
                for c in 0..<4 { worst = max(worst, abs(p[c] - e[c])) }
            }
        }
        #expect(Double(worst) <= Self.contract.tile_parity_pointwise_abs, "\(mode): worst \(worst)")
    }

    // MARK: Source conversions

    /// Range-backed planes reach Core Graphics and Core Image premultiplied; the boundary back to
    /// straight samples must return HDR and negative color and the alpha unchanged.
    @Test func sourceConversionsKeepExtendedValuesAndAlpha() throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 128 * 1024 * 1024))
        var values = PrecisionFixture.samples(300 * 290, seed: 77)
        for i in values.indices where values[i].w == 0 { values[i] = .zero } // Hidden color has no premultiplied form.
        let surface = try LWLinearSurface(width: 300, height: 290, pixels: values, maximumBytes: 300 * 290 * 16)
        let plane = try LWFloatCompositor.from(surface, workspace: workspace)
        // Placement at identity through the premultiplied provider and Core Graphics.
        let placed = try LWFloatCompositor.place(plane, transform: LayerTransform(origin: .zero, size: CGSize(width: 300, height: 290)),
            width: 300, height: 290, workspace: workspace)
        // Core Image round trip through the same provider.
        let identity = try LWFloatCoreImage.render(plane, makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }) { $0 }
        for (name, result) in [("place", placed), ("core image", identity)] {
            var worst = 0.0, hdr = 0, negative = 0
            try result.forEachTile { range in
                let tile = try result.read(range: range)
                for (i, p) in tile.surface.pixels.enumerated() {
                    let e = values[(range.y + i / range.width) * 300 + range.x + i % range.width]
                    // Straight color is only defined to the precision premultiplication by alpha leaves.
                    let colorScale = e.w > 0 ? 1 / Double(e.w) : 0
                    for c in 0..<3 { worst = max(worst, relative(p[c], Double(e[c])) / max(1, colorScale * 1e-2)) }
                    worst = max(worst, relative(p.w, Double(e.w)))
                    if p.x > 1 || p.y > 1 || p.z > 1 { hdr += 1 }
                    if p.x < 0 || p.y < 0 || p.z < 0 { negative += 1 }
                }
            }
            #expect(worst <= 1e-5, "\(name): worst \(worst)")
            #expect(hdr > 1000 && negative > 1000, "\(name): hdr \(hdr) negative \(negative)")
        }
    }

    /// Placement crops a tile's source when the layer is a pixel copy (native size, whole-pixel origin, no
    /// rotation or flip); every transform must give exactly the samples of the uncropped per-tile draw.
    @Test(arguments: ["integer", "fractional", "rotated", "reduced", "enlarged-flipped"])
    func croppedTilePlacementMatchesUncroppedDraw(_ kind: String) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 256 * 1024 * 1024))
        let source = ProceduralImage.make(width: 700, height: 610) { x, y in
            SIMD4(Float((x * 7 + y * 3) % 97) / 30, Float((x + y * 5) % 89) / 70 - 0.35, Float(x % 61) / 61, 0.5 + Float((x / 9 + y / 7) % 5) / 8)
        }
        var transform = LayerTransform(origin: CGPoint(x: 37, y: 21), size: CGSize(width: 700, height: 610))
        switch kind {
        case "fractional": transform.origin = CGPoint(x: 37.5, y: 21.25)
        case "rotated": transform.rotation = 23
        case "reduced": transform.size = CGSize(width: 233, height: 199); transform.origin = CGPoint(x: 300.3, y: 410)
        case "enlarged-flipped": transform.size = CGSize(width: 1250, height: 1100); transform.flipX = true; transform.flipY = true; transform.origin = CGPoint(x: -100, y: -50)
        default: break
        }
        #expect((LWFloatCompositor.visiblePart(of: source, transform: transform, range: LWFloatRange(x: 256, y: 256, width: 256, height: 256))?.image.width == 700) == (kind != "integer"))
        let width = 900, height = 800
        let tiled = try LWFloatCompositor.place(source, transform: transform, width: width, height: height, workspace: workspace)
        var worst: Float = 0
        try tiled.forEachTile { range in
            // Reference: the whole layer drawn into this range's context, as placement did before cropping.
            let context = try LWLinearSurface.context(width: range.width, height: range.height, maximumBytes: range.width * range.height * 16)
            context.translateBy(x: -CGFloat(range.x), y: CGFloat(range.y + range.height)); context.scaleBy(x: 1, y: -1)
            context.translateBy(x: transform.center.x, y: transform.center.y); context.rotate(by: transform.radians)
            context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
            context.interpolationQuality = transform.sampling.quality
            context.draw(source, in: CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2, width: transform.size.width, height: transform.size.height))
            let expected = try LWLinearSurface.read(try #require(context.makeImage()), maximumBytes: range.width * range.height * 16)
            let tile = try tiled.read(range: range)
            for (p, e) in zip(tile.surface.pixels, expected.pixels) { for c in 0..<4 { worst = max(worst, abs(p[c] - e[c])) } }
        }
        #expect(Double(worst) <= Self.contract.tile_parity_pointwise_abs, "\(kind): worst \(worst)")
    }

    // MARK: Display conversion

    @Test(arguments: LWDisplayTarget.allCases)
    func displayConversionKeepsExtendedRange(_ target: LWDisplayTarget) throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let lin = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        // Straight linear sRGB samples: HDR, negative (out of the sRGB gamut), in range.
        let samples: [SIMD4<Float>] = [SIMD4(4, 2, 1.5, 1), SIMD4(-0.05, 0.6, 0.2, 1), SIMD4(0.18, 0.18, 0.18, 1), SIMD4(1.5, -0.1, 0.9, 1)]
        let image = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: samples.count * 16,
            size: CGSize(width: samples.count, height: 1), format: .RGBAf, colorSpace: lin)
        let texture = try #require(renderer.displayTexture(width: samples.count, height: 1))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.render(image, to: texture, commandBuffer: buffer, size: CGSize(width: samples.count, height: 1), target: target)
        buffer.commit(); buffer.waitUntilCompleted()
        #expect(texture.pixelFormat == .rgba16Float)
        var halves = [Float16](repeating: 0, count: samples.count * 4)
        halves.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: samples.count * 8,
            from: MTLRegionMake2D(0, 0, samples.count, 1), mipmapLevel: 0) }
        // Analytic conversion: linear sRGB → linear target primaries → sign-mirrored sRGB transfer.
        let toP3: [[Double]] = [[0.8224621, 0.1775380, 0], [0.0331941, 0.9668058, 0], [0.0170827, 0.0723974, 0.9105199]]
        var aboveOne = false, belowZero = false
        for (i, s) in samples.enumerated() {
            let rgb = [Double(s.x), Double(s.y), Double(s.z)]
            let linear = target == .extendedDisplayP3 ? toP3.map { row in zip(row, rgb).map(*).reduce(0, +) } : rgb
            for c in 0..<3 {
                let expected = ReferenceBlend.enc(linear[c]), actual = Double(halves[i * 4 + c])
                #expect(abs(actual - expected) <= Self.contract.display_conversion_relative * max(1, abs(expected)),
                        "\(target) sample \(i) channel \(c): \(actual) vs \(expected)")
                if actual > 1.01 { aboveOne = true }
                if actual < -0.01 { belowZero = true }
            }
        }
        #expect(aboveOne && belowZero)
    }

    @Test func canvasDrawableIsExtendedHalfFloat() {
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(view.metalLayer.pixelFormat == .rgba16Float)
        #expect(view.metalLayer.wantsExtendedDynamicRangeContent)
        #expect(LWDisplayTarget(colorSpace: view.metalLayer.colorspace) != nil)
    }
}
