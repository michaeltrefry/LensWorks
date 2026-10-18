import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum LensWorksPanoramaProjection: String, CaseIterable, Codable, Sendable {
    case spherical, cylindrical, perspective
}

nonisolated enum LensWorksPanoramaBoundary: String, CaseIterable, Codable, Sendable {
    case autoCrop, fillEdges
}

nonisolated struct LensWorksPanoramaSource: Codable, Sendable, Equatable {
    let photoID: String
    let variantID: String
    let originalPath: String
    let nativeOriginal: LWCatalogNativePath?

    init(photoID: String, variantID: String, originalPath: String, nativeOriginal: LWCatalogNativePath?) {
        self.photoID = photoID; self.variantID = variantID; self.originalPath = originalPath; self.nativeOriginal = nativeOriginal
    }

    init(_ asset: LensWorksCatalogAsset) {
        photoID = asset.photoID
        variantID = asset.key?.variant_id ?? "master"
        originalPath = asset.originalPath
        nativeOriginal = asset.nativeOriginal
    }
}

nonisolated struct LensWorksPanoramaAlignment: Sendable, Equatable {
    let horizontalOffset: Int
    let verticalOffset: Int
    let meanSeamError: Double
}

nonisolated struct LensWorksPanoramaResult: Sendable {
    let width: Int
    let height: Int
    let rgba: Data
    let alignments: [LensWorksPanoramaAlignment]

    func pngData() throws -> Data {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw LensWorksCatalogError.message("The panorama could not be encoded as PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LensWorksCatalogError.message("The panorama PNG could not be finalized.")
        }
        return data as Data
    }
}

/// A bounded, deterministic image stitcher. It matches adjacent frames using their overlapping RGB samples, places
/// them in one common projection coordinate space, and keeps the source pixels unmodified outside the new result.
nonisolated enum LensWorksPanoramaStitcher {
    static let declaredSeamErrorTolerance = 3.0
    private static let maximumPixels = 100_000_000

    /// Small RGBA8 mathematical reference. Production media uses LensWorksPanoramaLinear.
    static func stitch(_ rasters: [Raster], projection: LensWorksPanoramaProjection, boundary: LensWorksPanoramaBoundary) throws -> LensWorksPanoramaResult {
        guard rasters.count >= 2 else { throw LensWorksCatalogError.message("Select at least two overlapping photos to merge to a panorama.") }
        guard let first = rasters.first, rasters.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw LensWorksCatalogError.message("Panorama frames must have matching dimensions.")
        }
        guard first.width >= 17, first.height >= 16 else {
            throw LensWorksCatalogError.message("Panorama frames must be at least 17 × 16 pixels for feature matching.")
        }
        let geometry = try Geometry(rasters: rasters, projection: projection, boundary: boundary)
        var rgba = Data(count: geometry.width * geometry.height * 4)
        try rgba.withUnsafeMutableBytes { destination in
            let bytes = destination.bindMemory(to: UInt8.self)
            for y in 0..<geometry.height {
                try Task.checkCancellation()
                for x in 0..<geometry.width {
                    let sample = try geometry.sample(x: x, y: y) { index, sx, sy in
                        let raster = rasters[index], left = Int(floor(sx)), right = min(raster.width - 1, left + 1)
                        let top = Int(floor(sy)), bottom = min(raster.height - 1, top + 1)
                        let tx = Float(sx - Double(left)), ty = Float(sy - Double(top))
                        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
                            let p = raster.pixel(x, y); return SIMD4(Float(p.0), Float(p.1), Float(p.2), 255)
                        }
                        return (pixel(left, top) * (1 - tx) + pixel(right, top) * tx) * (1 - ty)
                            + (pixel(left, bottom) * (1 - tx) + pixel(right, bottom) * tx) * ty
                    }
                    let offset = (y * geometry.width + x) * 4
                    for channel in 0..<4 { bytes[offset + channel] = UInt8(clamping: Int(sample[channel].rounded())) }
                }
            }
        }
        return .init(width: geometry.width, height: geometry.height, rgba: rgba, alignments: geometry.alignments)
    }

    /// Inverse mapping samples each output pixel once. Pixel centres map to pixel centres; an
    /// identity transform is bit-exact, including the first/last column and non-overlap regions.
    struct Geometry {
        let frameWidth: Int, frameHeight: Int
        let positions: [(x: Int, y: Int)]
        let worldX: [Double]
        let minY: Int
        let yScale: [Double]
        let focalLength: Double
        let projectedHeight: Int
        let worldHeight: Int
        let projection: LensWorksPanoramaProjection
        let boundary: LensWorksPanoramaBoundary
        let bounds: (left: Int, right: Int, top: Int, bottom: Int)
        let alignments: [LensWorksPanoramaAlignment]
        var width: Int { bounds.right - bounds.left + 1 }
        var height: Int { bounds.bottom - bounds.top + 1 }
        @_optimize(speed) init(rasters: [Raster], projection: LensWorksPanoramaProjection, boundary: LensWorksPanoramaBoundary,
             fullWidth: Int? = nil, fullHeight: Int? = nil, matchingScale: Int = 1, knownAlignments: [LensWorksPanoramaAlignment]? = nil) throws {
            guard let first = rasters.first, rasters.count >= 2,
                  rasters.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { throw ProjectError.invalid }
            let frameWidth = fullWidth ?? first.width, frameHeight = fullHeight ?? first.height
            self.frameWidth = frameWidth; self.frameHeight = frameHeight
            var placed = [(x: 0, y: 0)], aligned: [LensWorksPanoramaAlignment] = []
            for index in 1..<rasters.count {
                let match: Match
                if let knownAlignments {
                    let a = knownAlignments[index - 1]; match = .init(dx: a.horizontalOffset, dy: a.verticalOffset, error: a.meanSeamError, comparisons: 0, ambiguous: false)
                } else { match = try LensWorksPanoramaStitcher.match(rasters[index - 1], rasters[index]) }
                guard match.error <= declaredSeamErrorTolerance else {
                    throw LensWorksCatalogError.message("The selected photos do not have a reliable overlapping seam (mean error \(String(format: "%.2f", match.error)); tolerance \(declaredSeamErrorTolerance)).")
                }
                let dx = match.dx * matchingScale, dy = match.dy * matchingScale, previous = placed[index - 1]
                placed.append((previous.x + dx, previous.y + dy))
                aligned.append(.init(horizontalOffset: dx, verticalOffset: dy, meanSeamError: match.error))
            }
            positions = placed; alignments = aligned
            let minX = placed.map(\.x).min()!, maxX = placed.map { $0.x + frameWidth }.max()!
            let minY = placed.map(\.y).min()!
            self.minY = minY
            let worldWidth = maxX - minX, worldHeight = placed.map { $0.y + frameHeight }.max()! - minY
            self.worldHeight = worldHeight; self.projection = projection; self.boundary = boundary
            let focalLength = Double(worldWidth) / 1.15
            self.focalLength = focalLength
            let projectedHeight = projection == .spherical ? max(1, Int(ceil(2 * focalLength * atan(Double(worldHeight) / (2 * focalLength))))) : worldHeight
            self.projectedHeight = projectedHeight
            guard worldWidth > 0, worldHeight > 0, worldWidth <= DocumentLimits.maxSide,
                  worldHeight <= DocumentLimits.maxSide, worldWidth <= maximumPixels / worldHeight else {
                throw LensWorksCatalogError.message("The panorama exceeds the supported pixel limit.")
            }
            let horizontalAngle = atan(Double(worldWidth) / (2 * focalLength))
            let worldX = (0..<worldWidth).map { x in
                if projection == .perspective { return Double(x + minX) }
                let angle = ((Double(x) + 0.5) / Double(worldWidth) * 2 - 1) * horizontalAngle
                return focalLength * tan(angle) + Double(worldWidth) / 2 - 0.5 + Double(minX)
            }
            let yScale = worldX.map { wx in
                let centered = wx - Double(minX) + 0.5 - Double(worldWidth) / 2
                return sqrt(1 + centered * centered / (focalLength * focalLength))
            }
            self.worldX = worldX; self.yScale = yScale
            if boundary == .autoCrop {
                bounds = try Self.largestCoveredRectangle(width: worldWidth, height: projectedHeight) { x, y in
                    let py = Double(y) + 0.5 - Double(projectedHeight) / 2
                    let wy = (projection == .perspective ? py : projection == .cylindrical ? py * yScale[x]
                        : focalLength * tan(py / focalLength) * yScale[x]) + Double(worldHeight) / 2 - 0.5 + Double(minY)
                    return placed.contains { worldX[x] >= Double($0.x) - 0.5 && worldX[x] < Double($0.x + frameWidth) - 0.5
                        && wy >= Double($0.y) - 0.5 && wy < Double($0.y + frameHeight) - 0.5 }
                }
            } else { bounds = (0, worldWidth - 1, 0, projectedHeight - 1) }
        }
        func sourcePoint(x: Int, y: Int) -> (x: Double, y: Double) {
            let column = x + bounds.left
            let py = Double(y + bounds.top) + 0.5 - Double(projectedHeight) / 2
            let wy = (projection == .perspective ? py : projection == .cylindrical ? py * yScale[column]
                : focalLength * tan(py / focalLength) * yScale[column]) + Double(worldHeight) / 2 - 0.5 + Double(minY)
            return (worldX[column], wy)
        }
        /// Exact source footprint of an output tile, including bilinear neighbours and edge fill.
        /// Y is monotone in output y; evaluating both row endpoints at every column covers its
        /// curved extrema without allocating a full-resolution coordinate or sample buffer.
        func sourceRange(for range: LWFloatRange, frame: Int) -> LWFloatRange {
            let position = positions[frame]
            var minX = frameWidth - 1, maxX = 0, minY = frameHeight - 1, maxY = 0
            for x in range.x..<(range.x + range.width) {
                for y in [range.y, range.y + range.height - 1] {
                    let point = sourcePoint(x: x, y: y)
                    let sx = max(0, min(Double(frameWidth - 1), point.x - Double(position.x)))
                    let sy = max(0, min(Double(frameHeight - 1), point.y - Double(position.y)))
                    minX = min(minX, Int(floor(sx))); maxX = max(maxX, Int(ceil(sx)))
                    minY = min(minY, Int(floor(sy))); maxY = max(maxY, Int(ceil(sy)))
                }
            }
            return .init(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        @_optimize(speed) func sample(x: Int, y: Int, read: (Int, Double, Double) throws -> SIMD4<Float>) throws -> SIMD4<Float> {
            let point = sourcePoint(x: x, y: y), wx = point.x, wy = point.y
            var sum = SIMD4<Float>.zero, count: Float = 0
            var nearest: (index: Int, x: Double, y: Double, distance: Double)?
            for (index, position) in positions.enumerated() {
                let sx = wx - Double(position.x), sy = wy - Double(position.y)
                let cx = max(0, min(Double(frameWidth - 1), sx)), cy = max(0, min(Double(frameHeight - 1), sy))
                let distance = abs(cx - sx) + abs(cy - sy)
                if nearest == nil || distance < nearest!.distance { nearest = (index, cx, cy, distance) }
                if sx >= -0.5, sx < Double(frameWidth) - 0.5, sy >= -0.5, sy < Double(frameHeight) - 0.5 {
                    sum += try read(index, cx, cy); count += 1
                }
            }
            if count > 0 { return sum / count }
            guard boundary == .fillEdges else { return .zero }
            guard let nearest else { throw ProjectError.invalid }
            return try read(nearest.index, nearest.x, nearest.y)
        }
        @_optimize(speed) private static func largestCoveredRectangle(width: Int, height: Int, covered: (Int, Int) -> Bool) throws -> (left: Int, right: Int, top: Int, bottom: Int) {
            var heights = Array(repeating: 0, count: width)
            var best = (area: 0, left: 0, right: 0, top: 0, bottom: 0)
            for y in 0..<height {
                try Task.checkCancellation()
                for x in 0..<width { heights[x] = covered(x, y) ? heights[x] + 1 : 0 }
                var stack: [Int] = []
                for x in 0...width {
                    let current = x == width ? 0 : heights[x]
                    while let bar = stack.last, heights[bar] > current {
                        stack.removeLast()
                        let left = stack.last.map { $0 + 1 } ?? 0, area = heights[bar] * (x - left)
                        if area > best.area { best = (area, left, x - 1, y - heights[bar] + 1, y) }
                    }
                    if x < width { stack.append(x) }
                }
            }
            guard best.area > 0 else { throw ProjectError.invalid }
            return (best.left, best.right, best.top, best.bottom)
        }
    }

    /// A coarse-to-fine translation beam. Coarse search is at most 96 pixels on the long
    /// edge, thirty-two candidates survive each level, and each score reads at most 2048 samples.
    /// Full-resolution work is linear to make the pyramid, never quadratic in photo width.
    struct Match: Sendable {
        let dx: Int, dy: Int
        let error: Double
        let comparisons: Int
        let ambiguous: Bool
    }
    @_optimize(speed) static func match(_ left: Raster, _ right: Raster, maximumVertical: Int? = nil, minimumOverlap overrideOverlap: Int? = nil) throws -> Match {
        var pyramid = [(left, right)], scale = 1
        while max(pyramid.last!.0.width, pyramid.last!.0.height) > 96 {
            try Task.checkCancellation()
            pyramid.append((try pyramid.last!.0.reduced(), try pyramid.last!.1.reduced())); scale *= 2
        }
        var beam: [(dx: Int, dy: Int, error: Double)] = [], comparisons = 0
        for level in pyramid.indices.reversed() {
            let (a, b) = pyramid[level]
            let minimumOverlap = min(a.width, max(1, (overrideOverlap ?? max(16, left.width / 6)) / scale))
            let maxDX = a.width - minimumOverlap, maxDY = max(1, Int(ceil(Double(min(maximumVertical ?? 32, left.height / 4)) / Double(scale))))
            var candidates = Set<Offset>()
            if beam.isEmpty {
                for dx in -maxDX...maxDX { for dy in -maxDY...maxDY { candidates.insert(.init(x: dx, y: dy)) } }
            } else {
                for item in beam { for x in -2...2 { for y in -2...2 {
                    let dx = item.dx * 2 + x, dy = item.dy * 2 + y
                    if abs(dx) <= maxDX, abs(dy) <= maxDY { candidates.insert(.init(x: dx, y: dy)) }
                } } }
            }
            var scored: [(dx: Int, dy: Int, error: Double)] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let dx = candidate.x, dy = candidate.y
                let xStart = max(0, dx), xEnd = min(a.width, b.width + dx)
                let yStart = max(0, dy), yEnd = min(a.height, b.height + dy)
                guard xStart < xEnd, yEnd - yStart >= max(1, a.height / 2) else { continue }
                let sx = max(1, Int(ceil(Double(xEnd - xStart) / 64))), sy = max(1, Int(ceil(Double(yEnd - yStart) / 32)))
                var total = 0, count = 0
                for y in stride(from: yStart, to: yEnd, by: sy) { for x in stride(from: xStart, to: xEnd, by: sx) {
                    let p = a.pixel(x, y), q = b.pixel(x - dx, y - dy)
                    total += abs(Int(p.0) - Int(q.0)) + abs(Int(p.1) - Int(q.1)) + abs(Int(p.2) - Int(q.2)); count += 3; comparisons += 1
                } }
                scored.append((dx, dy, Double(total) / Double(count)))
            }
            scored.sort { a, b in
                if a.error != b.error { return a.error < b.error }
                if abs(a.dx) + abs(a.dy) != abs(b.dx) + abs(b.dy) { return abs(a.dx) + abs(a.dy) < abs(b.dx) + abs(b.dy) }
                return a.dx == b.dx ? a.dy < b.dy : a.dx < b.dx
            }
            beam = Array(scored.prefix(32)); scale = max(1, scale / 2)
        }
        guard let best = beam.first else { throw ProjectError.invalid }
        return .init(dx: best.dx, dy: best.dy, error: best.error, comparisons: comparisons,
            ambiguous: beam.dropFirst().contains { $0.error == best.error })
    }
    private struct Offset: Hashable { let x: Int, y: Int }

    struct Raster: Sendable {
        let width: Int, height: Int, rgba: [UInt8]
        let lease: LWFloatWorkingSet.Lease?
        let sourceScale: Int
        private let workingSet: LWFloatWorkingSet?
        init(width: Int, height: Int, rgba: [UInt8], lease: LWFloatWorkingSet.Lease? = nil, sourceScale: Int = 1, workingSet: LWFloatWorkingSet? = nil) { self.width = width; self.height = height; self.rgba = rgba; self.lease = lease; self.sourceScale = sourceScale; self.workingSet = workingSet }
        /// A shared robust scene-linear contrast for one adjacent pair. Matching is not a
        /// display conversion: signed, super-white and low-contrast detail all contribute.
        struct MatchingRange: Sendable {
            let low: SIMD3<Double>, high: SIMD3<Double>
            /// Adjacent-pair contrast from a fixed 64 × 64 grid per source. Percentile bounds
            /// prevent an isolated hot pixel from erasing the pair's texture or acceptance score;
            /// unrelated sources never set this pair's scale. Samples and sorting stay bounded.
            @_optimize(speed) static func measure(_ planes: [LWFloatPlane]) throws -> Self {
                guard !planes.isEmpty, planes.count <= 2, let first = planes.first else { throw ProjectError.invalid }
                let lease = try first.workingSet.reserve(1024 * 1024)
                defer { withExtendedLifetime(lease) {} }
                var values = [[Double]](repeating: [], count: 3)
                for plane in planes {
                    let sx = max(1, (plane.width + 63) / 64), sy = max(1, (plane.height + 63) / 64)
                    for entry in plane.manifest.entries {
                        try Task.checkCancellation()
                        let firstX = (entry.range.x + sx - 1) / sx * sx, firstY = (entry.range.y + sy - 1) / sy * sy
                        guard firstX < entry.range.x + entry.range.width, firstY < entry.range.y + entry.range.height else { continue }
                        let tile = try plane.read(entry.range)
                        for y in stride(from: firstY, to: entry.range.y + entry.range.height, by: sy) {
                            for x in stride(from: firstX, to: entry.range.x + entry.range.width, by: sx) {
                                let pixel = tile.surface.pixels[(y - entry.range.y) * entry.range.width + x - entry.range.x]
                                guard pixel.w == 1 else { throw LensWorksCatalogError.message("Panorama source photos must be opaque.") }
                                for channel in 0..<3 {
                                    let value = Double(pixel[channel])
                                    guard value.isFinite else { throw ProjectError.invalid }
                                    values[channel].append(value)
                                }
                            }
                        }
                    }
                }
                var low = SIMD3<Double>.zero, high = SIMD3<Double>.zero
                for channel in 0..<3 {
                    let sorted = values[channel].sorted()
                    guard !sorted.isEmpty else { throw ProjectError.invalid }
                    low[channel] = sorted[(sorted.count - 1) / 100]
                    high[channel] = sorted[(sorted.count - 1) * 99 / 100]
                }
                return .init(low: low, high: high)
            }
            func descriptor(_ value: Double, channel: Int) -> UInt8 {
                let span = high[channel] - low[channel]
                guard span > 0 else { return 0 }
                return UInt8(clamping: Int((max(0, min(1, (value - low[channel]) / span)) * 255).rounded()))
            }
            func difference(_ a: Float, _ b: Float, channel: Int) -> Double {
                let span = high[channel] - low[channel]
                // A percentile-flat channel can still contain sparse detail. Unequal actual
                // samples must disagree even when the robust descriptor has no usable span.
                // Bound an isolated sensor outlier's contribution without ever turning a real
                // mismatch into zero or allowing it to rescale all the other samples.
                return span > 0 ? min(255, abs(Double(a) - Double(b)) / span * 255) : a == b ? 0 : 255
            }
        }
        @_optimize(speed) init(plane: LWFloatPlane, matchingRange supplied: MatchingRange? = nil) throws {
            let matchingRange = try supplied ?? MatchingRange.measure([plane])
            var scale = 1
            while (max(plane.width, plane.height) + scale - 1) / scale > 1536 { scale *= 2 }
            let width = (plane.width + scale - 1) / scale, height = (plane.height + scale - 1) / scale
            sourceScale = scale; self.width = width; self.height = height; workingSet = plane.workingSet
            lease = try plane.workingSet.reserve(width * height * 4)
            rgba = try plane.workingSet.withScratch(bytes: width * height * 32) {
                var sums = [SIMD4<Double>](repeating: .zero, count: width * height)
                for entry in plane.manifest.entries {
                    try Task.checkCancellation()
                    let tile = try plane.read(entry.range)
                    for y in 0..<entry.range.height { for x in 0..<entry.range.width {
                        let pixel = tile.surface.pixels[y * entry.range.width + x]
                        guard pixel.w == 1 else { throw LensWorksCatalogError.message("Panorama source photos must be opaque.") }
                        let index = ((y + entry.range.y) / scale) * width + (x + entry.range.x) / scale
                        sums[index] += SIMD4(Double(pixel.x), Double(pixel.y), Double(pixel.z), 1)
                    } }
                }
                var bytes = [UInt8](repeating: 255, count: width * height * 4)
                for index in sums.indices { for channel in 0..<3 {
                    bytes[index * 4 + channel] = matchingRange.descriptor(sums[index][channel] / sums[index].w, channel: channel)
                } }
                return bytes
            }
        }
        @_optimize(speed) func reduced() throws -> Raster {
            let w = max(1, width / 2), h = max(1, height / 2)
            let charge = try workingSet?.reserve(w * h * 4)
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                try Task.checkCancellation()
                for x in 0..<w { for c in 0..<3 {
                    var total = 0
                    for yy in 0..<2 { for xx in 0..<2 { total += Int(rgba[(min(height - 1, y * 2 + yy) * width + min(width - 1, x * 2 + xx)) * 4 + c]) } }
                    bytes[(y * w + x) * 4 + c] = UInt8(total / 4)
                } }
            }
            return .init(width: w, height: h, rgba: bytes, lease: charge, workingSet: workingSet)
        }
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let offset = (y * width + x) * 4; return (rgba[offset], rgba[offset + 1], rgba[offset + 2]) }
    }
}
