import Foundation

/// One bracket frame developed by the editor's source development into
/// extended-linear sRGB float (straight alpha is ignored by the merge).
nonisolated struct LWHDRFrame: Sendable {
    let width: Int
    let height: Int
    var pixels: [SIMD4<Float>]
    init(width: Int, height: Int, pixels: [SIMD4<Float>]) throws {
        guard width > 0, height > 0, pixels.count == width * height else { throw LWHDRMergeError.invalidFrame }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

nonisolated enum LWHDRMergeError: LocalizedError, Equatable {
    case invalidFrame, tooFewFrames, tooManyFrames, sizeMismatch, insufficientOverlap
    var errorDescription: String? {
        switch self {
        case .invalidFrame: "A bracketed photo did not develop to a usable image."
        case .tooFewFrames: "Select two or more bracketed photos."
        case .tooManyFrames: "Select at most \(LWHDRMerger.maximumFrames) bracketed photos."
        case .sizeMismatch: "Bracketed photos must all have the same pixel dimensions."
        case .insufficientOverlap: "These photos do not share enough well-exposed pixels to be merged as one bracket."
        }
    }
}

nonisolated struct LWHDROffset: Codable, Equatable, Sendable { var x: Int; var y: Int }

nonisolated struct LWHDRMergeOptions: Sendable, Equatable {
    var deghost = true
    var align = true
}

/// Merged scene radiance in units of the reference frame's exposure.
nonisolated struct LWHDRMergeResult: Sendable {
    let width: Int
    let height: Int
    let radiance: [SIMD3<Float>]
    let referenceIndex: Int
    /// Linear exposure of each input relative to the reference (reference = 1).
    let exposures: [Double]
    /// Integer translation that aligns each input to the reference: aligned(x, y) = input(x + dx, y + dy).
    let offsets: [LWHDROffset]
    /// Pixels the deghosting motion mask excluded, per input (always 0 for the reference and with deghosting off).
    let maskedPixels: [Int]
    let options: LWHDRMergeOptions
}

/// Exposure-bracket radiance merge: exposure estimation, median-threshold-bitmap
/// alignment, clipping/exposure-weighted radiance averaging and reference-frame
/// deghosting with a motion mask. See docs/HDR_MERGE.md.
nonisolated enum LWHDRMerger {
    static let maximumFrames = 9
    /// Motion threshold, in stops of radiance disagreement with the reference.
    static let motionStops: Float = 0.75
    static let maskDilation = 2
    static let maskFeather = 2

    static func luminance(_ v: SIMD4<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
    static func luminance(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }

    /// The level above which a frame's channel is treated as clipped: just below its own white.
    static func clipLevel(_ frame: LWHDRFrame) -> Float {
        var white: Float = 0
        for p in frame.pixels { white = max(white, p.x, p.y, p.z) }
        return 0.98 * max(1, white)
    }

    /// The reference frame: the median exposure, ordered by mean luminance.
    static func referenceIndex(_ frames: [LWHDRFrame]) -> Int {
        let means = frames.map { frame in frame.pixels.reduce(0.0) { $0 + Double(luminance($1)) } / Double(frame.pixels.count) }
        let order = means.indices.sorted { means[$0] < means[$1] }
        return order[(order.count - 1) / 2]
    }

    static func merge(_ frames: [LWHDRFrame], options: LWHDRMergeOptions = .init()) throws -> LWHDRMergeResult {
        guard frames.count >= 2 else { throw LWHDRMergeError.tooFewFrames }
        guard frames.count <= maximumFrames else { throw LWHDRMergeError.tooManyFrames }
        let width = frames[0].width, height = frames[0].height, count = width * height
        guard frames.allSatisfy({ $0.width == width && $0.height == height }) else { throw LWHDRMergeError.sizeMismatch }
        let clips = frames.map(clipLevel)
        let floors = clips.map { $0 * 0.002 }
        let reference = referenceIndex(frames)

        var offsets = Array(repeating: LWHDROffset(x: 0, y: 0), count: frames.count)
        if options.align {
            for index in frames.indices where index != reference {
                try Task.checkCancellation()
                offsets[index] = align(frames[index], clip: clips[index], to: frames[reference], referenceClip: clips[reference])
            }
        }
        func sample(_ index: Int, _ x: Int, _ y: Int) -> SIMD4<Float>? {
            let sx = x + offsets[index].x, sy = y + offsets[index].y
            guard sx >= 0, sy >= 0, sx < width, sy < height else { return nil }
            return frames[index].pixels[sy * width + sx]
        }
        func valid(_ index: Int, _ v: SIMD4<Float>) -> Bool {
            max(v.x, v.y, v.z) < clips[index] && luminance(v) > floors[index]
        }

        // Exposure of each frame relative to the reference: the median log ratio over
        // pixels well exposed in both (robust to the minority of moving pixels).
        var exposures = Array(repeating: 1.0, count: frames.count)
        for index in frames.indices where index != reference {
            try Task.checkCancellation()
            var ratios: [Float] = []
            ratios.reserveCapacity(count / 4)
            for y in 0..<height {
                for x in 0..<width {
                    guard let v = sample(index, x, y) else { continue }
                    let r = frames[reference].pixels[y * width + x]
                    guard valid(index, v), valid(reference, r), luminance(v) > floors[index] * 4, luminance(r) > floors[reference] * 4 else { continue }
                    ratios.append(log2(luminance(v) / luminance(r)))
                }
            }
            guard ratios.count >= max(16, count / 100) else { throw LWHDRMergeError.insufficientOverlap }
            ratios.sort()
            exposures[index] = Double(exp2(ratios[ratios.count / 2]))
        }

        // Motion masks: a frame disagrees with the reference by more than motionStops
        // where both are valid, or violates the bound a clipped / underexposed reference sets.
        var masks = Array(repeating: [Float](), count: frames.count)
        var maskedPixels = Array(repeating: 0, count: frames.count)
        if options.deghost {
            let tolerance = exp2(motionStops)
            for index in frames.indices where index != reference {
                try Task.checkCancellation()
                var raw = [Bool](repeating: false, count: count)
                let e = Float(exposures[index])
                for y in 0..<height {
                    for x in 0..<width {
                        guard let v = sample(index, x, y), valid(index, v) else { continue }
                        let r = frames[reference].pixels[y * width + x]
                        let radiance = luminance(v) / e, referenceRadiance = luminance(r)
                        if valid(reference, r) {
                            raw[y * width + x] = abs(log2(radiance / referenceRadiance)) > motionStops
                        } else if max(r.x, r.y, r.z) >= clips[reference] {
                            raw[y * width + x] = radiance * tolerance < referenceRadiance
                        } else {
                            raw[y * width + x] = radiance > max(referenceRadiance, floors[reference]) * tolerance
                        }
                    }
                }
                let soft = feather(dilate(raw, width: width, height: height, radius: maskDilation), width: width, height: height, radius: maskFeather)
                masks[index] = soft
                maskedPixels[index] = soft.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            }
        }

        // Weighted radiance average: a hat on each frame's own level (zero when clipped
        // or at the noise floor) times its exposure (longer exposures carry less noise).
        var radiance = [SIMD3<Float>](repeating: .zero, count: count)
        let darkest = exposures.indices.min { exposures[$0] < exposures[$1] }!
        let brightest = exposures.indices.max { exposures[$0] < exposures[$1] }!
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let p = y * width + x
                var sum = SIMD3<Float>.zero, total: Float = 0, anyClipped = false, moved = false
                for index in frames.indices {
                    guard let v = sample(index, x, y) else { continue }
                    let peak = max(v.x, v.y, v.z)
                    if peak >= clips[index] { anyClipped = true; continue }
                    guard luminance(v) > floors[index] else { continue }
                    let t = peak / clips[index]
                    var w = max(0, 1 - pow(2 * t - 1, 12)) * Float(exposures[index])
                    if options.deghost, index != reference, masks[index][p] > 0 { w *= 1 - masks[index][p]; moved = true }
                    guard w > 0 else { continue }
                    sum += SIMD3(v.x, v.y, v.z) / Float(exposures[index]) * w
                    total += w
                }
                if total > 0 {
                    radiance[p] = sum / total
                } else {
                    // Nothing usable: a clipped highlight takes the darkest frame, a shadow the
                    // brightest; with deghosting a moving region keeps the reference.
                    var chosen = moved ? reference : (anyClipped ? darkest : brightest)
                    if sample(chosen, x, y) == nil { chosen = reference }
                    let v = sample(chosen, x, y)!
                    radiance[p] = SIMD3(max(0, v.x), max(0, v.y), max(0, v.z)) / Float(exposures[chosen])
                }
            }
        }
        return LWHDRMergeResult(width: width, height: height, radiance: radiance, referenceIndex: reference,
            exposures: exposures, offsets: offsets, maskedPixels: maskedPixels, options: options)
    }

    // MARK: Median threshold bitmaps (Ward 2003): exposure-invariant translation alignment.

    struct Bitmaps {
        let width: Int, height: Int
        let threshold: [Bool], exclusion: [Bool]
        init(width: Int, height: Int, gray: [UInt8]) {
            self.width = width; self.height = height
            var histogram = [Int](repeating: 0, count: 256)
            for g in gray { histogram[Int(g)] += 1 }
            var median = 0, seen = 0
            while median < 255, seen + histogram[median] <= gray.count / 2 { seen += histogram[median]; median += 1 }
            threshold = gray.map { Int($0) > median }
            exclusion = gray.map { abs(Int($0) - median) > 4 }
        }
        static func pyramid(_ frame: LWHDRFrame, clip: Float, levels: Int) -> [Bitmaps] {
            var gray = frame.pixels.map { UInt8(min(255, max(0, pow(min(1, max(0, LWHDRMerger.luminance($0) / clip)), 1 / 2.2) * 255)).rounded()) }
            var w = frame.width, h = frame.height
            var result = [Bitmaps(width: w, height: h, gray: gray)]
            for _ in 0..<levels {
                let nw = w / 2, nh = h / 2
                var next = [UInt8](repeating: 0, count: nw * nh)
                for y in 0..<nh {
                    for x in 0..<nw {
                        let s = Int(gray[2 * y * w + 2 * x]) + Int(gray[2 * y * w + 2 * x + 1]) + Int(gray[(2 * y + 1) * w + 2 * x]) + Int(gray[(2 * y + 1) * w + 2 * x + 1])
                        next[y * nw + x] = UInt8(s / 4)
                    }
                }
                gray = next; w = nw; h = nh
                result.append(Bitmaps(width: w, height: h, gray: gray))
            }
            return result
        }
    }

    static func pyramidLevels(width: Int, height: Int) -> Int {
        var levels = 0, side = min(width, height)
        while side >= 32, levels < 6 { side /= 2; levels += 1 }
        return levels
    }

    /// The translation of `frame` that best matches `referenceFrame`, searched coarse to fine.
    static func align(_ frame: LWHDRFrame, clip: Float, to referenceFrame: LWHDRFrame, referenceClip: Float) -> LWHDROffset {
        let levels = pyramidLevels(width: frame.width, height: frame.height)
        let moving = Bitmaps.pyramid(frame, clip: clip, levels: levels)
        let reference = Bitmaps.pyramid(referenceFrame, clip: referenceClip, levels: levels)
        var dx = 0, dy = 0
        for level in stride(from: levels, through: 0, by: -1) {
            dx *= 2; dy *= 2
            let m = moving[level], r = reference[level]
            var best = (error: Int.max, x: dx, y: dy)
            for oy in -1...1 {
                for ox in -1...1 {
                    let sx = dx + ox, sy = dy + oy
                    var error = 0
                    for y in 0..<r.height {
                        let my = y + sy
                        guard my >= 0, my < m.height else { continue }
                        for x in 0..<r.width {
                            let mx = x + sx
                            guard mx >= 0, mx < m.width else { continue }
                            let a = y * r.width + x, b = my * m.width + mx
                            if r.exclusion[a], m.exclusion[b], r.threshold[a] != m.threshold[b] { error += 1 }
                        }
                    }
                    // Prefer the smaller shift on ties so a static scene stays at zero.
                    if error < best.error || (error == best.error && abs(sx) + abs(sy) < abs(best.x) + abs(best.y)) { best = (error, sx, sy) }
                }
            }
            dx = best.x; dy = best.y
        }
        return LWHDROffset(x: dx, y: dy)
    }

    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for nx in max(0, x - radius)...min(width - 1, x + radius) { horizontal[y * width + nx] = true }
            }
        }
        var result = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where horizontal[y * width + x] {
                for ny in max(0, y - radius)...min(height - 1, y + radius) { result[ny * width + x] = true }
            }
        }
        return result
    }

    /// Box-feathers a dilated mask outward; masked pixels stay fully masked.
    static func feather(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Float] {
        let hard = mask.map { $0 ? Float(1) : 0 }
        guard radius > 0 else { return hard }
        let side = Float(2 * radius + 1)
        var horizontal = [Float](repeating: 0, count: hard.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0
                for nx in max(0, x - radius)...min(width - 1, x + radius) { s += hard[y * width + nx] }
                horizontal[y * width + x] = s / side
            }
        }
        var result = [Float](repeating: 0, count: hard.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0
                for ny in max(0, y - radius)...min(height - 1, y + radius) { s += horizontal[ny * width + x] }
                result[y * width + x] = mask[y * width + x] ? 1 : min(1, s / side)
            }
        }
        return result
    }
}

/// An inclusive pixel rectangle.
nonisolated struct LWHDRRegion: Codable, Equatable, Sendable {
    let minX: Int, minY: Int, maxX: Int, maxY: Int
    func contains(x: Int, y: Int) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
}

/// Ghosting metric G over a region S (docs/HDR_MERGE.md):
///   G = mean over p in S where the reference frame is valid (unclipped, above its
///       noise floor) of | log2(Y_merged(p) + ε) − log2(Y_ref(p) + ε) |,
/// with Y the Rec. 709 luminance of linear values in the merge's radiance unit (the
/// reference exposure, e_ref = 1) and ε = 1e-4. A ghost-free merge reproduces the
/// reference frame's scene where the subject moved, so G → 0; blended copies of the
/// subject (or of the background it covered) from other bracket frames raise G.
nonisolated enum LWHDRGhostingMetric {
    static let epsilon: Float = 1e-4
    static func measure(_ result: LWHDRMergeResult, reference: LWHDRFrame, region: [LWHDRRegion]) -> (value: Double, pixels: Int) {
        let clip = LWHDRMerger.clipLevel(reference), floor = clip * 0.002
        var sum = 0.0, pixels = 0
        for y in 0..<result.height {
            for x in 0..<result.width where region.contains(where: { $0.contains(x: x, y: y) }) {
                let r = reference.pixels[y * result.width + x]
                guard max(r.x, r.y, r.z) < clip, LWHDRMerger.luminance(r) > floor else { continue }
                let merged = LWHDRMerger.luminance(result.radiance[y * result.width + x])
                sum += Double(abs(log2(merged + epsilon) - log2(LWHDRMerger.luminance(r) + epsilon)))
                pixels += 1
            }
        }
        return (pixels == 0 ? 0 : sum / Double(pixels), pixels)
    }
}
