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
    /// Canvas pixels per radian at the centre: the frames' focal length, so the centre keeps its resolution.
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

    /// A half-open rectangle of canvas pixels.
    struct Region: Sendable, Equatable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
    }

    /// The canvas that holds every frame on the projection surface, and each frame's part of it.
    static func layout(_ alignment: LWPanoramaAlignment, projection: LWPanoramaProjection) throws -> (geometry: LWPanoramaGeometry, regions: [[Region]]) {
        let w = alignment.width, h = alignment.height, s = alignment.focal
        var border: [SIMD2<Double>] = []
        for x in 0..<w { border.append(SIMD2(Double(x), 0)); border.append(SIMD2(Double(x), Double(h - 1))) }
        for y in 0..<h { border.append(SIMD2(0, Double(y))); border.append(SIMD2(Double(w - 1), Double(y))) }
        struct Extent { var u0 = Double.infinity, u1 = -Double.infinity, v0 = Double.infinity, v1 = -Double.infinity; var whole = false }
        var extents: [Extent] = []
        let latitudeLimit = 80.0 * .pi / 180
        for frame in alignment.rotations.indices {
            var extent = Extent()
            if projection == .perspective {
                var widest = 0.0
                for p in border {
                    let d = alignment.ray(frame: frame, x: p.x, y: p.y)
                    let angle = acos(max(-1, min(1, d.z / simd_length(d))))
                    widest = max(widest, angle)
                    guard d.z > 1e-6 else { continue }
                    extent.u0 = min(extent.u0, s * d.x / d.z); extent.u1 = max(extent.u1, s * d.x / d.z)
                    extent.v0 = min(extent.v0, s * d.y / d.z); extent.v1 = max(extent.v1, s * d.y / d.z)
                }
                guard widest <= 70 * .pi / 180 else { throw LWPanoramaError.tooWideForPerspective(degrees: Int((widest * 2 * 180 / .pi).rounded())) }
            } else {
                let forward = alignment.rotations[frame][2], centre = atan2(forward.x, forward.z)
                var low = 0.0, high = 0.0
                for p in border {
                    let d = alignment.ray(frame: frame, x: p.x, y: p.y)
                    var delta = atan2(d.x, d.z) - centre
                    if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                    low = min(low, delta); high = max(high, delta)
                    let latitude = atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot())
                    let v = projection == .spherical ? latitude : tan(max(-latitudeLimit, min(latitudeLimit, latitude)))
                    extent.v0 = min(extent.v0, s * v); extent.v1 = max(extent.v1, s * v)
                }
                // A frame that looks at a pole sees every longitude, and the pole itself.
                for pole in [-1.0, 1.0] {
                    guard let p = alignment.pixel(frame: frame, ray: SIMD3(0, pole, 0)), p.x >= 0, p.y >= 0, p.x <= Double(w - 1), p.y <= Double(h - 1) else { continue }
                    extent.whole = true
                    let v = projection == .spherical ? pole * .pi / 2 : pole * tan(latitudeLimit)
                    extent.v0 = min(extent.v0, s * v); extent.v1 = max(extent.v1, s * v)
                }
                if high - low >= 2 * .pi - 1e-6 { extent.whole = true }
                extent.u0 = s * (centre + low); extent.u1 = s * (centre + high)
            }
            extents.append(extent)
        }
        var u0 = extents.map(\.u0).min()!, u1 = extents.map(\.u1).max()!
        let v0 = extents.map(\.v0).min()!, v1 = extents.map(\.v1).max()!
        var fullCircle = false
        if projection != .perspective {
            let half = s * .pi
            // Frames that reach past ±180°, or that together leave no gap, make a full circle.
            if extents.contains(where: \.whole) || u0 < -half || u1 > half || u1 - u0 >= 2 * half - 2 { fullCircle = true; u0 = -half; u1 = half - 1 }
        }
        guard u0.isFinite, u1.isFinite, v0.isFinite, v1.isFinite else { throw LWPanoramaError.notOnePanorama(rmsPixels: alignment.rms) }
        let originX = fullCircle ? Int((-s * .pi).rounded()) : Int(u0.rounded(.down)) - 1, originY = Int(v0.rounded(.down)) - 1
        let width = fullCircle ? Int((2 * s * .pi).rounded()) : Int(u1.rounded(.up)) + 2 - originX, height = Int(v1.rounded(.up)) + 2 - originY
        guard width > 0, height > 0, width < 1 << 24, height < 1 << 24 else { throw LWPanoramaError.outputTooLarge(width: max(0, width), height: max(0, height)) }
        guard width * height <= maximumOutputPixels else { throw LWPanoramaError.outputTooLarge(width: width, height: height) }
        // A frame that crosses the ±180° cut of a full circle lies on the canvas in two parts.
        let regions = extents.map { extent -> [Region] in
            let y0 = max(0, Int(extent.v0.rounded(.down)) - 1 - originY), y1 = min(height, Int(extent.v1.rounded(.up)) + 2 - originY)
            var x0 = Int(extent.u0.rounded(.down)) - 1 - originX, x1 = Int(extent.u1.rounded(.up)) + 2 - originX
            guard fullCircle else { return [Region(x0: max(0, x0), y0: y0, x1: min(width, x1), y1: y1)] }
            if extent.whole || x1 - x0 >= width { return [Region(x0: 0, y0: y0, x1: width, y1: y1)] }
            if x0 >= width { x0 -= width; x1 -= width } else if x1 <= 0 { x0 += width; x1 += width }
            if x0 < 0 { return [Region(x0: 0, y0: y0, x1: x1, y1: y1), Region(x0: x0 + width, y0: y0, x1: width, y1: y1)] }
            if x1 > width { return [Region(x0: 0, y0: y0, x1: x1 - width, y1: y1), Region(x0: x0, y0: y0, x1: width, y1: y1)] }
            return [Region(x0: x0, y0: y0, x1: x1, y1: y1)]
        }
        return (LWPanoramaGeometry(projection: projection, scale: s, originX: originX, originY: originY, width: width, height: height, fullCircle: fullCircle), regions)
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
        let v1: Double, v2: Double, corner: Double, flat: Bool
        init(_ alignment: LWPanoramaAlignment, frame: Int) {
            let t = alignment.rotations[frame].transpose
            ax = t[0][0]; ay = t[1][0]; az = t[2][0]; bx = t[0][1]; by = t[1][1]; bz = t[2][1]; cx = t[0][2]; cy = t[1][2]; cz = t[2][2]
            focal = alignment.focal; px = alignment.principal.x; py = alignment.principal.y
            maxX = Double(alignment.width - 1); maxY = Double(alignment.height - 1); halfSide = min(maxX, maxY) / 2
            let gain = alignment.gains[frame]
            red = 1 / gain.x; green = 1 / gain.y; blue = 1 / gain.z
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
    }

    /// Per-column and per-row factors of the canvas rays, as `LWPanoramaGeometry.tables` gives them.
    typealias Tables = (cx: [Double], cz: [Double], ry: [Double], rs: [Double])

    // MARK: Pyramids (5-tap binomial reduce and its expand, clamped at the borders)

    /// One output row of the reduction of `source` (width × height × channels half floats). `scratch` is width × channels floats.
    static func reduceRow(_ source: UnsafePointer<Float16>, _ width: Int, _ height: Int, _ channels: Int, row: Int,
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
        let out = (width + 1) / 2, last = width - 1
        var x = 0
        while x < out {
            let centre = 2 * x
            let a = (centre - 2 < 0 ? 0 : centre - 2) * channels, b = (centre - 1 < 0 ? 0 : centre - 1) * channels, c = centre * channels
            let d = (centre + 1 > last ? last : centre + 1) * channels, e = (centre + 2 > last ? last : centre + 2) * channels
            var k = 0
            while k < channels {
                target[x * channels + k] = Float16((scratch[a + k] + scratch[e + k]) * 0.0625 + (scratch[b + k] + scratch[d + k]) * 0.25 + scratch[c + k] * 0.375)
                k += 1
            }
            x += 1
        }
    }
    static func reduce(_ source: [Float16], _ width: Int, _ height: Int, _ channels: Int) throws -> [Float16] {
        var result = [Float16](repeating: 0, count: ((width + 1) / 2) * ((height + 1) / 2) * channels)
        try source.withUnsafeBufferPointer { src in try result.withUnsafeMutableBufferPointer { dst in try reduce(src.baseAddress!, width, height, channels, into: dst.baseAddress!) } }
        return result
    }
    /// The reduction of `source` (width × height × channels) into `target`, which holds ((width + 1) / 2) × ((height + 1) / 2) × channels.
    static func reduce(_ source: UnsafePointer<Float16>, _ width: Int, _ height: Int, _ channels: Int, into target: UnsafeMutablePointer<Float16>) throws {
        let w = (width + 1) / 2, h = (height + 1) / 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: width * channels)
        defer { scratch.deallocate() }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            reduceRow(source, width, height, channels, row: y, scratch: scratch, into: target + y * w * channels)
            y += 1
        }
    }
    /// The reduction of the coverage (1 where a label is set, 0 where it is 255), without holding the coverage itself.
    static func reduceCoverage(_ labels: [UInt8], _ width: Int, _ height: Int) throws -> [Float16] {
        let w = (width + 1) / 2, h = (height + 1) / 2, last = width - 1
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
                        let outer = scratch[centre - 2 < 0 ? 0 : centre - 2] + scratch[centre + 2 > last ? last : centre + 2]
                        let inner = scratch[centre - 1 < 0 ? 0 : centre - 1] + scratch[centre + 1 > last ? last : centre + 1]
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
    static func expandRow(_ coarse: UnsafePointer<Float16>, _ cw: Int, _ ch: Int, _ channels: Int, row: Int, width: Int,
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
            let mid = (i > cw - 1 ? cw - 1 : i) * channels, right = (i + 1 > cw - 1 ? cw - 1 : i + 1) * channels
            var k = 0
            if x % 2 == 0 {
                let left = (i - 1 < 0 ? 0 : i - 1) * channels
                while k < channels { out[k] = (scratch[left + k] + scratch[right + k]) * 0.125 + scratch[mid + k] * 0.75; k += 1 }
            } else {
                while k < channels { out[k] = (scratch[mid + k] + scratch[right + k]) * 0.5; k += 1 }
            }
            x += 1
        }
    }

    // MARK: Seams

    /// One frame on the reduced canvas the seams are found on: its compensated luminance where it
    /// has data (NaN elsewhere), and its claim on each pixel by distance from its own edge.
    /// Returns the sum of the covered positions and their count.
    private static func seamInputs(_ frame: UInt8, _ mapper: Mapper, _ work: Work, _ table: Tables, x0: Int, y0: Int, x1: Int, y1: Int, lowWidth: Int,
                                   values: UnsafeMutablePointer<Float>, strongest: UnsafeMutablePointer<Float>, labels: UnsafeMutablePointer<UInt8>) -> (x: Double, y: Double, count: Double) {
        var sumX = 0.0, sumY = 0.0, covered = 0.0, sx = 0.0, sy = 0.0
        let ww = work.width, wh = work.height, shift = Double(work.factor - 1) / 2, scale = 1 / Double(work.factor)
        work.rgb.withUnsafeBufferPointer { buffer in
            let rgb = buffer.baseAddress!
            table.cx.withUnsafeBufferPointer { tcx in table.cz.withUnsafeBufferPointer { tcz in table.ry.withUnsafeBufferPointer { tvy in table.rs.withUnsafeBufferPointer { trs in
                var y = y0
                while y < y1 {
                    let ry = tvy[y], rs = trs[y]
                    var x = x0
                    while x < x1 {
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
                            let r = w00 * p[0] + w10 * p[3] + w01 * q[0] + w11 * q[3]
                            let g = w00 * p[1] + w10 * p[4] + w01 * q[1] + w11 * q[4]
                            let b = w00 * p[2] + w10 * p[5] + w01 * q[2] + w11 * q[5]
                            let luminance = (0.2126 * r * mapper.red + 0.7152 * g * mapper.green + 0.0722 * b * mapper.blue) * mapper.unfalloff(sx, sy)
                            let i = y * lowWidth + x
                            values[i] = luminance > 0 ? luminance : 0
                            let weight = mapper.feather(sx, sy)
                            if weight > strongest[i] { strongest[i] = weight; labels[i] = frame }
                            sumX += Double(x); sumY += Double(y); covered += 1
                        }
                        x += 1
                    }
                    y += 1
                }
            } } } }
        }
        return (sumX, sumY, covered)
    }

    /// Moves the seam between two frames to the path through their overlap where they differ
    /// least (dynamic programming over one path position per row, or per column for frames one
    /// above the other). Only pixels already given to one of the two change hands.
    static func refineSeam(_ a: Int, _ b: Int, luminance: [[Float]], centres: [SIMD2<Double>], labels: inout [UInt8], width: Int, height: Int) {
        let vertical = abs(centres[a].x - centres[b].x) >= abs(centres[a].y - centres[b].y)
        // `first` keeps the low side of the path (left of a top-to-bottom seam, above a left-to-right one).
        let first = vertical ? (centres[a].x <= centres[b].x ? a : b) : (centres[a].y <= centres[b].y ? a : b)
        let second = first == a ? b : a
        luminance[a].withUnsafeBufferPointer { pa in luminance[b].withUnsafeBufferPointer { pb in labels.withUnsafeMutableBufferPointer { pl in
            refineSeam(UInt8(a), UInt8(b), UInt8(first), UInt8(second), vertical, pa.baseAddress!, pb.baseAddress!, pl.baseAddress!, width, height)
        } } }
    }
    private static func refineSeam(_ a: UInt8, _ b: UInt8, _ first: UInt8, _ second: UInt8, _ vertical: Bool,
                                   _ la: UnsafePointer<Float>, _ lb: UnsafePointer<Float>, _ labels: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int) {
        var x0 = width, x1 = -1, y0 = height, y1 = -1, owned = 0, p = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                // NaN marks a pixel a frame does not cover: it is the only value that differs from itself.
                if la[p] == la[p], lb[p] == lb[p] {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if y < y0 { y0 = y }
                    if y > y1 { y1 = y }
                    if labels[p] == a || labels[p] == b { owned += 1 }
                }
                p += 1; x += 1
            }
            y += 1
        }
        guard owned > 0, x1 >= x0, y1 >= y0 else { return }
        let along = vertical ? y1 - y0 + 1 : x1 - x0 + 1, across = vertical ? x1 - x0 + 1 : y1 - y0 + 1
        let cost = UnsafeMutablePointer<Float>.allocate(capacity: along * across), from = UnsafeMutablePointer<Int8>.allocate(capacity: along * across)
        defer { cost.deallocate(); from.deallocate() }
        let outside: Float = 8
        var i = 0
        while i < along {
            var j = 0
            while j < across {
                let p = vertical ? (y0 + i) * width + x0 + j : (y0 + j) * width + x0 + i
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
                let p = vertical ? (y0 + i) * width + x0 + k : (y0 + k) * width + x0 + i
                if la[p] == la[p], lb[p] == lb[p], labels[p] == a || labels[p] == b { labels[p] = k <= j ? first : second }
                k += 1
            }
            j += Int(from[i * across + j])
            i -= 1
        }
    }

    /// Gives one frame's claim to every canvas pixel it covers in `region`: the seam finder's choice
    /// where that frame really covers the pixel, otherwise the covering frame whose edge is farthest.
    private static func claim(_ frame: UInt8, _ mapper: Mapper, _ table: Tables, _ region: Region, _ width: Int, _ q: Int,
                              _ lowLabels: UnsafePointer<UInt8>, _ lowWidth: Int, _ labels: UnsafeMutablePointer<UInt8>, _ strongest: UnsafeMutablePointer<UInt8>) throws {
        var sx = 0.0, sy = 0.0
        try table.cx.withUnsafeBufferPointer { tcx in try table.cz.withUnsafeBufferPointer { tcz in try table.ry.withUnsafeBufferPointer { tvy in try table.rs.withUnsafeBufferPointer { trs in
            var y = region.y0
            while y < region.y1 {
                if y % 64 == 0 { try Task.checkCancellation() }
                let ry = tvy[y], rs = trs[y], low = lowLabels + (y / q) * lowWidth
                var x = region.x0
                while x < region.x1 {
                    if mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                        let i = y * width + x
                        if low[x / q] == frame { labels[i] = frame; strongest[i] = 255 }
                        else {
                            var weight = mapper.feather(sx, sy) * 253 + 1
                            if weight > 254 { weight = 254 }
                            if UInt8(weight) > strongest[i] { strongest[i] = UInt8(weight); labels[i] = frame }
                        }
                    }
                    x += 1
                }
                y += 1
            }
        } } } }
    }

    // MARK: Composition

    /// Level 0 of one frame's pyramid: the frame resampled onto `region` of the canvas with its
    /// exposure and falloff removed, where it has data, and where the seam finder gave it the pixel.
    private static func warpFrame(_ source: UnsafePointer<Float16>, _ sw: Int, _ sh: Int, _ mapper: Mapper, _ table: Tables, _ region: Region, _ width: Int, _ height: Int,
                                  _ frame: UInt8, _ labels: UnsafePointer<UInt8>, _ colour: UnsafeMutablePointer<Float16>,
                                  _ coverage: UnsafeMutablePointer<Float16>, _ mask: UnsafeMutablePointer<Float16>) throws {
        let rw = region.width, endY = region.y1 < height ? region.y1 : height, endX = region.x1 < width ? region.x1 : width
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 11)
        defer { scratch.deallocate() }
        let value = scratch + 8
        var sx = 0.0, sy = 0.0
        try table.cx.withUnsafeBufferPointer { tcx in try table.cz.withUnsafeBufferPointer { tcz in try table.ry.withUnsafeBufferPointer { tvy in try table.rs.withUnsafeBufferPointer { trs in
            var y = region.y0
            while y < endY {
                if y % 32 == 0 { try Task.checkCancellation() }
                let ry = tvy[y], rs = trs[y]
                var x = region.x0
                while x < endX {
                    if mapper.locate(tcx[x] * rs, ry, tcz[x] * rs, &sx, &sy) {
                        bicubic(source, sw, sh, sx, sy, scratch, into: value)
                        let falloff = mapper.unfalloff(sx, sy), i = (y - region.y0) * rw + x - region.x0
                        colour[i * 3] = half(value[0] * mapper.red * falloff); colour[i * 3 + 1] = half(value[1] * mapper.green * falloff); colour[i * 3 + 2] = half(value[2] * mapper.blue * falloff)
                        coverage[i] = 1
                        if labels[y * width + x] == frame { mask[i] = 1 }
                    }
                    x += 1
                }
                y += 1
            }
        } } } }
    }

    /// One level of one frame's pyramid, from the coarsest down: the level's picture is filled in
    /// from the expansion of the level above (`coarse`, nil at the top) where the frame has no
    /// data, and the band it adds to that expansion goes into the canvas sums, weighted by the
    /// frame's mask. `colour` holds the premultiplied level on entry and the filled picture on return.
    private static func addBand(_ colour: UnsafeMutablePointer<Float16>, _ coverage: UnsafePointer<Float16>, _ mask: UnsafePointer<Float16>, _ w: Int, _ h: Int,
                                coarse: UnsafePointer<Float16>?, _ uw: Int, _ uh: Int, sums: UnsafeMutablePointer<Float16>, weights: UnsafeMutablePointer<Float16>?,
                                _ cw: Int, _ ch: Int, _ ox: Int, _ oy: Int) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: max(1, uw) * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var i = 0
        while i < w * 3 { above[i] = 0; i += 1 }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            if let coarse { expandRow(coarse, uw, uh, 3, row: y, width: w, scratch: scratch, into: above) }
            let inside = y + oy < ch
            var x = 0
            while x < w {
                let i = y * w + x, v = Float(coverage[i]), pixel = colour + i * 3, up = above + x * 3
                var r = up[0], g = up[1], b = up[2]
                if v > 1e-3 { r = Float(pixel[0]) / v; g = Float(pixel[1]) / v; b = Float(pixel[2]) / v }
                pixel[0] = half(r); pixel[1] = half(g); pixel[2] = half(b)
                let m = Float(mask[i])
                if m > 0, inside, x + ox < cw {
                    let o = (y + oy) * cw + x + ox, sum = sums + o * 3
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
    /// pixels are left at zero and covered ones are kept non-negative.
    private static func collapse(_ sums: UnsafeMutablePointer<Float16>, _ w: Int, _ h: Int, weights: UnsafePointer<Float16>?, labels: UnsafePointer<UInt8>?,
                                 coarse: UnsafePointer<Float16>?, _ uw: Int, _ uh: Int) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: max(1, uw) * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var i = 0
        while i < w * 3 { above[i] = 0; i += 1 }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            if let coarse { expandRow(coarse, uw, uh, 3, row: y, width: w, scratch: scratch, into: above) }
            var x = 0
            while x < w {
                let i = y * w + x, pixel = sums + i * 3, up = above + x * 3
                var weight: Float = 1
                if let labels { weight = labels[i] == 255 ? 0 : 1 } else if let weights { weight = Float(weights[i]) }
                var r = up[0], g = up[1], b = up[2]
                if weight > 1e-3 { r += Float(pixel[0]) / weight; g += Float(pixel[1]) / weight; b += Float(pixel[2]) / weight }
                if labels != nil {
                    if weight == 0 { r = 0; g = 0; b = 0 } else { if r < 0 { r = 0 }; if g < 0 { g = 0 }; if b < 0 { b = 0 } }
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
        if !options.compensateExposure { alignment.gains = alignment.gains.map { _ in SIMD3(repeating: 1) }; alignment.vignetting = .zero }
        let (geometry, regions) = try layout(alignment, projection: options.projection)
        let width = geometry.width, height = geometry.height
        // Pyramid levels above the base: the coarsest band is 1/16 of the canvas's short side or finer.
        let bands = options.blend == .none ? 0 : max(1, min(5, Int(log2(Double(min(width, height)))) - 4))
        let grain = 1 << bands, margin = bands == 0 ? 0 : 4 * grain
        func expanded(_ r: Region) -> Region {
            Region(x0: max(0, (r.x0 - margin) / grain * grain), y0: max(0, (r.y0 - margin) / grain * grain),
                   x1: min((width + grain - 1) / grain * grain, (r.x1 + margin + grain - 1) / grain * grain),
                   y1: min((height + grain - 1) / grain * grain, (r.y1 + margin + grain - 1) / grain * grain))
        }
        let warp = regions.joined().map { let e = expanded($0); return e.width * e.height }.max() ?? 0
        let needed = workingBytes(frames: count, width: alignment.width, height: alignment.height, canvasPixels: width * height, warpPixels: warp)
        guard needed <= budget else {
            throw LWPanoramaError.tooLarge(frames: count, width: alignment.width, height: alignment.height, outputWidth: width, outputHeight: height, neededBytes: needed, budgetBytes: budget)
        }
        let mappers = (0..<count).map { Mapper(alignment, frame: $0) }

        // Seams, on the canvas reduced to about 400,000 pixels.
        let q = max(1, Int((Double(width * height) / 400_000).squareRoot().rounded(.up)))
        let lowWidth = (width + q - 1) / q, lowHeight = (height + q - 1) / q
        var lowLabels = [UInt8](repeating: 255, count: lowWidth * lowHeight)
        do {
            let table = geometry.tables(xs: (0..<lowWidth).map { Double($0 * q) + Double(q - 1) / 2 }, ys: (0..<lowHeight).map { Double($0 * q) + Double(q - 1) / 2 })
            var luminance: [[Float]] = [], centres: [SIMD2<Double>] = []
            var strongest = [Float](repeating: -1, count: lowWidth * lowHeight)
            for k in 0..<count {
                try Task.checkCancellation()
                var values = [Float](repeating: .nan, count: lowWidth * lowHeight)
                var centre = SIMD2<Double>(repeating: 0), covered = 0.0
                for region in regions[k] {
                    let part = values.withUnsafeMutableBufferPointer { v in strongest.withUnsafeMutableBufferPointer { s in lowLabels.withUnsafeMutableBufferPointer { l in
                        seamInputs(UInt8(k), mappers[k], works[k], table, x0: region.x0 / q, y0: region.y0 / q, x1: min(lowWidth, (region.x1 + q - 1) / q), y1: min(lowHeight, (region.y1 + q - 1) / q),
                                   lowWidth: lowWidth, values: v.baseAddress!, strongest: s.baseAddress!, labels: l.baseAddress!)
                    } } }
                    centre += SIMD2(part.x, part.y); covered += part.count
                }
                luminance.append(values); centres.append(covered > 0 ? centre / covered : .zero)
            }
            for a in 0..<count {
                for b in (a + 1)..<count {
                    try Task.checkCancellation()
                    refineSeam(a, b, luminance: luminance, centres: centres, labels: &lowLabels, width: lowWidth, height: lowHeight)
                }
            }
        }

        var labels = [UInt8](repeating: 255, count: width * height)
        let table = geometry.tables(xs: (0..<width).map(Double.init), ys: (0..<height).map(Double.init))
        do {
            var strongest = [UInt8](repeating: 0, count: width * height)
            for k in 0..<count {
                for region in regions[k] {
                    try lowLabels.withUnsafeBufferPointer { low in try labels.withUnsafeMutableBufferPointer { l in try strongest.withUnsafeMutableBufferPointer { s in
                        try claim(UInt8(k), mappers[k], table, region, width, q, low.baseAddress!, lowWidth, l.baseAddress!, s.baseAddress!)
                    } } }
                }
            }
        }

        // The blend pyramid: per level, the sum of each frame's band weighted by its mask.
        var levelWidth = [width], levelHeight = [height]
        for _ in 0..<bands { levelWidth.append((levelWidth.last! + 1) / 2); levelHeight.append((levelHeight.last! + 1) / 2) }
        var sums = (0...bands).map { [Float16](repeating: 0, count: levelWidth[$0] * levelHeight[$0] * 3) }
        var weights = (0...bands).map { $0 == 0 ? [] : [Float16](repeating: 0, count: levelWidth[$0] * levelHeight[$0]) }
        // One set of buffers, sized for the largest part at each level, serves every frame in turn:
        // the frame warped onto its part of the canvas, its coverage and its mask, and their pyramids.
        let parts = regions.enumerated().flatMap { k, own in own.map { (frame: k, region: expanded($0)) } }.filter { $0.region.width > 0 && $0.region.height > 0 }
        var capacity = [Int](repeating: 1, count: bands + 1)
        for part in parts {
            var w = part.region.width, h = part.region.height
            for level in 0...bands { capacity[level] = max(capacity[level], w * h); w = (w + 1) / 2; h = (h + 1) / 2 }
        }
        let colour = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0 * 3) }
        let coverage = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0) }, mask = capacity.map { UnsafeMutablePointer<Float16>.allocate(capacity: $0) }
        defer { for level in 0...bands { colour[level].deallocate(); coverage[level].deallocate(); mask[level].deallocate() } }
        for (k, region) in parts {
            try Task.checkCancellation()
            let rw = region.width, rh = region.height
            colour[0].update(repeating: 0, count: rw * rh * 3); coverage[0].update(repeating: 0, count: rw * rh); mask[0].update(repeating: 0, count: rw * rh)
            try frames[k].samples.withUnsafeBufferPointer { source in
                try labels.withUnsafeBufferPointer { l in
                    try warpFrame(source.baseAddress!, frames[k].width, frames[k].height, mappers[k], table, region, width, height, UInt8(k), l.baseAddress!, colour[0], coverage[0], mask[0])
                }
            }
            var sizes = [(rw, rh)]
            for level in 0..<bands {
                let (w, h) = sizes[level]
                try reduce(colour[level], w, h, 3, into: colour[level + 1]); try reduce(coverage[level], w, h, 1, into: coverage[level + 1]); try reduce(mask[level], w, h, 1, into: mask[level + 1])
                sizes.append(((w + 1) / 2, (h + 1) / 2))
            }
            for level in stride(from: bands, through: 0, by: -1) {
                let (w, h) = sizes[level], top = level == bands
                let (uw, uh) = top ? (0, 0) : sizes[level + 1]
                try sums[level].withUnsafeMutableBufferPointer { s in try weights[level].withUnsafeMutableBufferPointer { wt in
                    try addBand(colour[level], coverage[level], mask[level], w, h, coarse: top ? nil : UnsafePointer(colour[level + 1]), uw, uh,
                                sums: s.baseAddress!, weights: level > 0 ? wt.baseAddress! : nil, levelWidth[level], levelHeight[level], region.x0 >> level, region.y0 >> level)
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
                                 coarse: top ? nil : coarse.baseAddress!, top ? 0 : levelWidth[level + 1], top ? 0 : levelHeight[level + 1])
                }
            } } }
            sums[level] = fine
            if !top { sums[level + 1] = []; weights[level + 1] = [] }
        }
        var picture = sums[0]
        sums = []; weights = []

        var area = Region(x0: 0, y0: 0, x1: width, y1: height)
        switch options.boundary {
        case .fill: try fill(&picture, labels: labels, width: width, height: height)
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
        return LWPanoramaResult(width: area.width, height: area.height, samples: picture, labels: labels, offsetX: area.x0, offsetY: area.y0,
            geometry: geometry, alignment: alignment, options: options, bands: bands, uncoveredPixels: uncovered, workingBytes: needed)
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
    /// The fill continues the picture's colour and brightness; it invents no detail.
    static func fill(_ picture: inout [Float16], labels: [UInt8], width: Int, height: Int) throws {
        guard labels.contains(255) else { return }
        // Push: level 1 straight from the picture (already zero where uncovered) and the labels, then on up to one pixel.
        var sizes = [(width, height)], colours: [[Float16]] = [[]], covers: [[Float16]] = [[]]
        colours.append(try reduce(picture, width, height, 3)); covers.append(try reduceCoverage(labels, width, height))
        sizes.append(((width + 1) / 2, (height + 1) / 2))
        while sizes.last!.0 > 1 || sizes.last!.1 > 1 {
            let (w, h) = sizes.last!
            colours.append(try reduce(colours.last!, w, h, 3)); covers.append(try reduce(covers.last!, w, h, 1))
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
                        try pull(p.baseAddress!, w, h, cover: nil, labels: l.baseAddress!, coarse: coarse.baseAddress!, uw, uh)
                    } }
                } else {
                    try fine.withUnsafeMutableBufferPointer { p in try covers[level].withUnsafeBufferPointer { v in
                        try pull(p.baseAddress!, w, h, cover: v.baseAddress!, labels: nil, coarse: coarse.baseAddress!, uw, uh)
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
                             coarse: UnsafePointer<Float16>, _ uw: Int, _ uh: Int) throws {
        let above = UnsafeMutablePointer<Float>.allocate(capacity: w * 3), scratch = UnsafeMutablePointer<Float>.allocate(capacity: uw * 3)
        defer { above.deallocate(); scratch.deallocate() }
        var y = 0
        while y < h {
            if y % 64 == 0 { try Task.checkCancellation() }
            expandRow(coarse, uw, uh, 3, row: y, width: w, scratch: scratch, into: above)
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
/// Y is Rec. 709 luminance; Y_k is frame k resampled at the pixel by the panorama's own alignment,
/// with its solved exposure and falloff removed; ε = 1e-4. The seam band is every covered pixel
/// within `radius` pixels of a seam (a boundary between two frames' pixels).
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
    static func luminance(_ v: SIMD3<Float>) -> Float { max(0, 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z) }

    /// Luminance of one frame resampled at every pixel of the picture; NaN where the frame does not see the pixel.
    static func seen(_ result: LWPanoramaResult, frame: LWMergeFrame, index: Int) -> [Float] {
        let width = result.width, height = result.height
        let mapper = LWPanoramaStitcher.Mapper(result.alignment, frame: index)
        let table = result.geometry.tables(xs: (0..<width).map { Double($0 + result.offsetX) }, ys: (0..<height).map { Double($0 + result.offsetY) })
        var values = [Float](repeating: .nan, count: width * height)
        frame.samples.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { out in resample(source.baseAddress!, frame.width, frame.height, mapper, table, width, height, into: out.baseAddress!) }
        }
        return values
    }
    // Raw pointers and `while` loops, as in the stitcher: these run per pixel in the unoptimized test build.
    private static func resample(_ source: UnsafePointer<Float16>, _ sw: Int, _ sh: Int, _ mapper: LWPanoramaStitcher.Mapper, _ table: LWPanoramaStitcher.Tables,
                                 _ width: Int, _ height: Int, into out: UnsafeMutablePointer<Float>) {
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
                        let luminance = (0.2126 * value[0] * mapper.red + 0.7152 * value[1] * mapper.green + 0.0722 * value[2] * mapper.blue) * mapper.unfalloff(sx, sy)
                        out[y * width + x] = luminance > 0 ? luminance : 0
                    }
                    x += 1
                }
                y += 1
            }
        } } } }
    }

    static func measure(_ result: LWPanoramaResult, frames: [LWMergeFrame]) -> Measurement {
        let width = result.width, height = result.height, count = frames.count, pixels = width * height
        // Every frame's view of the picture, as log2 luminance (NaN where it does not see the pixel), one after another.
        var views = [Float](repeating: .nan, count: count * pixels)
        for k in 0..<count {
            let view = seen(result, frame: frames[k], index: k)
            for p in 0..<pixels where !view[p].isNaN { views[k * pixels + p] = log2(view[p] + epsilon) }
        }
        var out = [Float](repeating: 0, count: pixels)
        for p in 0..<pixels { out[p] = log2(luminance(result.rgb(p)) + epsilon) }
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
                        let nx = x + (side == 0 ? 1 : 0), ny = y + (side == 0 ? 0 : 1)
                        side += 1
                        if nx >= width || ny >= height { continue }
                        let q = ny * width + nx, b = labels[q]
                        if b == 255 || b == a { continue }
                        var dy = -radius
                        while dy <= radius {
                            var dx = -radius
                            while dx <= radius {
                                let px = x + dx, py = y + dy
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
