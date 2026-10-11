import Foundation
import CoreImage
import CoreGraphics

/// Retained Camera Raw math on straight, linear-sRGB float pixels. Only selection weights and
/// slider domains are bounded; RGB is never rounded to bytes or clipped to the display gamut.
nonisolated enum FloatImageAdjustmentPixels {
    typealias RGB = SIMD3<Double>
    static func unit(_ x: Double) -> Double { min(1, max(0, x)) }
    static func encode(_ x: Double) -> Double {
        let a = abs(x)
        let y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -y : y
    }
    static func decode(_ x: Double) -> Double {
        let a = abs(x)
        let y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -y : y
    }
    static func luminance(_ c: RGB) -> Double { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
    static func scaleLuminance(_ c: RGB, to target: Double) -> RGB {
        let y = luminance(c)
        if target == y { return c }
        // The signed float extension scales negative luminance too. Only true neutral black
        // needs an additive lift; do not replace finite negative RGB with black.
        if y == 0 { return c + RGB(repeating: target) }
        return c * (target / y)
    }
    static func checkedBytes(count: Int, bytesPerPixel: Int, maximumBytes: Int) throws {
        let bytes = count.multipliedReportingOverflow(by: bytesPerPixel)
        guard count > 0, bytesPerPixel > 0, !bytes.overflow, bytes.partialValue <= maximumBytes else {
            throw ProjectError.invalid
        }
    }
    static func mapPixels(_ surface: LWLinearSurface, retainedBytes: Int = 0,
                          _ operation: (RGB, Int, Int) throws -> RGB) throws -> LWLinearSurface {
        let sum = surface.byteLength.multipliedReportingOverflow(by: 2)
        let peak = sum.partialValue.addingReportingOverflow(retainedBytes)
        guard !sum.overflow, !peak.overflow, peak.partialValue <= surface.maximumBytes else { throw ProjectError.invalid }
        var pixels = surface.pixels
        for i in pixels.indices where pixels[i].w > 0 {
            let p = pixels[i]
            let c = try operation(RGB(Double(p.x), Double(p.y), Double(p.z)), i % surface.width, i / surface.width)
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { throw ProjectError.invalid }
            let result = SIMD4(Float(c.x), Float(c.y), Float(c.z), p.w)
            guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { throw ProjectError.invalid }
            pixels[i] = result
        }
        return try LWLinearSurface(width: surface.width, height: surface.height, pixels: pixels, maximumBytes: surface.maximumBytes)
    }
    /// Circular hue, saturation, lightness on a normalized color envelope. Unit-gamut samples
    /// use the retained HSL equations exactly. Out-of-gamut samples keep a reversible offset
    /// and scale, so a hue/saturation adjustment cannot implicitly discard HDR or negative RGB.
    struct ColorEnvelope {
        let offset: Double
        let scale: Double
        var h: Double
        var s: Double
        var l: Double
        init(_ c: RGB) {
            offset = min(0, min(c.x, min(c.y, c.z)))
            scale = max(1, max(c.x, max(c.y, c.z))) - offset
            let n = (c - RGB(repeating: offset)) / scale
            let high = max(n.x, max(n.y, n.z)), low = min(n.x, min(n.y, n.z)), d = high - low
            l = (high + low) / 2
            if d == 0 { h = 0; s = 0; return }
            s = d / (1 - abs(2 * l - 1))
            if high == n.x { h = (n.y - n.z) / d }
            else if high == n.y { h = (n.z - n.x) / d + 2 }
            else { h = (n.x - n.y) / d + 4 }
            h = FloatImageAdjustmentPixels.wrap(h / 6)
        }
        func rgb() -> RGB { FloatImageAdjustmentPixels.hsl(h, s, l) * scale + RGB(repeating: offset) }
    }
    static func wrap(_ x: Double) -> Double { x - floor(x) }
    static func hueDistance(_ a: Double, _ b: Double) -> Double { let d = abs(wrap(a) - wrap(b)); return min(d, 1 - d) }
    static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> RGB {
        let h = wrap(hue) * 6
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let c: RGB
        switch Int(floor(h)) {
        case 0: c = RGB(chroma, x, 0)
        case 1: c = RGB(x, chroma, 0)
        case 2: c = RGB(0, chroma, x)
        case 3: c = RGB(0, x, chroma)
        case 4: c = RGB(x, 0, chroma)
        default: c = RGB(chroma, 0, x)
        }
        return c + RGB(repeating: lightness - chroma / 2)
    }
    /// Shape-preserving Hermite points without a byte LUT. Endpoint secants provide a
    /// continuous linear extension for negative/HDR inputs instead of endpoint clipping.
    static func curve(_ x: Double, points: [CurvePoint]) -> Double {
        if points == CameraRawCurveSettings.linear { return x }
        let last = points.count - 1
        func secant(_ i: Int) -> Double { (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x) }
        func slope(_ j: Int) -> Double {
            if j == 0 { return secant(0) }
            if j == last { return secant(last - 1) }
            let a = secant(j - 1), b = secant(j)
            return a * b <= 0 ? 0 : 2 / (1 / a + 1 / b)
        }
        if x < points[0].x { return points[0].y + (x - points[0].x) * slope(0) }
        if x > points[last].x { return points[last].y + (x - points[last].x) * slope(last) }
        let i = min(last - 1, max(0, points.lastIndex(where: { $0.x <= x }) ?? 0))
        let extent = points[i + 1].x - points[i].x, t = (x - points[i].x) / extent
        return (2*t*t*t - 3*t*t + 1)*points[i].y + (t*t*t - 2*t*t + t)*extent*slope(i)
            + (-2*t*t*t + 3*t*t)*points[i + 1].y + (t*t*t - t*t)*extent*slope(i + 1)
    }
    static func parametricAnchors(_ s: CameraRawCurveSettings) -> [CurvePoint] {
        func bend(_ x: Double, lower: Double, low: Double, upper: Double, high: Double) -> Double {
            if x < lower { return lower * pow(x / lower, pow(2, -low / 100 * 1.66)) }
            if x > upper { return 1 - (1 - upper) * pow((1 - x) / (1 - upper), pow(2, high / 100 * 1.66)) }
            return x
        }
        return (0...32).map { i in
            let x = Double(i) / 32
            let y = bend(x, lower: s.shadowSplit / 100, low: s.shadows, upper: s.lightSplit / 100, high: s.highlights)
            return CurvePoint(x: x, y: bend(y, lower: s.darkSplit / 100, low: s.darks, upper: s.darkSplit / 100, high: s.lights))
        }
    }
    /// Separable edge-clamped box blur, matching the retained CPU kernel's radius policy.
    /// Caller admits the two simultaneous Double planes before either allocation.
    static func blur(_ source: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        let radius = min(64, max(1, radius)), size = Double(2 * radius + 1)
        var horizontal = [Double](repeating: 0, count: source.count)
        for y in 0..<height {
            var sum = 0.0
            for dx in -radius...radius { sum += source[y*width + min(width - 1, max(0, dx))] }
            for x in 0..<width {
                horizontal[y*width + x] = sum / size
                sum += source[y*width + min(width - 1, x + radius + 1)] - source[y*width + max(0, x - radius)]
            }
        }
        var output = [Double](repeating: 0, count: source.count)
        for x in 0..<width {
            var sum = 0.0
            for dy in -radius...radius { sum += horizontal[min(height - 1, max(0, dy))*width + x] }
            for y in 0..<height {
                output[y*width + x] = sum / size
                sum += horizontal[min(height - 1, y + radius + 1)*width + x] - horizontal[max(0, y - radius)*width + x]
            }
        }
        return output
    }
    static func edge(_ plane: [Double], width: Int, height: Int, x: Int, y: Int, radius: Int) -> Double {
        let radius = max(1, radius), center = plane[y*width + x]
        var sum = 0.0, count = 0
        for dy in stride(from: -radius, through: radius, by: radius) {
            for dx in stride(from: -radius, through: radius, by: radius) where dx != 0 || dy != 0 {
                let sx = x + dx, sy = y + dy
                if sx >= 0 && sy >= 0 && sx < width && sy < height { sum += abs(plane[sy*width + sx] - center); count += 1 }
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }
    static func mix32(_ x: UInt32) -> UInt32 {
        var x = x; x ^= x >> 16; x = x &* 0x7feb352d; x ^= x >> 15; x = x &* 0x846ca68b; x ^= x >> 16; return x
    }
    static func lattice(_ x: Int, _ y: Int, seed: UInt32) -> Double {
        let h = mix32(UInt32(truncatingIfNeeded: x) &* 0x9e3779b1 ^ mix32(UInt32(truncatingIfNeeded: y) &* 0x85ebca77 ^ seed))
        return Double(h & 65535) / 65535 + Double(h >> 16) / 65535 - 1
    }
    static func grain(_ x: Double, _ y: Double, size: Double, seed: UInt32) throws -> Double {
        guard x.isFinite, y.isFinite, size.isFinite, size > 0 else { throw ProjectError.invalid }
        let u = x / size, v = y / size
        guard u.isFinite, v.isFinite, floor(u) >= Double(Int.min), floor(v) >= Double(Int.min),
              floor(u) < Double(Int.max), floor(v) < Double(Int.max) else { throw ProjectError.invalid }
        let ix = Int(floor(u)), iy = Int(floor(v))
        let tx = u - floor(u), ty = v - floor(v), a = tx*tx*(3 - 2*tx), b = ty*ty*(3 - 2*ty)
        let upper = lattice(ix, iy, seed: seed)*(1 - a) + lattice(ix + 1, iy, seed: seed)*a
        let lower = lattice(ix, iy + 1, seed: seed)*(1 - a) + lattice(ix + 1, iy + 1, seed: seed)*a
        return (upper*(1 - b) + lower*b)*1.6
    }
    /// Bilinear interpolation in premultiplied linear light, returned as straight alpha.
    static func sample(_ s: LWLinearSurface, x: Double, y: Double, clamped: Bool = false) -> SIMD4<Float> {
        guard x.isFinite, y.isFinite else { return .zero }
        if !clamped && (x <= -1 || y <= -1 || x >= Double(s.width) || y >= Double(s.height)) { return .zero }
        let x = clamped ? min(Double(s.width - 1), max(0, x)) : x
        let y = clamped ? min(Double(s.height - 1), max(0, y)) : y
        let ix = Int(floor(x)), iy = Int(floor(y)), tx = x - Double(ix), ty = y - Double(iy)
        var color = RGB.zero, alpha = 0.0
        for dy in 0...1 {
            for dx in 0...1 {
                let sx = ix + dx, sy = iy + dy
                guard sx >= 0, sy >= 0, sx < s.width, sy < s.height else { continue }
                let weight = (dx == 0 ? 1 - tx : tx)*(dy == 0 ? 1 - ty : ty)
                let p = s.pixels[sy*s.width + sx], coverage = Double(p.w)*weight
                color += RGB(Double(p.x), Double(p.y), Double(p.z))*coverage; alpha += coverage
            }
        }
        guard alpha > 0 else { return .zero }
        color /= alpha
        return SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(unit(alpha)))
    }
}

nonisolated extension LayerAdjustment {
    /// All retained adjustment-layer kinds, operating on full float samples. Display conversion
    /// happens only after the graph, never between persisted adjustment nodes.
    func apply(_ surface: LWLinearSurface, region: CGRect? = nil, scale: CGFloat = 1) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        try surface.validate(maximumBytes: surface.maximumBytes)
        guard isValid, scale.isFinite, scale > 0 else { throw ProjectError.invalid }
        let region = region ?? CGRect(x: 0, y: 0, width: surface.width, height: surface.height)
        guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite), region.width > 0, region.height > 0 else { throw ProjectError.invalid }
        let units = Double(region.width)/Double(surface.width)
        guard Double(region.minX) > Double(Int64.min), Double(region.minY) > Double(Int64.min),
              Double(region.maxX) < Double(Int64.max), Double(region.maxY) < Double(Int64.max) else { throw ProjectError.invalid }
        if kind == .addNoise {
            let ox = Double(region.minX)/units, oy = Double(region.minY)/units
            guard ox.isFinite, oy.isFinite, floor(ox) > Double(Int64.min), floor(oy) > Double(Int64.min),
                  floor(ox) + Double(surface.width) < Double(Int64.max), floor(oy) + Double(surface.height) < Double(Int64.max) else { throw ProjectError.invalid }
        }
        switch kind {
        case .hsv where resolvedHSV.isIdentity: return surface
        case .levels where levels.isIdentity: return surface
        case .curves where curves.channels.allSatisfy({ $0 == CurvesSettings().channels[0] }): return surface
        case .exposure where exposure == ExposureSettings(): return surface
        case .colorBalance where colorBalance.isIdentity: return surface
        case .grain where grain.amount == 0: return surface
        case .gaussianBlur, .motionBlur:
            // Same retained Core Image operators, with RGBAf working/output format and a full
            // float provider. Admit source/provider/result/output extents before conversion.
            try K.checkedBytes(count: surface.pixels.count, bytesPerPixel: 80, maximumBytes: surface.maximumBytes)
            guard let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw ProjectError.invalid }
            let input = CIImage(cgImage: try surface.premultipliedCGImage(), options: [.colorSpace: color])
            let extent = CGRect(x: 0, y: 0, width: surface.width, height: surface.height)
            let edges = input.clampedToExtent()
            let result: CIImage
            if kind == .gaussianBlur { result = edges.applyingGaussianBlur(sigma: gaussianRadius * Double(scale)) }
            else { result = edges.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: resolvedMotionDistance * Double(scale) * PixelFilter.motionRadiusPerPixel, kCIInputAngleKey: resolvedMotionAngle * .pi / 180]) }
            return try LWLinearSurface.render(result.cropped(to: extent), width: surface.width, height: surface.height, maximumBytes: surface.maximumBytes)
        default: break
        }
        return try K.mapPixels(surface) { linear, x, y in
            if kind == .exposure {
                let value = linear*exp2(exposure.exposure) + K.RGB(repeating: exposure.offset)
                func gamma(_ x: Double) -> Double { let value = pow(abs(x), 1/exposure.gamma); return x < 0 ? -value : value }
                return K.RGB(gamma(value.x), gamma(value.y), gamma(value.z))
            }
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            switch kind {
            case .hsv:
                let s = resolvedHSV
                var e = K.ColorEnvelope(c)
                if s.colorize { e.h = K.wrap(s.hue/360); e.s = K.unit(s.saturation/100) }
                else {
                    var hue = 0.0, sat = 0.0
                    for range in ColorRange.allCases {
                        let a = s.adjustments[range] ?? RangeAdjustment(), w = s.weight(of: range, hue: e.h*360)
                        hue += a.hue*w; sat += a.saturation*w
                    }
                    e.h = K.wrap(e.h + hue/360); e.s = HueSaturationFilter.adjustedSaturation(e.s, by: sat)
                }
                var light = s.colorize ? s.lightness/100 : 0
                if !s.colorize {
                    let originalHue = K.ColorEnvelope(c).h*360
                    for range in ColorRange.allCases { light += (s.adjustments[range]?.lightness ?? 0)*s.weight(of: range, hue: originalHue)/100 }
                }
                light = min(1, max(-1, light)); e.l = light >= 0 ? e.l + (1 - e.l)*light : e.l*(1 + light); c = e.rgb()
            case .levels:
                let channels: [LevelsChannel] = [.red, .green, .blue]
                for i in 0..<3 { c[i] = levels.apply(c[i], channel: channels[i]) }
            case .curves:
                for i in 0..<3 {
                    let channel = curves.channels[i + 1].map { CurvePoint(x: $0.x/255, y: $0.y/255) }
                    let composite = curves.channels[0].map { CurvePoint(x: $0.x/255, y: $0.y/255) }
                    c[i] = K.curve(K.curve(c[i], points: channel), points: composite)
                }
            case .invert: c = K.RGB(repeating: 1) - c
            case .gradientMap:
                let ends = gradientMap.ends, t = K.luminance(c)
                let dark = K.RGB(ends.dark.red, ends.dark.green, ends.dark.blue), light = K.RGB(ends.light.red, ends.light.green, ends.light.blue)
                c = dark + (light - dark)*t
            case .blackWhite:
                let s = blackWhite, high = max(c.x, max(c.y, c.z)), low = min(c.x, min(c.y, c.z)), middle = c.x + c.y + c.z - high - low
                let primary: Double, secondary: Double
                if high == c.x { primary = s.reds; secondary = c.y >= c.z ? s.yellows : s.magentas }
                else if high == c.y { primary = s.greens; secondary = c.x >= c.z ? s.yellows : s.cyans }
                else { primary = s.blues; secondary = c.y >= c.x ? s.cyans : s.magentas }
                let gray = low + (middle - low)*secondary/100 + (high - middle)*primary/100
                c = K.RGB(repeating: gray)
                if s.tint {
                    var e = K.ColorEnvelope(c); e.h = s.tintHue/360; e.s = s.tintSaturation/100; c = e.rgb()
                }
            case .colorBalance:
                let s = colorBalance
                let shadows = K.RGB(s.shadowCyanRed, s.shadowMagentaGreen, s.shadowYellowBlue)/100
                let midtones = K.RGB(s.midCyanRed, s.midMagentaGreen, s.midYellowBlue)/100
                let highlights = K.RGB(s.highlightCyanRed, s.highlightMagentaGreen, s.highlightYellowBlue)/100
                let before = c.x*0.299 + c.y*0.587 + c.z*0.114
                for i in 0..<3 {
                    let v = c[i], shadow = K.unit((v - 0.333)/(-0.25) + 0.5)*0.7
                    let highlight = K.unit((v + 0.333 - 1)/0.25 + 0.5)*0.7
                    let mid = K.unit((v - 0.333)/0.25 + 0.5)*K.unit((v + 0.333 - 1)/(-0.25) + 0.5)*0.7
                    c[i] += shadows[i]*shadow + midtones[i]*mid + highlights[i]*highlight
                }
                if s.preserveLuminosity { let after = c.x*0.299 + c.y*0.587 + c.z*0.114; if after != 0 { c *= before/after } }
            case .grain:
                let s = grain, gx = Double(region.minX) + (Double(x) + 0.5)*units, gy = Double(region.minY) + (Double(y) + 0.5)*units
                let smooth = try K.grain(gx, gy, size: s.size, seed: s.seed)
                let fine = try K.grain(gx, gy, size: max(0.5, s.size*0.35), seed: K.mix32(s.seed ^ 0xa511e9b3))
                let noise = smooth + (fine - smooth)*s.roughness/100, level = K.unit(K.luminance(c))
                c += K.RGB(repeating: noise*s.amount/100*0.35*(0.4 + 2.4*level*(1 - level)))
            case .addNoise:
                let px = UInt32(truncatingIfNeeded: Int64(floor(Double(region.minX)/units)) + Int64(x))
                let py = UInt32(truncatingIfNeeded: Int64(floor(Double(region.minY)/units)) + Int64(y))
                let base = K.mix32(resolvedNoiseSeed ^ K.mix32(px &* 0x9e3779b9 ^ K.mix32(py &* 0x85ebca6b)))
                func unit(_ key: UInt32) -> Double { Double(K.mix32(key) >> 8)/16777216 }
                for i in 0..<3 {
                    let key = resolvedNoiseMonochromatic ? base : base &+ UInt32(i) &* 0x9e3779b9
                    let n = resolvedNoiseGaussian ? sqrt(-2*log(1 - unit(key)))*cos(6.2831853*unit(key ^ 0x68e31da4))*(2.0/3) : unit(key)*2 - 1
                    c[i] += n*resolvedNoiseAmount/100*0.5
                }
            case .exposure, .gaussianBlur, .motionBlur: throw ProjectError.invalid // dispatched above
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
}

nonisolated extension LayerAdjustment {
    /// All retained adjustment-layer kinds, operating on full float samples. Display conversion
    /// happens only after the graph, never between persisted adjustment nodes.
    func apply(_ plane: LWFloatPlane, region: CGRect? = nil, scale: CGFloat = 1,
               makeBuilder: @escaping (Int, Int) throws -> LWFloatPlane.Builder,
               makeScratchDirectory: @escaping () throws -> URL, fileOwner: LWFloatWorkspace? = nil) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        try LWFloatPlane.validateExtent(width: plane.width, height: plane.height)
        try Task.checkCancellation()
        let workspace = LWFloatKernelWorkspace(makeBuilder: makeBuilder, makeScratchDirectory: makeScratchDirectory, fileOwner: fileOwner)
        guard isValid, scale.isFinite, scale > 0 else { throw ProjectError.invalid }
        let region = region ?? CGRect(x: 0, y: 0, width: plane.width, height: plane.height)
        guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite), region.width > 0, region.height > 0 else { throw ProjectError.invalid }
        let units = Double(region.width)/Double(plane.width)
        guard Double(region.minX) > Double(Int64.min), Double(region.minY) > Double(Int64.min),
              Double(region.maxX) < Double(Int64.max), Double(region.maxY) < Double(Int64.max) else { throw ProjectError.invalid }
        if kind == .addNoise {
            let ox = Double(region.minX)/units, oy = Double(region.minY)/units
            guard ox.isFinite, oy.isFinite, floor(ox) > Double(Int64.min), floor(oy) > Double(Int64.min),
                  floor(ox) + Double(plane.width) < Double(Int64.max), floor(oy) + Double(plane.height) < Double(Int64.max) else { throw ProjectError.invalid }
        }
        switch kind {
        case .hsv where resolvedHSV.isIdentity: return plane
        case .levels where levels.isIdentity: return plane
        case .curves where curves.channels.allSatisfy({ $0 == CurvesSettings().channels[0] }): return plane
        case .exposure where exposure == ExposureSettings(): return plane
        case .colorBalance where colorBalance.isIdentity: return plane
        case .grain where grain.amount == 0: return plane
        case .gaussianBlur, .motionBlur:
            return try workspace.coreImage(plane, gaussianSigma: kind == .gaussianBlur ? gaussianRadius * Double(scale) : nil,
                motionRadius: resolvedMotionDistance * Double(scale) * PixelFilter.motionRadiusPerPixel,
                motionAngle: resolvedMotionAngle * .pi / 180)
        default: break
        }
        return try workspace.rgb(plane) { linear, x, y in
            if kind == .exposure {
                let value = linear*exp2(exposure.exposure) + K.RGB(repeating: exposure.offset)
                func gamma(_ x: Double) -> Double { let value = pow(abs(x), 1/exposure.gamma); return x < 0 ? -value : value }
                return K.RGB(gamma(value.x), gamma(value.y), gamma(value.z))
            }
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            switch kind {
            case .hsv:
                let s = resolvedHSV
                var e = K.ColorEnvelope(c)
                if s.colorize { e.h = K.wrap(s.hue/360); e.s = K.unit(s.saturation/100) }
                else {
                    var hue = 0.0, sat = 0.0
                    for range in ColorRange.allCases {
                        let a = s.adjustments[range] ?? RangeAdjustment(), w = s.weight(of: range, hue: e.h*360)
                        hue += a.hue*w; sat += a.saturation*w
                    }
                    e.h = K.wrap(e.h + hue/360); e.s = HueSaturationFilter.adjustedSaturation(e.s, by: sat)
                }
                var light = s.colorize ? s.lightness/100 : 0
                if !s.colorize {
                    let originalHue = K.ColorEnvelope(c).h*360
                    for range in ColorRange.allCases { light += (s.adjustments[range]?.lightness ?? 0)*s.weight(of: range, hue: originalHue)/100 }
                }
                light = min(1, max(-1, light)); e.l = light >= 0 ? e.l + (1 - e.l)*light : e.l*(1 + light); c = e.rgb()
            case .levels:
                let channels: [LevelsChannel] = [.red, .green, .blue]
                for i in 0..<3 { c[i] = levels.apply(c[i], channel: channels[i]) }
            case .curves:
                for i in 0..<3 {
                    let channel = curves.channels[i + 1].map { CurvePoint(x: $0.x/255, y: $0.y/255) }
                    let composite = curves.channels[0].map { CurvePoint(x: $0.x/255, y: $0.y/255) }
                    c[i] = K.curve(K.curve(c[i], points: channel), points: composite)
                }
            case .invert: c = K.RGB(repeating: 1) - c
            case .gradientMap:
                let ends = gradientMap.ends, t = K.luminance(c)
                let dark = K.RGB(ends.dark.red, ends.dark.green, ends.dark.blue), light = K.RGB(ends.light.red, ends.light.green, ends.light.blue)
                c = dark + (light - dark)*t
            case .blackWhite:
                let s = blackWhite, high = max(c.x, max(c.y, c.z)), low = min(c.x, min(c.y, c.z)), middle = c.x + c.y + c.z - high - low
                let primary: Double, secondary: Double
                if high == c.x { primary = s.reds; secondary = c.y >= c.z ? s.yellows : s.magentas }
                else if high == c.y { primary = s.greens; secondary = c.x >= c.z ? s.yellows : s.cyans }
                else { primary = s.blues; secondary = c.y >= c.x ? s.cyans : s.magentas }
                let gray = low + (middle - low)*secondary/100 + (high - middle)*primary/100
                c = K.RGB(repeating: gray)
                if s.tint {
                    var e = K.ColorEnvelope(c); e.h = s.tintHue/360; e.s = s.tintSaturation/100; c = e.rgb()
                }
            case .colorBalance:
                let s = colorBalance
                let shadows = K.RGB(s.shadowCyanRed, s.shadowMagentaGreen, s.shadowYellowBlue)/100
                let midtones = K.RGB(s.midCyanRed, s.midMagentaGreen, s.midYellowBlue)/100
                let highlights = K.RGB(s.highlightCyanRed, s.highlightMagentaGreen, s.highlightYellowBlue)/100
                let before = c.x*0.299 + c.y*0.587 + c.z*0.114
                for i in 0..<3 {
                    let v = c[i], shadow = K.unit((v - 0.333)/(-0.25) + 0.5)*0.7
                    let highlight = K.unit((v + 0.333 - 1)/0.25 + 0.5)*0.7
                    let mid = K.unit((v - 0.333)/0.25 + 0.5)*K.unit((v + 0.333 - 1)/(-0.25) + 0.5)*0.7
                    c[i] += shadows[i]*shadow + midtones[i]*mid + highlights[i]*highlight
                }
                if s.preserveLuminosity { let after = c.x*0.299 + c.y*0.587 + c.z*0.114; if after != 0 { c *= before/after } }
            case .grain:
                let s = grain, gx = Double(region.minX) + (Double(x) + 0.5)*units, gy = Double(region.minY) + (Double(y) + 0.5)*units
                let smooth = try K.grain(gx, gy, size: s.size, seed: s.seed)
                let fine = try K.grain(gx, gy, size: max(0.5, s.size*0.35), seed: K.mix32(s.seed ^ 0xa511e9b3))
                let noise = smooth + (fine - smooth)*s.roughness/100, level = K.unit(K.luminance(c))
                c += K.RGB(repeating: noise*s.amount/100*0.35*(0.4 + 2.4*level*(1 - level)))
            case .addNoise:
                let px = UInt32(truncatingIfNeeded: Int64(floor(Double(region.minX)/units)) + Int64(x))
                let py = UInt32(truncatingIfNeeded: Int64(floor(Double(region.minY)/units)) + Int64(y))
                let base = K.mix32(resolvedNoiseSeed ^ K.mix32(px &* 0x9e3779b9 ^ K.mix32(py &* 0x85ebca6b)))
                func unit(_ key: UInt32) -> Double { Double(K.mix32(key) >> 8)/16777216 }
                for i in 0..<3 {
                    let key = resolvedNoiseMonochromatic ? base : base &+ UInt32(i) &* 0x9e3779b9
                    let n = resolvedNoiseGaussian ? sqrt(-2*log(1 - unit(key)))*cos(6.2831853*unit(key ^ 0x68e31da4))*(2.0/3) : unit(key)*2 - 1
                    c[i] += n*resolvedNoiseAmount/100*0.5
                }
            case .exposure, .gaussianBlur, .motionBlur: throw ProjectError.invalid // dispatched above
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
}
