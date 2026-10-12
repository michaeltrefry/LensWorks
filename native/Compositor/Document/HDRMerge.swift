import Foundation

/// One bracket frame developed by the editor's source development into
/// extended-linear sRGB, held as packed RGB half floats: 6 bytes per pixel
/// (alpha is ignored by the merge). Half floats keep 11 significant bits per
/// stop over ±65504, which is finer than a camera sample, at 3/8 of the memory
/// of the developed float RGBA.
nonisolated struct LWHDRFrame: Sendable {
    let width: Int
    let height: Int
    /// R, G, B per pixel, row-major.
    let samples: [Float16]
    /// The frame's pixels as float RGB with alpha 1.
    struct Pixels: RandomAccessCollection, Sendable {
        let samples: [Float16]
        var startIndex: Int { 0 }
        var endIndex: Int { samples.count / 3 }
        subscript(index: Int) -> SIMD4<Float> {
            SIMD4(Float(samples[index * 3]), Float(samples[index * 3 + 1]), Float(samples[index * 3 + 2]), 1)
        }
    }
    var pixels: Pixels { Pixels(samples: samples) }
    init(width: Int, height: Int, samples: [Float16]) throws {
        guard width > 0, height > 0, samples.count == width * height * 3 else { throw LWHDRMergeError.invalidFrame }
        self.width = width; self.height = height; self.samples = samples
    }
    init<C: Collection>(width: Int, height: Int, pixels: C) throws where C.Element == SIMD4<Float> {
        guard width > 0, height > 0, pixels.count == width * height else { throw LWHDRMergeError.invalidFrame }
        var samples = [Float16](); samples.reserveCapacity(pixels.count * 3)
        for p in pixels { samples.append(Self.pack(p.x)); samples.append(Self.pack(p.y)); samples.append(Self.pack(p.z)) }
        try self.init(width: width, height: height, samples: samples)
    }
    /// A finite sample is clamped into the half-float range; a non-finite one stays non-finite.
    @inline(__always) static func pack(_ value: Float) -> Float16 {
        let limit = Float(Float16.greatestFiniteMagnitude)
        return value.isFinite ? Float16(max(-limit, min(limit, value))) : Float16(value)
    }
    @inline(__always) func rgb(_ pixel: Int) -> SIMD3<Float> {
        SIMD3(Float(samples[pixel * 3]), Float(samples[pixel * 3 + 1]), Float(samples[pixel * 3 + 2]))
    }

    /// Bytes of developed float RGBA one strip read asks the plane for. A read charges the shared
    /// float working set (512 MiB) twice this plus two tiles, so strips stay far below it.
    static let stripBytes = 32 * 1024 * 1024
    /// Loads a developed plane in bounded row strips; the whole frame never passes through the
    /// float working set at once.
    @_optimize(speed) init(plane: LWFloatPlane) throws {
        let width = plane.width, height = plane.height
        guard width > 0, height > 0 else { throw LWHDRMergeError.invalidFrame }
        var samples = [Float16](repeating: 0, count: width * height * 3)
        let rows = max(1, min(height, Self.stripBytes / (width * MemoryLayout<SIMD4<Float>>.stride)))
        var y = 0
        while y < height {
            try Task.checkCancellation()
            let count = min(rows, height - y)
            let strip = try plane.read(LWFloatRange(x: 0, y: y, width: width, height: count)).surface.pixels
            guard strip.count == width * count else { throw LWHDRMergeError.invalidFrame }
            let base = y * width * 3
            samples.withUnsafeMutableBufferPointer { target in
                var o = base
                for p in strip { target[o] = Self.pack(p.x); target[o + 1] = Self.pack(p.y); target[o + 2] = Self.pack(p.z); o += 3 }
            }
            y += count
        }
        try self.init(width: width, height: height, samples: samples)
    }
}

nonisolated enum LWHDRMergeError: LocalizedError, Equatable {
    case invalidFrame, tooFewFrames, tooManyFrames, sizeMismatch, insufficientOverlap
    case tooLarge(frames: Int, width: Int, height: Int, neededBytes: Int, budgetBytes: Int)
    var errorDescription: String? {
        switch self {
        case .invalidFrame: "A bracketed photo did not develop to a usable image."
        case .tooFewFrames: "Select two or more bracketed photos."
        case .tooManyFrames: "Select at most \(LWHDRMerger.maximumFrames) bracketed photos."
        case .sizeMismatch: "Bracketed photos must all have the same pixel dimensions."
        case .insufficientOverlap: "These photos do not share enough well-exposed pixels to be merged as one bracket."
        case .tooLarge(let frames, let width, let height, let needed, let budget):
            String(format: "Merging %d photos of %d × %d (%.0f MP) needs about %.1f GB of memory; this Mac allows %.1f GB for a merge. Select fewer photos.",
                frames, width, height, Double(width * height) / 1e6, Double(needed) / 1e9, Double(budget) / 1e9)
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
    /// R, G, B per pixel, row-major: 12 bytes per pixel.
    let samples: [Float]
    /// The merged pixels as float RGB.
    struct Radiance: RandomAccessCollection, Sendable {
        let samples: [Float]
        var startIndex: Int { 0 }
        var endIndex: Int { samples.count / 3 }
        subscript(index: Int) -> SIMD3<Float> { SIMD3(samples[index * 3], samples[index * 3 + 1], samples[index * 3 + 2]) }
    }
    var radiance: Radiance { Radiance(samples: samples) }
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

    // MARK: Working memory (docs/HDR_MERGE.md, "Memory")

    /// Each loaded frame: packed RGB half floats.
    static let frameBytesPerPixel = 6
    /// Everything else at the peak: the radiance sum (12), weight total (4) and flags (1), one
    /// frame's motion-mask scratch (9), and the alignment scratch (about 6) that the allocator
    /// still holds after it is freed. Measured peak footprint on 3-, 5- and 9-frame 45 MP
    /// brackets is 31.1 to 31.3 bytes per pixel above the frames. The file is streamed to disk
    /// from the result, so writing adds no whole-file buffer.
    static let sharedBytesPerPixel = 32
    /// The merge budget on the product-minimum 16 GB Mac.
    static let minimumBudgetBytes = 6 * 1024 * 1024 * 1024
    /// 3/8 of physical memory, and never less than the 16 GB Mac's budget.
    static var budgetBytes: Int { max(minimumBudgetBytes, Int(clamping: ProcessInfo.processInfo.physicalMemory / 8 * 3)) }
    static func workingBytes(frames: Int, width: Int, height: Int) -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, overflowed) = pixels.multipliedReportingOverflow(by: frames * frameBytesPerPixel + sharedBytesPerPixel)
        return overflow || overflowed ? .max : bytes
    }
    /// Refuses, with the numbers, a merge whose working memory exceeds the budget.
    static func admit(frames: Int, width: Int, height: Int, budget: Int = budgetBytes) throws {
        guard width > 0, height > 0 else { throw LWHDRMergeError.invalidFrame }
        let needed = workingBytes(frames: frames, width: width, height: height)
        guard needed <= budget else {
            throw LWHDRMergeError.tooLarge(frames: frames, width: width, height: height, neededBytes: needed, budgetBytes: budget)
        }
    }

    static func luminance(_ v: SIMD4<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
    static func luminance(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }

    /// The level above which each of a frame's channels is treated as clipped: just below that
    /// channel's own white. White-balanced RAW development leaves highlights unclipped, so the
    /// channels of a saturated sensor reach different levels (the engine's DNG and LibRaw paths
    /// both scale each channel by its white-balance gain); one level taken from the brightest
    /// channel would call a pixel whose green is saturated, but below the red maximum, well exposed.
    static func clipLevel(_ frame: LWHDRFrame) -> SIMD3<Float> {
        var white = SIMD3<Float>(repeating: 1)
        frame.samples.withUnsafeBufferPointer { samples in
            for p in stride(from: 0, to: samples.count, by: 3) {
                white = pointwiseMax(white, SIMD3(Float(samples[p]), Float(samples[p + 1]), Float(samples[p + 2])))
            }
        }
        return 0.98 * white
    }
    @inline(__always) static func clipped(_ v: SIMD3<Float>, _ clip: SIMD3<Float>) -> Bool { v.x >= clip.x || v.y >= clip.y || v.z >= clip.z }

    /// The regular grid the exposure estimate reads: every pixel of a frame up to about 4 MP,
    /// then every `step`-th pixel in x and in y, which keeps about 4 million of them.
    static func exposureGrid(width: Int, height: Int) -> (step: Int, samples: Int) {
        let step = max(1, Int((Double(width * height) / 4_000_000).squareRoot()))
        return (step, ((width + step - 1) / step) * ((height + step - 1) / step))
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
        try admit(frames: frames.count, width: width, height: height)
        let clips = frames.map(clipLevel)
        let floors = clips.map { luminance($0) * 0.002 }
        let reference = referenceIndex(frames)

        var offsets = Array(repeating: LWHDROffset(x: 0, y: 0), count: frames.count)
        if options.align {
            for index in frames.indices where index != reference {
                try Task.checkCancellation()
                offsets[index] = align(frames[index], clip: luminance(clips[index]), to: frames[reference], referenceClip: luminance(clips[reference]))
            }
        }
        func sample(_ index: Int, _ x: Int, _ y: Int) -> SIMD3<Float>? {
            let sx = x + offsets[index].x, sy = y + offsets[index].y
            guard sx >= 0, sy >= 0, sx < width, sy < height else { return nil }
            return frames[index].rgb(sy * width + sx)
        }
        func valid(_ index: Int, _ v: SIMD3<Float>) -> Bool {
            !clipped(v, clips[index]) && luminance(v) > floors[index]
        }

        // Exposure of each frame relative to the reference: the median log ratio over
        // pixels well exposed in both (robust to the minority of moving pixels). A frame
        // above about 4 MP is sampled on a regular grid of about 4 million pixels: the
        // median of that many is the same, and the ratios stay a few megabytes.
        var exposures = Array(repeating: 1.0, count: frames.count)
        let (step, sampled) = exposureGrid(width: width, height: height)
        for index in frames.indices where index != reference {
            try Task.checkCancellation()
            var ratios: [Float] = []
            ratios.reserveCapacity(sampled)
            for y in stride(from: 0, to: height, by: step) {
                if y % 64 == 0 { try Task.checkCancellation() }
                for x in stride(from: 0, to: width, by: step) {
                    guard let v = sample(index, x, y) else { continue }
                    let r = frames[reference].rgb(y * width + x)
                    guard valid(index, v), valid(reference, r), luminance(v) > floors[index] * 4, luminance(r) > floors[reference] * 4 else { continue }
                    ratios.append(log2(luminance(v) / luminance(r)))
                }
            }
            guard ratios.count >= max(16, sampled / 100) else { throw LWHDRMergeError.insufficientOverlap }
            ratios.sort()
            exposures[index] = Double(exp2(ratios[ratios.count / 2]))
        }

        // Motion mask of one frame: it disagrees with the reference by more than motionStops
        // where both are valid, or violates the bound a clipped / underexposed reference sets.
        // Built for one frame at a time and folded into that frame's weights, never retained.
        func motionMask(_ index: Int) throws -> [Float] {
            let tolerance = exp2(motionStops), e = Float(exposures[index])
            let dilated: [Bool] = try {
                var raw = [Bool](repeating: false, count: count)
                for y in 0..<height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    for x in 0..<width {
                        guard let v = sample(index, x, y), valid(index, v) else { continue }
                        let r = frames[reference].rgb(y * width + x)
                        let radiance = luminance(v) / e, referenceRadiance = luminance(r)
                        if valid(reference, r) {
                            raw[y * width + x] = abs(log2(radiance / referenceRadiance)) > motionStops
                        } else if clipped(r, clips[reference]) {
                            raw[y * width + x] = radiance * tolerance < referenceRadiance
                        } else {
                            raw[y * width + x] = radiance > max(referenceRadiance, floors[reference]) * tolerance
                        }
                    }
                }
                return dilate(raw, width: width, height: height, radius: maskDilation)
            }()
            return feather(dilated, width: width, height: height, radius: maskFeather)
        }

        // Weighted radiance average, accumulated one frame at a time: a hat on each frame's own
        // level (zero when clipped or at the noise floor) times its exposure (longer exposures
        // carry less noise), times what the frame's motion mask leaves.
        var sum = [Float](repeating: 0, count: count * 3)
        var total = [Float](repeating: 0, count: count)
        var flags = [UInt8](repeating: 0, count: count)  // 1: clipped in some frame; 2: masked as moving in some frame
        var maskedPixels = Array(repeating: 0, count: frames.count)
        for index in frames.indices {
            try Task.checkCancellation()
            let mask = options.deghost && index != reference ? try motionMask(index) : []
            maskedPixels[index] = mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            let e = Float(exposures[index]), clip = clips[index], floor = floors[index]
            for y in 0..<height {
                if y % 64 == 0 { try Task.checkCancellation() }
                for x in 0..<width {
                    guard let v = sample(index, x, y) else { continue }
                    let p = y * width + x
                    if clipped(v, clip) { flags[p] |= 1; continue }
                    guard luminance(v) > floor else { continue }
                    let t = max(v.x / clip.x, v.y / clip.y, v.z / clip.z)
                    var w = max(0, 1 - pow(2 * t - 1, 12)) * e
                    if !mask.isEmpty, mask[p] > 0 { w *= 1 - mask[p]; flags[p] |= 2 }
                    guard w > 0 else { continue }
                    let scaled = v / e * w
                    sum[p * 3] += scaled.x; sum[p * 3 + 1] += scaled.y; sum[p * 3 + 2] += scaled.z
                    total[p] += w
                }
            }
        }
        // The sum becomes the radiance in place.
        let darkest = exposures.indices.min { exposures[$0] < exposures[$1] }!
        let brightest = exposures.indices.max { exposures[$0] < exposures[$1] }!
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let p = y * width + x
                if total[p] > 0 {
                    sum[p * 3] /= total[p]; sum[p * 3 + 1] /= total[p]; sum[p * 3 + 2] /= total[p]
                } else {
                    // Nothing usable: a clipped highlight takes the darkest frame, a shadow the
                    // brightest; with deghosting a moving region keeps the reference.
                    var chosen = flags[p] & 2 != 0 ? reference : (flags[p] & 1 != 0 ? darkest : brightest)
                    if sample(chosen, x, y) == nil { chosen = reference }
                    let v = sample(chosen, x, y)! / Float(exposures[chosen])
                    sum[p * 3] = max(0, v.x); sum[p * 3 + 1] = max(0, v.y); sum[p * 3 + 2] = max(0, v.z)
                }
            }
        }
        return LWHDRMergeResult(width: width, height: height, samples: sum, referenceIndex: reference,
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

    /// Disagreement rate of the two bitmaps over their compared (non-excluded, overlapping)
    /// pixels at shift (sx, sy), so a larger shift is not rewarded for comparing fewer pixels.
    static func mismatch(_ m: Bitmaps, _ r: Bitmaps, _ sx: Int, _ sy: Int) -> Double {
        var error = 0, compared = 0
        for y in max(0, -sy)..<min(r.height, m.height - sy) {
            for x in max(0, -sx)..<min(r.width, m.width - sx) {
                let a = y * r.width + x, b = (y + sy) * m.width + x + sx
                guard r.exclusion[a], m.exclusion[b] else { continue }
                compared += 1
                if r.threshold[a] != m.threshold[b] { error += 1 }
            }
        }
        return compared == 0 ? .infinity : Double(error) / Double(compared)
    }
    /// The best shift within `radius` of (cx, cy); ties prefer the smaller shift.
    static func search(_ m: Bitmaps, _ r: Bitmaps, around cx: Int, _ cy: Int, radius: Int) -> (rate: Double, x: Int, y: Int) {
        var best = (rate: Double.infinity, x: cx, y: cy)
        for oy in -radius...radius {
            for ox in -radius...radius {
                let sx = cx + ox, sy = cy + oy
                guard abs(sx) < m.width, abs(sy) < m.height else { continue }
                let rate = mismatch(m, r, sx, sy)
                if rate < best.rate - 1e-12 || (abs(rate - best.rate) <= 1e-12 && abs(sx) + abs(sy) < abs(best.x) + abs(best.y)) { best = (rate, sx, sy) }
            }
        }
        return best
    }

    /// The translation of `frame` that best matches `referenceFrame`: a coarse-to-fine
    /// pyramid search (large handheld shifts), checked against a full-resolution search
    /// near zero (fine texture that averaging removes from coarse levels); the lower
    /// full-resolution disagreement wins.
    static func align(_ frame: LWHDRFrame, clip: Float, to referenceFrame: LWHDRFrame, referenceClip: Float) -> LWHDROffset {
        let levels = pyramidLevels(width: frame.width, height: frame.height)
        let moving = Bitmaps.pyramid(frame, clip: clip, levels: levels)
        let reference = Bitmaps.pyramid(referenceFrame, clip: referenceClip, levels: levels)
        var dx = 0, dy = 0, rate = Double.infinity
        for level in stride(from: levels, through: 0, by: -1) {
            (rate, dx, dy) = search(moving[level], reference[level], around: dx * 2, dy * 2, radius: level == levels ? 1 : 2)
        }
        let near = search(moving[0], reference[0], around: 0, 0, radius: 2)
        if near.rate < rate - 1e-12 || (abs(near.rate - rate) <= 1e-12 && abs(near.x) + abs(near.y) < abs(dx) + abs(dy)) { (dx, dy) = (near.x, near.y) }
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
        guard radius > 0 else { return mask.map { $0 ? 1 : 0 } }
        let side = Float(2 * radius + 1)
        var horizontal = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0
                for nx in max(0, x - radius)...min(width - 1, x + radius) where mask[y * width + nx] { s += 1 }
                horizontal[y * width + x] = s / side
            }
        }
        var result = [Float](repeating: 0, count: mask.count)
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
        let clip = LWHDRMerger.clipLevel(reference), floor = LWHDRMerger.luminance(clip) * 0.002
        var sum = 0.0, pixels = 0
        for y in 0..<result.height {
            for x in 0..<result.width where region.contains(where: { $0.contains(x: x, y: y) }) {
                let r = reference.rgb(y * result.width + x)
                guard !LWHDRMerger.clipped(r, clip), LWHDRMerger.luminance(r) > floor else { continue }
                let merged = LWHDRMerger.luminance(result.radiance[y * result.width + x])
                sum += Double(abs(log2(merged + epsilon) - log2(LWHDRMerger.luminance(r) + epsilon)))
                pixels += 1
            }
        }
        return (pixels == 0 ? 0 : sum / Double(pixels), pixels)
    }
}
