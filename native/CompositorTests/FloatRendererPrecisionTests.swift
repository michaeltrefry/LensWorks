import Testing
import AppKit
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
        let cache_budget_bytes: Int, peak_working_set_bytes: Int, texture_budget_bytes: Int, peak_footprint_growth_bytes: Int
    }
    let blend_reference_relative: Double
    let blend_core_image_in_range_abs: Double
    let tile_parity_pointwise_abs: Double
    let resampler_reference_relative: Double
    let raster_fast_path_relative: Double
    let document_region_parity_relative: Double
    let document_region_spatial_relative: Double
    let display_conversion_relative: Double
    let tile_cache_budget_bytes: Int
    let canvas_frame_budget_bytes: Int
    let texture_budget_bytes: Int
    let large_document: Large
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: repository.appendingPathComponent("RENDERER_PRECISION_CONTRACT.json")))
    }
}

/// Float64 transfer functions and the source-over compositing equation. The per-mode mixing
/// function is LWFloatBlend's own (its semantics are checked by property tests, not by a copy of
/// the formulas), so this verifies the vForce transfer and compositing path around it.
enum ReferenceBlend {
    static func enc(_ x: Double) -> Double { let a = abs(x), y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055; return x < 0 ? -y : y }
    static func dec(_ x: Double) -> Double { let a = abs(x), y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4); return x < 0 ? -y : y }
    static func pixel(_ m: LayerBlendMode, top t: SIMD4<Float>, bottom u: SIMD4<Float>) -> SIMD4<Double> {
        let a = Double(t.w), b = Double(u.w), ao = a + b * (1 - a)
        if a <= 0 && b <= 0 { return .zero }
        if a <= 0 { return SIMD4(Double(u.x), Double(u.y), Double(u.z), b) }
        if b <= 0 || (m == .normal && a >= 1) { return SIMD4(Double(t.x), Double(t.y), Double(t.z), a) }
        let cs = SIMD3(enc(Double(t.x)), enc(Double(t.y)), enc(Double(t.z))), cb = SIMD3(enc(Double(u.x)), enc(Double(u.y)), enc(Double(u.z)))
        let mixed = LWFloatBlend.mix(m, backdrop: SIMD3<Float>(cb), source: SIMD3<Float>(cs))
        let co = (cs * (a * (1 - b)) + SIMD3<Double>(mixed) * (a * b) + cb * ((1 - a) * b)) / ao
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

    /// Every mode, on HDR, negative, transparent and partially transparent straight samples: the buffer path
    /// against float64 transfer and compositing around the mode's mixing function, per straight channel.
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

    // MARK: Extended-range blend properties

    /// Encoded operands spanning negative, zero, subnormal, in-range, the 0.5 and 1 breakpoints and HDR.
    static let probes: [Float] = [-1e30, -7.5, -1, -0.5, -Float.leastNormalMagnitude, -Float.leastNonzeroMagnitude, 0,
        Float.leastNonzeroMagnitude, Float.leastNormalMagnitude, 1e-7, 0.1, 0.25, 0.3, 0.5, 0.5000001, 0.7, 0.999, 1, 1.001, 1.5, 2, 3, 6, 100, 1e30,
        Float.greatestFiniteMagnitude]
    static let separableModes = LayerBlendMode.allCases.filter { ![.hue, .saturation, .color, .luminosity].contains($0) }

    /// Each mode's extended rule is declared, in the kernel and in the repository contract.
    @Test func everyModeDeclaresItsExtendedRule() throws {
        let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: RendererContract.repository
            .appendingPathComponent("RENDERER_PRECISION_CONTRACT.json"))) as? [String: Any]
        let declared = try #require(contract?["blend_extended_rules"] as? [String: String])
        for mode in LayerBlendMode.allCases {
            let rule = try #require(LWFloatBlend.extendedRules[mode], "\(mode) has no extended rule")
            #expect(declared[mode.rawValue] == rule, "\(mode): contract and kernel disagree")
        }
        #expect(declared.count == LayerBlendMode.allCases.count)
    }

    /// The defining cases of the extended rules.
    @Test func extendedRulesKeepHighlightsAndNeutrals() {
        let sep = LWFloatBlend.separable
        // Screen never pulls HDR down; extrapolating b + s - bs would give 2 and 0 here.
        #expect(sep(.screen, 3, 0.5) == 3)
        #expect(sep(.screen, 2, 2) == 2)
        #expect(sep(.screen, 0.5, 4) == 4)
        // Exclusion of equal HDR operands is zero, not -4.
        #expect(sep(.exclusion, 2, 2) == 0)
        // Mid gray is neutral for Overlay and Hard Light over HDR, and neither goes negative.
        #expect(sep(.overlay, 3, 0.5) == 3)
        #expect(sep(.hardLight, 3, 0.5) == 3)
        #expect(sep(.overlay, 3, 2) >= 0 && sep(.hardLight, 2, 3) >= 0 && sep(.overlay, 0.75, 2) >= 0)
        // Soft Light keeps an HDR backdrop for every source.
        for s: Float in [0, 0.25, 0.5, 0.75, 1, 4] { #expect(sep(.softLight, 2.5, s) == 2.5) }
    }

    /// Screen and Lighten never darken a non-negative operand, in the encoded mix and through the
    /// whole pixel (transfer, compositing) for opaque operands.
    @Test func screenAndLightenNeverDarken() {
        let positive = Self.probes.filter { $0 >= 0 && $0 < 1e29 }
        for mode in [LayerBlendMode.screen, .lighten] {
            for b in positive { for s in positive {
                let made = LWFloatBlend.separable(mode, b, s), floor = max(b, s)
                #expect(made >= floor - 1e-6 * max(1, floor), "\(mode)(\(b), \(s)) = \(made)")
                let pixel = LWFloatBlend.pixel(mode, top: SIMD4(s, s, s, 1), bottom: SIMD4(b, b, b, 1))
                #expect(pixel.x >= floor - 2e-5 * max(1, floor), "\(mode) pixel (\(b), \(s)) = \(pixel.x)")
            } }
        }
    }

    /// Non-negative operands never give a negative result, in any mode.
    @Test(arguments: LayerBlendMode.allCases)
    func nonNegativeOperandsNeverGiveNegativeResults(_ mode: LayerBlendMode) {
        let positive = Self.probes.filter { $0 >= 0 }
        for b in positive { for s in positive {
            if Self.separableModes.contains(mode) {
                let made = LWFloatBlend.separable(mode, b, s)
                #expect(made.isNaN || made >= 0, "\(mode)(\(b), \(s)) = \(made)")
            }
            for (cb, cs) in [(SIMD3(b, 0.3, 0.7), SIMD3(s, 0.9, 0.1)), (SIMD3(0.2, b, 1.5), SIMD3(s, s, 0))] {
                let mixed = LWFloatBlend.mix(mode, backdrop: cb, source: cs)
                #expect(mixed.min() >= 0 || (0..<3).contains { mixed[$0].isNaN }, "\(mode) mix \(cb) \(cs) = \(mixed)")
            }
            for alpha: Float in [1, 0.5] {
                let pixel = LWFloatBlend.pixel(mode, top: SIMD4(s, 0.4, s, alpha), bottom: SIMD4(b, b, 0.2, 1))
                #expect(pixel.x >= 0 && pixel.y >= 0 && pixel.z >= 0, "\(mode) pixel (\(b), \(s), \(alpha)) = \(pixel)")
            }
        } }
    }

    /// No finite input — negative, zero, subnormal, huge, any alpha — produces NaN or infinity.
    @Test(arguments: LayerBlendMode.allCases)
    func finiteInputsGiveFiniteResults(_ mode: LayerBlendMode) {
        let linear: [Float] = Self.probes + [-Float.greatestFiniteMagnitude]
        let alphas: [Float] = [1, 0.5, 1e-7, Float.leastNormalMagnitude, Float.leastNonzeroMagnitude]
        for b in linear { for s in linear { for ta in alphas { for ba in [Float(1), 0.3, Float.leastNonzeroMagnitude] {
            let p = LWFloatBlend.pixel(mode, top: SIMD4(s, b, 0.5, ta), bottom: SIMD4(b, s, -s, ba))
            #expect((0..<4).allSatisfy { p[$0].isFinite } && (0...1).contains(p.w), "\(mode): \(s) over \(b) alpha \(ta)/\(ba) = \(p)")
        } } } }
    }

    /// Every mode except the Hard Mix threshold is continuous where its rule changes, at 1 for either
    /// operand (and at 0, except where the W3C definition itself jumps: Color Dodge and Vivid Light at a zero backdrop).
    @Test(arguments: LayerBlendMode.allCases)
    func extendedRulesAreContinuousAtTheDisplayBounds(_ mode: LayerBlendMode) {
        guard mode != .hardMix else { return }
        let eps: Float = 1e-3, others: [Float] = [0.05, 0.3, 0.6, 0.9, 1.5, 3]
        let bounds: [Float] = [.colorDodge, .vividLight].contains(mode) ? [1] : [0, 1]
        func value(_ b: Float, _ s: Float) -> SIMD3<Float> {
            LWFloatBlend.mix(mode, backdrop: SIMD3(b, 0.4, 0.8), source: SIMD3(s, 0.6, 0.2))
        }
        for edge in bounds { for o in others {
            for (lower, upper) in [(value(edge - eps, o), value(edge + eps, o)), (value(o, edge - eps), value(o, edge + eps))] {
                let jump = (lower - upper).max() > -(lower - upper).min() ? (lower - upper).max() : -(lower - upper).min()
                #expect(jump <= 50 * eps, "\(mode) jumps by \(jump) across \(edge) with the other operand \(o)")
            }
        } }
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

    /// Placement reads only the crop of the layer under each tile, and resamples it from document coordinates, so a
    /// tiled placement gives exactly the samples of one whole-frame evaluation for every transform. On smooth
    /// content the resampler also stays close to Core Graphics' own resampling of the whole image.
    @Test(arguments: ["integer", "fractional", "rotated", "reduced", "enlarged-flipped", "nearest-rotated", "smooth-reduced"])
    func tiledPlacementMatchesWholeFrameEvaluation(_ kind: String) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 256 * 1024 * 1024))
        // Smooth HDR and out-of-gamut content, partly transparent.
        @Sendable func smooth(_ u: Float, _ v: Float) -> SIMD4<Float> {
            SIMD4(1.6 + 1.5 * sin(u * 0.05) * cos(v * 0.043), 0.3 + 0.6 * sin(u * 0.031 + v * 0.017), 0.5 + 0.5 * cos(v * 0.06),
                  0.6 + 0.4 * sin(u * 0.023) * sin(v * 0.029))
        }
        let source = ProceduralImage.make(width: 700, height: 610) { x, y in smooth(Float(x), Float(y)) }
        var transform = LayerTransform(origin: CGPoint(x: 37, y: 21), size: CGSize(width: 700, height: 610))
        switch kind {
        case "fractional": transform.origin = CGPoint(x: 37.5, y: 21.25)
        case "rotated": transform.rotation = 23
        case "reduced": transform.size = CGSize(width: 233, height: 199); transform.origin = CGPoint(x: 300.3, y: 410)
        case "enlarged-flipped": transform.size = CGSize(width: 1250, height: 1100); transform.flipX = true; transform.flipY = true; transform.origin = CGPoint(x: -100, y: -50)
        case "nearest-rotated": transform.rotation = -31; transform.sampling = .nearest
        case "smooth-reduced": transform.size = CGSize(width: 310, height: 270); transform.rotation = 8; transform.sampling = .smooth
        default: break
        }
        // An interior tile reads only the part of the layer that reaches it.
        let part = try #require(LWFloatCompositor.visiblePart(of: source, transform: transform, range: LWFloatRange(x: 256, y: 256, width: 256, height: 256)))
        #expect(part.width < 700 && part.height < 610, "\(kind): crop \(part.width)x\(part.height)")
        let width = 900, height = 800
        let tiled = try LWFloatCompositor.place(source, transform: transform, width: width, height: height, workspace: workspace)
        let whole: LWLinearSurface
        if kind == "integer" {
            // A pixel copy: Core Graphics drawing the whole layer into one whole-frame context.
            let context = try LWLinearSurface.context(width: width, height: height, maximumBytes: width * height * 16)
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            context.translateBy(x: transform.center.x, y: transform.center.y); context.scaleBy(x: 1, y: -1)
            context.draw(source, in: CGRect(x: -350, y: -305, width: 700, height: 610))
            whole = try LWLinearSurface.read(try #require(context.makeImage()), maximumBytes: width * height * 16)
        } else {
            whole = try LWFloatCompositor.resampled(source, transform: transform, range: LWFloatRange(x: 0, y: 0, width: width, height: height),
                workingSet: workspace.workingSet)
        }
        var worst: Float = 0
        try tiled.forEachTile { range in
            let tile = try tiled.read(range: range)
            for (i, p) in tile.surface.pixels.enumerated() {
                let e = whole.pixels[(range.y + i / range.width) * width + range.x + i % range.width]
                for c in 0..<4 { worst = max(worst, abs(p[c] - e[c])) }
            }
        }
        #expect(Double(worst) <= Self.contract.tile_parity_pointwise_abs, "\(kind): worst \(worst)")
        guard kind != "integer", kind != "nearest-rotated" else { return }
        // Against Core Graphics drawing the whole layer into one context, on interior samples (away from the layer's
        // edge, where the two antialias differently) whose alpha is not tiny.
        let context = try LWLinearSurface.context(width: width, height: height, maximumBytes: width * height * 16)
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: transform.center.x, y: transform.center.y); context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        context.interpolationQuality = transform.sampling.quality
        context.draw(source, in: CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2, width: transform.size.width, height: transform.size.height))
        let cg = try LWLinearSurface.read(try #require(context.makeImage()), maximumBytes: width * height * 16)
        let toImage = LWFloatCompositor.documentToImage(source, transform: transform)
        var far = 0.0, analytic = 0.0, compared = 0, hdr = 0
        for y in 0..<height { for x in 0..<width {
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(toImage)
            guard p.x > 6, p.y > 6, p.x < 694, p.y < 604 else { continue }
            let a = whole.pixels[y * width + x], e = cg.pixels[y * width + x]
            for ch in 0..<4 { far = max(far, Double(abs(a[ch] - e[ch])) / max(1, Double(abs(e[ch])))) }
            // The continuous content at the pixel centre's image position (sample centres at +0.5).
            let f = smooth(Float(p.x - 0.5), Float(p.y - 0.5))
            for ch in 0..<4 { analytic = max(analytic, Double(abs(a[ch] - f[ch])) / max(1, Double(abs(f[ch])))) }
            if a.x > 1.5 { hdr += 1 }
            compared += 1
        } }
        #expect(compared > 10_000)
        #expect(hdr > compared / 10, "\(kind): HDR samples \(hdr) of \(compared)")
        // The resampler reproduces the continuous content (bilinear interpolation of a smooth function, and the
        // box mean of a reduction, stay within a small fraction of its range).
        #expect(analytic <= Self.contract.resampler_reference_relative, "\(kind): \(analytic) from the content")
        // Core Graphics' high-quality reduction of an extended float image is not a usable reference (it returns
        // alpha far from the content's: 0.82 where the content is 0.27); every other transform stays close to it.
        if kind != "reduced" {
            #expect(far <= Self.contract.resampler_reference_relative, "\(kind): \(far) from Core Graphics")
        }
        print("S09 placement \(kind): tiled vs whole \(worst), resampler vs content \(analytic), vs Core Graphics \(far)")
    }

    /// A plain raster layer is placed straight from its image. Placement converts the crop it reads to premultiplied
    /// extended-linear float before resampling, so an 8-bit sRGB raster that is rotated or scaled is still interpolated
    /// on linear samples: the result is the path every raster took before (a float plane of the whole image, then
    /// placement of that plane), within float rounding of the plane's straight/premultiplied round trip.
    @Test(arguments: ["8-bit rotated", "8-bit reduced", "8-bit integer", "float rotated", "float reduced"])
    func rasterPlacementMatchesTheFloatPlanePath(_ kind: String) throws {
        let workspace = try LWFloatWorkspace(workingSet: LWFloatWorkingSet(limit: 256 * 1024 * 1024))
        let w = 300, h = 260
        let source: CGImage
        if kind.hasPrefix("8-bit") {
            let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for y in 0..<h / 4 { for x in 0..<w / 4 {
                // Hard-edged high-contrast blocks: resampling them in encoded or linear space differs visibly.
                let on = (x + y) % 2 == 0
                context.setFillColor(CGColor(red: on ? 1 : 0.02, green: CGFloat(x % 7) / 6, blue: on ? 0 : 1, alpha: CGFloat(3 + y % 2) / 4))
                context.fill(CGRect(x: x * 4, y: y * 4, width: 4, height: 4))
            } }
            source = try #require(context.makeImage())
        } else {
            source = ProceduralImage.make(width: w, height: h) { x, y in
                SIMD4(Float((x * 7 + y * 3) % 97) / 30, Float((x + y * 5) % 89) / 70 - 0.35, Float(x % 61) / 61, 0.5 + Float((x / 9 + y / 7) % 5) / 8)
            }
        }
        var transform = LayerTransform(origin: CGPoint(x: 30, y: 25), size: CGSize(width: w, height: h))
        if kind.hasSuffix("rotated") { transform.rotation = 19; transform.origin = CGPoint(x: 41.5, y: 33.25) }
        if kind.hasSuffix("reduced") { transform.size = CGSize(width: 177, height: 151); transform.origin = CGPoint(x: 60.4, y: 47) }
        let id = UUID()
        var record = ProjectLayerRecord(id: id, name: "Raster", isVisible: true, transform: transform, imageFile: id.uuidString + ".png")
        record.blendMode = .normal
        let doc = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 420, height: 380, activeLayerID: id, layers: [record]),
            images: [id: ImportedImage(image: source, thumbnail: source, name: "fixture")], masks: [:])
        let made = try LWFloatCompositor.renderPlane(doc, workspace: workspace)
        // The path every raster took before: a float plane of the image, then placement of that plane.
        let reference = try LWFloatCompositor.place(LWFloatCompositor.from(source, workspace: workspace), transform: transform,
            width: 420, height: 380, workspace: workspace)
        var worst = 0.0
        try made.forEachTile { range in
            let a = try made.read(range: range), b = try reference.read(range: range)
            for (p, e) in zip(a.surface.pixels, b.surface.pixels) {
                for c in 0..<4 { worst = max(worst, Double(abs(p[c] - e[c])) / max(1, Double(abs(e[c])))) }
            }
        }
        #expect(worst <= Self.contract.raster_fast_path_relative, "\(kind): worst \(worst)")
        print("S09 raster placement \(kind): worst \(worst)")
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

    /// Values above the screen's EDR headroom saturate at it (as the display clips them, and inside half float's
    /// range); values below it, and negative components, are untouched.
    @Test func displayConversionSaturatesAtTheScreenHeadroom() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let lin = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let samples: [SIMD4<Float>] = [SIMD4(4, 1.5, -0.05, 1), SIMD4(1e6, 0.5, 0.25, 1)]
        let image = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: samples.count * 16,
            size: CGSize(width: samples.count, height: 1), format: .RGBAf, colorSpace: lin)
        let texture = try #require(renderer.displayTexture(width: samples.count, height: 1))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.render(image, to: texture, commandBuffer: buffer, size: CGSize(width: samples.count, height: 1), target: .extendedSRGB, headroom: 2)
        buffer.commit(); buffer.waitUntilCompleted()
        var halves = [Float16](repeating: 0, count: samples.count * 4)
        halves.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: samples.count * 8,
            from: MTLRegionMake2D(0, 0, samples.count, 1), mipmapLevel: 0) }
        let expected: [Double] = [ReferenceBlend.enc(2), ReferenceBlend.enc(1.5), ReferenceBlend.enc(-0.05), 1,
                                  ReferenceBlend.enc(2), ReferenceBlend.enc(0.5), ReferenceBlend.enc(0.25), 1]
        for (i, e) in expected.enumerated() {
            #expect(abs(Double(halves[i]) - e) <= Self.contract.display_conversion_relative * max(1, abs(e)), "component \(i): \(halves[i]) vs \(e)")
        }
        #expect(halves.allSatisfy { $0.isFinite })
    }

    /// Moving the canvas's window to another screen re-derives its display target even when the backing scale
    /// stays the same (no backing-property change is delivered then).
    @Test func canvasFollowsItsWindowsScreen() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView = view
        let expected = MetalCanvasView.target(for: window.screen)
        view.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(LWDisplayTarget(colorSpace: view.metalLayer.colorspace) == expected)
        #expect(view.headroom >= 1)
        window.contentView = nil
    }

    @Test func canvasDrawableIsExtendedHalfFloat() {
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(view.metalLayer.pixelFormat == .rgba16Float)
        #expect(view.metalLayer.wantsExtendedDynamicRangeContent)
        #expect(LWDisplayTarget(colorSpace: view.metalLayer.colorspace) != nil)
    }
}
