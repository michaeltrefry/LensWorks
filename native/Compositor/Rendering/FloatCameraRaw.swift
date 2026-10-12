import Foundation
import CoreGraphics

nonisolated extension CameraRawSettings {
    /// Complete retained development at source extent. Preview clipping, point-color visualization,
    /// and the sharpening-mask overlay remain transient UI views, not persisted development.
    func apply(_ surface: LWLinearSurface, seed: UInt32 = 0) throws -> LWLinearSurface {
        try develop(surface, seed: seed).surface
    }
    func develop(_ surface: LWLinearSurface, seed: UInt32 = 0) throws -> (surface: LWLinearSurface, map: LWSourceCoordinateMap) {
        try surface.validate(maximumBytes: surface.maximumBytes)
        try validateFloatControls()
        guard !isIdentity else { return (surface, .identity) }
        var result = surface
        let map = try geometry.coordinateMap(for: surface)
        if geometry.adjusts { result = try geometry.resample(surface, map: map) }
        let retained = surface.byteLength
        if calibration.adjusts { result = try floatCalibration(result, retainedBytes: retained) }
        if adjustsLight || adjustsColor { result = try floatLight(result, retainedBytes: retained) }
        if curve.adjusts || mixer.adjusts || grading.adjusts { result = try floatColor(result, retainedBytes: retained) }
        if adjustsEffects { result = try floatEffects(result, retainedBytes: retained, seed: seed) }
        if optics.adjusts { result = try floatOptics(result, retainedBytes: retained) }
        if detail.adjusts { result = try floatDetail(result, retainedBytes: retained) }
        try result.validate(maximumBytes: surface.maximumBytes)
        return (result, map)
    }
    /// Match existing normalized slider domains, but refuse malformed imported recipes rather
    /// than silently dropping a channel, point, guide, or nonfinite setting.
    func validateFloatControls() throws {
        guard isValid, self == normalized, mixer.hue.count == 8, mixer.saturation.count == 8,
              mixer.luminance.count == 8, mixer.points.count <= 8 else { throw ProjectError.invalid }
        for points in [curve.rgb, curve.red, curve.green, curve.blue] {
            guard points.count >= 2, points.first?.x == 0, points.last?.x == 1,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else { throw ProjectError.invalid }
        }
        for guide in geometry.guides {
            guard [guide.startX, guide.startY, guide.endX, guide.endY].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ProjectError.invalid
            }
        }
    }
    private func floatLight(_ surface: LWLinearSurface, retainedBytes: Int) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let gain = gains, ev = exp2(exposure)
        return try K.mapPixels(surface, retainedBytes: retainedBytes) { linear, _, _ in
            let exposed = linear * K.RGB(gain.red * ev, gain.green * ev, gain.blue * ev)
            // Exposure and white balance alone stay in linear light, including negative/HDR samples.
            if contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 && vibrance == 0 && saturation == 0 {
                return exposed
            }
            var c = K.RGB(K.encode(exposed.x), K.encode(exposed.y), K.encode(exposed.z))
            c = K.RGB(repeating: 0.5) + (c - K.RGB(repeating: 0.5)) * (1 + contrast / 100)
            var y = K.luminance(c)
            let hw = pow(K.unit((y - 0.5) / 0.5), 2), ha = highlights / 100
            y += ha * hw * (ha >= 0 ? 1 - y : y - 0.5)
            c = K.scaleLuminance(c, to: y)
            let sw = pow(K.unit((0.5 - y) / 0.5), 2), sa = shadows / 100
            y += sa * sw * (sa >= 0 ? 0.5 - y : y)
            c = K.scaleLuminance(c, to: y)
            if y > 0.75 { y = 0.75 + (y - 0.75) * (1 + whites / 100); c = K.scaleLuminance(c, to: y) }
            if y < 0.25 { y = 0.25 + (y - 0.25) * (1 - blacks / 100); c = K.scaleLuminance(c, to: y) }
            let envelope = K.ColorEnvelope(c)
            let n = (c - K.RGB(repeating: envelope.offset)) / envelope.scale
            let high = max(n.x, max(n.y, n.z)), low = min(n.x, min(n.y, n.z))
            let sat = high == 0 ? 0 : (high - low) / high
            let hue = envelope.h * 360
            var skin = 0.0
            if hue >= 10 && hue <= 50 { skin = (hue <= 30 ? (hue - 10) / 20 : (50 - hue) / 20) * K.unit((sat - 0.15) / 0.35) }
            var amount = vibrance / 100 * (1 - sat)
            if vibrance > 0 { amount *= 1 - 0.7 * skin }
            c = K.RGB(repeating: K.luminance(c)) + (c - K.RGB(repeating: K.luminance(c))) * (1 + amount)
            c = K.RGB(repeating: K.luminance(c)) + (c - K.RGB(repeating: K.luminance(c))) * (1 + saturation / 100)
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
    private func floatCalibration(_ surface: LWLinearSurface, retainedBytes: Int) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let s = calibration
        let response: [Double] = [0.55, 0.65, 0.75, 0.85, 0.92, 1]
        let scale = response[Int(s.process.kernelValue) - 1]
        return try K.mapPixels(surface, retainedBytes: retainedBytes) { linear, _, _ in
            let c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            var e = K.ColorEnvelope(c)
            if e.l < 0.35 { e.h += s.shadowTint / 100 * scale * 0.06 }
            if max(c.x, max(c.y, c.z)) != min(c.x, min(c.y, c.z)) {
                let hue: Double, saturation: Double
                if c.x >= c.y && c.x >= c.z { hue = s.redHue; saturation = s.redSaturation }
                else if c.y >= c.x && c.y >= c.z { hue = s.greenHue; saturation = s.greenSaturation }
                else { hue = s.blueHue; saturation = s.blueSaturation }
                e.h += hue / 100 * (15.0 / 360) * scale
                e.s = K.unit(e.s * (1 + saturation / 100 * 0.45 * scale))
            }
            let out = e.rgb()
            return K.RGB(K.decode(out.x), K.decode(out.y), K.decode(out.z))
        }
    }
    private func floatColor(_ surface: LWLinearSurface, retainedBytes: Int) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let anchors = K.parametricAnchors(curve)
        let parametric = curve.shadows != 0 || curve.darks != 0 || curve.lights != 0 || curve.highlights != 0
        return try K.mapPixels(surface, retainedBytes: retainedBytes) { linear, _, _ in
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            if curve.adjusts {
                func tone(_ x: Double) -> Double { K.curve(parametric ? K.curve(x, points: anchors) : x, points: curve.rgb) }
                let original = c
                c = K.RGB(tone(c.x), tone(c.y), tone(c.z))
                if curve.refineSaturation < 0 {
                    let brightnessOnly = K.scaleLuminance(original, to: tone(K.luminance(original)))
                    c += (brightnessOnly - c)*(-curve.refineSaturation / 100)
                } else if curve.refineSaturation > 0 {
                    let y = K.luminance(c), scale = 1 + curve.refineSaturation / 100
                    c = K.RGB(repeating: y) + (c - K.RGB(repeating: y)) * scale
                }
                c = K.RGB(K.curve(c.x, points: curve.red), K.curve(c.y, points: curve.green), K.curve(c.z, points: curve.blue))
            }
            if mixer.adjusts {
                var e = K.ColorEnvelope(c)
                var hue = 0.0, sat = 0.0, lum = 0.0, sum = 0.0
                for i in 0..<8 {
                    let weight = max(0, 1 - K.hueDistance(e.h, CameraRawMixerSettings.centers[i] / 360) / (40.0 / 360))
                    hue += mixer.hue[i] / 100 * weight * (30.0 / 360)
                    sat += mixer.saturation[i] / 100 * weight
                    lum += mixer.luminance[i] / 100 * weight * 0.25; sum += weight
                }
                if sum > 1 { hue /= sum; sat /= sum; lum /= sum }
                e.h = K.wrap(e.h + hue); e.s = K.unit(e.s * (1 + sat)); e.l = K.unit(e.l + lum)
                for p in mixer.points {
                    let wh = max(0, 1 - K.hueDistance(e.h, p.hue / 360) / max(0.01, p.hueRange / 360))
                    let ws = max(0, 1 - abs(e.s - p.saturation) / max(0.01, p.saturationRange))
                    let wl = max(0, 1 - abs(e.l - p.luminance) / max(0.01, p.luminanceRange))
                    let w = wh * ws * wl
                    e.h = K.wrap(e.h + p.hueShift / 100 * w * (30.0 / 360))
                    e.s = K.unit(e.s * (1 + p.saturationShift / 100 * w)); e.l = K.unit(e.l + p.luminanceShift / 100 * w * 0.25)
                }
                c = e.rgb()
            }
            if grading.adjusts {
                let y = K.luminance(c), split = 0.5 - grading.balance / 100 * 0.2, reach = 0.12 + grading.blending / 100 * 0.38
                var weights = [K.unit((split + reach - y) / max(0.05, reach * 2)), K.unit(1 - abs(y - split) / (0.35 + reach)), K.unit((y - (split - reach)) / max(0.05, reach * 2))]
                let sum = weights.reduce(0, +)
                if sum > 1e-4 { weights = weights.map { $0 / sum } }
                weights.append(1)
                let wheels = [grading.shadows, grading.midtones, grading.highlights, grading.global]
                for i in 0..<4 {
                    let wheel = wheels[i], w = weights[i]
                    let color = K.hsl(wheel.hue / 360, 1, 0.5)
                    c += (color - K.RGB(repeating: 0.5)) * (wheel.saturation / 100 * w * 0.85)
                    if wheel.luminance != 0 { c = K.scaleLuminance(c, to: K.luminance(c) + wheel.luminance / 100 * 0.25 * w) }
                }
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
    private func floatEffects(_ surface: LWLinearSurface, retainedBytes: Int, seed: UInt32) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let count = surface.pixels.count, width = surface.width, height = surface.height
        // Original + current + output float4, up to five retained Double planes and blur temp.
        try K.checkedBytes(count: count, bytesPerPixel: 96, maximumBytes: surface.maximumBytes)
        let luma = surface.pixels.map { p in p.w == 0 ? 0 : K.luminance(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))) }
        let fine = texture != 0 ? K.blur(luma, width: width, height: height, radius: 1) : []
        let coarse = clarity != 0 ? K.blur(luma, width: width, height: height, radius: 4) : []
        var halo: [Double] = []
        if glow > 0 {
            let threshold = 0.55 + 0.4 * glowRange / 100
            let source = luma.map { K.unit(($0 - threshold) / max(0.05, 1 - threshold)) }
            halo = K.blur(source, width: width, height: height, radius: Int(((glowStyle == .bloom ? 2.0 : 5.0) * (1 + glowSpread / 100)).rounded()))
        }
        return try K.mapPixels(surface, retainedBytes: retainedBytes + (luma.count + fine.count + coarse.count + halo.count) * 8) { linear, x, y in
            let i = y * width + x
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            let local = (fine.isEmpty ? 0 : texture / 100 * (luma[i] - fine[i])) + (coarse.isEmpty ? 0 : clarity / 100 * (luma[i] - coarse[i]))
            c = K.scaleLuminance(c, to: luma[i] + local)
            if dehaze != 0 {
                let d = dehaze / 100, before = K.luminance(c), pivot = 0.45 - 0.1 * max(d, 0)
                var target = pivot + (before - 0.45) * (1 + 0.8 * d)
                if d < 0 { target += -d * (1 - target) * 0.45 } else { target -= d * max(0, 0.4 - target) }
                c = K.scaleLuminance(c, to: target)
                c = K.RGB(repeating: target) + (c - K.RGB(repeating: target)) * (1 + 0.7 * d)
            }
            if !halo.isEmpty {
                let warm = glowWarmth / 100
                let color = glowStyle == .halation ? K.RGB(1, 0.35 - 0.3*warm, 0.2 - 0.2*warm) : K.RGB(0.75 + 0.25*warm, 0.6 + 0.2*warm, 0.75 - 0.6*warm)
                c += color * (halo[i] * glow / 100 * (glowStyle == .bloom ? 1.4 : 1))
            }
            if vignetteAmount != 0 {
                let nx = (Double(x) + 0.5) / Double(width)*2 - 1, ny = (Double(y) + 0.5) / Double(height)*2 - 1
                let circle = hypot(nx, ny) / sqrt(2), square = max(abs(nx), abs(ny))
                let distance = circle + (square - circle)*(1 - vignetteRoundness / 100)*0.5
                let t = K.unit((distance - vignetteMidpoint / 100 * 0.85) / max(0.05, vignetteFeather / 100)), mask = t*t*(3 - 2*t)
                var effect = vignetteAmount / 100 * mask
                if effect < 0 && vignetteStyle == .highlightPriority { effect *= 1 - vignetteHighlights / 100 * K.unit((K.luminance(c) - 0.45) / 0.55) }
                c = effect < 0 ? c*(1 + effect) : c + (K.RGB(repeating: 1) - c)*effect
                if vignetteStyle == .colorPriority { let lum = K.luminance(c); c = K.RGB(repeating: lum) + (c - K.RGB(repeating: lum))*(1 - 0.75*mask*abs(vignetteAmount / 100)) }
            }
            if grainAmount > 0 {
                let size = grainKernelSize
                let smooth = try K.grain(Double(x) + 0.5, Double(y) + 0.5, size: size, seed: seed)
                let detail = try K.grain(Double(x) + 0.5, Double(y) + 0.5, size: max(0.5, size*0.35), seed: K.mix32(seed ^ 0xa511e9b3))
                let noise = smooth + (detail - smooth)*grainRoughness / 100, level = K.unit(K.luminance(c))
                c += K.RGB(repeating: noise * grainAmount / 100 * 0.35 * (0.4 + 2.4*level*(1 - level)))
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
    private func floatDetail(_ surface: LWLinearSurface, retainedBytes: Int) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let width = surface.width, height = surface.height, s = detail, count = surface.pixels.count
        try K.checkedBytes(count: count, bytesPerPixel: 112, maximumBytes: surface.maximumBytes)
        var result = surface
        func luminance(_ image: LWLinearSurface) -> [Double] {
            image.pixels.map { p in p.w == 0 ? 0 : K.luminance(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))) }
        }
        if s.noiseLuminance > 0 {
            var luma = luminance(result)
            let blurred = K.blur(luma, width: width, height: height, radius: Int((1 + s.noiseLuminance / 50).rounded()))
            result = try K.mapPixels(result, retainedBytes: retainedBytes + luma.count * 16) { linear, x, y in
                let i = y*width + x, edge = K.edge(luma, width: width, height: height, x: x, y: y, radius: 1)
                let local = s.noiseLuminance / 100 * (1 - s.noiseLuminanceDetail / 100 * min(1, edge*6))
                let target = luma[i]*(1 - local) + blurred[i]*local + s.noiseLuminanceContrast / 100 * 0.25*(luma[i] - blurred[i])
                luma[i] = target // Retain the original row-major luminance-detail update order.
                let c = K.scaleLuminance(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)), to: target)
                return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        if s.noiseColor > 0 {
            let chroma = result.pixels.map { p in p.w == 0 ? 0 : K.ColorEnvelope(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))).s }
            let blurred = K.blur(chroma, width: width, height: height, radius: Int((1 + s.noiseColorSmoothness / 40).rounded()))
            result = try K.mapPixels(result, retainedBytes: retainedBytes + count * 16) { linear, x, y in
                let i = y*width + x
                let local = s.noiseColor / 100*(1 - s.noiseColorDetail / 100*min(1, abs(chroma[i] - blurred[i])*4))
                var e = K.ColorEnvelope(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)))
                e.s = chroma[i]*(1 - local) + blurred[i]*local
                let c = e.rgb(); return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        if s.sharpenAmount > 0 {
            let luma = luminance(result), radius = max(1, Int((0.5 + s.sharpenRadius / 100*2.5).rounded()))
            let blurred = K.blur(luma, width: width, height: height, radius: radius)
            result = try K.mapPixels(result, retainedBytes: retainedBytes + count * 16) { linear, x, y in
                let i = y*width + x, edge = K.edge(luma, width: width, height: height, x: x, y: y, radius: radius)
                let threshold = s.sharpenMasking / 100*0.35, boost = 0.5 + s.sharpenDetail / 100
                let mask = K.unit((edge*boost - threshold) / max(0.04, 0.35 - threshold*0.5))
                let target = luma[i] + (luma[i] - blurred[i])*s.sharpenAmount / 100*mask*boost
                let c = K.scaleLuminance(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)), to: target)
                return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        return result
    }
    private func floatOptics(_ surface: LWLinearSurface, retainedBytes: Int) throws -> LWLinearSurface {
        typealias K = FloatImageAdjustmentPixels
        let s = optics, width = surface.width, height = surface.height, count = surface.pixels.count
        try K.checkedBytes(count: count, bytesPerPixel: 80, maximumBytes: surface.maximumBytes)
        var result = surface
        let k = s.distortionK(profileStrength: PixelFilter.lensStrength)
        if k != 0 {
            var pixels = [SIMD4<Float>](repeating: .zero, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    let p = try s.sourcePoint(for: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), width: width, height: height)
                    pixels[y*width + x] = K.sample(result, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5)
                }
            }
            result = try LWLinearSurface(width: width, height: height, pixels: pixels, maximumBytes: surface.maximumBytes)
        }
        if s.removeChromaticAberration {
            let source = result
            var pixels = source.pixels
            let cx = Double(width)*0.5, cy = Double(height)*0.5, maxRadius = hypot(cx, cy)
            for y in 0..<height {
                for x in 0..<width where pixels[y*width + x].w > 0 {
                    let radial = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)/maxRadius
                    let shift = 0.45*radial*radial*2.5
                    // Retain channel correction's horizontal, nearest-neighbor convention.
                    let rx = min(width - 1, max(0, Int((Double(x) - shift).rounded())))
                    let bx = min(width - 1, max(0, Int((Double(x) + shift).rounded())))
                    let red = source.pixels[y*width + rx], blue = source.pixels[y*width + bx]
                    pixels[y*width + x].x = red.w > 0 ? red.x : 0
                    pixels[y*width + x].z = blue.w > 0 ? blue.z : 0
                }
            }
            result = try LWLinearSurface(width: width, height: height, pixels: pixels, maximumBytes: surface.maximumBytes)
        }
        let vignette = s.vignetteAmount + (s.enableLensProfile ? s.profileVignetting / 100*35 : 0)
        if s.purpleAmount == 0 && s.greenAmount == 0 && vignette == 0 { return result }
        return try K.mapPixels(result, retainedBytes: retainedBytes) { linear, x, y in
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            let e = K.ColorEnvelope(c), hue = e.h*360
            var reduce = 0.0
            if hue >= s.purpleHueLow && hue <= s.purpleHueHigh { reduce = s.purpleAmount / 100 }
            if hue >= s.greenHueLow && hue <= s.greenHueHigh { reduce = max(reduce, s.greenAmount / 100) }
            if reduce > 0 {
                let n = (c - K.RGB(repeating: e.offset))/e.scale, high = max(n.x, max(n.y, n.z)), low = min(n.x, min(n.y, n.z))
                if high > 0 { let lum = K.luminance(c); c = K.RGB(repeating: lum) + (c - K.RGB(repeating: lum))*(1 - reduce*(high - low)/high) }
            }
            if vignette != 0 {
                let nx = (Double(x) + 0.5)/Double(width)*2 - 1, ny = (Double(y) + 0.5)/Double(height)*2 - 1
                let t = K.unit((hypot(nx, ny)/sqrt(2) - s.vignetteMidpoint / 100*0.85)/0.35)
                let lift = vignette / 100*t*t*(3 - 2*t)
                c = lift > 0 ? c + (K.RGB(repeating: 1) - c)*lift : c*(1 + lift)
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
}

nonisolated extension CameraRawGeometrySettings {
    /// Top-row-first source pixel-boundary coordinates → developed pixel-boundary coordinates.
    /// The dimension-only map excludes image-dependent Constrain Crop; develop returns its
    /// effective surface-aware map. Optics' separate radial warp is not a homography.
    func coordinateMap(width: Int, height: Int) throws -> LWSourceCoordinateMap {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, self == normalized, scale > -100 else { throw ProjectError.invalid }
        guard adjusts else { return .identity }
        var v = vertical, hz = horizontal, rotation = rotate
        if upright == .guided, let first = guides.first {
            let angle = atan2(first.endY - first.startY, first.endX - first.startX)*180 / .pi
            var correction = -angle
            if correction > 45 { correction -= 90 } else if correction < -45 { correction += 90 }
            rotation += correction
            if guides.count > 1 {
                let g = guides[1], a = atan2(g.endY - g.startY, g.endX - g.startX)*180 / .pi
                if abs(a) > 45 { v += a > 0 ? 25 : -25 } else { hz += a > 0 ? 25 : -25 }
            }
        }
        let w = Double(width), h = Double(height), strength = projection == .perspective ? 1.0 : 0.55
        let verticalShift = v / 100*w*0.18*strength, horizontalShift = hz / 100*h*0.18*strength
        let sx = offsetX / 100*w*0.15, sy = offsetY / 100*h*0.15, center = CGPoint(x: w/2 + sx, y: h/2 + sy)
        let aspectScale = 1 + aspect / 200, zoom = 1 + scale / 100, radians = rotation * .pi / 180
        // Retained lower-left corner construction, then converted once to top-first coordinates.
        let corners = [CGPoint(x: -verticalShift + sx, y: h + sy), CGPoint(x: w + verticalShift + sx, y: h + sy),
                       CGPoint(x: w + horizontalShift + sx, y: -sy), CGPoint(x: -horizontalShift + sx, y: -sy)].map { p in
            let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
            let rx = dx*cos(radians) - dy*sin(radians), ry = dx*sin(radians) + dy*cos(radians)
            return CGPoint(x: Double(center.x) + rx*aspectScale*zoom, y: h - (Double(center.y) + ry/aspectScale*zoom))
        }
        // Projective unit square→quadrilateral closed form; no least-squares approximation.
        let p0 = corners[0], p1 = corners[1], p2 = corners[2], p3 = corners[3]
        let dx1 = Double(p1.x - p2.x), dx2 = Double(p3.x - p2.x), dx3 = Double(p0.x - p1.x + p2.x - p3.x)
        let dy1 = Double(p1.y - p2.y), dy2 = Double(p3.y - p2.y), dy3 = Double(p0.y - p1.y + p2.y - p3.y)
        var g = 0.0, j = 0.0
        if dx3 != 0 || dy3 != 0 {
            let determinant = dx1*dy2 - dx2*dy1
            guard determinant.isFinite, determinant != 0 else { throw ProjectError.invalid }
            g = (dx3*dy2 - dx2*dy3)/determinant; j = (dx1*dy3 - dx3*dy1)/determinant
        }
        let a = Double(p1.x - p0.x) + g*Double(p1.x), b = Double(p3.x - p0.x) + j*Double(p3.x)
        let d = Double(p1.y - p0.y) + g*Double(p1.y), e = Double(p3.y - p0.y) + j*Double(p3.y)
        let map = try LWSourceCoordinateMap([a/w, b/h, Double(p0.x), d/w, e/h, Double(p0.y), g/w, j/h, 1])
        // A projective horizon through the source rectangle cannot be sampled safely.
        let denominators = [1.0, 1 + g, 1 + j, 1 + g + j]
        guard denominators.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ProjectError.invalid }
        return map
    }
    func coordinateMap(for surface: LWLinearSurface) throws -> LWSourceCoordinateMap {
        try surface.validate(maximumBytes: surface.maximumBytes)
        let map = try coordinateMap(width: surface.width, height: surface.height)
        guard adjusts && constrainCrop else { return map }
        let inverse = try map.inverse(), w = surface.width, h = surface.height
        var left = w, top = h, right = 0, bottom = 0
        for y in 0..<h {
            for x in 0..<w {
                let p = try inverse.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let alpha = FloatImageAdjustmentPixels.sample(surface, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5).w
                if alpha > 0 { left = min(left, x); top = min(top, y); right = max(right, x + 1); bottom = max(bottom, y + 1) }
            }
        }
        guard right > left, bottom > top, right - left < w || bottom - top < h else { return map }
        let fit = min(Double(w)/Double(right - left), Double(h)/Double(bottom - top))
        let tx = (Double(w) - Double(right - left)*fit)/2 - Double(left)*fit
        let ty = (Double(h) - Double(bottom - top)*fit)/2 - Double(top)*fit
        let m = map.values
        return try LWSourceCoordinateMap([fit*m[0] + tx*m[6], fit*m[1] + tx*m[7], fit*m[2] + tx*m[8],
                                          fit*m[3] + ty*m[6], fit*m[4] + ty*m[7], fit*m[5] + ty*m[8], m[6], m[7], m[8]])
    }
    func resample(_ surface: LWLinearSurface, map: LWSourceCoordinateMap) throws -> LWLinearSurface {
        try FloatImageAdjustmentPixels.checkedBytes(count: surface.pixels.count, bytesPerPixel: 32, maximumBytes: surface.maximumBytes)
        let inverse = try map.inverse(), w = surface.width, h = surface.height
        var pixels = [SIMD4<Float>](repeating: .zero, count: surface.pixels.count)
        for y in 0..<h {
            for x in 0..<w {
                let p = try inverse.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                pixels[y*w + x] = FloatImageAdjustmentPixels.sample(surface, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5)
            }
        }
        return try LWLinearSurface(width: w, height: h, pixels: pixels, maximumBytes: surface.maximumBytes)
    }
}

nonisolated extension CameraRawOpticsSettings {
    /// Pixel-boundary coordinate used by the exact retained radial resampler. Channel correction
    /// is horizontal nearest-neighbor sampling and therefore has no single shared inverse map.
    func sourcePoint(for developedPoint: CGPoint, width: Int, height: Int, channel: Int = 1) throws -> CGPoint {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, (0...2).contains(channel), self == normalized,
              developedPoint.x.isFinite, developedPoint.y.isFinite,
              developedPoint.x >= 0, developedPoint.y >= 0, developedPoint.x <= Double(width), developedPoint.y <= Double(height) else { throw ProjectError.invalid }
        let cx = Double(width)*0.5, cy = Double(height)*0.5
        var pointX = Double(developedPoint.x)
        if removeChromaticAberration && channel != 1 {
            let radial = hypot(pointX - cx, Double(developedPoint.y) - cy)/hypot(cx, cy)
            let shift = 0.45*radial*radial*2.5*(channel == 0 ? -1 : 1)
            pointX = Double(min(width - 1, max(0, Int((pointX - 0.5 + shift).rounded())))) + 0.5
        }
        let dx = pointX - cx, dy = Double(developedPoint.y) - cy
        let k = distortionK(profileStrength: PixelFilter.lensStrength), diagonal = cx*cx + cy*cy
        let factor = 1 - k*(dx*dx + dy*dy)/diagonal
        let point = CGPoint(x: cx + dx*factor, y: cy + dy*factor)
        guard point.x.isFinite, point.y.isFinite else { throw ProjectError.invalid }
        return point
    }
    /// Inverts the common green/luminance radial grid only when the full retained extent is
    /// one-to-one. A folded radial warp has no truthful shared source-space inverse.
    func developedPoint(for sourcePoint: CGPoint, width: Int, height: Int) throws -> CGPoint {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, self == normalized, sourcePoint.x.isFinite, sourcePoint.y.isFinite else { throw ProjectError.invalid }
        let cx = Double(width)*0.5, cy = Double(height)*0.5, dx = Double(sourcePoint.x) - cx, dy = Double(sourcePoint.y) - cy
        let radius = hypot(cx, cy), target = hypot(dx, dy), k = distortionK(profileStrength: PixelFilter.lensStrength)
        guard k < 1.0/3 else { throw ProjectError.invalid }
        if target == 0 { return CGPoint(x: cx, y: cy) }
        guard target <= radius*(1 - k) else { throw ProjectError.invalid }
        var low = 0.0, high = radius
        for _ in 0..<64 {
            let mid = (low + high)/2, mapped = mid*(1 - k*mid*mid/(radius*radius))
            if mapped < target { low = mid } else { high = mid }
        }
        let r = (low + high)/2, mapped = r*(1 - k*r*r/(radius*radius))
        guard abs(mapped - target) <= 64*Double.ulpOfOne*max(1, radius) else { throw ProjectError.invalid }
        let result = CGPoint(x: cx + dx*r/target, y: cy + dy*r/target)
        guard result.x >= 0, result.y >= 0, result.x <= Double(width), result.y <= Double(height) else { throw ProjectError.invalid }
        return result
    }
}

nonisolated extension CameraRawSettings {
    /// Gray-world solve directly from covered linear samples, before display conversion.
    static func autoBalance(of surface: LWLinearSurface) -> (temperature: Double, tint: Double)? {
        guard (try? surface.validate(maximumBytes: surface.maximumBytes)) != nil else { return nil }
        var total = SIMD3<Double>.zero, count = 0.0
        for p in surface.pixels where p.w > 0 { total += SIMD3(Double(p.x), Double(p.y), Double(p.z)); count += 1 }
        guard count > 0, total.x.isFinite, total.y.isFinite, total.z.isFinite else { return nil }
        return neutralize(linearRed: total.x/count, green: total.y/count, blue: total.z/count)
    }
}

nonisolated extension CameraRawSettings {
    private func floatLight(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let gain = gains, ev = exp2(exposure)
        return try workspace.rgb(plane) { linear, _, _ in
            let exposed = linear * K.RGB(gain.red * ev, gain.green * ev, gain.blue * ev)
            // Exposure and white balance alone stay in linear light, including negative/HDR samples.
            if contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 && vibrance == 0 && saturation == 0 {
                return exposed
            }
            var c = K.RGB(K.encode(exposed.x), K.encode(exposed.y), K.encode(exposed.z))
            c = K.RGB(repeating: 0.5) + (c - K.RGB(repeating: 0.5)) * (1 + contrast / 100)
            var y = K.luminance(c)
            let hw = pow(K.unit((y - 0.5) / 0.5), 2), ha = highlights / 100
            y += ha * hw * (ha >= 0 ? 1 - y : y - 0.5)
            c = K.scaleLuminance(c, to: y)
            let sw = pow(K.unit((0.5 - y) / 0.5), 2), sa = shadows / 100
            y += sa * sw * (sa >= 0 ? 0.5 - y : y)
            c = K.scaleLuminance(c, to: y)
            if y > 0.75 { y = 0.75 + (y - 0.75) * (1 + whites / 100); c = K.scaleLuminance(c, to: y) }
            if y < 0.25 { y = 0.25 + (y - 0.25) * (1 - blacks / 100); c = K.scaleLuminance(c, to: y) }
            let envelope = K.ColorEnvelope(c)
            let n = (c - K.RGB(repeating: envelope.offset)) / envelope.scale
            let high = max(n.x, max(n.y, n.z)), low = min(n.x, min(n.y, n.z))
            let sat = high == 0 ? 0 : (high - low) / high
            let hue = envelope.h * 360
            var skin = 0.0
            if hue >= 10 && hue <= 50 { skin = (hue <= 30 ? (hue - 10) / 20 : (50 - hue) / 20) * K.unit((sat - 0.15) / 0.35) }
            var amount = vibrance / 100 * (1 - sat)
            if vibrance > 0 { amount *= 1 - 0.7 * skin }
            c = K.RGB(repeating: K.luminance(c)) + (c - K.RGB(repeating: K.luminance(c))) * (1 + amount)
            c = K.RGB(repeating: K.luminance(c)) + (c - K.RGB(repeating: K.luminance(c))) * (1 + saturation / 100)
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
    private func floatCalibration(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let s = calibration
        let response: [Double] = [0.55, 0.65, 0.75, 0.85, 0.92, 1]
        let scale = response[Int(s.process.kernelValue) - 1]
        return try workspace.rgb(plane) { linear, _, _ in
            let c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            var e = K.ColorEnvelope(c)
            if e.l < 0.35 { e.h += s.shadowTint / 100 * scale * 0.06 }
            if max(c.x, max(c.y, c.z)) != min(c.x, min(c.y, c.z)) {
                let hue: Double, saturation: Double
                if c.x >= c.y && c.x >= c.z { hue = s.redHue; saturation = s.redSaturation }
                else if c.y >= c.x && c.y >= c.z { hue = s.greenHue; saturation = s.greenSaturation }
                else { hue = s.blueHue; saturation = s.blueSaturation }
                e.h += hue / 100 * (15.0 / 360) * scale
                e.s = K.unit(e.s * (1 + saturation / 100 * 0.45 * scale))
            }
            let out = e.rgb()
            return K.RGB(K.decode(out.x), K.decode(out.y), K.decode(out.z))
        }
    }
    private func floatColor(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let anchors = K.parametricAnchors(curve)
        let parametric = curve.shadows != 0 || curve.darks != 0 || curve.lights != 0 || curve.highlights != 0
        return try workspace.rgb(plane) { linear, _, _ in
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            if curve.adjusts {
                func tone(_ x: Double) -> Double { K.curve(parametric ? K.curve(x, points: anchors) : x, points: curve.rgb) }
                let original = c
                c = K.RGB(tone(c.x), tone(c.y), tone(c.z))
                if curve.refineSaturation < 0 {
                    let brightnessOnly = K.scaleLuminance(original, to: tone(K.luminance(original)))
                    c += (brightnessOnly - c)*(-curve.refineSaturation / 100)
                } else if curve.refineSaturation > 0 {
                    let y = K.luminance(c), scale = 1 + curve.refineSaturation / 100
                    c = K.RGB(repeating: y) + (c - K.RGB(repeating: y)) * scale
                }
                c = K.RGB(K.curve(c.x, points: curve.red), K.curve(c.y, points: curve.green), K.curve(c.z, points: curve.blue))
            }
            if mixer.adjusts {
                var e = K.ColorEnvelope(c)
                var hue = 0.0, sat = 0.0, lum = 0.0, sum = 0.0
                for i in 0..<8 {
                    let weight = max(0, 1 - K.hueDistance(e.h, CameraRawMixerSettings.centers[i] / 360) / (40.0 / 360))
                    hue += mixer.hue[i] / 100 * weight * (30.0 / 360)
                    sat += mixer.saturation[i] / 100 * weight
                    lum += mixer.luminance[i] / 100 * weight * 0.25; sum += weight
                }
                if sum > 1 { hue /= sum; sat /= sum; lum /= sum }
                e.h = K.wrap(e.h + hue); e.s = K.unit(e.s * (1 + sat)); e.l = K.unit(e.l + lum)
                for p in mixer.points {
                    let wh = max(0, 1 - K.hueDistance(e.h, p.hue / 360) / max(0.01, p.hueRange / 360))
                    let ws = max(0, 1 - abs(e.s - p.saturation) / max(0.01, p.saturationRange))
                    let wl = max(0, 1 - abs(e.l - p.luminance) / max(0.01, p.luminanceRange))
                    let w = wh * ws * wl
                    e.h = K.wrap(e.h + p.hueShift / 100 * w * (30.0 / 360))
                    e.s = K.unit(e.s * (1 + p.saturationShift / 100 * w)); e.l = K.unit(e.l + p.luminanceShift / 100 * w * 0.25)
                }
                c = e.rgb()
            }
            if grading.adjusts {
                let y = K.luminance(c), split = 0.5 - grading.balance / 100 * 0.2, reach = 0.12 + grading.blending / 100 * 0.38
                var weights = [K.unit((split + reach - y) / max(0.05, reach * 2)), K.unit(1 - abs(y - split) / (0.35 + reach)), K.unit((y - (split - reach)) / max(0.05, reach * 2))]
                let sum = weights.reduce(0, +)
                if sum > 1e-4 { weights = weights.map { $0 / sum } }
                weights.append(1)
                let wheels = [grading.shadows, grading.midtones, grading.highlights, grading.global]
                for i in 0..<4 {
                    let wheel = wheels[i], w = weights[i]
                    let color = K.hsl(wheel.hue / 360, 1, 0.5)
                    c += (color - K.RGB(repeating: 0.5)) * (wheel.saturation / 100 * w * 0.85)
                    if wheel.luminance != 0 { c = K.scaleLuminance(c, to: K.luminance(c) + wheel.luminance / 100 * 0.25 * w) }
                }
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
}

nonisolated extension CameraRawSettings {

    /// Pixel reach at the evaluated grid. `scale` is evaluated pixels per full-resolution pixel: 1 for
    /// commit/export (unchanged radii), below 1 when the preview develops a reduced grid.
    private static func reach(_ radius: Int, _ scale: Double) -> Int {
        scale == 1 ? radius : max(1, Int((Double(radius) * scale).rounded()))
    }
    private func floatEffects(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace, seed: UInt32, scale: Double) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let width = plane.width, height = plane.height
        let luma = try workspace.scalar(plane) { p in p.w == 0 ? 0 : K.luminance(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))) }
        let lum = luma.reader()
        let fine = texture != 0 ? try workspace.blur(luma, radius: Self.reach(1, scale)).reader() : nil
        let coarse = clarity != 0 ? try workspace.blur(luma, radius: Self.reach(4, scale)).reader() : nil
        var halo: LWFloatDoubleRows.Reader?
        if glow > 0 {
            let threshold = 0.55 + 0.4 * glowRange / 100
            let field = try LWFloatDoubleRows.create(width: width, height: height, workingSet: plane.workingSet,
                directory: workspace.makeScratchDirectory(), fileOwner: workspace.fileOwner) { y in
                let row = try luma.read(y)
                return row.values.map { K.unit(($0 - threshold) / max(0.05, 1 - threshold)) }
            }
            halo = try workspace.blur(field, radius: Self.reach(Int(((glowStyle == .bloom ? 2.0 : 5.0) * (1 + glowSpread / 100)).rounded()), scale)).reader()
        }
        return try workspace.rgb(plane) { linear, x, y in
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            let local = (fine == nil ? 0 : texture / 100 * ((try lum.value(x: x, y: y)) - (try fine!.value(x: x, y: y)))) + (coarse == nil ? 0 : clarity / 100 * ((try lum.value(x: x, y: y)) - (try coarse!.value(x: x, y: y))))
            c = K.scaleLuminance(c, to: (try lum.value(x: x, y: y)) + local)
            if dehaze != 0 {
                let d = dehaze / 100, before = K.luminance(c), pivot = 0.45 - 0.1 * max(d, 0)
                var target = pivot + (before - 0.45) * (1 + 0.8 * d)
                if d < 0 { target += -d * (1 - target) * 0.45 } else { target -= d * max(0, 0.4 - target) }
                c = K.scaleLuminance(c, to: target)
                c = K.RGB(repeating: target) + (c - K.RGB(repeating: target)) * (1 + 0.7 * d)
            }
            if halo != nil {
                let warm = glowWarmth / 100
                let color = glowStyle == .halation ? K.RGB(1, 0.35 - 0.3*warm, 0.2 - 0.2*warm) : K.RGB(0.75 + 0.25*warm, 0.6 + 0.2*warm, 0.75 - 0.6*warm)
                c += color * ((try halo!.value(x: x, y: y)) * glow / 100 * (glowStyle == .bloom ? 1.4 : 1))
            }
            if vignetteAmount != 0 {
                let nx = (Double(x) + 0.5) / Double(width)*2 - 1, ny = (Double(y) + 0.5) / Double(height)*2 - 1
                let circle = hypot(nx, ny) / sqrt(2), square = max(abs(nx), abs(ny))
                let distance = circle + (square - circle)*(1 - vignetteRoundness / 100)*0.5
                let t = K.unit((distance - vignetteMidpoint / 100 * 0.85) / max(0.05, vignetteFeather / 100)), mask = t*t*(3 - 2*t)
                var effect = vignetteAmount / 100 * mask
                if effect < 0 && vignetteStyle == .highlightPriority { effect *= 1 - vignetteHighlights / 100 * K.unit((K.luminance(c) - 0.45) / 0.55) }
                c = effect < 0 ? c*(1 + effect) : c + (K.RGB(repeating: 1) - c)*effect
                if vignetteStyle == .colorPriority { let lum = K.luminance(c); c = K.RGB(repeating: lum) + (c - K.RGB(repeating: lum))*(1 - 0.75*mask*abs(vignetteAmount / 100)) }
            }
            if grainAmount > 0 {
                let size = grainKernelSize * scale
                let smooth = try K.grain(Double(x) + 0.5, Double(y) + 0.5, size: size, seed: seed)
                let detail = try K.grain(Double(x) + 0.5, Double(y) + 0.5, size: max(0.5, size*0.35), seed: K.mix32(seed ^ 0xa511e9b3))
                let noise = smooth + (detail - smooth)*grainRoughness / 100, level = K.unit(K.luminance(c))
                c += K.RGB(repeating: noise * grainAmount / 100 * 0.35 * (0.4 + 2.4*level*(1 - level)))
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }

    private func floatOptics(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace, scale: Double) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let s = optics, width = plane.width, height = plane.height
        var result = plane
        if s.distortionK(profileStrength: PixelFilter.lensStrength) != 0 {
            result = try workspace.map(result) { _, x, y, sampler in
                let p = try s.sourcePoint(for: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), width: width, height: height)
                return try LWFloatKernelWorkspace.sample(sampler, width: width, height: height, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5)
            }
        }
        if s.removeChromaticAberration {
            let cx = Double(width)*0.5, cy = Double(height)*0.5, maxRadius = hypot(cx, cy)
            result = try workspace.map(result) { pixel, x, y, sampler in
                guard pixel.w > 0 else { return pixel }
                let radial = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)/maxRadius
                let shift = 0.45*radial*radial*2.5*scale
                let rx = min(width - 1, max(0, Int((Double(x) - shift).rounded())))
                let bx = min(width - 1, max(0, Int((Double(x) + shift).rounded())))
                let red = try sampler.pixel(x: rx, y: y), blue = try sampler.pixel(x: bx, y: y)
                return SIMD4(red.w > 0 ? red.x : 0, pixel.y, blue.w > 0 ? blue.z : 0, pixel.w)
            }
        }
        let vignette = s.vignetteAmount + (s.enableLensProfile ? s.profileVignetting / 100*35 : 0)
        if s.purpleAmount == 0 && s.greenAmount == 0 && vignette == 0 { return result }
        return try workspace.rgb(result) { linear, x, y in
            var c = K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z))
            let e = K.ColorEnvelope(c), hue = e.h*360
            var reduce = 0.0
            if hue >= s.purpleHueLow && hue <= s.purpleHueHigh { reduce = s.purpleAmount / 100 }
            if hue >= s.greenHueLow && hue <= s.greenHueHigh { reduce = max(reduce, s.greenAmount / 100) }
            if reduce > 0 {
                let n = (c - K.RGB(repeating: e.offset))/e.scale, high = max(n.x, max(n.y, n.z)), low = min(n.x, min(n.y, n.z))
                if high > 0 { let lum = K.luminance(c); c = K.RGB(repeating: lum) + (c - K.RGB(repeating: lum))*(1 - reduce*(high - low)/high) }
            }
            if vignette != 0 {
                let nx = (Double(x) + 0.5)/Double(width)*2 - 1, ny = (Double(y) + 0.5)/Double(height)*2 - 1
                let t = K.unit((hypot(nx, ny)/sqrt(2) - s.vignetteMidpoint / 100*0.85)/0.35)
                let lift = vignette / 100*t*t*(3 - 2*t)
                c = lift > 0 ? c + (K.RGB(repeating: 1) - c)*lift : c*(1 + lift)
            }
            return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
        }
    }
}

nonisolated extension CameraRawSettings {
    private func floatDetail(_ plane: LWFloatPlane, workspace: LWFloatKernelWorkspace, scale: Double) throws -> LWFloatPlane {
        typealias K = FloatImageAdjustmentPixels
        let width = plane.width, height = plane.height, s = detail
        var result = plane
        func luminance(_ image: LWFloatPlane) throws -> LWFloatDoubleRows {
            try workspace.scalar(image) { p in p.w == 0 ? 0 : K.luminance(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))) }
        }
        if s.noiseLuminance > 0 {
            let source = try luminance(result)
            let blurred = try workspace.blur(source, radius: Self.reach(Int((1 + s.noiseLuminance / 50).rounded()), scale))
            // The inherited pass updates its scalar field in global row-major order. A
            // tiled map would reorder dependencies; retain just the prior updated row.
            let previousLease = try plane.workingSet.reserve(try LWFloatDoubleRows.rowBytes(width))
            var previous = [Double](repeating: 0, count: width)
            let pixels = result
            let targets = try LWFloatDoubleRows.create(width: width, height: height,
                workingSet: plane.workingSet, directory: workspace.makeScratchDirectory(), fileOwner: workspace.fileOwner) { y in
                let original = try source.read(y), soft = try blurred.read(y)
                let next = y + 1 < height ? try source.read(y + 1) : nil
                let pixelRow = try pixels.read(LWFloatRange(x: 0, y: y, width: width, height: 1))
                // create() admits its output Double row plus serialization before
                // invoking this callback; previousLease owns the retained prior row.
                // Copy into that already admitted output, never mutate a borrowed view.
                var current = Array(original.values)
                for x in 0..<width where pixelRow.surface.pixels[x].w > 0 {
                    let center = current[x]
                    var edge = 0.0, neighbors = 0
                    for dy in -1...1 {
                        let sy = y + dy
                        guard sy >= 0, sy < height else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let sx = x + dx
                            guard sx >= 0, sx < width else { continue }
                            let value = dy == -1 ? previous[sx] : (dy == 0 ? current[sx] : next!.values[sx])
                            edge += abs(value - center); neighbors += 1
                        }
                    }
                    if neighbors != 0 { edge /= Double(neighbors) }
                    let local = s.noiseLuminance / 100 * (1 - s.noiseLuminanceDetail / 100 * min(1, edge*6))
                    current[x] = center*(1 - local) + soft.values[x]*local + s.noiseLuminanceContrast / 100 * 0.25*(center - soft.values[x])
                }
                previous = current
                return current
            }
            withExtendedLifetime(previousLease) {}
            let target = targets.reader()
            result = try workspace.rgb(result) { linear, x, y in
                let c = K.scaleLuminance(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)), to: try target.value(x: x, y: y))
                return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        if s.noiseColor > 0 {
            let chromaField = try workspace.scalar(result) { p in p.w == 0 ? 0 : K.ColorEnvelope(K.RGB(K.encode(Double(p.x)), K.encode(Double(p.y)), K.encode(Double(p.z)))).s }
            let chroma = chromaField.reader()
            let blurred = try workspace.blur(chromaField, radius: Self.reach(Int((1 + s.noiseColorSmoothness / 40).rounded()), scale)).reader()
            result = try workspace.rgb(result) { linear, x, y in
                let before = try chroma.value(x: x, y: y), soft = try blurred.value(x: x, y: y)
                let local = s.noiseColor / 100*(1 - s.noiseColorDetail / 100*min(1, abs(before - soft)*4))
                var e = K.ColorEnvelope(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)))
                e.s = before*(1 - local) + soft*local
                let c = e.rgb(); return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        if s.sharpenAmount > 0 {
            let field = try luminance(result), radius = Self.reach(max(1, Int((0.5 + s.sharpenRadius / 100*2.5).rounded())), scale)
            let luma = field.reader(), blurred = try workspace.blur(field, radius: radius).reader()
            result = try workspace.rgb(result) { linear, x, y in
                let before = try luma.value(x: x, y: y), soft = try blurred.value(x: x, y: y)
                let edge = try luma.edge(x: x, y: y, radius: radius)
                let threshold = s.sharpenMasking / 100*0.35, boost = 0.5 + s.sharpenDetail / 100
                let mask = K.unit((edge*boost - threshold) / max(0.04, 0.35 - threshold*0.5))
                let target = before + (before - soft)*s.sharpenAmount / 100*mask*boost
                let c = K.scaleLuminance(K.RGB(K.encode(linear.x), K.encode(linear.y), K.encode(linear.z)), to: target)
                return K.RGB(K.decode(c.x), K.decode(c.y), K.decode(c.z))
            }
        }
        return result
    }
    func apply(_ plane: LWFloatPlane, seed: UInt32 = 0,
               makeBuilder: @escaping (Int, Int) throws -> LWFloatPlane.Builder,
               makeScratchDirectory: @escaping () throws -> URL, fileOwner: LWFloatWorkspace? = nil) throws -> LWFloatPlane {
        try develop(plane, seed: seed, makeBuilder: makeBuilder, makeScratchDirectory: makeScratchDirectory, fileOwner: fileOwner).surface
    }
    func develop(_ plane: LWFloatPlane, seed: UInt32 = 0, scale: Double = 1,
                 makeBuilder: @escaping (Int, Int) throws -> LWFloatPlane.Builder,
                 makeScratchDirectory: @escaping () throws -> URL, fileOwner: LWFloatWorkspace? = nil) throws -> (surface: LWFloatPlane, map: LWSourceCoordinateMap) {
        try validateFloatControls(); try Task.checkCancellation()
        try LWFloatPlane.validateExtent(width: plane.width, height: plane.height)
        guard scale.isFinite, scale > 0, scale <= 1 else { throw ProjectError.invalid }
        guard !isIdentity else { return (plane, .identity) }
        let workspace = LWFloatKernelWorkspace(makeBuilder: makeBuilder, makeScratchDirectory: makeScratchDirectory, fileOwner: fileOwner)
        var result = plane
        let map = try geometry.coordinateMap(for: plane)
        if geometry.adjusts { result = try geometry.resample(plane, map: map, workspace: workspace) }
        if calibration.adjusts { result = try floatCalibration(result, workspace: workspace) }
        if adjustsLight || adjustsColor { result = try floatLight(result, workspace: workspace) }
        if curve.adjusts || mixer.adjusts || grading.adjusts { result = try floatColor(result, workspace: workspace) }
        if adjustsEffects { result = try floatEffects(result, workspace: workspace, seed: seed, scale: scale) }
        if optics.adjusts { result = try floatOptics(result, workspace: workspace, scale: scale) }
        if detail.adjusts { result = try floatDetail(result, workspace: workspace, scale: scale) }
        return (result, map)
    }
    /// Full-frame row-major reduction; no per-tile white balance or preview-byte solve.
    static func autoBalance(of plane: LWFloatPlane) throws -> (temperature: Double, tint: Double)? {
        var total = SIMD3<Double>.zero, count = 0.0
        for y in 0..<plane.height {
            try Task.checkCancellation()
            let row = try plane.read(LWFloatRange(x: 0, y: y, width: plane.width, height: 1))
            for p in row.surface.pixels where p.w > 0 {
                total += SIMD3(Double(p.x), Double(p.y), Double(p.z)); count += 1
            }
        }
        guard count > 0, total.x.isFinite, total.y.isFinite, total.z.isFinite else { return nil }
        return neutralize(linearRed: total.x/count, green: total.y/count, blue: total.z/count)
    }
}

nonisolated extension CameraRawGeometrySettings {
    func coordinateMap(for plane: LWFloatPlane) throws -> LWSourceCoordinateMap {
        let map = try coordinateMap(width: plane.width, height: plane.height)
        guard adjusts && constrainCrop else { return map }
        let inverse = try map.inverse(), w = plane.width, h = plane.height, sampler = plane.sampler()
        var left = w, top = h, right = 0, bottom = 0
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                let p = try inverse.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let alpha = try LWFloatKernelWorkspace.sample(sampler, width: w, height: h, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5).w
                if alpha > 0 { left = min(left, x); top = min(top, y); right = max(right, x + 1); bottom = max(bottom, y + 1) }
            }
        }
        guard right > left, bottom > top, right - left < w || bottom - top < h else { return map }
        let fit = min(Double(w)/Double(right - left), Double(h)/Double(bottom - top))
        let tx = (Double(w) - Double(right - left)*fit)/2 - Double(left)*fit
        let ty = (Double(h) - Double(bottom - top)*fit)/2 - Double(top)*fit
        let m = map.values
        return try LWSourceCoordinateMap([fit*m[0] + tx*m[6], fit*m[1] + tx*m[7], fit*m[2] + tx*m[8],
            fit*m[3] + ty*m[6], fit*m[4] + ty*m[7], fit*m[5] + ty*m[8], m[6], m[7], m[8]])
    }
    fileprivate func resample(_ plane: LWFloatPlane, map: LWSourceCoordinateMap,
                             workspace: LWFloatKernelWorkspace) throws -> LWFloatPlane {
        let inverse = try map.inverse(), w = plane.width, h = plane.height
        return try workspace.map(plane) { _, x, y, sampler in
            let p = try inverse.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            return try LWFloatKernelWorkspace.sample(sampler, width: w, height: h, x: Double(p.x) - 0.5, y: Double(p.y) - 0.5)
        }
    }
}
