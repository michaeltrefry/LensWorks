import Foundation
import CoreGraphics

/// A complete float image with an immutable range-backed provider. The provider
/// never hands Core Graphics a pointer to a whole-frame native array.
nonisolated final class LWFloatPlaneImage: @unchecked Sendable {
    enum Format { case rgba32, coverage8, rgba16SRGB, rgba8SRGB
        var pixelBytes: Int { switch self { case .rgba32: 16; case .coverage8: 1; case .rgba16SRGB: 8; case .rgba8SRGB: 4 } }
    }
    let plane: LWFloatPlane
    let format: Format
    private let consumerCancellation: LWFloatCancellation?
    private let lock = NSLock()
    private var failure: Error?
    init(plane: LWFloatPlane, format: Format = .rgba32, cancellation: LWFloatCancellation? = nil) {
        self.plane = plane; self.format = format; consumerCancellation = cancellation
    }

    func check() throws {
        try consumerCancellation?.check()
        try plane.checkCancellation()
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    func image() throws -> CGImage {
        try check()
        _ = try plane.globalExtent.validate(frameWidth: plane.width, frameHeight: plane.height)
        let bytes = plane.width * plane.height * format.pixelBytes
        let retained = Unmanaged.passRetained(self)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil,
            releaseBytePointer: nil, getBytesAtPosition: { info, output, position, count in
                guard let info else { return 0 }
                let owner = Unmanaged<LWFloatPlaneImage>.fromOpaque(info).takeUnretainedValue()
                do { return try owner.copy(into: output, position: position, count: count) }
                catch { owner.lock.withLock { if owner.failure == nil { owner.failure = error } }; return 0 }
            }, releaseInfo: { info in
                if let info { Unmanaged<LWFloatPlaneImage>.fromOpaque(info).release() }
            })
        guard let provider = CGDataProvider(info: retained.toOpaque(), size: off_t(bytes), callbacks: &callbacks) else {
            retained.release(); throw ProjectError.invalid
        }
        let bits: Int, space: CGColorSpace, info: CGBitmapInfo
        switch format {
        case .rgba32:
            guard let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw ProjectError.invalid }
            space = color; bits = 32
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .coverage8:
            space = CGColorSpaceCreateDeviceGray(); bits = 8; info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case .rgba16SRGB, .rgba8SRGB:
            guard let color = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProjectError.invalid }
            space = color; bits = format.pixelBytes == 8 ? 16 : 8
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        }
        guard let image = CGImage(width: plane.width, height: plane.height, bitsPerComponent: bits,
            bitsPerPixel: format.pixelBytes * 8, bytesPerRow: plane.width * format.pixelBytes, space: space,
            bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ProjectError.invalid }
        return image
    }

    /// Handles unaligned byte requests without a full-frame intermediate. Each
    /// borrowed tile and the small encoded pixel remain charged while in use.
    func copy(into output: UnsafeMutableRawPointer, position: off_t, count: Int) throws -> Int {
        try check()
        _ = try plane.globalExtent.validate(frameWidth: plane.width, frameHeight: plane.height)
        let extent = plane.width * plane.height * format.pixelBytes
        guard position >= 0, let start = Int(exactly: position), start <= extent, count >= 0 else { throw ProjectError.invalid }
        let length = min(count, extent - start)
        let scratch = try plane.workingSet.reserve(16)
        defer { withExtendedLifetime(scratch) {} }
        var copied = 0
        while copied < length {
            try check();try Task.checkCancellation()
            let absolute = start + copied
            let pixelIndex = absolute / format.pixelBytes
            let x = pixelIndex % plane.width, y = pixelIndex / plane.width
            let blockEnd = min(plane.width, ((x / LWFloatPlane.tileSide) + 1) * LWFloatPlane.tileSide)
            let tile = try plane.read(range: LWFloatRange(x: x, y: y, width: blockEnd - x, height: 1))
            let offset = absolute % format.pixelBytes
            switch format {
            case .rgba32:
                for (index, pixel) in tile.surface.pixels.enumerated() {
                    var value = SIMD4(pixel.x * pixel.w, pixel.y * pixel.w, pixel.z * pixel.w, pixel.w)
                    let skip = index == 0 ? offset : 0, taken = min(16 - skip, length - copied)
                    withUnsafeBytes(of: &value) { raw in
                        output.advanced(by: copied).copyMemory(from: raw.baseAddress!.advanced(by: skip), byteCount: taken)
                    }
                    copied += taken; if copied == length { break }
                }
            case .coverage8:
                for pixel in tile.surface.pixels {
                    var value = UInt8((max(0, min(1, pixel.x)) * 255).rounded())
                    withUnsafeBytes(of: &value) { output.advanced(by: copied).copyMemory(from: $0.baseAddress!, byteCount: 1) }
                    copied += 1; if copied == length { break }
                }
            case .rgba16SRGB, .rgba8SRGB:
                let bytes = tile.surface.byteLength, lease = try plane.workingSet.reserve(bytes * 4)
                let surface = try LWLinearSurface(width: tile.surface.width, height: 1, pixels: Array(tile.surface.pixels), maximumBytes: bytes * 3)
                guard let color = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProjectError.invalid }
                let image = try surface.integerOutput(bits: format.pixelBytes == 8 ? 16 : 8, colorSpace: color)
                guard image.bitsPerPixel == format.pixelBytes * 8, let raw = image.dataProvider?.data,
                    CFDataGetLength(raw) >= tile.surface.width * format.pixelBytes,
                    let input = CFDataGetBytePtr(raw) else { throw ProjectError.invalid }
                let taken = min(tile.surface.width * format.pixelBytes - offset, length - copied)
                output.advanced(by: copied).copyMemory(from: input.advanced(by: offset), byteCount: taken)
                copied += taken; withExtendedLifetime(lease) {}
            }
        }
        try check()
        return copied
    }
}

nonisolated extension ImportedImage {
    init(plane: LWFloatPlane, name: String) throws {
        let provider = LWFloatPlaneImage(plane: plane)
        let image = try provider.image()
        let scratch = try plane.workingSet.reserve(96 * 96 * 4 * 4)
        let thumbnail = try LWFloatThumbnail.owned(PixelAdjust.thumbnail(of: image), workingSet: plane.workingSet)
        try provider.check(); withExtendedLifetime(scratch) {}
        self.init(image: image, thumbnail: thumbnail, name: name, linearPlane: plane, planeImage: provider,
            planeArchiveReference: try LWFloatPlaneArchive.reference(plane))
    }
    init(maskPlane: LWFloatPlane, name: String) throws {
        let provider = LWFloatPlaneImage(plane: maskPlane, format: .coverage8), image = try provider.image()
        let scratch = try maskPlane.workingSet.reserve(96 * 96 * 4)
        let preview = try LayerMask.asset(from: image)
        let thumbnail = try LWFloatThumbnail.owned(preview.thumbnail, workingSet: maskPlane.workingSet)
        try provider.check(); withExtendedLifetime(scratch) {}
        self.init(image: image, thumbnail: thumbnail, name: name, linearPlane: maskPlane, planeImage: provider,
            planeArchiveReference: try LWFloatPlaneArchive.reference(maskPlane))
    }
    func validatePlaneRead() throws { try planeImage?.check() }
}
