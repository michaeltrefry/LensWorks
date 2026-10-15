import Foundation
import simd

/// The surface a panorama is laid out on (docs/PANORAMA_MERGE.md, "Projections").
nonisolated enum LWPanoramaProjection: String, Codable, CaseIterable, Sendable {
    case spherical, cylindrical, perspective
    var title: String {
        switch self {
        case .spherical: "Spherical"
        case .cylindrical: "Cylindrical"
        case .perspective: "Perspective"
        }
    }
}

/// What becomes of the canvas the photos do not cover.
nonisolated enum LWPanoramaBoundary: String, Codable, CaseIterable, Sendable {
    /// Keep the largest rectangle the photos cover completely.
    case autoCrop
    /// Keep the whole canvas and extend the picture into the uncovered border.
    case fill
    var title: String { self == .autoCrop ? "Auto Crop" : "Fill Edges" }
}

nonisolated enum LWPanoramaError: Error, Equatable {
    case tooFewFrames, tooManyFrames
    case sizeMismatch(frame: Int)
    /// A photo with nothing to match on (a blank wall, a clear sky, a black frame).
    case featureless(frame: Int)
    /// A photo that shares no recognizable detail with any other.
    case unmatched(frame: Int)
    /// Two photos that show the same detail, but in too thin a strip to join them reliably.
    case insufficientOverlap(frame: Int, other: Int)
    /// Two photos that can be joined in two different ways: a second alignment explains a good
    /// part of the detail the first leaves out.
    case ambiguous(frame: Int, other: Int)
    /// The photos match pairwise but not as views from one position.
    case notOnePanorama(rmsPixels: Double)
    case tooWideForPerspective(degrees: Int)
    case tooLarge(frames: Int, width: Int, height: Int, outputWidth: Int, outputHeight: Int, neededBytes: Int, budgetBytes: Int)
    case outputTooLarge(width: Int, height: Int)

    /// The reason in words a person can act on; `names` are the photos' file names, in frame order.
    func message(names: [String] = []) -> String {
        func name(_ frame: Int) -> String { names.indices.contains(frame) ? "“\(names[frame])”" : "Photo \(frame + 1)" }
        switch self {
        case .tooFewFrames: return "Select two or more overlapping photos."
        case .tooManyFrames: return "Select at most \(LWPanoramaStitcher.maximumFrames) photos."
        case .sizeMismatch(let frame):
            return "\(name(frame)) has different pixel dimensions from the first photo. A panorama needs photos taken with the same camera, orientation and zoom."
        case .featureless(let frame):
            return "\(name(frame)) has too little detail to place it in the panorama. Remove it from the selection."
        case .unmatched(let frame):
            return "\(name(frame)) does not match any of the other photos. Remove it from the selection, or add a photo that overlaps it."
        case .insufficientOverlap(let frame, let other):
            return "\(name(frame)) and \(name(other)) overlap too little to be joined. Add a photo taken between them, or reshoot with about a third of each photo overlapping the next."
        case .ambiguous(let frame, let other):
            return "\(name(frame)) and \(name(other)) can be joined in two different ways. Either the scene repeats (a fence, bricks, rows of windows), or near and far subjects line up differently because the camera changed position. Reshoot turning the camera about its lens, with something that does not repeat in the overlap, or leave one of the two out."
        case .notOnePanorama(let rms):
            // No figure when no alignment was found at all.
            let figure = rms.isFinite ? String(format: " (they disagree by %.0f pixels)", rms) : ""
            return "These photos match each other but do not fit together as one panorama\(figure). They may have been taken from different positions."
        case .tooWideForPerspective(let degrees):
            return "These photos span about \(degrees)°, which is too wide for the Perspective projection. Choose Cylindrical or Spherical."
        case .tooLarge(let frames, let width, let height, let outputWidth, let outputHeight, let needed, let budget):
            // Before the photos are aligned the panorama's size is not known, only that it cannot fit.
            let output = outputWidth > 0 ? String(format: "a %d × %d (%.0f MP) panorama", outputWidth, outputHeight, Double(outputWidth * outputHeight) / 1e6) : "a panorama"
            return String(format: "Merging %d photos of %d × %d (%.0f MP) into %@ needs about %.1f GB of memory; this Mac allows %.1f GB for a merge. Select fewer photos.",
                frames, width, height, Double(width * height) / 1e6, output, Double(needed) / 1e9, Double(budget) / 1e9)
        case .outputTooLarge(let width, let height):
            return String(format: "The panorama would be %d × %d (%.0f MP); the largest that can be written is %.0f MP. Select fewer photos.",
                width, height, Double(width * height) / 1e6, Double(LWPanoramaStitcher.maximumOutputPixels) / 1e6)
        }
    }
}
extension LWPanoramaError: LocalizedError {
    nonisolated var errorDescription: String? { message() }
}

/// Two frames the registration joined.
nonisolated struct LWPanoramaPair: Codable, Equatable, Sendable {
    let first: Int, second: Int
    /// Descriptor matches found, and how many of them one homography explains.
    let matches: Int, inliers: Int
    /// How many of the rest a second, different homography explains.
    var rival = 0
}

/// Where each frame's camera pointed, and how each frame's exposure relates to the others.
nonisolated struct LWPanoramaAlignment: Sendable, Equatable {
    var width: Int, height: Int
    /// The shared focal length, in pixels.
    var focal: Double
    /// Camera-to-world rotation of each frame. World x is right, y is down, z is the panorama's centre.
    var rotations: [simd_double3x3]
    /// Each frame's linear gain per channel; a frame's samples are divided by it.
    var gains: [SIMD3<Float>]
    /// Lens falloff shared by the frames: log2 V(ρ) = v.x ρ² + v.y ρ⁴, ρ = distance from the frame centre / distance to the corner.
    var vignetting: SIMD2<Double>
    var pairs: [LWPanoramaPair]
    /// Root-mean-square distance, in pixels, between matched points after the global alignment.
    var rms: Double
    /// The frame the others were first placed against.
    var reference: Int

    var principal: SIMD2<Double> { SIMD2(Double(width - 1) / 2, Double(height - 1) / 2) }
    /// The world direction seen at a frame pixel.
    func ray(frame: Int, x: Double, y: Double) -> SIMD3<Double> {
        rotations[frame] * SIMD3((x - principal.x) / focal, (y - principal.y) / focal, 1)
    }
    /// The frame pixel that sees a world direction, or nil when it is behind the camera.
    func pixel(frame: Int, ray: SIMD3<Double>) -> SIMD2<Double>? {
        let c = rotations[frame].transpose * ray
        guard c.z > 1e-9 else { return nil }
        return SIMD2(focal * c.x / c.z + principal.x, focal * c.y / c.z + principal.y)
    }
}

/// Panorama stitching: feature detection and matching, robust pairwise registration, global
/// alignment of camera rotations and focal length, exposure and vignetting compensation, seam
/// finding, multi-band blending, auto-crop and fill. See docs/PANORAMA_MERGE.md.
nonisolated enum LWPanoramaStitcher {
    static let maximumFrames = 24
    /// A 32-bit float RGB strip must stay below the 4 GiB a TIFF offset can address.
    static let maximumOutputPixels = 357_000_000
    /// Registration works on a copy of each frame reduced to about this many pixels.
    static let workPixels = 1_000_000

    // MARK: Reduced working copy

    /// A frame reduced by an integer factor with an area average: linear RGB, 3 floats per pixel.
    struct Work: Sendable {
        let width: Int, height: Int, factor: Int
        let rgb: [Float]
        @inline(__always) func luminance(_ p: Int) -> Float { 0.2126 * rgb[p * 3] + 0.7152 * rgb[p * 3 + 1] + 0.0722 * rgb[p * 3 + 2] }
        /// Full-resolution frame coordinate of a working-copy coordinate.
        @inline(__always) func full(_ v: Double) -> Double { v * Double(factor) + Double(factor - 1) / 2 }
        @inline(__always) func work(_ v: Double) -> Double { (v - Double(factor - 1) / 2) / Double(factor) }
        /// Bilinear sample; nil outside the copy.
        @inline(__always) func sample(_ x: Double, _ y: Double) -> SIMD3<Float>? {
            guard x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else { return nil }
            let x0 = min(width - 2, Int(x)), y0 = min(height - 2, Int(y))
            guard x0 >= 0, y0 >= 0 else { return nil }
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let i = (y0 * width + x0) * 3, j = i + width * 3
            let a = SIMD3(rgb[i], rgb[i + 1], rgb[i + 2]), b = SIMD3(rgb[i + 3], rgb[i + 4], rgb[i + 5])
            let c = SIMD3(rgb[j], rgb[j + 1], rgb[j + 2]), d = SIMD3(rgb[j + 3], rgb[j + 4], rgb[j + 5])
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
    }

    static func workFactor(width: Int, height: Int) -> Int {
        max(1, Int((Double(width * height) / Double(workPixels)).squareRoot().rounded(.up)))
    }

    static func reduce(_ frame: LWMergeFrame) throws -> Work {
        let k = workFactor(width: frame.width, height: frame.height)
        let w = frame.width / k, h = frame.height / k
        guard w >= 16, h >= 16 else { throw LWMergeFrameError.invalid }
        var rgb = [Float](repeating: 0, count: w * h * 3)
        try frame.samples.withUnsafeBufferPointer { source in
            try rgb.withUnsafeMutableBufferPointer { target in try reduce(source, frame.width, factor: k, into: target, w, h) }
        }
        return Work(width: w, height: h, factor: k, rgb: rgb)
    }
    private static func reduce(_ source: UnsafeBufferPointer<Float16>, _ fw: Int, factor k: Int, into target: UnsafeMutableBufferPointer<Float>, _ w: Int, _ h: Int) throws {
        let scale = 1 / Float(k * k)
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for sy in 0..<k {
                    var p = ((y * k + sy) * fw + x * k) * 3
                    for _ in 0..<k { r += Float(source[p]); g += Float(source[p + 1]); b += Float(source[p + 2]); p += 3 }
                }
                let o = (y * w + x) * 3
                target[o] = r.isFinite ? r * scale : 0; target[o + 1] = g.isFinite ? g * scale : 0; target[o + 2] = b.isFinite ? b * scale : 0
            }
        }
    }

    // MARK: Features (multi-scale oriented patches, Brown, Szeliski and Winder 2005)

    static let descriptorSide = 8, descriptorLength = 64
    /// Descriptor samples are this many pyramid pixels apart: a 24-pixel window.
    static let descriptorSpacing: Float = 3

    struct Features: Sendable {
        /// Full-resolution frame coordinates.
        var points: [SIMD2<Double>] = []
        var levels: [UInt8] = []
        /// `descriptorLength` values per feature: a blurred, oriented patch with zero mean and unit variance.
        var descriptors: [Float] = []
        var count: Int { points.count }
    }

    /// Separable Gaussian blur with clamped borders.
    static func blur(_ image: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
        var horizontal = [Float](repeating: 0, count: image.count), result = [Float](repeating: 0, count: image.count)
        image.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { mid in
                result.withUnsafeMutableBufferPointer { dst in
                    kernel.withUnsafeBufferPointer { k in blur(src.baseAddress!, mid.baseAddress!, dst.baseAddress!, k.baseAddress!, radius, width, height) }
                }
            }
        }
        return result
    }
    // Written with raw pointers and `while` loops. In an optimized build that changes nothing; in
    // the unoptimized test build a `for` over a range and a buffer subscript are calls, and this
    // is the registration's hot loop (unoptimized, it was most of the test suite's time).
    private static func blur(_ src: UnsafePointer<Float>, _ mid: UnsafeMutablePointer<Float>, _ dst: UnsafeMutablePointer<Float>,
                             _ k: UnsafePointer<Float>, _ radius: Int, _ width: Int, _ height: Int) {
        let taps = 2 * radius + 1, last = width - 1
        var y = 0
        while y < height {
            let row = src + y * width, out = mid + y * width
            var x = 0
            while x < width {
                var s: Float = 0, i = 0
                if x >= radius, x + radius < width {
                    let base = row + (x - radius)
                    while i < taps { s += k[i] * base[i]; i += 1 }
                } else {
                    while i < taps {
                        var c = x + i - radius
                        if c < 0 { c = 0 } else if c > last { c = last }
                        s += k[i] * row[c]; i += 1
                    }
                }
                out[x] = s; x += 1
            }
            y += 1
        }
        y = 0
        while y < height {
            let out = dst + y * width
            var i = 0
            while i < taps {
                var sy = y + i - radius
                if sy < 0 { sy = 0 } else if sy >= height { sy = height - 1 }
                let line = UnsafePointer(mid) + sy * width, weight = k[i]
                var x = 0
                while x < width { out[x] += weight * line[x]; x += 1 }
                i += 1
            }
            y += 1
        }
    }

    @inline(__always) static func bilinear(_ image: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> Float {
        let cx = min(Float(width - 1), max(0, x)), cy = min(Float(height - 1), max(0, y))
        let x0 = min(width - 2, Int(cx)), y0 = min(height - 2, Int(cy))
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = image[y0 * width + x0], b = image[y0 * width + x0 + 1], c = image[(y0 + 1) * width + x0], d = image[(y0 + 1) * width + x0 + 1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Harris corners at up to four pyramid levels, the strongest per grid cell, each with an
    /// orientation from the smoothed gradient and a normalized 8 × 8 patch descriptor.
    static func features(_ work: Work) throws -> Features {
        var mean = 0.0
        for p in 0..<(work.width * work.height) { mean += Double(work.luminance(p)) }
        mean /= Double(work.width * work.height)
        // A display-like encoding, so corners in shadow count like corners in light.
        let reference = Float(max(mean * 6, 1e-6))
        var gray = [Float](repeating: 0, count: work.width * work.height)
        for p in gray.indices { gray[p] = pow(min(1, max(0, work.luminance(p) / reference)), 1 / 2.2) }
        var width = work.width, height = work.height, level = 0
        let cell = max(12, Int((Double(width * height) / 800).squareRoot()))
        var result = Features()
        while level < 4, min(width, height) >= 48 {
            try Task.checkCancellation()
            let smooth = blur(gray, width: width, height: height, sigma: 1)
            var ixx = [Float](repeating: 0, count: gray.count), iyy = ixx, ixy = ixx
            smooth.withUnsafeBufferPointer { g in
                ixx.withUnsafeMutableBufferPointer { xx in iyy.withUnsafeMutableBufferPointer { yy in ixy.withUnsafeMutableBufferPointer { xy in
                    gradientProducts(g.baseAddress!, xx.baseAddress!, yy.baseAddress!, xy.baseAddress!, width, height)
                } } }
            }
            ixx = blur(ixx, width: width, height: height, sigma: 1.5)
            iyy = blur(iyy, width: width, height: height, sigma: 1.5)
            ixy = blur(ixy, width: width, height: height, sigma: 1.5)
            var response = [Float](repeating: 0, count: gray.count)
            let patch = blur(gray, width: width, height: height, sigma: 2), broad = blur(gray, width: width, height: height, sigma: 4.5)
            // The strongest local maximum in each grid cell.
            let margin = 17, columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
            var best = [Int](repeating: -1, count: columns * rows)
            ixx.withUnsafeBufferPointer { xx in iyy.withUnsafeBufferPointer { yy in ixy.withUnsafeBufferPointer { xy in
                response.withUnsafeMutableBufferPointer { r in best.withUnsafeMutableBufferPointer { slots in
                    corners(xx.baseAddress!, yy.baseAddress!, xy.baseAddress!, r.baseAddress!, width, height, margin: margin, cell: cell, columns: columns, into: slots.baseAddress!)
                } }
            } } }
            let scale = Double(1 << level)
            for p in best where p >= 0 {
                let x = p % width, y = p / width
                // Sub-pixel position from a quadratic through the neighbours.
                let fx = Float(x) + refine(response[p - 1], response[p], response[p + 1])
                let fy = Float(y) + refine(response[p - width], response[p], response[p + width])
                let gx = broad[p + 1] - broad[p - 1], gy = broad[p + width] - broad[p - width]
                let length = (gx * gx + gy * gy).squareRoot()
                guard let values = patch.withUnsafeBufferPointer({ descriptor($0, width, height, fx, fy, length > 1e-9 ? gx / length : 1, length > 1e-9 ? gy / length : 0) }) else { continue }
                result.points.append(SIMD2(work.full(Double(fx) * scale), work.full(Double(fy) * scale)))
                result.levels.append(UInt8(level)); result.descriptors.append(contentsOf: values)
            }
            // The next level: the smoothed image at every second pixel.
            let nw = width / 2, nh = height / 2
            var next = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh { for x in 0..<nw { next[y * nw + x] = smooth[2 * y * width + 2 * x] } }
            gray = next; width = nw; height = nh; level += 1
        }
        return result
    }

    // Raw pointers and `while` loops, as in `blur`: these run per pixel in the unoptimized test build.
    private static func gradientProducts(_ g: UnsafePointer<Float>, _ xx: UnsafeMutablePointer<Float>, _ yy: UnsafeMutablePointer<Float>, _ xy: UnsafeMutablePointer<Float>, _ width: Int, _ height: Int) {
        var y = 1
        while y < height - 1 {
            var p = y * width + 1
            let end = y * width + width - 1
            while p < end {
                let gx = (g[p + 1] - g[p - 1]) * 0.5, gy = (g[p + width] - g[p - width]) * 0.5
                xx[p] = gx * gx; yy[p] = gy * gy; xy[p] = gx * gy
                p += 1
            }
            y += 1
        }
    }
    /// The Harris response (harmonic mean of the structure tensor's eigenvalues) and, per grid cell, its strongest local maximum.
    private static func corners(_ xx: UnsafePointer<Float>, _ yy: UnsafePointer<Float>, _ xy: UnsafePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ width: Int, _ height: Int,
                                margin: Int, cell: Int, columns: Int, into best: UnsafeMutablePointer<Int>) {
        var p = 0
        let count = width * height
        while p < count { r[p] = (xx[p] * yy[p] - xy[p] * xy[p]) / (xx[p] + yy[p] + 1e-12); p += 1 }
        guard width > 2 * margin, height > 2 * margin else { return }
        var y = margin
        while y < height - margin {
            var x = margin
            while x < width - margin {
                let p = y * width + x, value = r[p]
                if value > 1e-6, value > r[p - 1], value >= r[p + 1], value > r[p - width], value >= r[p + width],
                   value > r[p - width - 1], value > r[p - width + 1], value >= r[p + width - 1], value >= r[p + width + 1] {
                    let slot = (y / cell) * columns + x / cell
                    if best[slot] < 0 || value > r[best[slot]] { best[slot] = p }
                }
                x += 1
            }
            y += 1
        }
    }
    @inline(__always) private static func refine(_ a: Float, _ b: Float, _ c: Float) -> Float {
        let d = a - 2 * b + c
        return d < 0 ? min(0.5, max(-0.5, (a - c) / (2 * d))) : 0
    }
    /// The 8 × 8 patch around (fx, fy), turned to the direction (c, s), with zero mean and unit variance; nil for a flat patch.
    private static func descriptor(_ patch: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ fx: Float, _ fy: Float, _ c: Float, _ s: Float) -> [Float]? {
        var values = [Float](repeating: 0, count: descriptorLength), sum: Float = 0
        for v in 0..<descriptorSide {
            for u in 0..<descriptorSide {
                let du = (Float(u) - 3.5) * descriptorSpacing, dv = (Float(v) - 3.5) * descriptorSpacing
                let value = bilinear(patch, width, height, fx + c * du - s * dv, fy + s * du + c * dv)
                values[v * descriptorSide + u] = value; sum += value
            }
        }
        let average = sum / Float(descriptorLength)
        var variance: Float = 0
        for i in 0..<descriptorLength { values[i] -= average; variance += values[i] * values[i] }
        let deviation = (variance / Float(descriptorLength)).squareRoot()
        guard deviation > 1e-4 else { return nil }
        for i in 0..<descriptorLength { values[i] /= deviation }
        return values
    }

    /// Mutual nearest neighbours at the same pyramid level that pass the ratio test (the nearest
    /// descriptor is clearly closer than the second nearest).
    static func match(_ a: Features, _ b: Features) throws -> [(Int, Int)] {
        let forward = try nearest(a, b), backward = try nearest(b, a)
        var pairs: [(Int, Int)] = []
        for (i, j) in forward.enumerated() where j >= 0 && backward[j] == i { pairs.append((i, j)) }
        return pairs
    }
    static func nearest(_ from: Features, _ to: Features) throws -> [Int] {
        var result = [Int](repeating: -1, count: from.count)
        guard from.count > 0, to.count > 0 else { return result }
        try from.descriptors.withUnsafeBufferPointer { fd in
            try to.descriptors.withUnsafeBufferPointer { td in
                try from.levels.withUnsafeBufferPointer { fl in
                    try to.levels.withUnsafeBufferPointer { tl in
                        try result.withUnsafeMutableBufferPointer { try nearest(fd.baseAddress!, fl.baseAddress!, from.count, td.baseAddress!, tl.baseAddress!, to.count, into: $0.baseAddress!) }
                    }
                }
            }
        }
        return result
    }
    private static func nearest(_ fd: UnsafePointer<Float>, _ fl: UnsafePointer<UInt8>, _ fromCount: Int, _ td: UnsafePointer<Float>, _ tl: UnsafePointer<UInt8>, _ toCount: Int,
                                into result: UnsafeMutablePointer<Int>) throws {
        let n = descriptorLength
        var i = 0
        while i < fromCount {
            if i % 256 == 0 { try Task.checkCancellation() }
            var first = Float.infinity, second = Float.infinity, index = -1
            let level = fl[i], a = fd + i * n
            var j = 0
            while j < toCount {
                if tl[j] == level {
                    var d: Float = 0, k = 0
                    let b = td + j * n
                    while k < n, d < second {
                        let e0 = a[k] - b[k], e1 = a[k + 1] - b[k + 1], e2 = a[k + 2] - b[k + 2], e3 = a[k + 3] - b[k + 3]
                        d += e0 * e0 + e1 * e1 + e2 * e2 + e3 * e3; k += 4
                    }
                    if d < first { second = first; first = d; index = j } else if d < second { second = d }
                }
                j += 1
            }
            if index >= 0, first < 0.64 * second { result[i] = index }
            i += 1
        }
    }

    // MARK: Pairwise registration

    /// Solves A x = b for a small dense system by elimination with partial pivoting; nil when singular.
    static func solve(_ matrix: [Double], _ vector: [Double], _ n: Int) -> [Double]? {
        var a = matrix, b = vector
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
            guard abs(a[pivot * n + column]) > 1e-14 else { return nil }
            if pivot != column {
                for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                b.swapAt(column, pivot)
            }
            for row in column..<n where row != column {
                let factor = a[row * n + column] / a[column * n + column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = b[row]
            for k in row..<n where k != row { s -= a[row * n + k] * x[k] }
            x[row] = s / a[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// The least-squares homography (h33 = 1) taking `from` to `to`.
    static func homography(_ from: [SIMD2<Double>], _ to: [SIMD2<Double>]) -> simd_double3x3? {
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        var row = [Double](repeating: 0, count: 8)
        for (p, q) in zip(from, to) {
            for axis in 0..<2 {
                let value = axis == 0 ? q.x : q.y
                if axis == 0 { row = [p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y] } else { row = [0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y] }
                for i in 0..<8 where row[i] != 0 {
                    atb[i] += row[i] * value
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(ata, atb, 8) else { return nil }
        return simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
    }
    @inline(__always) static func apply(_ h: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double>? {
        let v = h * SIMD3(p.x, p.y, 1)
        guard v.z > 1e-9 else { return nil }
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    /// The matches a homography takes to within the squared distance `limit` of their partners.
    private static func agreeing(_ h: simd_double3x3, _ a: [SIMD2<Double>], _ b: [SIMD2<Double>], _ limit: Double) -> [Int] {
        var result: [Int] = []
        for i in 0..<a.count {
            guard let p = apply(h, a[i]) else { continue }
            if simd_length_squared(p - b[i]) <= limit { result.append(i) }
        }
        return result
    }

    struct Registration: Sendable {
        let first: Int, second: Int
        /// Maps `first` to `second`, in centred coordinates divided by `unit`.
        var homography: simd_double3x3
        /// Matched points the homography explains, in centred full-resolution pixels.
        var from: [SIMD2<Double>], to: [SIMD2<Double>]
        let matches: Int
        /// Matched points that the homography does not explain and a second, different one does.
        var rival = 0
        var inliers: Int { from.count }
        /// Brown and Lowe's test that the matches are a real overlap and not chance agreement.
        var accepted: Bool { inliers >= 12 && Double(inliers) > 8 + 0.3 * Double(matches) }
        /// A second alignment has enough support to be a join of its own (12 matches, the least
        /// that joins two frames) and at least an eighth of the first's: the scene repeats, or
        /// near and far subjects moved against each other. Neither join can be trusted.
        var ambiguous: Bool { accepted && rival >= 12 && rival * 8 >= inliers }
    }

    /// RANSAC over four-point homographies, refitted on its inliers. The matches the homography
    /// leaves out are then searched for a second one (`rival`).
    static func register(first: Int, second: Int, from: [SIMD2<Double>], to: [SIMD2<Double>], unit: Double, tolerance: Double) throws -> Registration {
        let a = from.map { $0 / unit }, b = to.map { $0 / unit }, limit = (tolerance / unit) * (tolerance / unit)
        var state: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(first * 1000 + second)
        func next(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
        /// The largest set of `among` that one homography explains, as positions in `among`.
        func consensus(_ among: [Int]) throws -> (inliers: [Int], model: simd_double3x3) {
            let count = among.count
            var best: [Int] = [], bestModel = matrix_identity_double3x3
            guard count >= 4 else { return (best, bestModel) }
            let pa = among.map { a[$0] }, pb = among.map { b[$0] }
            // As many draws as it takes to be 99.9 % sure of one all-inlier sample at the best
            // inlier share seen so far: 1000 at most, 60 at least.
            var needed = 1000, iteration = 0
            while iteration < needed {
                if iteration % 100 == 0 { try Task.checkCancellation() }
                iteration += 1
                var picks: [Int] = []
                while picks.count < 4 { let i = next(count); if !picks.contains(i) { picks.append(i) } }
                guard let h = homography(picks.map { pa[$0] }, picks.map { pb[$0] }) else { continue }
                let found = agreeing(h, pa, pb, limit)
                guard found.count > best.count else { continue }
                best = found; bestModel = h
                let share = Double(best.count) / Double(count), miss = 1 - share * share * share * share
                needed = miss <= 1e-9 ? 60 : min(1000, max(60, Int((log(0.001) / log(miss)).rounded(.up))))
            }
            for _ in 0..<3 where best.count >= 4 {
                guard let h = homography(best.map { pa[$0] }, best.map { pb[$0] }) else { break }
                let found = agreeing(h, pa, pb, limit)
                guard found.count >= best.count else { break }
                best = found; bestModel = h
            }
            return (best, bestModel)
        }
        let all = Array(from.indices)
        let best = try consensus(all)
        var rival = 0
        if best.inliers.count >= 12 {
            let taken = Set(best.inliers), rest = all.filter { !taken.contains($0) }
            if rest.count >= 12 { rival = try consensus(rest).inliers.count }
        }
        return Registration(first: first, second: second, homography: best.model, from: best.inliers.map { from[$0] }, to: best.inliers.map { to[$0] }, matches: from.count, rival: rival)
    }

    /// Focal length of both cameras from a rotation homography (Szeliski and Shum 1997), in the homography's unit.
    static func focal(_ h: simd_double3x3) -> Double? {
        let m = [h[0][0], h[1][0], h[2][0], h[0][1], h[1][1], h[2][1], h[0][2], h[1][2], h[2][2]]  // row-major
        func pick(_ v1: Double, _ v2: Double, _ d1: Double, _ d2: Double) -> Double? {
            let a = max(v1, v2), b = min(v1, v2)
            if a > 0, b > 0 { return (abs(d1) > abs(d2) ? v1 : v2).squareRoot() }
            return a > 0 ? a.squareRoot() : nil
        }
        var d1 = m[6] * m[7], d2 = (m[7] - m[6]) * (m[7] + m[6])
        let f1 = pick(-(m[0] * m[1] + m[3] * m[4]) / d1, (m[0] * m[0] + m[3] * m[3] - m[1] * m[1] - m[4] * m[4]) / d2, d1, d2)
        d1 = m[0] * m[3] + m[1] * m[4]; d2 = m[0] * m[0] + m[1] * m[1] - m[3] * m[3] - m[4] * m[4]
        let f0 = pick(-m[2] * m[5] / d1, (m[5] * m[5] - m[2] * m[2]) / d2, d1, d2)
        guard let f0, let f1, f0.isFinite, f1.isFinite, f0 > 0, f1 > 0 else { return nil }
        return (f0 * f1).squareRoot()
    }

    /// True when one frame's edge strip shows the same detail as the other's opposite edge strip:
    /// an overlap too thin (under about a sixth of the frame) for the feature registration, whose
    /// descriptors need room around each point. The strips are compared by normalized correlation
    /// of local contrast at about 160 pixels across, over every strip width and sideways shift.
    static func thinOverlap(_ a: Work, _ b: Work) -> Bool {
        let first = contrast(a), second = contrast(b)
        guard first.width == second.width, first.height == second.height else { return false }
        return first.pixels.withUnsafeBufferPointer { p in second.pixels.withUnsafeBufferPointer { q in stripCorrelation(p, q, first.width, first.height) } } >= 0.6
    }
    /// Local contrast of log luminance, at about 160 pixels across.
    private static func contrast(_ work: Work) -> (pixels: [Float], width: Int, height: Int) {
        let m = max(1, work.width / 160), w = work.width / m, h = work.height / m
        var gray = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for sy in 0..<m { for sx in 0..<m { sum += work.luminance((y * m + sy) * work.width + x * m + sx) } }
                gray[y * w + x] = log2(max(1e-6, sum / Float(m * m)))
            }
        }
        let broad = blur(gray, width: w, height: h, sigma: 3)
        for i in gray.indices { gray[i] -= broad[i] }
        return (gray, w, h)
    }
    /// Correlation of `first`'s window at (ax, ay) with `second`'s at (bx, by).
    @inline(__always) private static func correlation(_ first: UnsafeBufferPointer<Float>, _ second: UnsafeBufferPointer<Float>, _ w: Int,
                                                      _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, _ cw: Int, _ ch: Int) -> Float {
        var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        for y in 0..<ch {
            for x in 0..<cw {
                let p = first[(ay + y) * w + ax + x], q = second[(by + y) * w + bx + x]
                sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
            }
        }
        let n = Float(cw * ch), va = saa - sa * sa / n, vb = sbb - sb * sb / n
        guard va > 1e-4 * n, vb > 1e-4 * n else { return 0 }
        return (sab - sa * sb / n) / (va * vb).squareRoot()
    }
    /// The best correlation of one image's edge strip with the other's opposite edge strip.
    private static func stripCorrelation(_ first: UnsafeBufferPointer<Float>, _ second: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int) -> Float {
        var best: Float = 0
        // first's right strip on second's left strip, and the reverse; then bottom on top, and the reverse.
        for strip in 3...max(3, w / 6) {
            for shift in -(h / 8)...(h / 8) {
                let ay = max(0, shift), by = max(0, -shift), ch = h - abs(shift)
                guard strip * ch >= 200 else { continue }
                best = max(best, correlation(first, second, w, w - strip, ay, 0, by, strip, ch), correlation(first, second, w, 0, ay, w - strip, by, strip, ch))
            }
        }
        for strip in 3...max(3, h / 6) {
            for shift in -(w / 8)...(w / 8) {
                let ax = max(0, shift), bx = max(0, -shift), cw = w - abs(shift)
                guard strip * cw >= 200 else { continue }
                best = max(best, correlation(first, second, w, ax, h - strip, bx, 0, cw, strip), correlation(first, second, w, ax, 0, bx, h - strip, cw, strip))
            }
        }
        return best
    }

    // MARK: Global alignment

    /// The rotation nearest to a matrix (polar decomposition by Newton's iteration).
    static func rotation(nearest matrix: simd_double3x3) -> simd_double3x3? {
        let determinant = matrix.determinant
        guard determinant.isFinite, determinant > 1e-12 else { return nil }
        var r = matrix * (1 / cbrt(determinant))
        for _ in 0..<30 {
            let next = (r + r.inverse.transpose) * 0.5
            let change = (0..<3).reduce(0.0) { $0 + simd_length_squared(next[$1] - r[$1]) }
            r = next
            if change < 1e-24 { break }
        }
        return (0..<3).allSatisfy { r[$0].x.isFinite && r[$0].y.isFinite && r[$0].z.isFinite } ? r : nil
    }
    static func rotation(vector v: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(v)
        guard angle > 1e-15 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: angle, axis: v / angle))
    }

    /// Camera rotations from the pairwise homographies along the strongest spanning tree, for one focal length.
    static func initialRotations(count: Int, reference: Int, registrations: [Registration], focal: Double, unit: Double) -> [simd_double3x3]? {
        var rotations = [simd_double3x3?](repeating: nil, count: count)
        rotations[reference] = matrix_identity_double3x3
        let f = focal / unit
        let k = simd_double3x3(diagonal: SIMD3(f, f, 1)), inverse = simd_double3x3(diagonal: SIMD3(1 / f, 1 / f, 1))
        var remaining = count - 1
        while remaining > 0 {
            // The strongest registration that joins a placed frame to an unplaced one.
            var chosen: (Registration, Bool)?
            for r in registrations {
                let forward = rotations[r.first] != nil && rotations[r.second] == nil, backward = rotations[r.second] != nil && rotations[r.first] == nil
                guard forward || backward else { continue }
                if chosen == nil || r.inliers > chosen!.0.inliers { chosen = (r, forward) }
            }
            guard let (r, forward) = chosen else { return nil }
            // inverse(K) H K = transpose(R_second) R_first.
            guard let relative = rotation(nearest: inverse * r.homography * k) else { return nil }
            if forward { rotations[r.second] = rotations[r.first]! * relative.transpose }
            else { rotations[r.first] = rotations[r.second]! * relative }
            remaining -= 1
        }
        return rotations.map { $0! }
    }

    /// Reprojection residuals of every matched point, both ways, in pixels.
    static func residuals(_ registrations: [Registration], rotations: [simd_double3x3], focal: Double, into out: inout [Double], only frame: Int? = nil, offsets: [Int]) {
        for (index, r) in registrations.enumerated() {
            if let frame, r.first != frame, r.second != frame { continue }
            let forward = rotations[r.second].transpose * rotations[r.first], backward = forward.transpose
            var o = offsets[index]
            for i in 0..<r.from.count {
                let p = r.from[i], q = r.to[i]
                let a = forward * SIMD3(p.x / focal, p.y / focal, 1), b = backward * SIMD3(q.x / focal, q.y / focal, 1)
                if a.z > 1e-6 { out[o] = focal * a.x / a.z - q.x; out[o + 1] = focal * a.y / a.z - q.y } else { out[o] = 1e4; out[o + 1] = 1e4 }
                if b.z > 1e-6 { out[o + 2] = focal * b.x / b.z - p.x; out[o + 3] = focal * b.y / b.z - p.y } else { out[o + 2] = 1e4; out[o + 3] = 1e4 }
                o += 4
            }
        }
    }

    /// Levenberg–Marquardt over the shared focal length and every rotation but the reference's,
    /// with a Huber loss. Returns the refined values and the root-mean-square residual in pixels.
    static func bundleAdjust(_ registrations: [Registration], rotations start: [simd_double3x3], focal startFocal: Double, reference: Int, huber: Double) throws -> (rotations: [simd_double3x3], focal: Double, rms: Double) {
        var rotations = start, focal = startFocal
        var offsets: [Int] = [], total = 0
        for r in registrations { offsets.append(total); total += r.from.count * 4 }
        guard total > 0 else { return (rotations, focal, 0) }
        let free = rotations.indices.filter { $0 != reference }, parameters = 1 + free.count * 3
        func cost(_ r: [Double]) -> Double {
            var c = 0.0
            for v in r { let a = abs(v); c += a <= huber ? 0.5 * a * a : huber * (a - 0.5 * huber) }
            return c
        }
        var current = [Double](repeating: 0, count: total)
        residuals(registrations, rotations: rotations, focal: focal, into: &current, offsets: offsets)
        var currentCost = cost(current), lambda = 1e-3
        let step = 1e-6
        for _ in 0..<40 {
            try Task.checkCancellation()
            // Jacobian by forward differences, one parameter at a time; a rotation only moves its own frame's pairs.
            var jtj = [Double](repeating: 0, count: parameters * parameters), jtr = [Double](repeating: 0, count: parameters)
            var columns = [[Double]](repeating: [], count: parameters)
            for parameter in 0..<parameters {
                var trial = rotations, trialFocal = focal, frame: Int?
                if parameter == 0 { trialFocal = focal * exp(step) }
                else {
                    let which = free[(parameter - 1) / 3]; frame = which
                    var v = SIMD3<Double>(repeating: 0); v[(parameter - 1) % 3] = step
                    trial[which] = rotations[which] * rotation(vector: v)
                }
                var moved = current
                residuals(registrations, rotations: trial, focal: trialFocal, into: &moved, only: frame, offsets: offsets)
                for i in 0..<total { moved[i] = (moved[i] - current[i]) / step }
                columns[parameter] = moved
            }
            var weights = [Double](repeating: 1, count: total)
            for i in 0..<total { let a = abs(current[i]); if a > huber { weights[i] = huber / a } }
            for i in 0..<parameters {
                var g = 0.0
                for k in 0..<total where columns[i][k] != 0 { g += columns[i][k] * weights[k] * current[k] }
                jtr[i] = g
                for j in i..<parameters {
                    var s = 0.0
                    for k in 0..<total where columns[i][k] != 0 { s += columns[i][k] * weights[k] * columns[j][k] }
                    jtj[i * parameters + j] = s; jtj[j * parameters + i] = s
                }
            }
            var improved = false
            for _ in 0..<8 {
                var damped = jtj
                for i in 0..<parameters { damped[i * parameters + i] += lambda * max(jtj[i * parameters + i], 1e-9) }
                guard let delta = solve(damped, jtr.map { -$0 }, parameters) else { lambda *= 10; continue }
                var trial = rotations
                let trialFocal = focal * exp(delta[0])
                for (index, which) in free.enumerated() {
                    trial[which] = rotations[which] * rotation(vector: SIMD3(delta[1 + index * 3], delta[2 + index * 3], delta[3 + index * 3]))
                }
                var next = current
                residuals(registrations, rotations: trial, focal: trialFocal, into: &next, offsets: offsets)
                let nextCost = cost(next)
                if nextCost < currentCost, trialFocal.isFinite, trialFocal > 0 {
                    let gain = (currentCost - nextCost) / max(currentCost, 1e-30)
                    rotations = trial; focal = trialFocal; current = next; currentCost = nextCost
                    lambda = max(1e-9, lambda / 10); improved = gain > 1e-10
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        // Rounding drifts a product of rotations off the rotation group; put each back.
        rotations = rotations.map { rotation(nearest: $0) ?? $0 }
        let rms = (current.reduce(0) { $0 + $1 * $1 } / Double(total / 2)).squareRoot()
        return (rotations, focal, rms)
    }

    /// Eigenvalues (ascending) and eigenvectors of a symmetric 3 × 3 matrix, by Jacobi rotations.
    static func eigen(_ matrix: simd_double3x3) -> [(value: Double, vector: SIMD3<Double>)] {
        var a = matrix, v = matrix_identity_double3x3
        for _ in 0..<60 {
            var p = 0, q = 1, largest = 0.0
            for (i, j) in [(0, 1), (0, 2), (1, 2)] where abs(a[j][i]) > largest { largest = abs(a[j][i]); p = i; q = j }
            guard largest > 1e-15 else { break }
            let theta = 0.5 * atan2(2 * a[q][p], a[q][q] - a[p][p]), c = cos(theta), s = sin(theta)
            var j = matrix_identity_double3x3
            j[p][p] = c; j[q][q] = c; j[q][p] = s; j[p][q] = -s
            a = j.transpose * a * j; v = v * j
        }
        return (0..<3).map { (a[$0][$0], v[$0]) }.sorted { $0.0 < $1.0 }
    }

    /// Turns the world so the horizon is level and the panorama's centre is straight ahead
    /// (Brown and Lowe 2007: the cameras' x axes lie in the horizontal plane). With
    /// `levelPitch` false the centre is the mean viewing direction, pitch included.
    static func straighten(_ rotations: [simd_double3x3], reference: Int, levelPitch: Bool) -> [simd_double3x3] {
        var covariance = simd_double3x3(0), meanDown = SIMD3<Double>(repeating: 0), meanForward = SIMD3<Double>(repeating: 0)
        for r in rotations {
            let x = r[0]
            covariance = covariance + simd_double3x3(columns: (x * x.x, x * x.y, x * x.z))
            meanDown += r[1]; meanForward += r[2]
        }
        let spectrum = eigen(covariance)
        var down = spectrum[0].vector
        if spectrum[1].value < 1e-4 * spectrum[2].value || !down.x.isFinite {
            // The frames barely turn: any direction across the shared x axis would do. Keep the cameras' own.
            let x = simd_normalize(spectrum[2].vector)
            down = meanDown - x * simd_dot(meanDown, x)
        }
        guard simd_length(down) > 1e-9 else { return rotations }
        down = simd_normalize(down)
        if simd_dot(down, meanDown) < 0 { down = -down }
        var forward = meanForward
        if simd_length(forward) < 1e-3 * Double(rotations.count) { forward = rotations[reference][2] }  // A full circle has no mean direction.
        if levelPitch || abs(simd_dot(simd_normalize(forward), down)) > 0.99 {
            forward -= down * simd_dot(forward, down)
            if simd_length(forward) < 1e-6 { forward = rotations[reference][0] - down * simd_dot(rotations[reference][0], down) }
        } else {
            forward = simd_normalize(forward)
            down = simd_normalize(down - forward * simd_dot(down, forward))
        }
        forward = simd_normalize(forward)
        let right = simd_cross(down, forward)
        let world = simd_double3x3(columns: (right, down, forward))
        return rotations.map { world.transpose * $0 }
    }

    // MARK: Exposure and vignetting

    /// Solves, by iteratively reweighted least squares, each frame's exposure (log2 gain, per
    /// channel) and the shared lens falloff from the colours the frames record for the same
    /// directions: log2 I_a − log2 I_b = (g_a − g_b) + c1 (ρ_a² − ρ_b²) + c2 (ρ_a⁴ − ρ_b⁴).
    static func exposures(_ works: [Work], frames: [LWMergeFrame], alignment: LWPanoramaAlignment) throws -> (gains: [SIMD3<Float>], vignetting: SIMD2<Double>) {
        struct Sample { let a: Int, b: Int; let ratio: SIMD3<Double>; let luminance: Double; let r2: Double, r4: Double }
        let count = works.count
        let unity = [SIMD3<Float>](repeating: SIMD3(repeating: 1), count: count)
        var samples: [Sample] = []
        let clips = frames.map(\.clipLevel), corner = simd_length_squared(alignment.principal)
        func radius2(_ x: Double, _ y: Double) -> Double { simd_length_squared(SIMD2(x, y) - alignment.principal) / corner }
        func usable(_ v: SIMD3<Float>, _ clip: SIMD3<Float>) -> Bool {
            let floor = 0.01 * clip
            return v.x < clip.x * 0.95 && v.y < clip.y * 0.95 && v.z < clip.z * 0.95 && v.x > floor.x && v.y > floor.y && v.z > floor.z
        }
        for pair in alignment.pairs {
            try Task.checkCancellation()
            let a = works[pair.first], b = works[pair.second]
            let step = max(1, Int((Double(a.width * a.height) / 3000).squareRoot()))
            for y in stride(from: step / 2, to: a.height, by: step) {
                for x in stride(from: step / 2, to: a.width, by: step) {
                    let fx = a.full(Double(x)), fy = a.full(Double(y))
                    guard let q = alignment.pixel(frame: pair.second, ray: alignment.ray(frame: pair.first, x: fx, y: fy)) else { continue }
                    let bx = b.work(q.x), by = b.work(q.y)
                    guard bx >= 1, by >= 1, bx <= Double(b.width - 2), by <= Double(b.height - 2), let other = b.sample(bx, by) else { continue }
                    let p = y * a.width + x, own = SIMD3(a.rgb[p * 3], a.rgb[p * 3 + 1], a.rgb[p * 3 + 2])
                    guard usable(own, clips[pair.first]), usable(other, clips[pair.second]) else { continue }
                    let ra = radius2(fx, fy), rb = radius2(q.x, q.y)
                    let ratio = SIMD3(log2(Double(own.x) / Double(other.x)), log2(Double(own.y) / Double(other.y)), log2(Double(own.z) / Double(other.z)))
                    let ya = 0.2126 * Double(own.x) + 0.7152 * Double(own.y) + 0.0722 * Double(own.z)
                    let yb = 0.2126 * Double(other.x) + 0.7152 * Double(other.y) + 0.0722 * Double(other.z)
                    samples.append(Sample(a: pair.first, b: pair.second, ratio: ratio, luminance: log2(ya / yb), r2: ra - rb, r4: ra * ra - rb * rb))
                }
            }
        }
        guard samples.count >= 16 * max(1, alignment.pairs.count) else { return (unity, .zero) }
        /// Unknowns: one log2 gain per frame, then (when `falloff`) c1 and c2. A weak prior holds
        /// the gains near zero mean (or near `prior`) and the falloff near none.
        func fit(_ value: (Sample) -> Double, falloff: Bool, prior: [Double]?) -> [Double]? {
            let n = count + (falloff ? 2 : 0)
            var x = [Double](repeating: 0, count: n), weights = [Double](repeating: 1, count: samples.count)
            for _ in 0..<4 {
                var ata = [Double](repeating: 0, count: n * n), atb = [Double](repeating: 0, count: n)
                for (index, s) in samples.enumerated() {
                    let w = weights[index], v = value(s)
                    var row: [(Int, Double)] = [(s.a, 1), (s.b, -1)]
                    if falloff { row.append((count, s.r2)); row.append((count + 1, s.r4)) }
                    for (i, ci) in row { atb[i] += w * ci * v; for (j, cj) in row { ata[i * n + j] += w * ci * cj } }
                }
                let hold = 1e-3 * Double(samples.count) / Double(count)
                for i in 0..<count {
                    for j in 0..<count { ata[i * n + j] += hold / Double(count) }
                    if let prior { ata[i * n + i] += 30 * hold; atb[i] += 30 * hold * prior[i] } else { ata[i * n + i] += 1e-3 * hold }
                }
                if falloff { for i in count..<n { ata[i * n + i] += hold } }
                guard let solved = solve(ata, atb, n) else { return nil }
                x = solved
                for (index, s) in samples.enumerated() {
                    var residual = value(s) - x[s.a] + x[s.b]
                    if falloff { residual -= x[count] * s.r2 + x[count + 1] * s.r4 }
                    weights[index] = abs(residual) <= 0.1 ? 1 : 0.1 / abs(residual)
                }
            }
            return x
        }
        var vignetting = SIMD2<Double>.zero
        var luminance = fit({ $0.luminance }, falloff: true, prior: nil)
        if let solved = luminance {
            let c = SIMD2(solved[count], solved[count + 1])
            // A lens darkens toward its corners, by less than two stops, and never brightens.
            let plausible = (1...10).allSatisfy { step -> Bool in
                let r2 = Double(step) / 10, value = c.x * r2 + c.y * r2 * r2
                return value <= 0.03 && value >= -2
            }
            if plausible, abs(c.x) + abs(c.y) > 0.02 { vignetting = c } else { luminance = nil }
        }
        if luminance == nil { luminance = fit({ $0.luminance }, falloff: false, prior: nil) }
        guard let base = luminance.map({ Array($0[0..<count]) }) else { return (unity, .zero) }
        let mean = base.reduce(0, +) / Double(count)
        let centred = base.map { $0 - mean }
        var stops = [SIMD3<Double>](repeating: .zero, count: count)
        for channel in 0..<3 {
            let solved = fit({ $0.ratio[channel] - vignetting.x * $0.r2 - vignetting.y * $0.r4 }, falloff: false, prior: centred) ?? centred
            for i in 0..<count { stops[i][channel] = solved[i] }
        }
        return ((0..<count).map { gain(luminanceStops: centred[$0], channelStops: stops[$0]) }, vignetting)
    }
    /// The most a frame's exposure is taken to differ from the set's mean, and the most one of its
    /// channels from its exposure (a white-balance difference), in stops. A solve that asks for
    /// more has gone wrong, and is held here rather than crush or blow the frame.
    static let exposureLimitStops = 4.0, channelLimitStops = 1.0
    /// A frame's linear gain per channel from its solved exposure and per-channel exposures, in
    /// stops. The exposure is held within `exposureLimitStops` of the set's mean; each channel
    /// keeps its own offset from the solved exposure (its white balance), held within
    /// `channelLimitStops`, on top of the held exposure.
    static func gain(luminanceStops: Double, channelStops: SIMD3<Double>) -> SIMD3<Float> {
        let solved = luminanceStops.isFinite ? luminanceStops : 0
        let exposure = max(-exposureLimitStops, min(exposureLimitStops, solved))
        var gain = SIMD3<Float>(repeating: 1)
        for channel in 0..<3 {
            var offset = channelStops[channel] - solved
            if offset.isNaN { offset = 0 }
            gain[channel] = Float(exp2(exposure + max(-channelLimitStops, min(channelLimitStops, offset))))
        }
        return gain
    }

    // MARK: Alignment

    /// Registers the frames against each other and solves where each camera pointed.
    /// `focalHint` is a focal length in pixels from the photos' metadata, tried along with the
    /// estimates from the registrations themselves.
    static func align(_ frames: [LWMergeFrame], focalHint: Double? = nil, compensateExposure: Bool = true) throws -> (alignment: LWPanoramaAlignment, works: [Work]) {
        guard frames.count >= 2 else { throw LWPanoramaError.tooFewFrames }
        guard frames.count <= maximumFrames else { throw LWPanoramaError.tooManyFrames }
        let width = frames[0].width, height = frames[0].height, count = frames.count
        if let odd = frames.firstIndex(where: { $0.width != width || $0.height != height }) { throw LWPanoramaError.sizeMismatch(frame: odd) }
        var works: [Work] = [], found: [Features] = []
        for (index, frame) in frames.enumerated() {
            let work = try reduce(frame), detected = try features(work)
            guard detected.count >= 12 else { throw LWPanoramaError.featureless(frame: index) }
            works.append(work); found.append(detected)
        }
        let centre = SIMD2(Double(width - 1) / 2, Double(height - 1) / 2), unit = Double(max(width, height))
        let tolerance = 3 * Double(works[0].factor)
        var registrations: [Registration] = [], weak: [Registration] = []
        for a in 0..<count {
            for b in (a + 1)..<count {
                let matched = try match(found[a], found[b])
                let registration = try register(first: a, second: b, from: matched.map { found[a].points[$0.0] - centre }, to: matched.map { found[b].points[$0.1] - centre }, unit: unit, tolerance: tolerance)
                if registration.accepted { registrations.append(registration) } else { weak.append(registration) }
            }
        }
        if let pair = registrations.first(where: \.ambiguous) { throw LWPanoramaError.ambiguous(frame: pair.first, other: pair.second) }
        // Every frame must be joined to the others, directly or through other frames.
        var group = Array(0..<count)
        func root(_ i: Int) -> Int { var i = i; while group[i] != i { i = group[i] }; return i }
        for r in registrations { let a = root(r.first), b = root(r.second); if a != b { group[max(a, b)] = min(a, b) } }
        var sizes = [Int: Int]()
        for i in 0..<count { sizes[root(i), default: 0] += 1 }
        let main = sizes.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        if let outside = (0..<count).first(where: { root($0) != main }) {
            // Which reason applies: two photos that agree on a few points, or whose facing edges
            // show the same strip of the scene, overlap, but too little.
            let attempts = weak.filter { ($0.first == outside && root($0.second) == main) || ($0.second == outside && root($0.first) == main) }
            if let near = attempts.max(by: { $0.inliers < $1.inliers }), near.inliers >= 8 {
                throw LWPanoramaError.insufficientOverlap(frame: near.first, other: near.second)
            }
            for other in 0..<count where root(other) == main {
                try Task.checkCancellation()
                if thinOverlap(works[outside], works[other]) { throw LWPanoramaError.insufficientOverlap(frame: min(outside, other), other: max(outside, other)) }
            }
            throw LWPanoramaError.unmatched(frame: outside)
        }
        // The reference is the best-connected frame.
        var strength = [Int](repeating: 0, count: count)
        for r in registrations { strength[r.first] += r.inliers; strength[r.second] += r.inliers }
        let reference = strength.indices.max { strength[$0] < strength[$1] }!
        // At most 300 matched points per pair take part in the global solve.
        let thinned = registrations.map { r -> Registration in
            guard r.inliers > 300 else { return r }
            let stride = Double(r.inliers) / 300
            var copy = r
            copy.from = (0..<300).map { r.from[Int(Double($0) * stride)] }; copy.to = (0..<300).map { r.to[Int(Double($0) * stride)] }
            return copy
        }
        var candidates: [Double] = []
        let estimates = registrations.compactMap { focal($0.homography) }.map { $0 * unit }.sorted()
        if !estimates.isEmpty { candidates.append(estimates[estimates.count / 2]) }
        if let focalHint, focalHint.isFinite, focalHint > 0 { candidates.append(focalHint) }
        candidates += [0.6, 1, 1.6, 2.6, 4.5].map { $0 * unit }
        var best: (rotations: [simd_double3x3], focal: Double, rms: Double)?
        for (index, candidate) in candidates.enumerated() {
            guard let start = initialRotations(count: count, reference: reference, registrations: registrations, focal: candidate, unit: unit) else { continue }
            let solved = try bundleAdjust(thinned, rotations: start, focal: candidate, reference: reference, huber: tolerance)
            guard solved.focal.isFinite, solved.focal > 0.1 * unit, solved.focal < 50 * unit else { continue }
            if best == nil || solved.rms < best!.rms { best = solved }
            // The registrations' own estimate fits: the other starting points are not needed.
            if index == 0, !estimates.isEmpty, solved.rms < 0.35 * tolerance { break }
        }
        guard let best else { throw LWPanoramaError.notOnePanorama(rmsPixels: .infinity) }
        guard best.rms <= 1.5 * tolerance else { throw LWPanoramaError.notOnePanorama(rmsPixels: best.rms) }
        var alignment = LWPanoramaAlignment(width: width, height: height, focal: best.focal,
            rotations: straighten(best.rotations, reference: reference, levelPitch: true),
            gains: [SIMD3<Float>](repeating: SIMD3(repeating: 1), count: count), vignetting: .zero,
            pairs: registrations.map { LWPanoramaPair(first: $0.first, second: $0.second, matches: $0.matches, inliers: $0.inliers, rival: $0.rival) },
            rms: best.rms, reference: reference)
        if compensateExposure {
            let exposure = try exposures(works, frames: frames, alignment: alignment)
            alignment.gains = exposure.gains; alignment.vignetting = exposure.vignetting
        }
        return (alignment, works)
    }
}
