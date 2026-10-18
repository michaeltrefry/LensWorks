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

nonisolated enum HDRMergeError: Error, Equatable {
    case invalidFrame, tooFewFrames, mismatchedFrames, destinationIsSource, destinationExists
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
