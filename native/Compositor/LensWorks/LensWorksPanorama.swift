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

    static func stitch(_ urls: [URL], projection: LensWorksPanoramaProjection, boundary: LensWorksPanoramaBoundary) throws -> LensWorksPanoramaResult {
        try stitch(try urls.map(Raster.init(url:)), projection: projection, boundary: boundary)
    }

    static func stitch(_ rasters: [Raster], projection: LensWorksPanoramaProjection, boundary: LensWorksPanoramaBoundary) throws -> LensWorksPanoramaResult {
        guard rasters.count >= 2 else { throw LensWorksCatalogError.message("Select at least two overlapping photos to merge to a panorama.") }
        guard let first = rasters.first, rasters.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw LensWorksCatalogError.message("Panorama frames must have matching dimensions.")
        }
        guard first.width >= 17, first.height >= 16 else {
            throw LensWorksCatalogError.message("Panorama frames must be at least 17 × 16 pixels for feature matching.")
        }
        var positions = [(x: 0, y: 0)]
        var alignments: [LensWorksPanoramaAlignment] = []
        for index in 1..<rasters.count {
            let match = match(rasters[index - 1], rasters[index])
            guard match.error <= declaredSeamErrorTolerance else {
                throw LensWorksCatalogError.message("The selected photos do not have a reliable overlapping seam (mean error \(String(format: "%.2f", match.error)); tolerance \(declaredSeamErrorTolerance)).")
            }
            let previous = positions[index - 1]
            positions.append((previous.x + match.dx, previous.y + match.dy))
            alignments.append(.init(horizontalOffset: match.dx, verticalOffset: match.dy, meanSeamError: match.error))
        }
        let minX = positions.map(\.x).min()!, maxX = zip(positions, rasters).map { $0.0.x + $0.1.width }.max()!
        let minY = positions.map(\.y).min()!, maxY = zip(positions, rasters).map { $0.0.y + $0.1.height }.max()!
        let worldWidth = maxX - minX, worldHeight = maxY - minY
        // Projected coordinates are normalised, so rescale them to span the world's pixel width.
        let projected = (0...worldWidth).map { project(Double($0) / Double(max(1, worldWidth)), projection: projection) }
        let projectedLow = projected.first!, projectedSpan = max(1e-9, projected.last! - projectedLow)
        let mappedX = projected.map { ($0 - projectedLow) / projectedSpan * Double(worldWidth) }
        // Keep one unpainted projection column on each side. Auto Crop removes it; Fill Edges retains it and extends
        // the adjacent projected samples, which makes the chosen boundary policy explicit in the published rectangle.
        let mappedMinimum = mappedX.min()!
        let outputWidth = max(1, Int((mappedX.max()! - mappedMinimum).rounded()) + 3)
        guard outputWidth * worldHeight <= maximumPixels else { throw LensWorksCatalogError.message("The panorama exceeds the supported pixel limit.") }
        var sums = Array(repeating: (r: 0, g: 0, b: 0, count: 0), count: outputWidth * worldHeight)
        for (raster, position) in zip(rasters, positions) {
            for y in 0..<raster.height { for x in 0..<raster.width {
                let worldX = position.x + x - minX
                let outputX = Int((mappedX[worldX] - mappedMinimum).rounded()) + 1
                let nextOutputX = Int((mappedX[worldX + 1] - mappedMinimum).rounded()) + 1
                let outputY = position.y + y - minY
                guard (0..<worldHeight).contains(outputY) else { continue }
                let pixel = raster.pixel(x, y)
                for projectedX in min(outputX, nextOutputX)...max(outputX, nextOutputX) where (0..<outputWidth).contains(projectedX) {
                    let index = outputY * outputWidth + projectedX
                    sums[index].r += Int(pixel.0); sums[index].g += Int(pixel.1); sums[index].b += Int(pixel.2); sums[index].count += 1
                }
            } }
        }
        let bounds = boundary == .autoCrop ? largestCoveredRectangle(sums, width: outputWidth, height: worldHeight) : (left: 0, right: outputWidth - 1, top: 0, bottom: worldHeight - 1)
        let width = bounds.right - bounds.left + 1, height = bounds.bottom - bounds.top + 1
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { destination in
            let bytes = destination.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let point = sums[(bounds.top + y) * outputWidth + bounds.left + x]
                let sample = point.count > 0 ? point : boundary == .fillEdges ? nearestSample(sums, width: outputWidth, height: worldHeight, x: bounds.left + x, y: bounds.top + y) : point
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(sample.r / max(1, sample.count)); bytes[offset + 1] = UInt8(sample.g / max(1, sample.count))
                bytes[offset + 2] = UInt8(sample.b / max(1, sample.count)); bytes[offset + 3] = sample.count > 0 ? 255 : 0
            } }
        }
        return .init(width: width, height: height, rgba: rgba, alignments: alignments)
    }

    private static func project(_ x: Double, projection: LensWorksPanoramaProjection) -> Double {
        switch projection {
        case .perspective: x
        case .cylindrical: atan((x - 0.5) * 1.15) / atan(0.575) * 0.5 + 0.5
        case .spherical: asin(max(-1, min(1, (x - 0.5) * 1.0))) / .pi + 0.5
        }
    }

    private static func nearestSample(_ samples: [(r: Int, g: Int, b: Int, count: Int)], width: Int, height: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, count: Int) {
        for radius in 1...max(width, height) {
            for candidateX in [x - radius, x + radius] where (0..<width).contains(candidateX) {
                let sample = samples[y * width + candidateX]; if sample.count > 0 { return sample }
            }
        }
        return (0, 0, 0, 1)
    }

    private static func largestCoveredRectangle(_ samples: [(r: Int, g: Int, b: Int, count: Int)], width: Int, height: Int) -> (left: Int, right: Int, top: Int, bottom: Int) {
        var heights = Array(repeating: 0, count: width)
        var best = (area: 0, left: 0, right: 0, top: 0, bottom: 0)
        for y in 0..<height {
            for x in 0..<width { heights[x] = samples[y * width + x].count > 0 ? heights[x] + 1 : 0 }
            var stack: [Int] = []
            for x in 0...width {
                let current = x == width ? 0 : heights[x]
                while let bar = stack.last, heights[bar] > current {
                    stack.removeLast()
                    let left = (stack.last.map { $0 + 1 }) ?? 0, rectangleWidth = x - left
                    let area = heights[bar] * rectangleWidth
                    if area > best.area {
                        best = (area, left, x - 1, y - heights[bar] + 1, y)
                    }
                }
                stack.append(x)
            }
        }
        return (best.left, best.right, best.top, best.bottom)
    }

    private static func match(_ left: Raster, _ right: Raster) -> (dx: Int, dy: Int, error: Double) {
        var best = (dx: 0, dy: 0, error: Double.infinity)
        let minimumOverlap = max(16, left.width / 6), maximumVertical = min(32, left.height / 4)
        let minimumVerticalOverlap = max(1, left.height / 2)
        for dx in -(right.width - minimumOverlap)...(left.width - minimumOverlap) { for dy in -maximumVertical...maximumVertical {
            let xStart = max(0, dx), xEnd = min(left.width, right.width + dx)
            let yStart = max(0, dy), yEnd = min(left.height, right.height + dy)
            guard xEnd - xStart >= minimumOverlap, yEnd - yStart >= minimumVerticalOverlap else { continue }
            var total = 0, count = 0
            for y in stride(from: yStart, to: yEnd, by: 2) { for x in stride(from: xStart, to: xEnd, by: 2) {
                let a = left.pixel(x, y), b = right.pixel(x - dx, y - dy)
                total += abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2)); count += 3
            } }
            let error = Double(total) / Double(max(1, count))
            if error < best.error { best = (dx, dy, error) }
        } }
        return best
    }

    struct Raster: Sendable {
        let width: Int, height: Int, rgba: [UInt8]
        init(url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LensWorksCatalogError.message("\(url.lastPathComponent) could not be decoded for panorama matching.")
            }
            try self.init(image: image)
        }
        init(image: CGImage) throws {
            width = image.width; height = image.height
            guard width > 0, height > 0, width * height <= LensWorksPanoramaStitcher.maximumPixels else { throw LensWorksCatalogError.message("A panorama frame exceeds the supported pixel limit.") }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LensWorksCatalogError.message("A panorama frame could not be converted to RGB.")
            }
            context.interpolationQuality = .none; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); rgba = bytes
        }
        init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let offset = (y * width + x) * 4; return (rgba[offset], rgba[offset + 1], rgba[offset + 2]) }
    }
}
