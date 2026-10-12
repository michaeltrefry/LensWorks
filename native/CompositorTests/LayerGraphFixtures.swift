import Testing
import Foundation
import CoreGraphics
@testable import Compositor

/// Shared fixtures for the S10 layer-graph suites: small sRGB layers with soft alpha on whole-pixel
/// positions, so the retained Core Graphics compositor and the float compositor read the same samples.
enum LayerGraphFixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An 8-bit sRGB layer image. `pixel` returns straight encoded r, g, b, a in 0...255.
    static func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (Int, Int, Int, Int)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = pixel(x, y), i = (y * width + x) * 4
            bytes[i] = UInt8((p.0 * p.3 + 127) / 255); bytes[i + 1] = UInt8((p.1 * p.3 + 127) / 255)
            bytes[i + 2] = UInt8((p.2 * p.3 + 127) / 255); bytes[i + 3] = UInt8(p.3)
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Smooth colour with a different phase per `seed`; `alpha` nil gives soft coverage that reaches 0 and 255.
    static func pattern(_ width: Int, _ height: Int, seed: Int, alpha: Int? = nil) -> CGImage {
        image(width, height) { x, y in
            let r = (x * 9 + y * 4 + seed * 53) % 256, g = (x * 5 + y * 11 + seed * 97) % 256, b = (x * 3 + y * 7 + seed * 31) % 256
            let soft = min(255, max(0, ((x + seed) % 9) * 40 - 20 + ((y + seed * 2) % 5) * 12))
            return (r, g, b, alpha ?? soft)
        }
    }

    /// A grayscale mask. `level` returns coverage 0...255.
    static func mask(_ width: Int, _ height: Int, _ level: (Int, Int) -> Int) throws -> ImportedImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = UInt8(min(255, max(0, level(x, y)))) } }
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try LayerMask.asset(from: image)
    }
    static func ramp(_ width: Int, _ height: Int, seed: Int) throws -> ImportedImage {
        try mask(width, height) { x, y in ((x * 13 + y * 29 + seed * 71) % 300) - 20 }
    }

    static func asset(_ image: CGImage, _ name: String = "Fixture") -> ImportedImage { ImportedImage(image: image, thumbnail: image, name: name) }

    /// The same pixels as an extended-linear float plane layer, scaled by `gain` (above 1: HDR).
    static func floatAsset(_ image: CGImage, gain: Float = 1, workspace: LWFloatWorkspace, name: String = "Float") throws -> ImportedImage {
        let surface = try LWLinearSurface.read(image, maximumBytes: image.width * image.height * 16)
        let scaled = try LWLinearSurface(width: surface.width, height: surface.height,
            pixels: surface.pixels.map { SIMD4($0.x * gain, $0.y * gain, $0.z * gain, $0.w) }, maximumBytes: image.width * image.height * 16)
        return try ImportedImage(plane: LWFloatCompositor.from(scaled, workspace: workspace), name: name)
    }

    // MARK: Records

    static func raster(id: UUID = UUID(), _ name: String, _ image: CGImage, at origin: CGPoint = .zero, parent: UUID? = nil,
                       mode: LayerBlendMode = .normal, opacity: Double = 1, visible: Bool = true, clip: UUID? = nil) -> ProjectLayerRecord {
        var transform = LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height))
        transform.sampling = .nearest
        var record = ProjectLayerRecord(id: id, name: name, isVisible: visible, transform: transform, imageFile: id.uuidString + ".png")
        record.parentID = parent; record.blendMode = mode; record.opacity = opacity; record.maskSourceID = clip
        return record
    }
    static func folder(id: UUID = UUID(), _ name: String, width: Int, height: Int, parent: UUID? = nil, opacity: Double = 1,
                       visible: Bool = true) -> ProjectLayerRecord {
        var transform = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))
        transform.sampling = .nearest
        return ProjectLayerRecord(id: id, name: name, isVisible: visible, transform: transform, imageFile: nil, parentID: parent, isGroup: true, opacity: opacity)
    }

    // MARK: Rendering

    /// Straight extended-linear float samples of the whole document.
    static func float(_ snapshot: ProjectSnapshot, workingSet: LWFloatWorkingSet) throws -> [SIMD4<Float>] {
        let workspace = try LWFloatWorkspace(workingSet: workingSet)
        return try pixels(LWFloatCompositor.renderPlane(snapshot, workspace: workspace))
    }
    static func pixels(_ plane: LWFloatPlane) throws -> [SIMD4<Float>] {
        var pixels = [SIMD4<Float>](repeating: .zero, count: plane.width * plane.height)
        try plane.forEachTile { range in
            let tile = try plane.read(range: range)
            for (i, p) in tile.surface.pixels.enumerated() { pixels[(range.y + i / range.width) * plane.width + range.x + i % range.width] = p }
        }
        return pixels
    }
    /// The same document through the tile cache, one evaluation block at a time.
    static func tiled(_ snapshot: ProjectSnapshot, workingSet: LWFloatWorkingSet) throws -> [SIMD4<Float>] {
        let tiles = try LWDocumentTileRenderer(budgetBytes: 64 * 1024 * 1024, workingSet: workingSet)
        return try tiles.surface(LWFloatRange(x: 0, y: 0, width: snapshot.manifest.width, height: snapshot.manifest.height), plan: tiles.plan(snapshot)).pixels
    }
    static func encode(_ x: Float) -> Double {
        let v = Double(x), a = abs(v), y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -y : y
    }
    /// Straight float samples as premultiplied sRGB levels (0...255, unrounded).
    static func levels(_ pixels: [SIMD4<Float>]) -> [SIMD4<Double>] {
        pixels.map { p in
            let a = Double(p.w)
            return SIMD4(min(1, max(0, encode(p.x))) * a, min(1, max(0, encode(p.y))) * a, min(1, max(0, encode(p.z))) * a, a) * 255
        }
    }
    /// Premultiplied sRGB levels of an image drawn pixel for pixel.
    static func levels(_ image: CGImage) throws -> [SIMD4<Double>] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self), row = context.bytesPerRow
        return (0..<image.width * image.height).map { i in
            let o = (i / image.width) * row + (i % image.width) * 4
            return SIMD4(Double(bytes[o]), Double(bytes[o + 1]), Double(bytes[o + 2]), Double(bytes[o + 3]))
        }
    }
    /// The worst premultiplied level difference, and where.
    static func worst(_ a: [SIMD4<Double>], _ b: [SIMD4<Double>]) -> (error: Double, index: Int) {
        var worst = 0.0, at = 0
        for i in a.indices { let d = (a[i] - b[i]); let e = max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)); if e > worst { worst = e; at = i } }
        return (worst, at)
    }
    static func worstRelative(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
        zip(a, b).reduce(0.0) { worst, pair in
            (0..<4).reduce(worst) { max($0, Double(abs(pair.0[$1] - pair.1[$1])) / max(1, Double(abs(pair.1[$1])))) }
        }
    }
}
