import Foundation

/// One source photo of a merge (Merge to HDR…, Merge to Panorama…) developed by the editor's
/// source development into extended-linear sRGB, held as packed RGB half floats: 6 bytes per
/// pixel (alpha is ignored by a merge). Half floats keep 11 significant bits per stop over
/// ±65504, which is finer than a camera sample, at 3/8 of the memory of the developed float RGBA.
nonisolated struct LWMergeFrame: Sendable {
    static let bytesPerPixel = 6
    let width: Int
    let height: Int
    /// R, G, B per pixel, row-major.
    let samples: [Float16]
    /// Where a neutral subject first clips in this frame, per channel, as the decoder reports
    /// it from the sensor's white level and white balance (`RenderProvenance.neutral_clip`).
    /// Nil for a raster source, which has no sensor white level.
    let whiteLevel: SIMD3<Float>?
    /// The frame's pixels as float RGB with alpha 1.
    struct Pixels: RandomAccessCollection, Sendable {
        let samples: [Float16]
        var startIndex: Int { 0 }
        var endIndex: Int { samples.count / 3 }
        subscript(index: Int) -> SIMD4<Float> {
            SIMD4(Float(samples[index * 3]), Float(samples[index * 3 + 1]), Float(samples[index * 3 + 2]), 1)
        }
    }
    var pixels: Pixels { Pixels(samples: samples) }
    init(width: Int, height: Int, samples: [Float16], whiteLevel: SIMD3<Float>? = nil) throws {
        guard width > 0, height > 0, samples.count == width * height * 3 else { throw LWMergeFrameError.invalid }
        if let whiteLevel { guard whiteLevel.x.isFinite, whiteLevel.y.isFinite, whiteLevel.z.isFinite, whiteLevel.min() > 0 else { throw LWMergeFrameError.invalid } }
        self.width = width; self.height = height; self.samples = samples; self.whiteLevel = whiteLevel
    }
    init<C: Collection>(width: Int, height: Int, pixels: C, whiteLevel: SIMD3<Float>? = nil) throws where C.Element == SIMD4<Float> {
        guard width > 0, height > 0, pixels.count == width * height else { throw LWMergeFrameError.invalid }
        var samples = [Float16](); samples.reserveCapacity(pixels.count * 3)
        for p in pixels { samples.append(Self.pack(p.x)); samples.append(Self.pack(p.y)); samples.append(Self.pack(p.z)) }
        try self.init(width: width, height: height, samples: samples, whiteLevel: whiteLevel)
    }
    /// A finite sample is clamped into the half-float range; a non-finite one stays non-finite.
    @inline(__always) static func pack(_ value: Float) -> Float16 {
        let limit = Float(Float16.greatestFiniteMagnitude)
        return value.isFinite ? Float16(max(-limit, min(limit, value))) : Float16(value)
    }
    @inline(__always) func rgb(_ pixel: Int) -> SIMD3<Float> {
        SIMD3(Float(samples[pixel * 3]), Float(samples[pixel * 3 + 1]), Float(samples[pixel * 3 + 2]))
    }

    /// The level at or above which each channel is treated as clipped.
    ///
    /// For camera RAW it comes from the source: just below the level at which the decoder says
    /// a neutral subject's first sensor channel saturates. RAW development leaves highlights
    /// unclipped, so above that level a neutral highlight is colour-shifted (DNG) or synthesized
    /// (LibRaw highlight blending) while a saturated coloured subject can read far higher. The
    /// frame's own maximum says nothing about either, and the level need not be 1.0.
    ///
    /// A raster source carries no white level. Its fallback is an estimate from the frame: just
    /// below each channel's brightest sample, and never below 1.0, where raster data saturates.
    var clipLevel: SIMD3<Float> {
        if let white = whiteLevel { return 0.98 * white }
        var white = SIMD3<Float>(repeating: 1)
        samples.withUnsafeBufferPointer { samples in
            for p in stride(from: 0, to: samples.count, by: 3) {
                white = pointwiseMax(white, SIMD3(Float(samples[p]), Float(samples[p + 1]), Float(samples[p + 2])))
            }
        }
        return 0.98 * white
    }
}

nonisolated enum LWMergeFrameError: LocalizedError, Equatable {
    case invalid
    var errorDescription: String? { "A selected photo did not develop to a usable image." }
}

/// The working-memory budget of a merge: what its frames, working buffers and result may hold at
/// once. Each merge states its own bytes-per-pixel model and checks it before loading frames.
nonisolated enum LWMergeBudget {
    /// The budget on the product-minimum 16 GB Mac.
    static let minimumBytes = 6 * 1024 * 1024 * 1024
    /// 3/8 of physical memory, and never less than the 16 GB Mac's budget.
    static var bytes: Int { max(minimumBytes, Int(clamping: ProcessInfo.processInfo.physicalMemory / 8 * 3)) }
}
