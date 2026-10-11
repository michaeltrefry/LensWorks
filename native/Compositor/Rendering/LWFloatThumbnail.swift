import Foundation
import CoreGraphics

/// The bounded display thumbnail owns its charge through the CGDataProvider,
/// including consumers that retain the CGImage after releasing its layer asset.
nonisolated enum LWFloatThumbnail {
    private final class Backing: @unchecked Sendable {
        let data: Data
        let lease: LWFloatWorkingSet.Lease
        init(data: Data, lease: LWFloatWorkingSet.Lease) { self.data = data; self.lease = lease }
    }
    static func owned(_ image: CGImage, workingSet: LWFloatWorkingSet) throws -> CGImage {
        guard (1...96).contains(image.width), (1...96).contains(image.height),
            image.bitsPerComponent == 8, image.bitsPerPixel <= 32,
            image.bytesPerRow >= image.width, image.bytesPerRow <= 96 * 4 + 64 else { throw ProjectError.invalid }
        let bytes = image.bytesPerRow * image.height
        let lease = try workingSet.reserve(bytes + 1024)
        guard let raw = image.dataProvider?.data, CFDataGetLength(raw) == bytes,
            let pointer = CFDataGetBytePtr(raw) else { throw ProjectError.invalid }
        let owner = Backing(data: Data(bytes: pointer, count: bytes), lease: lease)
        let retained = Unmanaged.passRetained(owner)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, output, position, count in
                guard let info, position >= 0, count >= 0, let start = Int(exactly: position) else { return 0 }
                let owner = Unmanaged<Backing>.fromOpaque(info).takeUnretainedValue()
                guard start <= owner.data.count else { return 0 }
                let copied = min(count, owner.data.count - start)
                owner.data.withUnsafeBytes { bytes in
                    if copied > 0 { output.copyMemory(from: bytes.baseAddress!.advanced(by: start), byteCount: copied) }
                }
                return copied
            }, releaseInfo: { info in if let info { Unmanaged<Backing>.fromOpaque(info).release() } })
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: off_t(bytes), callbacks: &callbacks) else {
            retained.release(); throw ProjectError.invalid
        }
        guard let result = CGImage(width: image.width, height: image.height,
            bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow, space: try requiredSpace(image), bitmapInfo: image.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else { throw ProjectError.invalid }
        return result
    }
    private static func requiredSpace(_ image: CGImage) throws -> CGColorSpace {
        guard let space = image.colorSpace else { throw ProjectError.invalid }; return space
    }
}
