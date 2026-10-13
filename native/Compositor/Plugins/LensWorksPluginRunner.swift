import CoreGraphics
import Foundation

/// One instantiated plugin inside the WebAssembly sandbox (adapters/plugins). It can call nothing but the filter
/// interface's `param`, and every resource it uses is bounded by `limits`; a failure of any kind is thrown with the
/// runtime's own words and leaves the caller's pixels as they were.
nonisolated final class LensWorksPluginSandbox {
    /// Every bound a plugin runs under: the runtime's one definition.
    static let limits: LWPluginLimits = { var limits = LWPluginLimits(); lw_plugin_limits(&limits); return limits }()
    static let messageBytes = 512

    private let instance: UnsafeMutableRawPointer

    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> Bool) throws {
        var message = [CChar](repeating: 0, count: messageBytes)
        let succeeded = message.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
        guard succeeded else { throw LensWorksPluginFailure(String(cString: message)) }
    }

    /// Checks a module against the filter interface without running it: size, well-formedness, imports, exports.
    static func validate(_ wasm: Data) throws {
        try call { message, capacity in
            wasm.withUnsafeBytes { lw_plugin_validate($0.bindMemory(to: UInt8.self).baseAddress, wasm.count, message, capacity) == 0 }
        }
    }

    /// Validates `wasm` again and instantiates it. `parameters` answer the plugin's `param(index)` calls.
    init(wasm: Data, parameters: [Double]) throws {
        var opened: UnsafeMutableRawPointer?
        try Self.call { message, capacity in
            opened = wasm.withUnsafeBytes { bytes in
                parameters.withUnsafeBufferPointer { values in
                    lw_plugin_open(bytes.bindMemory(to: UInt8.self).baseAddress, wasm.count, values.baseAddress, values.count, message, capacity)
                }
            }
            return opened != nil
        }
        instance = opened!
    }
    deinit { lw_plugin_close(instance) }

    /// Filters one tile in place: `width × height` RGBA float32 pixels, straight alpha, linear light, whose
    /// top-left pixel is (`x`, `y`) of a `frameWidth × frameHeight` layer.
    func filter(_ pixels: inout [Float], width: Int, height: Int, x: Int, y: Int, frameWidth: Int, frameHeight: Int) throws {
        guard let width = UInt32(exactly: width), let height = UInt32(exactly: height), let x = UInt32(exactly: x), let y = UInt32(exactly: y),
              let frameWidth = UInt32(exactly: frameWidth), let frameHeight = UInt32(exactly: frameHeight) else {
            throw LensWorksPluginFailure("The tile does not lie inside its layer.")
        }
        try Self.call { message, capacity in
            pixels.withUnsafeMutableBufferPointer { buffer in
                lw_plugin_filter_tile(instance, buffer.baseAddress, buffer.count, width, height, x, y, frameWidth, frameHeight, message, capacity) == 0
            }
        }
    }
}

/// Runs a plugin over one layer's pixels, a tile at a time, off the main actor. The plugin sees only the tile it is
/// handed: the layer it was given, never another layer or document. The layer's own storage decides the path — a
/// float plane is read and written tile by tile and stays a float plane; an 8-bit layer is converted to linear
/// float one tile at a time and stays 8-bit — so the float copy in memory is never more than one tile.
nonisolated enum LensWorksPluginRunner {
    struct Job: @unchecked Sendable {
        let wasm: Data
        let parameters: [Double]
        let asset: ImportedImage
        let selection: SelectionClip?
        /// Maps the layer's top-left pixel grid to document pixels, for the selection.
        let pixelToDocument: CGAffineTransform
        let name: String
        let cancellation: LWFloatCancellation
        /// The side of the square tiles an 8-bit layer is cut into (a float plane uses its own stored tiles).
        var tileSide = LWFloatPlane.tileSide
        var progress: @Sendable (Double) -> Void = { _ in }
    }

    static func run(_ job: Job) throws -> ImportedImage {
        guard job.tileSide > 0, job.tileSide * job.tileSide <= Int(LensWorksPluginSandbox.limits.tile_pixels) else { throw ProjectError.invalid }
        let sandbox = try LensWorksPluginSandbox(wasm: job.wasm, parameters: job.parameters)
        if job.asset.linearPlane != nil || job.asset.linear != nil { return try runPlane(job, sandbox) }
        return try runBitmap(job, sandbox)
    }

    private static func check(_ job: Job) throws {
        try job.cancellation.check(); try Task.checkCancellation()
    }

    /// Selection coverage on the layer's pixel grid: one byte a pixel, rows top-down.
    private final class Coverage {
        private let context: CGContext
        private let data: UnsafeMutableRawPointer
        private let rowBytes: Int
        init(_ selection: SelectionClip, width: Int, height: Int, pixelToDocument: CGAffineTransform) throws {
            context = try PixelAdjust.bitmap(width: width, height: height, mask: true)
            context.draw(try PixelAdjust.coverage(selection, width: width, height: height, pixelToDocument: pixelToDocument), in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { throw ExportError.render }
            self.data = data; rowBytes = context.bytesPerRow
        }
        func amount(x: Int, y: Int) -> UInt8 { data.load(fromByteOffset: y * rowBytes + x, as: UInt8.self) }
    }
    private static func coverage(_ job: Job, width: Int, height: Int) throws -> Coverage? {
        try job.selection.map { try Coverage($0, width: width, height: height, pixelToDocument: job.pixelToDocument) }
    }

    /// Lays the plugin's result over the original through the selection. Pixels wholly outside it keep their
    /// original values exactly; soft edges blend with alpha taken into account.
    private static func blend(_ made: inout [Float], over original: [Float], coverage: Coverage?, range: LWFloatRange) {
        guard let coverage else { return }
        for row in 0..<range.height { for column in 0..<range.width {
            let amount = coverage.amount(x: range.x + column, y: range.y + row), at = (row * range.width + column) * 4
            if amount == 255 { continue }
            let old = SIMD4(original[at], original[at + 1], original[at + 2], original[at + 3])
            let mixed = amount == 0 ? old : LWFloatFilter.interpolate(old, SIMD4(made[at], made[at + 1], made[at + 2], made[at + 3]), coverage: Float(amount) / 255)
            made[at] = mixed.x; made[at + 1] = mixed.y; made[at + 2] = mixed.z; made[at + 3] = mixed.w
        } }
    }

    // MARK: Float planes

    private static func runPlane(_ job: Job, _ sandbox: LensWorksPluginSandbox) throws -> ImportedImage {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let registration = job.cancellation.register { workspace.cancellation.cancel() }
        defer { withExtendedLifetime(registration) {} }
        let plane: LWFloatPlane
        if let stored = job.asset.linearPlane { plane = stored }
        else if let surface = job.asset.linear { plane = try LWFloatCompositor.from(surface, workspace: workspace) }
        else { throw ProjectError.invalid }
        let width = plane.width, height = plane.height
        let coverage = try coverage(job, width: width, height: height)
        let builder = try workspace.makeBuilder(width: width, height: height)
        let total = Double(((width + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide) * ((height + LWFloatPlane.tileSide - 1) / LWFloatPlane.tileSide))
        var done = 0.0
        while let range = builder.nextRange {
            try check(job); try workspace.cancellation.check()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            // The tile as read, the copy the plugin works on, and the surface handed to the builder.
            let lease = try workspace.workingSet.reserve(bytes * 3)
            let tile = try plane.read(range: range)
            var original = [Float](repeating: 0, count: range.width * range.height * 4)
            var index = 0
            for pixel in tile.surface.pixels { original[index] = pixel.x; original[index + 1] = pixel.y; original[index + 2] = pixel.z; original[index + 3] = pixel.w; index += 4 }
            var made = original
            try sandbox.filter(&made, width: range.width, height: range.height, x: range.x, y: range.y, frameWidth: width, frameHeight: height)
            blend(&made, over: original, coverage: coverage, range: range)
            var pixels = [SIMD4<Float>](repeating: .zero, count: range.width * range.height)
            for position in pixels.indices { pixels[position] = SIMD4(made[position * 4], made[position * 4 + 1], made[position * 4 + 2], made[position * 4 + 3]) }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
            done += 1; job.progress(done / total)
        }
        try check(job)
        return try ImportedImage(plane: builder.finish(), name: job.name)
    }

    // MARK: 8-bit layers

    /// sRGB byte to linear light.
    private static let linear: [Float] = (0...255).map { Float(FloatImageAdjustmentPixels.decode(Double($0) / 255)) }

    private static func runBitmap(_ job: Job, _ sandbox: LensWorksPluginSandbox) throws -> ImportedImage {
        let image = job.asset.image, width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let source = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let target = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        guard let from = source.data, let to = target.data else { throw ExportError.render }
        let rowBytes = source.bytesPerRow
        guard target.bytesPerRow == rowBytes else { throw ExportError.render }
        to.copyMemory(from: from, byteCount: rowBytes * height)
        let coverage = try coverage(job, width: width, height: height)
        let side = job.tileSide
        let total = Double(((width + side - 1) / side) * ((height + side - 1) / side))
        var done = 0.0
        for top in stride(from: 0, to: height, by: side) { for left in stride(from: 0, to: width, by: side) {
            try check(job)
            let range = LWFloatRange(x: left, y: top, width: min(side, width - left), height: min(side, height - top))
            var original = [Float](repeating: 0, count: range.width * range.height * 4)
            for row in 0..<range.height { for column in 0..<range.width {
                let pixel = from + (top + row) * rowBytes + (left + column) * 4, at = (row * range.width + column) * 4
                let alpha = pixel.load(fromByteOffset: 3, as: UInt8.self)
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    let byte = pixel.load(fromByteOffset: channel, as: UInt8.self)
                    // Premultiplied bytes back to straight color, then to linear light.
                    original[at + channel] = alpha == 255 ? linear[Int(byte)]
                        : Float(FloatImageAdjustmentPixels.decode(min(1, Double(byte) / Double(alpha))))
                }
                original[at + 3] = Float(alpha) / 255
            } }
            var made = original
            try sandbox.filter(&made, width: range.width, height: range.height, x: left, y: top, frameWidth: width, frameHeight: height)
            blend(&made, over: original, coverage: coverage, range: range)
            for row in 0..<range.height { for column in 0..<range.width {
                let at = (row * range.width + column) * 4
                // A pixel the plugin left alone keeps its bytes exactly.
                if made[at] == original[at], made[at + 1] == original[at + 1], made[at + 2] == original[at + 2], made[at + 3] == original[at + 3] { continue }
                let pixel = to + (top + row) * rowBytes + (left + column) * 4
                let alpha = Double(min(1, max(0, made[at + 3])))
                for channel in 0..<3 {
                    // An 8-bit layer holds display-range color: values outside 0–1 are clipped here.
                    let encoded = FloatImageAdjustmentPixels.encode(FloatImageAdjustmentPixels.unit(Double(made[at + channel])))
                    pixel.storeBytes(of: UInt8((encoded * alpha * 255).rounded()), toByteOffset: channel, as: UInt8.self)
                }
                pixel.storeBytes(of: UInt8((alpha * 255).rounded()), toByteOffset: 3, as: UInt8.self)
            } }
            done += 1; job.progress(done / total)
        } }
        try check(job)
        guard let result = target.makeImage() else { throw ExportError.render }
        return ImportedImage(image: result, thumbnail: try PixelAdjust.thumbnail(of: result), name: job.name)
    }
}
