import Foundation
import Accelerate

/// Every retained layer blend mode evaluated directly on straight extended-linear float samples.
///
/// Core Image's blend kernels clamp their operands and results to [0, 1] (Multiply of 2.5 over 0.6
/// returns 1; Darken of -0.2 returns 0), so they cannot carry RAW latitude through the layer graph.
/// This kernel keeps the editor's blend definition — the separable and non-separable formulas of
/// the W3C Compositing specification plus Photoshop's linear/light/hard-mix/subtract/divide modes,
/// computed in sign-mirrored encoded sRGB and composited with the general source-over equation —
/// and reproduces Core Image for operands inside [0, 1]. Outside [0, 1]:
///
/// - Arithmetic modes (Normal, Multiply, Screen, Darken, Lighten, Overlay, Hard/Soft Light,
///   Pin Light, Difference, Exclusion) are evaluated unclamped.
/// - Modes whose definition saturates (Color Burn/Dodge, Linear Burn/Dodge/Light, Vivid Light,
///   Hard Mix, Subtract, Divide, and the ClipColor step of Hue/Saturation/Color/Luminosity)
///   saturate to the union of the display range and the operands' own range,
///   `[min(0, b, s), max(1, b, s)]`, rather than to [0, 1]. In range this is exactly the
///   specified clamp; an HDR or negative operand is never pulled back inside [0, 1].
///
/// The operator is pointwise, so any tiling of the frame gives the same samples as a whole-frame
/// evaluation. Fully transparent sources and empty backdrops pass the other operand through
/// without a transfer round trip, so untouched samples keep their exact bits.
nonisolated enum LWFloatBlend {
    /// Results are kept finite; a formula can only exceed this from operands already near the
    /// float range, where the plane would otherwise refuse a non-finite sample.
    static let finiteLimit = Float.greatestFiniteMagnitude

    // MARK: Separable modes

    @inline(__always) static func separable(_ mode: LayerBlendMode, _ b: Float, _ s: Float) -> Float {
        let lo = min(0, b, s), hi = max(1, b, s)
        @inline(__always) func burn(_ b: Float, _ s: Float) -> Float {
            if b >= 1 { return b }
            if s <= 0 { return lo }
            return max(lo, 1 - (1 - b) / s)
        }
        @inline(__always) func dodge(_ b: Float, _ s: Float) -> Float {
            if b <= 0 { return b }
            if s >= 1 { return hi }
            return min(hi, b / (1 - s))
        }
        @inline(__always) func hardLight(_ b: Float, _ s: Float) -> Float {
            if s <= 0.5 { return b * 2 * s }
            let t = 2 * s - 1; return b + t - b * t
        }
        switch mode {
        case .normal: return s
        case .darken: return min(b, s)
        case .lighten: return max(b, s)
        case .multiply: return b * s
        case .screen: return b + s - b * s
        case .colorBurn: return burn(b, s)
        case .colorDodge: return dodge(b, s)
        case .linearBurn: return max(lo, b + s - 1)
        case .linearDodge: return min(hi, b + s)
        case .hardLight: return hardLight(b, s)
        case .overlay: return hardLight(s, b)
        case .softLight:
            if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return b + (2 * s - 1) * (d - b)
        case .vividLight: return s <= 0.5 ? burn(b, 2 * s) : dodge(b, 2 * s - 1)
        case .linearLight: return min(hi, max(lo, b + 2 * s - 1))
        case .pinLight: return s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1)
        case .hardMix: return b + s >= 1 ? hi : lo
        case .difference: return abs(b - s)
        case .exclusion: return b + s - 2 * b * s
        case .subtract: return max(lo, b - s)
        case .divide:
            if s > 0 { return min(hi, b / s) }
            return b > 0 ? hi : (b < 0 ? lo : 0)
        case .hue, .saturation, .color, .luminosity: return s // non-separable; handled by `mix`
        }
    }

    // MARK: Non-separable modes

    @inline(__always) private static func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }
    @inline(__always) private static func clip(_ c: SIMD3<Float>, lo: Float, hi: Float) -> SIMD3<Float> {
        let l = lum(c), n = c.min(), x = c.max(), lv = SIMD3(repeating: l)
        var r = c
        if n < lo, l > lo { r = lv + (r - lv) * ((l - lo) / (l - n)) }
        if x > hi, l < hi { r = lv + (r - lv) * ((hi - l) / (x - l)) }
        return r
    }
    @inline(__always) private static func setLum(_ c: SIMD3<Float>, _ l: Float, lo: Float, hi: Float) -> SIMD3<Float> {
        clip(c + SIMD3(repeating: l - lum(c)), lo: lo, hi: hi)
    }
    @inline(__always) private static func sat(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }
    @inline(__always) private static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let n = c.min(), x = c.max()
        guard x > n else { return .zero }
        return (c - SIMD3(repeating: n)) * (s / (x - n))
    }

    /// `B(Cb, Cs)` for one pixel, both encoded.
    @inline(__always) static func mix(_ mode: LayerBlendMode, backdrop b: SIMD3<Float>, source s: SIMD3<Float>) -> SIMD3<Float> {
        switch mode {
        case .hue, .saturation, .color, .luminosity:
            let lo = min(0, b.min(), s.min()), hi = max(1, b.max(), s.max())
            switch mode {
            case .hue: return setLum(setSat(s, sat(b)), lum(b), lo: lo, hi: hi)
            case .saturation: return setLum(setSat(b, sat(s)), lum(b), lo: lo, hi: hi)
            case .color: return setLum(s, lum(b), lo: lo, hi: hi)
            default: return setLum(b, lum(s), lo: lo, hi: hi)
            }
        default:
            return SIMD3(separable(mode, b.x, s.x), separable(mode, b.y, s.y), separable(mode, b.z, s.z))
        }
    }

    /// One pixel: straight extended-linear `top` over straight extended-linear `bottom`. The same
    /// evaluation as `blend(_:over:mode:into:)`, so a pixel and a buffer agree bit for bit.
    static func pixel(_ mode: LayerBlendMode, top: SIMD4<Float>, bottom: SIMD4<Float>) -> SIMD4<Float> {
        var t = top, b = bottom, result = SIMD4<Float>.zero
        withUnsafePointer(to: &t) { tp in withUnsafePointer(to: &b) { bp in withUnsafeMutablePointer(to: &result) { rp in
            blend(UnsafeBufferPointer(start: tp, count: 1), over: UnsafeBufferPointer(start: bp, count: 1), mode: mode,
                  into: UnsafeMutableBufferPointer(start: rp, count: 1))
        } } }
        return result
    }

    @inline(__always) private static func finite(_ v: Float) -> Float { v.isNaN ? 0 : min(finiteLimit, max(-finiteLimit, v)) }

    @inline(__always) private static func passthrough(_ mode: LayerBlendMode, top: SIMD4<Float>, bottom: SIMD4<Float>) -> SIMD4<Float>? {
        if top.w <= 0, bottom.w <= 0 { return .zero }
        if top.w <= 0 { return bottom }
        if bottom.w <= 0 || (mode == .normal && top.w >= 1) { return top }
        return nil
    }

    /// Whole buffers, for range-aligned pairs of tiles. Transfer functions run through vForce;
    /// the result equals `pixel` applied to every index.
    static func blend(_ top: UnsafeBufferPointer<SIMD4<Float>>, over bottom: UnsafeBufferPointer<SIMD4<Float>>,
        mode: LayerBlendMode, into output: UnsafeMutableBufferPointer<SIMD4<Float>>) {
        precondition(top.count == bottom.count && output.count == top.count)
        var pending = [Int](); pending.reserveCapacity(top.count)
        for i in 0..<top.count {
            if let exact = passthrough(mode, top: top[i], bottom: bottom[i]) { output[i] = exact } else { pending.append(i) }
        }
        guard !pending.isEmpty else { return }
        let n = pending.count
        // Six magnitudes per pixel (top rgb, bottom rgb) for one vvpowf call.
        var magnitude = [Float](repeating: 0, count: n * 6)
        for (k, i) in pending.enumerated() {
            let t = top[i], u = bottom[i]
            magnitude[k * 6] = abs(t.x); magnitude[k * 6 + 1] = abs(t.y); magnitude[k * 6 + 2] = abs(t.z)
            magnitude[k * 6 + 3] = abs(u.x); magnitude[k * 6 + 4] = abs(u.y); magnitude[k * 6 + 5] = abs(u.z)
        }
        var powered = [Float](repeating: 0, count: n * 6), exponent = [Float](repeating: 1 / 2.4, count: n * 6)
        var count = Int32(n * 6)
        vvpowf(&powered, &exponent, &magnitude, &count)
        func encoded(_ index: Int, _ signed: Float) -> Float {
            let a = magnitude[index], y = a <= 0.0031308 ? a * 12.92 : 1.055 * powered[index] - 0.055
            return signed < 0 ? -y : y
        }
        var mixed = [Float](repeating: 0, count: n * 3)
        for (k, i) in pending.enumerated() {
            let t = top[i], u = bottom[i], ao = t.w + u.w * (1 - t.w)
            let cs = SIMD3(encoded(k * 6, t.x), encoded(k * 6 + 1, t.y), encoded(k * 6 + 2, t.z))
            let cb = SIMD3(encoded(k * 6 + 3, u.x), encoded(k * 6 + 4, u.y), encoded(k * 6 + 5, u.z))
            let co = (cs * (t.w * (1 - u.w)) + mix(mode, backdrop: cb, source: cs) * (t.w * u.w) + cb * ((1 - t.w) * u.w)) / ao
            mixed[k * 3] = co.x; mixed[k * 3 + 1] = co.y; mixed[k * 3 + 2] = co.z
        }
        var base = mixed.map { (abs($0) + 0.055) / 1.055 }, decodeExponent = [Float](repeating: 2.4, count: n * 3)
        var decoded = [Float](repeating: 0, count: n * 3); count = Int32(n * 3)
        vvpowf(&decoded, &decodeExponent, &base, &count)
        for (k, i) in pending.enumerated() {
            var value = SIMD4<Float>.zero
            for c in 0..<3 {
                let e = mixed[k * 3 + c], a = abs(e), y = a <= 0.04045 ? a / 12.92 : decoded[k * 3 + c]
                value[c] = finite(e < 0 ? -y : y)
            }
            value.w = min(1, max(0, top[i].w + bottom[i].w * (1 - top[i].w)))
            output[i] = value
        }
    }
}
