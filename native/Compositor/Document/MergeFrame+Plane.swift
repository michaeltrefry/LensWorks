import Foundation

nonisolated extension LWMergeFrame {
    /// Bytes of developed float RGBA one strip read asks the plane for. A read charges the shared
    /// float working set (512 MiB) twice this plus two tiles, so strips stay far below it.
    static let stripBytes = 32 * 1024 * 1024
    /// Loads a developed plane in bounded row strips; the whole frame never passes through the
    /// float working set at once.
    @_optimize(speed) init(plane: LWFloatPlane, whiteLevel: SIMD3<Float>? = nil) throws {
        let width = plane.width, height = plane.height
        guard width > 0, height > 0 else { throw LWMergeFrameError.invalid }
        var samples = [Float16](repeating: 0, count: width * height * 3)
        let rows = max(1, min(height, Self.stripBytes / (width * MemoryLayout<SIMD4<Float>>.stride)))
        var y = 0
        while y < height {
            try Task.checkCancellation()
            let count = min(rows, height - y)
            let strip = try plane.read(LWFloatRange(x: 0, y: y, width: width, height: count)).surface.pixels
            guard strip.count == width * count else { throw LWMergeFrameError.invalid }
            let base = y * width * 3
            samples.withUnsafeMutableBufferPointer { target in
                var o = base
                for p in strip { target[o] = Self.pack(p.x); target[o + 1] = Self.pack(p.y); target[o + 2] = Self.pack(p.z); o += 3 }
            }
            y += count
        }
        try self.init(width: width, height: height, samples: samples, whiteLevel: whiteLevel)
    }
}
