import Foundation
import simd

nonisolated enum LWPanoramaBlend: String, Codable, Sendable {
    /// Laplacian-pyramid blending across the seams (Burt and Adelson 1983).
    case multiBand
    /// Each pixel straight from the frame that owns it. For measurement, not for use.
    case none
}

nonisolated struct LWPanoramaOptions: Sendable, Equatable {
    var projection = LWPanoramaProjection.spherical
    var boundary = LWPanoramaBoundary.autoCrop
    /// Solve and remove the frames' exposure differences and lens falloff.
    var compensateExposure = true
    var blend = LWPanoramaBlend.multiBand
}

/// Where the panorama's canvas sits on its projection surface.
nonisolated struct LWPanoramaGeometry: Sendable, Equatable {
    let projection: LWPanoramaProjection
    /// Canvas pixels per radian at the centre: the frames' focal length, so the centre keeps its
    /// resolution (for a full circle, the nearest scale that makes the circle a multiple of 32 pixels).
    let scale: Double
    /// Projected coordinate of canvas pixel (0, 0).
    let originX: Int, originY: Int
    let width: Int, height: Int
    /// The canvas spans the whole 360° of longitude.
    let fullCircle: Bool

    /// Per-column and per-row factors of the world direction a canvas position shows, for canvas
    /// positions `xs` and `ys`: direction = (cx · rs, ry, cz · rs).
    func tables(xs: [Double], ys: [Double]) -> (cx: [Double], cz: [Double], ry: [Double], rs: [Double]) {
        let us = xs.map { ($0 + Double(originX)) / scale }, vs = ys.map { ($0 + Double(originY)) / scale }
        switch projection {
        case .spherical: return (us.map { sin($0) }, us.map { cos($0) }, vs.map { sin($0) }, vs.map { cos($0) })
        case .cylindrical: return (us.map { sin($0) }, us.map { cos($0) }, vs, vs.map { _ in 1 })
        case .perspective: return (us, us.map { _ in 1 }, vs, vs.map { _ in 1 })
        }
    }
}

/// A stitched panorama: linear radiance with the frames' exposure differences removed.
nonisolated struct LWPanoramaResult: Sendable {
    let width: Int, height: Int
    /// R, G, B per pixel, row-major, as half floats: 6 bytes per pixel.
    let samples: [Float16]
    /// The frame each pixel was taken from at the seam finder's choice; 255 where no frame covers the pixel (filled).
    let labels: [UInt8]
    /// Canvas position of this picture's pixel (0, 0): the crop's corner, or (0, 0) for a filled canvas.
    let offsetX: Int, offsetY: Int
    let geometry: LWPanoramaGeometry
    /// The alignment the picture was composed with (re-centred for the perspective projection).
    let alignment: LWPanoramaAlignment
    let options: LWPanoramaOptions
    /// Pyramid levels blended above the base.
    let bands: Int
    /// Pixels of this picture no frame covers: always 0 after an auto-crop.
    let uncoveredPixels: Int
    /// The working memory the merge was budgeted at.
    let workingBytes: Int
    /// The brightest sample of the picture.
    let peak: Float
    @inline(__always) func rgb(_ pixel: Int) -> SIMD3<Float> {
        SIMD3(Float(samples[pixel * 3]), Float(samples[pixel * 3 + 1]), Float(samples[pixel * 3 + 2]))
    }
}

nonisolated extension LWPanoramaStitcher {
    // MARK: Working memory (docs/PANORAMA_MERGE.md, "Memory")

    /// Each reduced working copy and its feature scratch, per frame.
    static let workBytesPerFrame = 48 * 1024 * 1024
    /// The canvas: the blend pyramid that becomes the result in place (8), its mask sums above the
    /// base (0.7) and the seam labels (1). The label pass's weights (1) are released before the blend.
    static let canvasBytesPerPixel = 10
    /// One frame at a time warped onto its part of the canvas with its coverage and mask (10) and
    /// their pyramids (3.3), in one set of buffers sized for the largest part and reused for every frame.
    static let warpBytesPerPixel = 14
    /// Canvas pixels expected before the frames are aligned: each frame after the first adds about 70 % of itself.
    static func expectedCanvasPixels(frames: Int, width: Int, height: Int) -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels < Int.max / 64 else { return .max }
        return pixels + pixels / 10 * 7 * (frames - 1)
    }
    static func workingBytes(frames: Int, width: Int, height: Int, canvasPixels: Int, warpPixels: Int) -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels < Int.max / 1024, canvasPixels < Int.max / 64, warpPixels < Int.max / 64 else { return .max }
        return frames * (pixels * LWMergeFrame.bytesPerPixel + workBytesPerFrame) + canvasPixels * canvasBytesPerPixel + warpPixels * warpBytesPerPixel
    }
    /// Refuses, with the numbers, a merge that cannot fit the budget whatever its layout turns out
    /// to be. Called as soon as the first photo's dimensions are known, before any frame is loaded.
    static func admit(frames: Int, width: Int, height: Int, budget: Int = LWMergeBudget.bytes) throws {
        guard width > 0, height > 0 else { throw LWMergeFrameError.invalid }
        let canvas = expectedCanvasPixels(frames: frames, width: width, height: height)
        let needed = workingBytes(frames: frames, width: width, height: height, canvasPixels: canvas, warpPixels: width * height)
        guard needed <= budget else {
            throw LWPanoramaError.tooLarge(frames: frames, width: width, height: height, outputWidth: 0, outputHeight: 0, neededBytes: needed, budgetBytes: budget)
        }
    }

    // MARK: Layout

    /// A half-open rectangle of canvas pixels. On a full circle a frame's rectangle may start
    /// before column 0 or end past the last column: its columns are taken round the circle.
    struct Region: Sendable, Equatable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
    }

    /// The longitudes and latitudes a frame sees, in radians: longitudes `centre + low` to
    /// `centre + high`, where `centre` is the longitude the camera points at.
    struct Span: Sendable {
        var centre = 0.0, low = 0.0, high = 0.0
        var south = Double.infinity, north = -Double.infinity
        /// The frame sees a pole, and so every longitude.
        var whole = false
    }
    static func spans(_ alignment: LWPanoramaAlignment) -> [Span] {
        let w = alignment.width, h = alignment.height
        var border: [SIMD2<Double>] = []
        for x in 0..<w { border.append(SIMD2(Double(x), 0)); border.append(SIMD2(Double(x), Double(h - 1))) }
        for y in 0..<h { border.append(SIMD2(0, Double(y))); border.append(SIMD2(Double(w - 1), Double(y))) }
        return alignment.rotations.indices.map { frame in
            let forward = alignment.rotations[frame][2]
            var span = Span(centre: atan2(forward.x, forward.z))
            for p in border {
                let d = alignment.ray(frame: frame, x: p.x, y: p.y)
                var delta = atan2(d.x, d.z) - span.centre
                if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                span.low = min(span.low, delta); span.high = max(span.high, delta)
                let latitude = atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot())
                span.south = min(span.south, latitude); span.north = max(span.north, latitude)
            }
            for pole in [-1.0, 1.0] {
                guard let p = alignment.pixel(frame: frame, ray: SIMD3(0, pole, 0)), p.x >= 0, p.y >= 0, p.x <= Double(w - 1), p.y <= Double(h - 1) else { continue }
                span.whole = true
                if pole < 0 { span.south = -.pi / 2 } else { span.north = .pi / 2 }
            }
            if span.high - span.low >= 2 * .pi - 1e-6 { span.whole = true }
            return span
        }
    }
    /// The widest stretch of longitude that no frame sees, as its middle and its width in radians;
    /// nil when the frames leave none wider than `least`, which makes the panorama a full circle.
    static func widestGap(_ spans: [Span], least: Double) -> (middle: Double, width: Double)? {
        guard !spans.isEmpty, !spans.contains(where: \.whole) else { return nil }
        let turn = 2 * Double.pi
        // Each frame's stretch, starting in 0 ..< 360°; one that passes 360° also covers the start of the circle.
        let stretches = spans.map { span -> (start: Double, end: Double) in
            var start = (span.centre + span.low).truncatingRemainder(dividingBy: turn)
            if start < 0 { start += turn }
            return (start, start + span.high - span.low)
        }.sorted { $0.start < $1.start }
        let furthest = stretches.map(\.end).max()!
        var reach = max(stretches[0].end, furthest - turn)
        var best: (middle: Double, width: Double)?
        func consider(from: Double, to: Double) { if to - from > (best?.width ?? least) { best = ((from + to) / 2, to - from) } }
        for stretch in stretches.dropFirst() {
            consider(from: reach, to: stretch.start)
            reach = max(reach, stretch.end)
        }
        consider(from: furthest, to: stretches[0].start + turn)
        return best
    }
    /// Turns the world about the vertical so the widest stretch no frame sees lies at ±180°, where
    /// a spherical or cylindrical canvas is cut. A set with no such stretch is left as it is.
    static func centredOnCoverage(_ alignment: LWPanoramaAlignment) -> [simd_double3x3] {
        guard let gap = widestGap(spans(alignment), least: 2 / alignment.focal) else { return alignment.rotations }
        let turn = simd_double3x3(simd_quatd(angle: .pi - gap.middle, axis: SIMD3(0, 1, 0)))
        return alignment.rotations.map { turn * $0 }
    }

    /// Pyramid levels above the base that a full circle's width is a whole number of pixels at.
    static let maximumBands = 5

    /// The canvas that holds every frame on the projection surface, and each frame's part of it.
    static func layout(_ alignment: LWPanoramaAlignment, projection: LWPanoramaProjection) throws -> (geometry: LWPanoramaGeometry, regions: [Region]) {
        let w = alignment.width, h = alignment.height
        struct Extent { var u0 = Double.infinity, u1 = -Double.infinity, v0 = Double.infinity, v1 = -Double.infinity; var whole = false }
        var extents: [Extent] = []
        var scale = alignment.focal, fullCircle = false
        if projection == .perspective {
            var border: [SIMD2<Double>] = []
            for x in 0..<w { border.append(SIMD2(Double(x), 0)); border.append(SIMD2(Double(x), Double(h - 1))) }
            for y in 0..<h { border.append(SIMD2(0, Double(y))); border.append(SIMD2(Double(w - 1), Double(y))) }
            for frame in alignment.rotations.indices {
                var extent = Extent(), widest = 0.0
                for p in border {
                    let d = alignment.ray(frame: frame, x: p.x, y: p.y)
                    let angle = acos(max(-1, min(1, d.z / simd_length(d))))
                    widest = max(widest, angle)
                    guard d.z > 1e-6 else { continue }
                    extent.u0 = min(extent.u0, scale * d.x / d.z); extent.u1 = max(extent.u1, scale * d.x / d.z)
                    extent.v0 = min(extent.v0, scale * d.y / d.z); extent.v1 = max(extent.v1, scale * d.y / d.z)
                }
                guard widest <= 70 * .pi / 180 else { throw LWPanoramaError.tooWideForPerspective(degrees: Int((widest * 2 * 180 / .pi).rounded())) }
                extents.append(extent)
            }
        } else {
            let seen = spans(alignment), latitudeLimit = 80.0 * .pi / 180
            // Frames that leave no stretch of longitude unseen make a full circle. Its width is a
            // whole number of pixels at every pyramid level, so the blend runs round the circle
            // and the picture's two ends meet; the scale gives way by at most a part in a hundred.
            if widestGap(seen, least: 2 / scale) == nil {
                fullCircle = true
                let grain = Double(1 << maximumBands)
                scale = max(1, (2 * .pi * scale / grain).rounded()) * grain / (2 * .pi)
            }
            func height(_ latitude: Double) -> Double { projection == .spherical ? latitude : tan(max(-latitudeLimit, min(latitudeLimit, latitude))) }
            extents = seen.map { span in
                Extent(u0: scale * (span.centre + span.low), u1: scale * (span.centre + span.high), v0: scale * height(span.south), v1: scale * height(span.north), whole: span.whole)
            }
        }
        let u0 = extents.map(\.u0).min()!, u1 = extents.map(\.u1).max()!
        let v0 = extents.map(\.v0).min()!, v1 = extents.map(\.v1).max()!
        guard u0.isFinite, u1.isFinite, v0.isFinite, v1.isFinite else { throw LWPanoramaError.notOnePanorama(rmsPixels: alignment.rms) }
        let circle = Int((2 * scale * .pi).rounded())
        let originX = fullCircle ? -circle / 2 : Int(u0.rounded(.down)) - 1, originY = Int(v0.rounded(.down)) - 1
        let width = fullCircle ? circle : Int(u1.rounded(.up)) + 2 - originX, height = Int(v1.rounded(.up)) + 2 - originY
        guard width > 0, height > 0, width < 1 << 24, height < 1 << 24 else { throw LWPanoramaError.outputTooLarge(width: max(0, width), height: max(0, height)) }
        guard width * height <= maximumOutputPixels else { throw LWPanoramaError.outputTooLarge(width: width, height: height) }
        let regions = extents.map { extent -> Region in
            let y0 = max(0, Int(extent.v0.rounded(.down)) - 1 - originY), y1 = min(height, Int(extent.v1.rounded(.up)) + 2 - originY)
            var x0 = Int(extent.u0.rounded(.down)) - 1 - originX, x1 = Int(extent.u1.rounded(.up)) + 2 - originX
            guard fullCircle else { return Region(x0: max(0, x0), y0: y0, x1: min(width, x1), y1: y1) }
            if extent.whole || x1 - x0 >= width { return Region(x0: 0, y0: y0, x1: width, y1: y1) }
            // Start inside the canvas; the end may pass the last column, and comes round to the first.
            let turns = Int((Double(x0) / Double(width)).rounded(.down)) * width
            x0 -= turns; x1 -= turns
            return Region(x0: x0, y0: y0, x1: x1, y1: y1)
        }
        return (LWPanoramaGeometry(projection: projection, scale: scale, originX: originX, originY: originY, width: width, height: height, fullCircle: fullCircle), regions)
    }

    // MARK: Sampling
    //
    // The per-pixel code from here on is written with scalars, raw pointers and `while` loops.
    // In an optimized build that changes nothing. In the unoptimized test build a `for` over a
    // range, a buffer subscript and a SIMD operation are each a call, and these loops run once
    // per canvas pixel.

    /// A finite sample clamped into the half-float range; a non-finite one stays non-finite.
    @inline(__always) static func half(_ value: Float) -> Float16 {
        if value > 65504 { return Float16(65504) }
        if value < -65504 { return Float16(-65504) }
        return Float16(value)
    }

    /// Catmull–Rom bicubic sample of a frame (R, G, B half floats) at a position inside it, into
    /// `out[0..<3]`. `scratch` is 8 floats.
    @inline(__always) static func bicubic(_ samples: UnsafePointer<Float16>, _ width: Int, _ height: Int, _ x: Double, _ y: Double,
                                          _ scratch: UnsafeMutablePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let ix = Int(x), iy = Int(y)
        var t = Float(x - Double(ix)), t2 = t * t, t3 = t2 * t
        scratch[0] = -0.5 * t3 + t2 - 0.5 * t; scratch[1] = 1.5 * t3 - 2.5 * t2 + 1; scratch[2] = -1.5 * t3 + 2 * t2 + 0.5 * t; scratch[3] = 0.5 * t3 - 0.5 * t2
        t = Float(y - Double(iy)); t2 = t * t; t3 = t2 * t
        scratch[4] = -0.5 * t3 + t2 - 0.5 * t; scratch[5] = 1.5 * t3 - 2.5 * t2 + 1; scratch[6] = -1.5 * t3 + 2 * t2 + 0.5 * t; scratch[7] = 0.5 * t3 - 0.5 * t2
        var r: Float = 0, g: Float = 0, b: Float = 0, j = 0
        while j < 4 {
            var sy = iy + j - 1
            if sy < 0 { sy = 0 } else if sy >= height { sy = height - 1 }
            let row = samples + sy * width * 3
            var lr: Float = 0, lg: Float = 0, lb: Float = 0, i = 0
            while i < 4 {
                var sx = ix + i - 1
                if sx < 0 { sx = 0 } else if sx >= width { sx = width - 1 }
                let p = row + sx * 3, weight = scratch[i]
                lr += weight * Float(p[0]); lg += weight * Float(p[1]); lb += weight * Float(p[2])
                i += 1
            }
            let weight = scratch[4 + j]
            r += weight * lr; g += weight * lg; b += weight * lb
            j += 1
        }
        out[0] = r; out[1] = g; out[2] = b
    }

    /// What one frame contributes at canvas positions: where each falls in the frame, and how to
    /// take the frame's exposure and lens falloff out of the sample there.
    struct Mapper {
        // transpose(R), by rows.
        let ax: Double, ay: Double, az: Double, bx: Double, by: Double, bz: Double, cx: Double, cy: Double, cz: Double
        let focal: Double, px: Double, py: Double, maxX: Double, maxY: Double, halfSide: Double
        /// 1 / gain, per channel.
        let red: Float, green: Float, blue: Float
        /// The level at or above which the frame's own samples are clipped, per channel.
        let clipRed: Float, clipGreen: Float, clipBlue: Float
        /// The level no compensated sample exceeds (`LWPanoramaStitcher.ceiling`).
        let ceiling: Float
        let v1: Double, v2: Double, corner: Double, flat: Bool
        init(_ alignment: LWPanoramaAlignment, frame: Int, clips: [SIMD3<Float>]) {
            let t = alignment.rotations[frame].transpose
            ax = t[0][0]; ay = t[1][0]; az = t[2][0]; bx = t[0][1]; by = t[1][1]; bz = t[2][1]; cx = t[0][2]; cy = t[1][2]; cz = t[2][2]
            focal = alignment.focal; px = alignment.principal.x; py = alignment.principal.y
            maxX = Double(alignment.width - 1); maxY = Double(alignment.height - 1); halfSide = min(maxX, maxY) / 2
            let gain = alignment.gains[frame], clip = clips[frame]
            red = 1 / gain.x; green = 1 / gain.y; blue = 1 / gain.z
            clipRed = clip.x; clipGreen = clip.y; clipBlue = clip.z
            ceiling = LWPanoramaStitcher.ceiling(alignment, clips: clips)
            v1 = alignment.vignetting.x; v2 = alignment.vignetting.y; flat = alignment.vignetting == .zero
            corner = px * px + py * py
        }
        /// The frame position of the world direction (rx, ry, rz); false outside the frame.
        @inline(__always) func locate(_ rx: Double, _ ry: Double, _ rz: Double, _ x: inout Double, _ y: inout Double) -> Bool {
            let z = cx * rx + cy * ry + cz * rz
            if z <= 1e-9 { return false }
            x = focal * (ax * rx + ay * ry + az * rz) / z + px
            y = focal * (bx * rx + by * ry + bz * rz) / z + py
            return x >= 0 && y >= 0 && x <= maxX && y <= maxY
        }
        /// Distance to the nearest frame edge, as a fraction of half the frame's short side.
        @inline(__always) func feather(_ x: Double, _ y: Double) -> Float {
            var d = x
            if maxX - x < d { d = maxX - x }
            if y < d { d = y }
            if maxY - y < d { d = maxY - y }
            return Float(d / halfSide)
        }
        /// What undoes the lens falloff at a frame position.
        @inline(__always) func unfalloff(_ x: Double, _ y: Double) -> Float {
            if flat { return 1 }
            let r2 = ((x - px) * (x - px) + (y - py) * (y - py)) / corner
            return Float(exp2(-(v1 * r2 + v2 * r2 * r2)))
        }
        /// Takes the frame's exposure and falloff out of the sample `value[0..<3]` read at a frame
        /// position, in place. A sample at or above the frame's clip level records no colour and no
        /// brightness of its own, only that the scene was at least that bright: it becomes the
        /// neutral ceiling, the same for every frame, and no sample is brighter than the ceiling.
        @inline(__always) func compensate(_ value: UnsafeMutablePointer<Float>, _ x: Double, _ y: Double) {
            if value[0] >= clipRed || value[1] >= clipGreen || value[2] >= clipBlue { value[0] = ceiling; value[1] = ceiling; value[2] = ceiling; return }
            let falloff = unfalloff(x, y)
            let r = value[0] * red * falloff, g = value[1] * green * falloff, b = value[2] * blue * falloff
            value[0] = r > ceiling ? ceiling : r; value[1] = g > ceiling ? ceiling : g; value[2] = b > ceiling ? ceiling : b
        }
    }

    /// The brightest level the panorama holds: the compensated clip level of the frame with the
    /// least headroom. Above it that frame has nothing to offer, so where it is blown and another
    /// frame is not, the two could not be joined; every frame's samples stop there instead.
    static func ceiling(_ alignment: LWPanoramaAlignment, clips: [SIMD3<Float>]) -> Float {
        var lowest = Float.infinity
        for (clip, gain) in zip(clips, alignment.gains) {
            let level = (clip / gain).min()
            if level.isFinite, level > 0, level < lowest { lowest = level }
        }
        return lowest
    }

    /// Per-column and per-row factors of the canvas rays, as `LWPanoramaGeometry.tables` gives them.
    typealias Tables = (cx: [Double], cz: [Double], ry: [Double], rs: [Double])

    // MARK: Pyramids (5-tap binomial reduce and its expand; borders are clamped, or with `wrap` the
    // columns run round a full circle)

    /// Column `x` of `width`, taken round the circle when `wrap` is set and clamped otherwise.
    @inline(__always) static func column(_ x: Int, _ width: Int, _ wrap: Bool) -> Int {
        if x >= 0, x < width { return x }
        if wrap { let m = x % width; return m < 0 ? m + width : m }
        return x < 0 ? 0 : width - 1
    }

    /// One output row of the reduction of `source` (width × height × channels half floats). `scratch` is width × channels floats.
    static func reduceRow(_ source: UnsafePointer<Float16>, _ width: Int, _ height: Int, _ channels: Int, row: Int, wrap: Bool = false,
                          scratch: UnsafeMutablePointer<Float>, into target: UnsafeMutablePointer<Float16>) {
        let stride = width * channels
        var i = 0
        while i < stride { scratch[i] = 0; i += 1 }
        var j = 0
        while j < 5 {
            var sy = 2 * row + j - 2
            if sy < 0 { sy = 0 } else if sy >= height { sy = height - 1 }
            let line = source + sy * stride
            let weight: Float = j == 2 ? 0.375 : (j == 1 || j == 3 ? 0.25 : 0.0625)
            i = 0
            while i < stride { scratch[i] += weight * Float(line[i]); i += 1 }
            j += 1
        }
        let out = (width + 1) / 2
        var x = 0
        while x < out {
            let centre = 2 * x
            let a = column(centre - 2, width, wrap) * channels, b = column(centre - 1, width, wrap) * channels, c = centre * channels
            let d = column(centre + 1, width, wrap) * channels, e = column(centre + 2, width, wrap) * channels
            var k = 0
            while k < channels {
                target[x * channels + k] = Float16((scratch[a + k] + scratch[e + k]) * 0.0625 + (scratch[b + k] + scratch[d + k]) * 0.25 + scratch[c + k] * 0.375)
                k += 1
            }
            x += 1
        }
    }
    static func reduce(_ source: [Float16], _ width: Int, _ height: Int, _ channels: Int, wrap: Bool = false) throws -> [Float16] {
        var result = [Float16](repeating: 0, count: ((width + 1) / 2) * ((height + 1) / 2) * channels)
        try source.withUnsafeBufferPointer { src in try result.withUnsafeMutableBufferPointer { dst in try reduce(src.baseAddress!, width, height, channels, wrap: wrap, into: dst.baseAddress!) } }
        return result
    }
    /// The reduction of `source` (width × height × channels) into `target`, which holds ((width + 1) / 2) × ((height + 1) / 2) × channels.
    static func reduce(_ source: UnsafePointer<Float16>, _ width: Int, _ height: Int, _ channels: Int, wrap: Bool = false, into target: UnsafeMutablePointer<Float16>) throws {
        let w = (width + 1) / 2, h = (height + 1) / 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: width * channels)
        defer { scratch.deallocate() }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            reduceRow(source, width, height, channels, row: y, wrap: wrap, scratch: scratch, into: target + y * w * channels)
            y += 1
        }
    }
    /// The reduction of the coverage (1 where a label is set, 0 where it is 255), without holding the coverage itself.
    static func reduceCoverage(_ labels: [UInt8], _ width: Int, _ height: Int, wrap: Bool = false) throws -> [Float16] {
        let w = (width + 1) / 2, h = (height + 1) / 2
        var result = [Float16](repeating: 0, count: w * h)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: width)
        defer { scratch.deallocate() }
        try labels.withUnsafeBufferPointer { source in
            try result.withUnsafeMutableBufferPointer { target in
                let src = source.baseAddress!, dst = target.baseAddress!
                var y = 0
                while y < h {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    var i = 0
                    while i < width { scratch[i] = 0; i += 1 }
                    var j = 0
                    while j < 5 {
                        var sy = 2 * y + j - 2
                        if sy < 0 { sy = 0 } else if sy >= height { sy = height - 1 }
                        let line = src + sy * width
                        let weight: Float = j == 2 ? 0.375 : (j == 1 || j == 3 ? 0.25 : 0.0625)
                        i = 0
                        while i < width { if line[i] != 255 { scratch[i] += weight }; i += 1 }
                        j += 1
                    }
                    var x = 0
                    while x < w {
                        let centre = 2 * x
                        let outer = scratch[column(centre - 2, width, wrap)] + scratch[column(centre + 2, width, wrap)]
                        let inner = scratch[column(centre - 1, width, wrap)] + scratch[column(centre + 1, width, wrap)]
                        dst[y * w + x] = Float16(outer * 0.0625 + inner * 0.25 + scratch[centre] * 0.375)
                        x += 1
                    }
                    y += 1
                }
            }
        }
        return result
    }
    /// One row, `width` pixels wide, of the expansion of `coarse` (cw × ch × channels) to twice
    /// its size. `scratch` is cw × channels floats; `target` is width × channels.
    static func expandRow(_ coarse: UnsafePointer<Float16>, _ cw: Int, _ ch: Int, _ channels: Int, row: Int, width: Int, wrap: Bool = false,
                          scratch: UnsafeMutablePointer<Float>, into target: UnsafeMutablePointer<Float>) {
        let stride = cw * channels, j = row / 2
        let lower = (j > ch - 1 ? ch - 1 : j), upper = (j + 1 > ch - 1 ? ch - 1 : j + 1)
        var i = 0
        if row % 2 == 0 {
            let a = coarse + (j - 1 < 0 ? 0 : j - 1) * stride, b = coarse + lower * stride, c = coarse + upper * stride
            while i < stride { scratch[i] = (Float(a[i]) + Float(c[i])) * 0.125 + Float(b[i]) * 0.75; i += 1 }
        } else {
            let a = coarse + lower * stride, b = coarse + upper * stride
            while i < stride { scratch[i] = (Float(a[i]) + Float(b[i])) * 0.5; i += 1 }
        }
        var x = 0
        while x < width {
            let i = x / 2, out = target + x * channels
            let mid = (i > cw - 1 ? cw - 1 : i) * channels, right = column(i + 1, cw, wrap) * channels
            var k = 0
            if x % 2 == 0 {
                let left = column(i - 1, cw, wrap) * channels
                while k < channels { out[k] = (scratch[left + k] + scratch[right + k]) * 0.125 + scratch[mid + k] * 0.75; k += 1 }
            } else {
                while k < channels { out[k] = (scratch[mid + k] + scratch[right + k]) * 0.5; k += 1 }
            }
            x += 1
        }
    }

    // MARK: Seams

    /// Where a frame lies on the reduced canvas the seams are found on: how many of its pixels
    /// fall in each column, the sum of their rows, and their count.
    struct Footprint: Sendable {
        var columns: [Int32]
        var rows = 0.0, count = 0.0
    }

    /// One frame on the reduced canvas the seams are found on: its compensated luminance where it
    /// has data (NaN elsewhere), its claim on each pixel by distance from its own edge, and its
    /// footprint. `columns` are the canvas columns its part of the canvas takes in.
    private static func seamInputs(_ frame: UInt8, _ mapper: Mapper, _ work: Work, _ table: Tables, columns: [Int], y0: Int, y1: Int, lowWidth: Int,
                                   values: UnsafeMutablePointer<Float>, strongest: UnsafeMutablePointer<Float>, labels: UnsafeMutablePointer<UInt8>, footprint: inout Footprint) {
        var sumY = 0.0, covered = 0.0, sx = 0.0, sy = 0.0
        let ww = work.width, wh = work.height, shift = Double(work.factor - 1) / 2, scale = 1 / Double(work.factor)
        let value = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        defer { value.deallocate() }
        work.rgb.withUnsafeBufferPointer { buffer in
            let rgb = buffer.baseAddress!
            table.cx.withUnsafeBufferPointer { tcx in table.cz.withUnsafeBufferPointer { tcz in table.ry.withUnsafeBufferPointer { tvy in table.rs.withUnsafeBufferPointer { trs in
            columns.withUnsafeBufferPointer { cols in footprint.columns.withUnsafeMutableBufferPointer { counts in
                var y = y0
                while y < y1 {
                    let ry = tvy[y], rs = trs[y]
                    var c = 0
                    while c < cols.count {
                        let x = cols[c]
                        c += 1
                        if mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                            // Bilinear sample of the reduced copy.
                            var wx = (sx - shift) * scale, wy = (sy - shift) * scale
                            if wx < 0 { wx = 0 } else if wx > Double(ww - 1) { wx = Double(ww - 1) }
                            if wy < 0 { wy = 0 } else if wy > Double(wh - 1) { wy = Double(wh - 1) }
                            var ix = Int(wx), iy = Int(wy)
                            if ix > ww - 2 { ix = ww - 2 }
                            if iy > wh - 2 { iy = wh - 2 }
                            let fx = Float(wx - Double(ix)), fy = Float(wy - Double(iy))
                            let p = rgb + (iy * ww + ix) * 3, q = p + ww * 3
                            let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                            value[0] = w00 * p[0] + w10 * p[3] + w01 * q[0] + w11 * q[3]
                            value[1] = w00 * p[1] + w10 * p[4] + w01 * q[1] + w11 * q[4]
                            value[2] = w00 * p[2] + w10 * p[5] + w01 * q[2] + w11 * q[5]
                            mapper.compensate(value, sx, sy)
                            let luminance = 0.2126 * value[0] + 0.7152 * value[1] + 0.0722 * value[2]
                            let i = y * lowWidth + x
                            values[i] = luminance > 0 ? luminance : 0
                            let weight = mapper.feather(sx, sy)
                            if weight > strongest[i] { strongest[i] = weight; labels[i] = frame }
                            counts[x] += 1; sumY += Double(y); covered += 1
                        }
                    }
                    y += 1
                }
            } }
            } } } }
        }
        footprint.rows += sumY; footprint.count += covered
    }

    /// Moves the seam between two frames to the path through their overlap where they differ
    /// least (dynamic programming over one path position per row, or per column for frames one
    /// above the other). Only pixels already given to one of the two change hands.
    ///
    /// Which frame keeps which side of the path is decided for this overlap: by where each
    /// frame lies relative to it. On a full circle (`cyclic`) the columns run round the canvas,
    /// so an overlap that crosses the ±180° cut is one piece, and the frame that straddles the
    /// cut is on the right of its neighbour at one end of the canvas and on the left of its other
    /// neighbour at the other end.
    static func refineSeam(_ a: Int, _ b: Int, luminance: [[Float]], footprints: [Footprint], labels: inout [UInt8], width: Int, height: Int, cyclic: Bool) {
        luminance[a].withUnsafeBufferPointer { pa in luminance[b].withUnsafeBufferPointer { pb in labels.withUnsafeMutableBufferPointer { pl in
            refineSeam(UInt8(a), UInt8(b), footprints[a], footprints[b], cyclic, pa.baseAddress!, pb.baseAddress!, pl.baseAddress!, width, height)
        } } }
    }
    /// A frame's centre on the reduced canvas, its columns measured from `middle`: on a full
    /// circle by the shorter way round, so a frame that crosses the cut has one centre, not the
    /// middle of the canvas between its two ends.
    static func centre(_ footprint: Footprint, from middle: Double, width: Int, cyclic: Bool) -> SIMD2<Double> {
        var sum = 0.0
        footprint.columns.withUnsafeBufferPointer { counts in
            var x = 0
            while x < width {
                if counts[x] > 0 {
                    var distance = Double(x) - middle
                    if cyclic { distance -= (distance / Double(width)).rounded() * Double(width) }
                    sum += distance * Double(counts[x])
                }
                x += 1
            }
        }
        return footprint.count > 0 ? SIMD2(sum / footprint.count, footprint.rows / footprint.count) : .zero
    }
    private static func refineSeam(_ a: UInt8, _ b: UInt8, _ fa: Footprint, _ fb: Footprint, _ cyclic: Bool,
                                   _ la: UnsafePointer<Float>, _ lb: UnsafePointer<Float>, _ labels: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int) {
        let occupied = UnsafeMutablePointer<Bool>.allocate(capacity: width)
        defer { occupied.deallocate() }
        occupied.update(repeating: false, count: width)
        var y0 = height, y1 = -1, owned = 0, p = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                // NaN marks a pixel a frame does not cover: it is the only value that differs from itself.
                if la[p] == la[p], lb[p] == lb[p] {
                    occupied[x] = true
                    if y < y0 { y0 = y }
                    if y > y1 { y1 = y }
                    if labels[p] == a || labels[p] == b { owned += 1 }
                }
                p += 1; x += 1
            }
            y += 1
        }
        guard owned > 0, y1 >= y0 else { return }
        // The overlap's columns, in order. On a full circle they start after the widest stretch
        // of columns the overlap leaves empty.
        var start = 0, span = width
        if cyclic {
            var widest = 0, end = -1, run = 0, x = 0
            while x < 2 * width, run < width {
                if occupied[x % width] { run = 0 } else { run += 1; if run > widest { widest = run; end = x % width } }
                x += 1
            }
            if widest > 0, widest < width { start = (end + 1) % width; span = width - widest }
        } else {
            var x0 = 0, x1 = width - 1
            while !occupied[x0] { x0 += 1 }
            while !occupied[x1] { x1 -= 1 }
            start = x0; span = x1 - x0 + 1
        }
        let middle = Double(start) + Double(span) / 2
        let ca = centre(fa, from: middle, width: width, cyclic: cyclic), cb = centre(fb, from: middle, width: width, cyclic: cyclic)
        let vertical = abs(ca.x - cb.x) >= abs(ca.y - cb.y)
        // `first` keeps the low side of the path (left of a top-to-bottom seam, above a left-to-right one).
        let first = vertical ? (ca.x <= cb.x ? a : b) : (ca.y <= cb.y ? a : b), second = first == a ? b : a
        let rows = y1 - y0 + 1
        let along = vertical ? rows : span, across = vertical ? span : rows
        let cost = UnsafeMutablePointer<Float>.allocate(capacity: along * across), from = UnsafeMutablePointer<Int8>.allocate(capacity: along * across)
        defer { cost.deallocate(); from.deallocate() }
        let outside: Float = 8
        @inline(__always) func pixel(_ i: Int, _ j: Int) -> Int {
            var x = start + (vertical ? j : i)
            if x >= width { x -= width }
            return (y0 + (vertical ? i : j)) * width + x
        }
        var i = 0
        while i < along {
            var j = 0
            while j < across {
                let p = pixel(i, j)
                var c = outside, step: Int8 = 0
                if la[p] == la[p], lb[p] == lb[p] {
                    var difference = log2((la[p] + 1e-4) / (lb[p] + 1e-4))
                    if difference < 0 { difference = -difference }
                    c = (difference > 2 ? 2 : difference) + 0.02
                }
                if i > 0 {
                    let above = cost + (i - 1) * across
                    var best = above[j]
                    if j > 0, above[j - 1] < best { best = above[j - 1]; step = -1 }
                    if j + 1 < across, above[j + 1] < best { best = above[j + 1]; step = 1 }
                    c += best
                }
                cost[i * across + j] = c; from[i * across + j] = step
                j += 1
            }
            i += 1
        }
        var j = 0, candidate = 1
        while candidate < across { if cost[(along - 1) * across + candidate] < cost[(along - 1) * across + j] { j = candidate }; candidate += 1 }
        i = along - 1
        while i >= 0 {
            var k = 0
            while k < across {
                let p = pixel(i, k)
                if la[p] == la[p], lb[p] == lb[p], labels[p] == a || labels[p] == b { labels[p] = k <= j ? first : second }
                k += 1
            }
            j += Int(from[i * across + j])
            i -= 1
        }
    }

    /// Gives one frame's claim to every canvas pixel it covers in `region`: the seam finder's choice
    /// where that frame really covers the pixel, otherwise the covering frame whose edge is farthest.
    /// `columns` holds the canvas column of each of the region's columns, or -1 outside the canvas.
    private static func claim(_ frame: UInt8, _ mapper: Mapper, _ table: Tables, _ region: Region, columns: [Int], _ width: Int, _ q: Int,
                              _ lowLabels: UnsafePointer<UInt8>, _ lowWidth: Int, _ labels: UnsafeMutablePointer<UInt8>, _ strongest: UnsafeMutablePointer<UInt8>) throws {
        var sx = 0.0, sy = 0.0
        try table.cx.withUnsafeBufferPointer { tcx in try table.cz.withUnsafeBufferPointer { tcz in try table.ry.withUnsafeBufferPointer { tvy in try table.rs.withUnsafeBufferPointer { trs in
        try columns.withUnsafeBufferPointer { cols in
            var y = region.y0
            while y < region.y1 {
                if y % 64 == 0 { try Task.checkCancellation() }
                let ry = tvy[y], rs = trs[y], low = lowLabels + (y / q) * lowWidth
                var c = 0
                while c < cols.count {
                    let x = cols[c]
                    c += 1
                    if x >= 0, mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                        let i = y * width + x
                        if low[x / q] == frame { labels[i] = frame; strongest[i] = 255 }
                        else {
                            var weight = mapper.feather(sx, sy) * 253 + 1
                            if weight > 254 { weight = 254 }
                            if UInt8(weight) > strongest[i] { strongest[i] = UInt8(weight); labels[i] = frame }
                        }
                    }
                }
                y += 1
            }
        }
        } } } }
    }

    // MARK: Composition

    /// Level 0 of one frame's pyramid: the frame resampled onto `region` of the canvas with its
    /// exposure and falloff removed, where it has data, and where the seam finder gave it the pixel.
    /// `columns` holds the canvas column of each of the region's columns, or -1 outside the canvas.
    private static func warpFrame(_ source: UnsafePointer<Float16>, _ sw: Int, _ sh: Int, _ mapper: Mapper, _ table: Tables, _ region: Region, columns: [Int], _ width: Int, _ height: Int,
                                  _ frame: UInt8, _ labels: UnsafePointer<UInt8>, _ colour: UnsafeMutablePointer<Float16>,
                                  _ coverage: UnsafeMutablePointer<Float16>, _ mask: UnsafeMutablePointer<Float16>) throws {
        let rw = region.width, endY = region.y1 < height ? region.y1 : height
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 11)
        defer { scratch.deallocate() }
        let value = scratch + 8
        var sx = 0.0, sy = 0.0
        try table.cx.withUnsafeBufferPointer { tcx in try table.cz.withUnsafeBufferPointer { tcz in try table.ry.withUnsafeBufferPointer { tvy in try table.rs.withUnsafeBufferPointer { trs in
        try columns.withUnsafeBufferPointer { cols in
            var y = region.y0
            while y < endY {
                if y % 32 == 0 { try Task.checkCancellation() }
                let ry = tvy[y], rs = trs[y]
                var c = 0
                while c < rw {
                    let x = cols[c]
                    if x >= 0, mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                        bicubic(source, sw, sh, sx, sy, scratch, into: value)
                        mapper.compensate(value, sx, sy)
                        let i = (y - region.y0) * rw + c
                        colour[i * 3] = half(value[0]); colour[i * 3 + 1] = half(value[1]); colour[i * 3 + 2] = half(value[2])
                        coverage[i] = 1
                        if labels[y * width + x] == frame { mask[i] = 1 }
                    }
                    c += 1
                }
                y += 1
            }
        }
        } } } }
    }

    /// One level of one frame's pyramid, from the coarsest down: the level's picture is filled in
    /// from the expansion of the level above (`coarse`, nil at the top) where the frame has no
    /// data, and the band it adds to that expansion goes into the canvas sums, weighted by the
    /// frame's mask. `colour` holds the premultiplied level on entry and the filled picture on return.
    /// On a full circle (`circle`) the level's columns are taken round the canvas; a part that is
    /// the whole circle (`own`) is itself expanded round it.
    private static func addBand(_ colour: UnsafeMutablePointer<Float16>, _ coverage: UnsafePointer<Float16>, _ mask: UnsafePointer<Float16>, _ w: Int, _ h: Int,
                                coarse: UnsafePointer<Float16>?, _ uw: Int, _ uh: Int, sums: UnsafeMutablePointer<Float16>, weights: UnsafeMutablePointer<Float16>?,
                                _ cw: Int, _ ch: Int, _ ox: Int, _ oy: Int, own: Bool, circle: Bool) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: max(1, uw) * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var i = 0
        while i < w * 3 { above[i] = 0; i += 1 }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            if let coarse { expandRow(coarse, uw, uh, 3, row: y, width: w, wrap: own, scratch: scratch, into: above) }
            let inside = y + oy < ch
            var x = 0
            while x < w {
                let i = y * w + x, v = Float(coverage[i]), pixel = colour + i * 3, up = above + x * 3
                var r = up[0], g = up[1], b = up[2]
                if v > 1e-3 { r = Float(pixel[0]) / v; g = Float(pixel[1]) / v; b = Float(pixel[2]) / v }
                pixel[0] = half(r); pixel[1] = half(g); pixel[2] = half(b)
                let m = Float(mask[i])
                var column = x + ox
                if circle { if column < 0 { column += cw } else if column >= cw { column -= cw } }
                if m > 0, inside, column < cw {
                    let o = (y + oy) * cw + column, sum = sums + o * 3
                    sum[0] = half(Float(sum[0]) + (r - up[0]) * m); sum[1] = half(Float(sum[1]) + (g - up[1]) * m); sum[2] = half(Float(sum[2]) + (b - up[2]) * m)
                    if let weights { weights[o] = Float16(Float(weights[o]) + m) }
                }
                x += 1
            }
            y += 1
        }
    }

    /// One level of the collapse: the level's normalized band plus the expansion of the level above
    /// (`coarse`, nil at the top). At the base (`labels` given) the weight is the coverage, uncovered
    /// pixels are left at zero and covered ones are kept between zero and `ceiling`: the bands of
    /// two frames that meet at a bright edge can ring past the level no frame records above.
    private static func collapse(_ sums: UnsafeMutablePointer<Float16>, _ w: Int, _ h: Int, weights: UnsafePointer<Float16>?, labels: UnsafePointer<UInt8>?,
                                 coarse: UnsafePointer<Float16>?, _ uw: Int, _ uh: Int, circle: Bool, ceiling: Float) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: max(1, uw) * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var i = 0
        while i < w * 3 { above[i] = 0; i += 1 }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            if let coarse { expandRow(coarse, uw, uh, 3, row: y, width: w, wrap: circle, scratch: scratch, into: above) }
            var x = 0
            while x < w {
                let i = y * w + x, pixel = sums + i * 3, up = above + x * 3
                var weight: Float = 1
                if let labels { weight = labels[i] == 255 ? 0 : 1 } else if let weights { weight = Float(weights[i]) }
                var r = up[0], g = up[1], b = up[2]
                if weight > 1e-3 { r += Float(pixel[0]) / weight; g += Float(pixel[1]) / weight; b += Float(pixel[2]) / weight }
                if labels != nil {
                    if weight == 0 { r = 0; g = 0; b = 0 } else {
                        if r < 0 { r = 0 } else if r > ceiling { r = ceiling }
                        if g < 0 { g = 0 } else if g > ceiling { g = ceiling }
                        if b < 0 { b = 0 } else if b > ceiling { b = ceiling }
                    }
                }
                pixel[0] = half(r); pixel[1] = half(g); pixel[2] = half(b)
                x += 1
            }
            y += 1
        }
    }

    /// Lays the aligned frames out on the projection surface, finds the seams, blends, and crops
    /// or fills the border.
    static func compose(_ frames: [LWMergeFrame], alignment aligned: LWPanoramaAlignment, works: [Work], options: LWPanoramaOptions = .init(), budget: Int = LWMergeBudget.bytes) throws -> LWPanoramaResult {
        let count = frames.count
        guard count >= 2, aligned.rotations.count == count, works.count == count else { throw LWPanoramaError.tooFewFrames }
        var alignment = aligned
        if options.projection == .perspective { alignment.rotations = straighten(aligned.rotations, reference: aligned.reference, levelPitch: false) }
        else { alignment.rotations = centredOnCoverage(aligned) }
        if !options.compensateExposure { alignment.gains = alignment.gains.map { _ in SIMD3(repeating: 1) }; alignment.vignetting = .zero }
        let (geometry, regions) = try layout(alignment, projection: options.projection)
        let width = geometry.width, height = geometry.height, circle = geometry.fullCircle
        // Pyramid levels above the base: the coarsest band is 1/16 of the canvas's short side or finer.
        let bands = options.blend == .none ? 0 : max(1, min(maximumBands, Int(log2(Double(min(width, height)))) - 4))
        let grain = 1 << bands, margin = bands == 0 ? 0 : 4 * grain
        func down(_ value: Int, _ unit: Int) -> Int { Int((Double(value) / Double(unit)).rounded(.down)) }
        func up(_ value: Int, _ unit: Int) -> Int { -down(-value, unit) }
        // A frame's part of the canvas with room for its pyramid, on the pyramid's grid.
        func expanded(_ r: Region) -> Region {
            let y0 = max(0, down(r.y0 - margin, grain) * grain), y1 = min(up(height, grain), up(r.y1 + margin, grain)) * grain
            if circle {
                let x0 = down(r.x0 - margin, grain) * grain, x1 = up(r.x1 + margin, grain) * grain
                return x1 - x0 >= width ? Region(x0: 0, y0: y0, x1: width, y1: y1) : Region(x0: x0, y0: y0, x1: x1, y1: y1)
            }
            return Region(x0: max(0, down(r.x0 - margin, grain) * grain), y0: y0, x1: min(up(width, grain), up(r.x1 + margin, grain)) * grain, y1: y1)
        }
        /// The canvas column of each column of a part, or -1 outside the canvas.
        func columns(_ r: Region) -> [Int] { (r.x0..<r.x1).map { circle ? column($0, width, true) : ($0 >= 0 && $0 < width ? $0 : -1) } }
        let parts = regions.map(expanded)
        let warp = parts.map { $0.width * $0.height }.max() ?? 0
        let needed = workingBytes(frames: count, width: alignment.width, height: alignment.height, canvasPixels: width * height, warpPixels: warp)
        guard needed <= budget else {
            throw LWPanoramaError.tooLarge(frames: count, width: alignment.width, height: alignment.height, outputWidth: width, outputHeight: height, neededBytes: needed, budgetBytes: budget)
        }
        let clips = frames.map(\.clipLevel)
        let mappers = (0..<count).map { Mapper(alignment, frame: $0, clips: clips) }

        // Seams, on the canvas reduced to about 400,000 pixels. A full circle is reduced by a
        // power of two, which divides its width, so the reduced canvas is a circle too.
        var q = max(1, Int((Double(width * height) / 400_000).squareRoot().rounded(.up)))
        if circle { var power = 1; while power < q { power *= 2 }; q = power }
        let lowWidth = (width + q - 1) / q, lowHeight = (height + q - 1) / q
        var lowLabels = [UInt8](repeating: 255, count: lowWidth * lowHeight)
        do {
            let table = geometry.tables(xs: (0..<lowWidth).map { Double($0 * q) + Double(q - 1) / 2 }, ys: (0..<lowHeight).map { Double($0 * q) + Double(q - 1) / 2 })
            var luminance: [[Float]] = [], footprints: [Footprint] = []
            var strongest = [Float](repeating: -1, count: lowWidth * lowHeight)
            for k in 0..<count {
                try Task.checkCancellation()
                var values = [Float](repeating: .nan, count: lowWidth * lowHeight)
                var footprint = Footprint(columns: [Int32](repeating: 0, count: lowWidth))
                let region = regions[k], from = down(region.x0, q), to = up(region.x1, q)
                let own = circle ? (to - from >= lowWidth ? Array(0..<lowWidth) : (from..<to).map { column($0, lowWidth, true) }) : Array(max(0, from)..<min(lowWidth, to))
                values.withUnsafeMutableBufferPointer { v in strongest.withUnsafeMutableBufferPointer { s in lowLabels.withUnsafeMutableBufferPointer { l in
                    seamInputs(UInt8(k), mappers[k], works[k], table, columns: own, y0: region.y0 / q, y1: min(lowHeight, (region.y1 + q - 1) / q),
                               lowWidth: lowWidth, values: v.baseAddress!, strongest: s.baseAddress!, labels: l.baseAddress!, footprint: &footprint)
                } } }
                luminance.append(values); footprints.append(footprint)
            }
            for a in 0..<count {
                for b in (a + 1)..<count {
                    try Task.checkCancellation()
                    refineSeam(a, b, luminance: luminance, footprints: footprints, labels: &lowLabels, width: lowWidth, height: lowHeight, cyclic: circle)
                }
            }
        }

        var labels = [UInt8](repeating: 255, count: width * height)
        let table = geometry.tables(xs: (0..<width).map(Double.init), ys: (0..<height).map(Double.init))
        do {
            var strongest = [UInt8](repeating: 0, count: width * height)
            for k in 0..<count {
                try lowLabels.withUnsafeBufferPointer { low in try labels.withUnsafeMutableBufferPointer { l in try strongest.withUnsafeMutableBufferPointer { s in
                    try claim(UInt8(k), mappers[k], table, regions[k], columns: columns(regions[k]), width, q, low.baseAddress!, lowWidth, l.baseAddress!, s.baseAddress!)
                } } }
            }
        }

        // The blend pyramid: per level, the sum of each frame's band weighted by its mask.
        var levelWidth = [width], levelHeight = [height]
        for _ in 0..<bands { levelWidth.append((levelWidth.last! + 1) / 2); levelHeight.append((levelHeight.last! + 1) / 2) }
        var sums = (0...bands).map { [Float16](repeating: 0, count: levelWidth[$0] * levelHeight[$0] * 3) }
        var weights = (0...bands).map { $0 == 0 ? [] : [Float16](repeating: 0, count: levelWidth[$0] * levelHeight[$0]) }
        // One set of buffers, sized for the largest part at each level, serves every frame in turn:
        // the frame warped onto its part of the canvas, its coverage and its mask, and their pyramids.
        var capacity = [Int](repeating: 1, count: bands + 1)
        for part in parts {
            var w = part.width, h = part.height
            for level in 0...bands { capacity[level] = max(capacity[level], w * h); w = (w + 1) / 2; h = (h + 1) / 2 }
        }
        let colour = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0 * 3) }
        let coverage = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0) }, mask = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0) }
        defer { for level in 0...bands { colour[level].deallocate(); coverage[level].deallocate(); mask[level].deallocate() } }
        for (k, region) in parts.enumerated() where region.width > 0 && region.height > 0 {
            try Task.checkCancellation()
            let rw = region.width, rh = region.height
            // A part that is the whole circle is its own neighbour across the cut.
            let own = circle && rw == width
            colour[0].update(repeating: 0, count: rw * rh * 3); coverage[0].update(repeating: 0, count: rw * rh); mask[0].update(repeating: 0, count: rw * rh)
            try frames[k].samples.withUnsafeBufferPointer { source in
                try labels.withUnsafeBufferPointer { l in
                    try warpFrame(source.baseAddress!, frames[k].width, frames[k].height, mappers[k], table, region, columns: columns(region), width, height, UInt8(k), l.baseAddress!, colour[0], coverage[0], mask[0])
                }
            }
            var sizes = [(rw, rh)]
            for level in 0..<bands {
                let (w, h) = sizes[level]
                try reduce(colour[level], w, h, 3, wrap: own, into: colour[level + 1]); try reduce(coverage[level], w, h, 1, wrap: own, into: coverage[level + 1])
                try reduce(mask[level], w, h, 1, wrap: own, into: mask[level + 1])
                sizes.append(((w + 1) / 2, (h + 1) / 2))
            }
            for level in stride(from: bands, through: 0, by: -1) {
                let (w, h) = sizes[level], top = level == bands
                let (uw, uh) = top ? (0, 0) : sizes[level + 1]
                try sums[level].withUnsafeMutableBufferPointer { s in try weights[level].withUnsafeMutableBufferPointer { wt in
                    try addBand(colour[level], coverage[level], mask[level], w, h, coarse: top ? nil : UnsafePointer(colour[level + 1]), uw, uh,
                                sums: s.baseAddress!, weights: level > 0 ? wt.baseAddress! : nil, levelWidth[level], levelHeight[level], region.x0 >> level, region.y0 >> level, own: own, circle: circle)
                } }
            }
        }

        // Collapse: each level is its normalized band plus the expansion of the level above.
        for level in stride(from: bands, through: 0, by: -1) {
            let top = level == bands
            var fine = sums[level]
            sums[level] = []
            try fine.withUnsafeMutableBufferPointer { s in try weights[level].withUnsafeBufferPointer { wt in try labels.withUnsafeBufferPointer { l in
                try (top ? [] : sums[level + 1]).withUnsafeBufferPointer { coarse in
                    try collapse(s.baseAddress!, levelWidth[level], levelHeight[level], weights: level > 0 ? wt.baseAddress! : nil, labels: level == 0 ? l.baseAddress! : nil,
                                 coarse: top ? nil : coarse.baseAddress!, top ? 0 : levelWidth[level + 1], top ? 0 : levelHeight[level + 1], circle: circle, ceiling: mappers[0].ceiling)
                }
            } } }
            sums[level] = fine
            if !top { sums[level + 1] = []; weights[level + 1] = [] }
        }
        var picture = sums[0]
        sums = []; weights = []

        var area = Region(x0: 0, y0: 0, x1: width, y1: height)
        switch options.boundary {
        case .fill: try fill(&picture, labels: labels, width: width, height: height, circle: circle)
        case .autoCrop:
            area = try largestCoveredRectangle(labels, width: width, height: height)
            guard area.width > 0, area.height > 0 else { throw LWPanoramaError.notOnePanorama(rmsPixels: alignment.rms) }
            // Compact both in place: every destination index is at or before its source.
            let cropWidth = area.width
            labels.withUnsafeMutableBufferPointer { l in picture.withUnsafeMutableBufferPointer { p in
                for y in 0..<area.height {
                    let from = (area.y0 + y) * width + area.x0, to = y * cropWidth
                    memmove(l.baseAddress! + to, l.baseAddress! + from, cropWidth)
                    memmove(p.baseAddress! + to * 3, p.baseAddress! + from * 3, cropWidth * 3 * MemoryLayout<Float16>.stride)
                }
            } }
            labels.removeSubrange((area.width * area.height)...); picture.removeSubrange((area.width * area.height * 3)...)
        }
        var uncovered = 0
        labels.withUnsafeBufferPointer { l in var i = 0; while i < l.count { if l[i] == 255 { uncovered += 1 }; i += 1 } }
        // The brightest sample, for the DNG's normalization: found here, off the main actor.
        var peak: Float = 0
        picture.withUnsafeBufferPointer { p in var i = 0; while i < p.count { let value = Float(p[i]); if value > peak { peak = value }; i += 1 } }
        return LWPanoramaResult(width: area.width, height: area.height, samples: picture, labels: labels, offsetX: area.x0, offsetY: area.y0,
            geometry: geometry, alignment: alignment, options: options, bands: bands, uncoveredPixels: uncovered, workingBytes: needed, peak: peak)
    }

    /// Registers, aligns and composes in one call.
    static func stitch(_ frames: [LWMergeFrame], options: LWPanoramaOptions = .init(), focalHint: Double? = nil, budget: Int = LWMergeBudget.bytes) throws -> LWPanoramaResult {
        guard frames.count >= 2 else { throw LWPanoramaError.tooFewFrames }
        try admit(frames: frames.count, width: frames[0].width, height: frames[0].height, budget: budget)
        let (alignment, works) = try align(frames, focalHint: focalHint, compensateExposure: options.compensateExposure)
        return try compose(frames, alignment: alignment, works: works, options: options, budget: budget)
    }

    // MARK: Border

    /// The largest axis-aligned rectangle of covered pixels (largest rectangle under a histogram, row by row).
    static func largestCoveredRectangle(_ labels: [UInt8], width: Int, height: Int) throws -> Region {
        var heights = [Int32](repeating: 0, count: width + 1), stack = [Int32](repeating: 0, count: width + 2)
        var best = Region(x0: 0, y0: 0, x1: 0, y1: 0), bestArea = 0
        for y in 0..<height {
            if y % 256 == 0 { try Task.checkCancellation() }
            for x in 0..<width { heights[x] = labels[y * width + x] == 255 ? 0 : heights[x] + 1 }
            var top = 0
            for x in 0...width {
                let current = x == width ? 0 : heights[x]
                while top > 0, heights[Int(stack[top - 1])] >= current {
                    let column = Int(stack[top - 1]), tall = Int(heights[column]); top -= 1
                    let left = top > 0 ? Int(stack[top - 1]) + 1 : 0, area = tall * (x - left)
                    if area > bestArea { bestArea = area; best = Region(x0: left, y0: y - tall + 1, x1: x, y1: y + 1) }
                }
                if x < width { stack[top] = Int32(x); top += 1 }
            }
        }
        return best
    }

    /// Extends the picture into the pixels no frame covers (push–pull: each uncovered pixel takes
    /// the average of the nearest covered ones, from as coarse a level as it takes to find them).
    /// The fill continues the picture's colour and brightness; it invents no detail. On a full
    /// circle (`circle`) the nearest covered pixels may be across the cut.
    static func fill(_ picture: inout [Float16], labels: [UInt8], width: Int, height: Int, circle: Bool = false) throws {
        guard labels.contains(255) else { return }
        // Push: level 1 straight from the picture (already zero where uncovered) and the labels, then on up to one pixel.
        var sizes = [(width, height)], colours: [[Float16]] = [[]], covers: [[Float16]] = [[]]
        colours.append(try reduce(picture, width, height, 3, wrap: circle)); covers.append(try reduceCoverage(labels, width, height, wrap: circle))
        sizes.append(((width + 1) / 2, (height + 1) / 2))
        while sizes.last!.0 > 1 || sizes.last!.1 > 1 {
            let (w, h) = sizes.last!
            colours.append(try reduce(colours.last!, w, h, 3, wrap: circle)); covers.append(try reduce(covers.last!, w, h, 1, wrap: circle))
            sizes.append(((w + 1) / 2, (h + 1) / 2))
        }
        // Pull: top down, each level keeps what it has and takes the rest from above.
        let top = sizes.count - 1
        do {
            let v = Float(covers[top][0])
            if v > 0 { for k in 0..<3 { colours[top][k] = half(Float(colours[top][k]) / v) } }
        }
        for level in stride(from: top - 1, through: 0, by: -1) {
            let (w, h) = sizes[level], (uw, uh) = sizes[level + 1]
            var fine = level == 0 ? [] : colours[level]
            colours[level] = []
            try colours[level + 1].withUnsafeBufferPointer { coarse in
                if level == 0 {
                    try picture.withUnsafeMutableBufferPointer { p in try labels.withUnsafeBufferPointer { l in
                        try pull(p.baseAddress!, w, h, cover: nil, labels: l.baseAddress!, coarse: coarse.baseAddress!, uw, uh, circle: circle)
                    } }
                } else {
                    try fine.withUnsafeMutableBufferPointer { p in try covers[level].withUnsafeBufferPointer { v in
                        try pull(p.baseAddress!, w, h, cover: v.baseAddress!, labels: nil, coarse: coarse.baseAddress!, uw, uh, circle: circle)
                    } }
                }
            }
            colours[level] = fine
            colours[level + 1] = []; covers[level + 1] = []
        }
    }
    /// One level of the pull. Above the base, a level's premultiplied colour takes the share its
    /// coverage leaves from the expansion of the level above; at the base (`labels` given) only
    /// uncovered pixels are written.
    private static func pull(_ colour: UnsafeMutablePointer<Float16>, _ w: Int, _ h: Int, cover: UnsafePointer<Float16>?, labels: UnsafePointer<UInt8>?,
                             coarse: UnsafePointer<Float16>, _ uw: Int, _ uh: Int, circle: Bool) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: uw * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            expandRow(coarse, uw, uh, 3, row: y, width: w, wrap: circle, scratch: scratch, into: above)
            var x = 0
            while x < w {
                let i = y * w + x, pixel = colour + i * 3, up = above + x * 3
                if let labels {
                    if labels[i] == 255 {
                        pixel[0] = half(up[0] > 0 ? up[0] : 0); pixel[1] = half(up[1] > 0 ? up[1] : 0); pixel[2] = half(up[2] > 0 ? up[2] : 0)
                    }
                } else if let cover {
                    var rest = 1 - Float(cover[i])
                    if rest < 0 { rest = 0 }
                    pixel[0] = half(Float(pixel[0]) + rest * up[0]); pixel[1] = half(Float(pixel[1]) + rest * up[1]); pixel[2] = half(Float(pixel[2]) + rest * up[2])
                }
                x += 1
            }
            y += 1
        }
    }
}

/// Seam error E of a stitched panorama (docs/PANORAMA_MERGE.md, "Seam metric"), in stops:
///   E = max(A, D)
///   A = mean over p in the seam band of max over the frames k that see p of
///       | log2(Y_out(p) + ε) − log2(Y_k(p) + ε) |
///   D = mean over neighbouring pixel pairs (p, q) that the seam separates of
///       max(0, | log2(Y_out(p) + ε) − log2(Y_out(q) + ε) | − min over k in {frame of p, frame of q} of | log2(Y_k(p) + ε) − log2(Y_k(q) + ε) |)
/// Y is Rec. 709 luminance (or, with other `weights`, one channel); Y_k is frame k resampled at
/// the pixel by the panorama's own alignment, with its solved exposure and falloff removed;
/// ε = 1e-4. The seam band is every covered pixel within `radius` pixels of a seam (a boundary
/// between two frames' pixels). In a full circle the last column's neighbour is the first.
/// A says the picture near a seam is what every frame there saw: frames that are misregistered,
/// or whose exposure differs, cannot all agree with one picture. D says the picture does not
/// step across the seam by more than the scene does.
nonisolated enum LWPanoramaSeamMetric {
    static let epsilon: Float = 1e-4
    static let radius = 8
    struct Measurement: Sendable {
        let agreement: Double, step: Double
        let bandPixels: Int, seamPairs: Int
        var value: Double { max(agreement, step) }
    }
    static let rec709 = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    static func luminance(_ v: SIMD3<Float>, weights: SIMD3<Float> = rec709) -> Float { max(0, weights.x * v.x + weights.y * v.y + weights.z * v.z) }

    /// Luminance of one frame resampled at every pixel of the picture; NaN where the frame does not see the pixel.
    static func seen(_ result: LWPanoramaResult, frames: [LWMergeFrame], index: Int, weights: SIMD3<Float> = rec709) -> [Float] {
        let width = result.width, height = result.height, frame = frames[index]
        let mapper = LWPanoramaStitcher.Mapper(result.alignment, frame: index, clips: frames.map(\.clipLevel))
        let table = result.geometry.tables(xs: (0..<width).map { Double($0 + result.offsetX) }, ys: (0..<height).map { Double($0 + result.offsetY) })
        var values = [Float](repeating: .nan, count: width * height)
        frame.samples.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { out in resample(source.baseAddress!, frame.width, frame.height, mapper, table, width, height, weights, into: out.baseAddress!) }
        }
        return values
    }
    // Raw pointers and `while` loops, as in the stitcher: these run per pixel in the unoptimized test build.
    private static func resample(_ source: UnsafePointer<Float16>, _ sw: Int, _ sh: Int, _ mapper: LWPanoramaStitcher.Mapper, _ table: LWPanoramaStitcher.Tables,
                                 _ width: Int, _ height: Int, _ weights: SIMD3<Float>, into out: UnsafeMutablePointer<Float>) {
        let wr = weights.x, wg = weights.y, wb = weights.z
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 11)
        defer { scratch.deallocate() }
        let value = scratch + 8
        var sx = 0.0, sy = 0.0
        table.cx.withUnsafeBufferPointer { tcx in table.cz.withUnsafeBufferPointer { tcz in table.ry.withUnsafeBufferPointer { tvy in table.rs.withUnsafeBufferPointer { trs in
            var y = 0
            while y < height {
                let ry = tvy[y], rs = trs[y]
                var x = 0
                while x < width {
                    if mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                        LWPanoramaStitcher.bicubic(source, sw, sh, sx, sy, scratch, into: value)
                        mapper.compensate(value, sx, sy)
                        let luminance = wr * value[0] + wg * value[1] + wb * value[2]
                        out[y * width + x] = luminance > 0 ? luminance : 0
                    }
                    x += 1
                }
                y += 1
            }
        } } } }
    }

    static func measure(_ result: LWPanoramaResult, frames: [LWMergeFrame], weights: SIMD3<Float> = rec709) -> Measurement {
        let width = result.width, height = result.height, count = frames.count, pixels = width * height
        // The whole of a full circle: its last column and its first are neighbours.
        let circle = result.geometry.fullCircle && width == result.geometry.width
        // Every frame's view of the picture, as log2 luminance (NaN where it does not see the pixel), one after another.
        var views = [Float](repeating: .nan, count: count * pixels)
        for k in 0..<count {
            let view = seen(result, frames: frames, index: k, weights: weights)
            for p in 0..<pixels where !view[p].isNaN { views[k * pixels + p] = log2(view[p] + epsilon) }
        }
        var out = [Float](repeating: 0, count: pixels)
        for p in 0..<pixels { out[p] = log2(luminance(result.rgb(p), weights: weights) + epsilon) }
        var near = [Bool](repeating: false, count: pixels)
        var stepSum = 0.0, pairs = 0, agreementSum = 0.0, band = 0
        result.labels.withUnsafeBufferPointer { labelBuffer in views.withUnsafeBufferPointer { viewBuffer in out.withUnsafeBufferPointer { outBuffer in near.withUnsafeMutableBufferPointer { nearBuffer in
            let labels = labelBuffer.baseAddress!, views = viewBuffer.baseAddress!, out = outBuffer.baseAddress!, near = nearBuffer.baseAddress!
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let p = y * width + x, a = labels[p]
                    var side = 0
                    while a != 255, side < 2 {
                        var nx = x + (side == 0 ? 1 : 0)
                        let ny = y + (side == 0 ? 0 : 1)
                        side += 1
                        if nx == width, circle { nx = 0 }
                        if nx >= width || ny >= height { continue }
                        let q = ny * width + nx, b = labels[q]
                        if b == 255 || b == a { continue }
                        var dy = -radius
                        while dy <= radius {
                            var dx = -radius
                            while dx <= radius {
                                var px = x + dx
                                let py = y + dy
                                if circle { if px < 0 { px += width } else if px >= width { px -= width } }
                                if dx * dx + dy * dy <= radius * radius, px >= 0, py >= 0, px < width, py < height { near[py * width + px] = true }
                                dx += 1
                            }
                            dy += 1
                        }
                        // The scene's own step here, as the smaller of what the two frames that meet record.
                        var natural = Float.infinity
                        let ua = views[Int(a) * pixels + p], va = views[Int(a) * pixels + q], ub = views[Int(b) * pixels + p], vb = views[Int(b) * pixels + q]
                        if ua == ua, va == va { natural = ua > va ? ua - va : va - ua }
                        if ub == ub, vb == vb { let step = ub > vb ? ub - vb : vb - ub; if step < natural { natural = step } }
                        if natural == Float.infinity { continue }
                        let step = out[p] > out[q] ? out[p] - out[q] : out[q] - out[p]
                        if step > natural { stepSum += Double(step - natural) }
                        pairs += 1
                    }
                    x += 1
                }
                y += 1
            }
            var p = 0
            while p < pixels {
                if near[p], labels[p] != 255 {
                    var worst: Float = 0, seeing = 0, k = 0
                    while k < count {
                        let value = views[k * pixels + p]
                        if value == value {
                            let difference = out[p] > value ? out[p] - value : value - out[p]
                            if difference > worst { worst = difference }
                            seeing += 1
                        }
                        k += 1
                    }
                    if seeing > 0 { agreementSum += Double(worst); band += 1 }
                }
                p += 1
            }
        } } } }
        return Measurement(agreement: band == 0 ? 0 : agreementSum / Double(band), step: pairs == 0 ? 0 : stepSum / Double(pairs), bandPixels: band, seamPairs: pairs)
    }
}
