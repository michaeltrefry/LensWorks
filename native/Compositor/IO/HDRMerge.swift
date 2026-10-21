import Foundation

/// One bracket frame: linear RGB (scene-referred, not display-encoded) in 0...1 plus its exposure offset in stops.
nonisolated struct HDRFrame: Sendable {
    let width: Int
    let height: Int
    /// Interleaved linear RGB, `width * height * 3` samples.
    let rgb: [Float]
    let exposureStops: Float

    init(width: Int, height: Int, rgb: [Float], exposureStops: Float) throws {
        guard width > 0, height > 0, rgb.count == width * height * 3, exposureStops.isFinite else { throw HDRMergeError.invalidFrame }
        self.width = width; self.height = height; self.rgb = rgb; self.exposureStops = exposureStops
    }
}

nonisolated enum HDRMergeError: LocalizedError, Equatable {
    case invalidFrame, tooFewFrames, mismatchedFrames, nonOpaqueFrame, destinationIsSource, destinationExists
    var errorDescription: String? {
        switch self {
        case .invalidFrame: "The HDR inputs or alignment/deghosting options are invalid."
        case .tooFewFrames: "Select at least two bracketed originals."
        case .mismatchedFrames: "Every bracketed original must have the same full-resolution dimensions."
        case .nonOpaqueFrame: "Bracketed originals must be opaque: a linear RGB DNG cannot preserve transparency. No HDR was published."
        case .destinationIsSource: "The HDR destination would replace an original; nothing was written."
        case .destinationExists: "The HDR destination already exists; nothing was replaced."
        }
    }
}

nonisolated struct HDRMergeOptions: Sendable {
    var align = true
    var deghost = false
    /// Largest per-axis translation the aligner searches, in pixels.
    var maximumShift = 8
    /// Relative radiance disagreement above which a frame is treated as showing a moving subject.
    var ghostTolerance: Float = 0.25
}

nonisolated struct HDRMergeResult: Sendable {
    let width: Int
    let height: Int
    /// Linear floating-point RGB radiance relative to the reference frame's exposure. Values may exceed 1.
    let rgb: [Float]
    let referenceIndex: Int
    /// Per-frame translation (x, y) applied so the frame lines up with the reference.
    let shifts: [(x: Int, y: Int)]
}

nonisolated enum HDRMerge {
    private static let low: Float = 0.04, high: Float = 0.96

    static func merge(_ frames: [HDRFrame], options: HDRMergeOptions = HDRMergeOptions()) throws -> HDRMergeResult {
        guard frames.count >= 2 else { throw HDRMergeError.tooFewFrames }
        guard (0...256).contains(options.maximumShift), options.ghostTolerance.isFinite, options.ghostTolerance >= 0 else { throw HDRMergeError.invalidFrame }
        let (w, h) = (frames[0].width, frames[0].height)
        guard frames.allSatisfy({ $0.width == w && $0.height == h }) else { throw HDRMergeError.mismatchedFrames }
        let ref = frames.indices.min { abs(frames[$0].exposureStops) < abs(frames[$1].exposureStops) }!
        var shifts = [(x: Int, y: Int)](repeating: (0, 0), count: frames.count)
        if options.align {
            for i in frames.indices where i != ref { shifts[i] = align(frames[i], to: frames[ref], limit: options.maximumShift) }
        }
        // Radiance scale: pixel / 2^stops puts every frame on the scene's scale; the reference exposure is the output unit.
        let scale = frames.map { exp2(-$0.exposureStops) / exp2(-frames[ref].exposureStops) }
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let r = sample(frames[ref], x, y)
                let refRad = [r[0] * scale[ref], r[1] * scale[ref], r[2] * scale[ref]]
                let refReliable = r.allSatisfy { $0 > low && $0 < high }
                var num: [Float] = [0, 0, 0], den: Float = 0
                var fallback: [Float] = refRad
                for i in frames.indices {
                    let p = sample(frames[i], x - shifts[i].x, y - shifts[i].y)
                    let peak = p.max()!, floor = p.min()!
                    guard floor > 0 || peak > 0 else { continue }
                    var weight = hat(peak) * hat(floor)
                    if options.deghost, i != ref, refReliable {
                        // Compare in radiance space against the reference; a moving subject disagrees.
                        let rad = [p[0] * scale[i], p[1] * scale[i], p[2] * scale[i]]
                        let reliable = p.allSatisfy { $0 > low && $0 < high }
                        if reliable {
                            let diff = zip(rad, refRad).map { abs($0 - $1) }.max()!
                            if diff > options.ghostTolerance * max(refRad.max()!, 0.02) { weight = 0 }
                        } else if p.contains(where: { $0 >= high }) {
                            // A clipped frame cannot confirm the reference; moving content stays out.
                            weight = 0
                        }
                    }
                    if weight > 0 { for c in 0..<3 { num[c] += weight * p[c] * scale[i] }; den += weight }
                    if i == ref { fallback = refRad }
                }
                let o = (y * w + x) * 3
                for c in 0..<3 { out[o + c] = den > 0 ? num[c] / den : fallback[c] }
            }
        }
        return HDRMergeResult(width: w, height: h, rgb: out, referenceIndex: ref, shifts: shifts)
    }

    /// Triangle weight peaking at mid-exposure; never exactly zero so an all-clipped pixel still resolves.
    private static func hat(_ v: Float) -> Float { max(0.001, 1 - abs(2 * v - 1)) }

    private static func sample(_ f: HDRFrame, _ x: Int, _ y: Int) -> [Float] {
        let cx = min(max(x, 0), f.width - 1), cy = min(max(y, 0), f.height - 1)
        let o = (cy * f.width + cx) * 3
        return [f.rgb[o], f.rgb[o + 1], f.rgb[o + 2]]
    }

    /// Exhaustive translation search on exposure-normalised luminance, scored over pixels well exposed in both frames.
    static func align(_ frame: HDRFrame, to ref: HDRFrame, limit: Int) -> (x: Int, y: Int) {
        let gain = exp2(ref.exposureStops - frame.exposureStops)
        func luma(_ f: HDRFrame, _ x: Int, _ y: Int) -> Float {
            let o = (y * f.width + x) * 3
            return 0.2126 * f.rgb[o] + 0.7152 * f.rgb[o + 1] + 0.0722 * f.rgb[o + 2]
        }
        var best = (x: 0, y: 0), bestScore = Float.infinity
        let step = max(1, min(frame.width, frame.height) / 64)
        for dy in -limit...limit {
            for dx in -limit...limit {
                var sum: Float = 0, n: Float = 0
                var y = limit
                while y < frame.height - limit {
                    var x = limit
                    while x < frame.width - limit {
                        let a = luma(ref, x, y), b = luma(frame, x - dx, y - dy)
                        if a > low, a < high, b > low, b < high { sum += abs(a - b * gain); n += 1 }
                        x += step
                    }
                    y += step
                }
                guard n > 0 else { continue }
                // Prefer the smaller shift on ties so a static scene stays put.
                let score = sum / n + 1e-6 * Float(abs(dx) + abs(dy))
                if score < bestScore { bestScore = score; best = (dx, dy) }
            }
        }
        return best
    }
}

/// Ghosting metric: mean absolute radiance error against the reference frame inside the moving-subject region,
/// ignoring reference pixels that are clipped or crushed (no trustworthy truth there).
nonisolated enum HDRGhostMetric {
    static func measure(_ merged: HDRMergeResult, reference: HDRFrame, region: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> Float {
        var sum: Float = 0, n: Float = 0
        for y in max(0, region.minY)...min(merged.height - 1, region.maxY) {
            for x in max(0, region.minX)...min(merged.width - 1, region.maxX) {
                let o = (y * merged.width + x) * 3
                guard (0..<3).allSatisfy({ reference.rgb[o + $0] > 0.04 && reference.rgb[o + $0] < 0.96 }) else { continue }
                for c in 0..<3 { sum += abs(merged.rgb[o + c] - reference.rgb[o + c]); n += 1 }
            }
        }
        return n > 0 ? sum / n : 0
    }
}

/// Production frames retain the authoritative, full-resolution native float plane.
/// The small array-based frames above remain mathematical reference controls.
nonisolated struct HDRPlaneFrame: Sendable {
    let plane: LWFloatPlane
    let exposureStops: Float
    let original: URL
    let sha256: String
}

nonisolated struct HDRPlaneMergeResult: Sendable {
    let plane: LWFloatPlane
    let referenceIndex: Int
    let shifts: [(x: Int, y: Int)]
    var width: Int { plane.width }
    var height: Int { plane.height }
}

nonisolated extension HDRMerge {
    /// Merge through bounded native tiles; neither input nor output goes through
    /// an integer browse image or a whole-frame Swift sample array.
    static func merge(_ frames: [HDRPlaneFrame], options: HDRMergeOptions = HDRMergeOptions()) throws -> HDRPlaneMergeResult {
        guard frames.count >= 2 else { throw HDRMergeError.tooFewFrames }
        let width = frames[0].plane.width, height = frames[0].plane.height
        guard frames.allSatisfy({ $0.plane.width == width && $0.plane.height == height && $0.exposureStops.isFinite }) else {
            throw HDRMergeError.mismatchedFrames
        }
        guard (0...256).contains(options.maximumShift), options.ghostTolerance.isFinite, options.ghostTolerance >= 0 else {
            throw HDRMergeError.invalidFrame
        }
        let reference = frames.indices.min { abs(frames[$0].exposureStops) < abs(frames[$1].exposureStops) }!
        var shifts = [(x: Int, y: Int)](repeating: (0, 0), count: frames.count)
        if options.align {
            for index in frames.indices where index != reference {
                try Task.checkCancellation()
                shifts[index] = try align(frames[index], to: frames[reference], limit: options.maximumShift)
            }
        }
        let scale = frames.map { exp2(frames[reference].exposureStops - $0.exposureStops) }
        guard scale.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw HDRMergeError.invalidFrame }
        let samplers = frames.map { $0.plane.sampler(edge: .clamp) }
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) {
                try Task.checkCancellation()
                for x in range.x..<(range.x + range.width) {
                    let r = try samplers[reference].pixel(x: x, y: y)
                    guard r.w == 1 else { throw HDRMergeError.nonOpaqueFrame }
                    let referenceRGB = SIMD3(r.x, r.y, r.z) * scale[reference]
                    let referenceReliable = r.x > low && r.y > low && r.z > low && r.x < high && r.y < high && r.z < high
                    var numerator = SIMD3<Float>.zero, denominator: Float = 0
                    for index in frames.indices {
                        let p = try samplers[index].pixel(x: x - shifts[index].x, y: y - shifts[index].y)
                        guard p.w == 1 else { throw HDRMergeError.nonOpaqueFrame }
                        let rgb = SIMD3(p.x, p.y, p.z)
                        let peak = max(p.x, p.y, p.z), floor = min(p.x, p.y, p.z)
                        guard peak > 0 || floor > 0 else { continue }
                        var weight = hat(peak) * hat(floor)
                        if options.deghost, index != reference, referenceReliable {
                            let reliable = floor > low && peak < high
                            let delta = rgb * scale[index] - referenceRGB
                            if reliable && max(abs(delta.x), abs(delta.y), abs(delta.z)) > options.ghostTolerance * max(referenceRGB.x, referenceRGB.y, referenceRGB.z, 0.02) {
                                weight = 0
                            } else if !reliable && peak >= high { weight = 0 }
                        }
                        if weight > 0 { numerator += rgb * (weight * scale[index]); denominator += weight }
                    }
                    let merged = denominator > 0 ? numerator / denominator : referenceRGB
                    guard merged.x.isFinite, merged.y.isFinite, merged.z.isFinite else { throw HDRMergeError.invalidFrame }
                    pixels.append(SIMD4(merged.x, merged.y, merged.z, 1))
                }
            }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return HDRPlaneMergeResult(plane: try builder.finish(), referenceIndex: reference, shifts: shifts)
    }

    /// Score every candidate while a local source neighborhood is resident. The
    /// reference grid is bounded; full-size frames retain their native dimensions.
    static func align(_ frame: HDRPlaneFrame, to reference: HDRPlaneFrame, limit: Int) throws -> (x: Int, y: Int) {
        guard (0...256).contains(limit) else { throw HDRMergeError.invalidFrame }
        let width = frame.plane.width, height = frame.plane.height
        let search = min(limit, max(0, (min(width, height) - 1) / 2))
        let side = search * 2 + 1
        let lease = try frame.plane.workingSet.reserve(side * side * MemoryLayout<Float>.stride * 2)
        defer { withExtendedLifetime(lease) {} }
        var sums = [Float](repeating: 0, count: side * side), counts = [Float](repeating: 0, count: side * side)
        let source = frame.plane.sampler(edge: .clamp), target = reference.plane.sampler(edge: .clamp)
        let gain = exp2(reference.exposureStops - frame.exposureStops)
        let step = max(1, min(width, height) / 64)
        for y in stride(from: search, to: height - search, by: step) {
            try Task.checkCancellation()
            for x in stride(from: search, to: width - search, by: step) {
                let p = try target.pixel(x: x, y: y)
                let a = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                guard a > low, a < high else { continue }
                for dy in -search...search { for dx in -search...search {
                    let q = try source.pixel(x: x - dx, y: y - dy)
                    let b = 0.2126 * q.x + 0.7152 * q.y + 0.0722 * q.z
                    if b > low, b < high {
                        let index = (dy + search) * side + dx + search
                        sums[index] += abs(a - b * gain); counts[index] += 1
                    }
                } }
            }
        }
        var best = (x: 0, y: 0), score = Float.infinity
        for dy in -search...search { for dx in -search...search {
            let index = (dy + search) * side + dx + search
            guard counts[index] > 0 else { continue }
            let candidate = sums[index] / counts[index] + 1e-6 * Float(abs(dx) + abs(dy))
            if candidate < score { score = candidate; best = (dx, dy) }
        } }
        return best
    }
}
