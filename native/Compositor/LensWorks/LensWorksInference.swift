import CoreGraphics
import Darwin
import Foundation

// Typed Swift boundary over the LensWorks-owned inference adapter
// (adapters/inference, ABI in LensWorksInference.h). The adapter dylib is loaded at runtime
// so the app build does not link the MLX runtime; build-native.sh embeds it in
// Contents/Helpers and mlx.metallib in Contents/Resources (sealed by the app signature).
// Inference runs on the adapter's own executor thread; callbacks arrive there and are
// forwarded into an AsyncStream. The calls that block (input copies, the capability
// enumeration, the self-test) are async and run off the caller's thread, so a UI caller
// never blocks.

nonisolated enum LWInferenceError: Error, Equatable, CustomStringConvertible {
    case libraryUnavailable(String)
    case abiMismatch(expected: UInt32, found: UInt32)
    case rejected(kind: String, message: String)
    case protocolViolation(String)

    var description: String {
        switch self {
        case .libraryUnavailable(let m): "Inference runtime unavailable: \(m)"
        case .abiMismatch(let e, let f): "Inference ABI \(f) does not match the expected \(e)"
        case .rejected(let kind, let message): "Inference request rejected (\(kind)): \(message)"
        case .protocolViolation(let m): "Inference protocol violation: \(m)"
        }
    }
}

// MARK: - Pixel buffers

/// 8-bit sRGB pixels crossing the inference boundary. Outputs are tightly packed with straight
/// alpha; inputs may be premultiplied (the adapter converts them to straight alpha).
nonisolated struct LWInferenceImage: Sendable, Equatable {
    enum Alpha: UInt32, Sendable { case none = 0, straight = 1, premultiplied = 2 }

    let width: Int
    let height: Int
    let channels: Int
    let rowBytes: Int
    let alpha: Alpha
    let pixels: Data

    init(width: Int, height: Int, channels: Int, rowBytes: Int? = nil, alpha: Alpha, pixels: Data) throws {
        let rowBytes = rowBytes ?? width * channels
        guard width > 0, height > 0, [1, 3, 4].contains(channels), rowBytes >= width * channels,
              pixels.count >= rowBytes * (height - 1) + width * channels,
              (channels == 4) == (alpha != .none) else {
            throw LWInferenceError.protocolViolation("Invalid \(width)x\(height) \(channels)-channel buffer layout.")
        }
        self.width = width; self.height = height; self.channels = channels
        self.rowBytes = rowBytes; self.alpha = alpha; self.pixels = pixels
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Colour-manages any CGImage into sRGB RGBA8 (premultiplied, as Core Graphics renders).
    init(cgImage: CGImage) throws {
        let width = cgImage.width, height = cgImage.height
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Self.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LWInferenceError.protocolViolation("Could not render the image into sRGB.") }
        try self.init(width: width, height: height, channels: 4, alpha: .premultiplied, pixels: data)
    }

    /// Single-channel mask (0 = outside, 255 = inside) or gray image.
    static func mask(width: Int, height: Int, values: Data) throws -> LWInferenceImage {
        try LWInferenceImage(width: width, height: height, channels: 1, alpha: .none, pixels: values)
    }

    /// Tightly packed copy with straight alpha.
    func straightened() -> LWInferenceImage {
        var out = packed()
        guard alpha == .premultiplied else { return out }
        out.withMutablePixels { p in
            for i in stride(from: 0, to: p.count, by: 4) {
                let a = UInt32(p[i + 3])
                if a == 0 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 }
                else if a < 255 { for c in 0..<3 { p[i + c] = UInt8(min(255, (UInt32(p[i + c]) * 255 + a / 2) / a)) } }
            }
        }
        return out.with(alpha: .straight)
    }

    /// Tightly packed copy with premultiplied alpha (what Core Graphics and Metal layers use).
    func premultiplied() -> LWInferenceImage {
        var out = packed()
        guard alpha == .straight else { return out }
        out.withMutablePixels { p in
            for i in stride(from: 0, to: p.count, by: 4) {
                let a = UInt32(p[i + 3])
                if a < 255 { for c in 0..<3 { p[i + c] = UInt8((UInt32(p[i + c]) * a + 127) / 255) } }
            }
        }
        return out.with(alpha: .premultiplied)
    }

    /// An sRGB-tagged CGImage. Straight alpha is declared as non-premultiplied (`.last`).
    func cgImage() -> CGImage? {
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : Self.sRGB
        let info: CGImageAlphaInfo = switch (channels, alpha) {
        case (4, .straight): .last
        case (4, _): .premultipliedLast
        default: .none
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: rowBytes,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func packed() -> LWInferenceImage {
        let packedRow = width * channels
        if rowBytes == packedRow { return self }
        var data = Data(capacity: packedRow * height)
        pixels.withUnsafeBytes { raw in
            for row in 0..<height { data.append(contentsOf: raw[(row * rowBytes)..<(row * rowBytes + packedRow)]) }
        }
        return try! LWInferenceImage(width: width, height: height, channels: channels, alpha: alpha, pixels: data)
    }

    private func with(alpha: Alpha) -> LWInferenceImage {
        try! LWInferenceImage(width: width, height: height, channels: channels, rowBytes: rowBytes, alpha: alpha, pixels: pixels)
    }

    /// Mutates the (already packed, uniquely owned) pixel buffer in place.
    private mutating func withMutablePixels(_ body: (UnsafeMutableBufferPointer<UInt8>) -> Void) {
        var data = pixels
        data.withUnsafeMutableBytes { body($0.bindMemory(to: UInt8.self)) } // one copy-on-write
        self = try! LWInferenceImage(width: width, height: height, channels: channels, rowBytes: rowBytes, alpha: alpha, pixels: data)
    }
}

// MARK: - Requests

nonisolated enum LWInferenceWeights: Encodable, Sendable, Equatable {
    case dir(URL), file(URL)
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .dir(let url): try c.encode(url.path, forKey: .dir)
        case .file(let url): try c.encode(url.path, forKey: .file)
        }
    }
    private enum Key: String, CodingKey { case dir, file }
}

nonisolated struct LWInferenceLoadOptions: Encodable, Sendable, Equatable {
    enum Quantize: String, Encodable, Sendable { case q4, q8 }
    enum Residency: String, Encodable, Sendable { case unloadAfter = "unload_after", keepLoaded = "keep_loaded" }
    var quantize: Quantize? = nil
    var residency: Residency = .unloadAfter
}

nonisolated enum LWInferenceConditioning: Encodable, Sendable, Equatable {
    enum ControlKind: String, Sendable { case pose, canny, depth, other }
    case reference(input: Int, strength: Float? = nil)
    case referenceRGBA(input: Int, strength: Float? = nil)
    case multiReference(inputs: [Int])
    case reduxRefs(inputs: [Int], weights: [Float])
    case control(input: Int, kind: ControlKind, other: String? = nil, scale: Float? = nil)
    case depth(input: Int)
    case mask(input: Int)

    private enum Key: String, CodingKey { case kind, input, inputs, strength, weights, control, other, scale }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .reference(let i, let s): try c.encode("reference", forKey: .kind); try c.encode(i, forKey: .input); try c.encodeIfPresent(s, forKey: .strength)
        case .referenceRGBA(let i, let s): try c.encode("reference_rgba", forKey: .kind); try c.encode(i, forKey: .input); try c.encodeIfPresent(s, forKey: .strength)
        case .multiReference(let i): try c.encode("multi_reference", forKey: .kind); try c.encode(i, forKey: .inputs)
        case .reduxRefs(let i, let w): try c.encode("redux_refs", forKey: .kind); try c.encode(i, forKey: .inputs); try c.encode(w, forKey: .weights)
        case .control(let i, let k, let o, let s):
            try c.encode("control", forKey: .kind); try c.encode(i, forKey: .input); try c.encode(k.rawValue, forKey: .control)
            try c.encodeIfPresent(o, forKey: .other); try c.encodeIfPresent(s, forKey: .scale)
        case .depth(let i): try c.encode("depth", forKey: .kind); try c.encode(i, forKey: .input)
        case .mask(let i): try c.encode("mask", forKey: .kind); try c.encode(i, forKey: .input)
        }
    }
}

nonisolated struct LWGenerateParams: Encodable, Sendable, Equatable {
    var prompt: String
    var width: Int
    var height: Int
    var negativePrompt: String? = nil
    var count: Int? = nil
    var seed: UInt64? = nil
    var steps: Int? = nil
    var guidance: Float? = nil
    var trueCfg: Float? = nil
    var sampler: String? = nil
    var scheduler: String? = nil
    var guidanceMethod: String? = nil
    var strength: Float? = nil
    var controlScale: Float? = nil
    var alphaOutput: Bool = false
    var conditioning: [LWInferenceConditioning] = []
}

nonisolated struct LWTransformParams: Encodable, Sendable, Equatable {
    enum Target: Encodable, Sendable, Equatable {
        case scale(Float), minEdge(Int), resolution(width: Int, height: Int)
        private enum Key: String, CodingKey { case mode, factor, edge, width, height }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case .scale(let f): try c.encode("scale", forKey: .mode); try c.encode(f, forKey: .factor)
            case .minEdge(let e): try c.encode("min_edge", forKey: .mode); try c.encode(e, forKey: .edge)
            case .resolution(let w, let h): try c.encode("resolution", forKey: .mode); try c.encode(w, forKey: .width); try c.encode(h, forKey: .height)
            }
        }
    }
    var input: Int
    var target: Target
    var seed: UInt64? = nil
    var strength: Float? = nil
    var steps: Int? = nil
}

nonisolated struct LWCaptionParams: Encodable, Sendable, Equatable {
    var input: Int
    var captionType: String? = nil
    var captionLength: String? = nil
    var extraOptions: [String] = []
    var nameInput: String? = nil
    var customPrompt: String? = nil
    var lowVram: Bool = false
    var temperature: Float? = nil
    var topP: Float? = nil
    var maxNewTokens: Int? = nil
    var seed: UInt64? = nil
    var repetitionPenalty: Float? = nil
}

nonisolated struct LWEmbedImageParams: Encodable, Sendable, Equatable { var inputs: [Int] }
nonisolated struct LWEmbedTextParams: Encodable, Sendable, Equatable { var texts: [String] }

nonisolated struct LWSam2BoxParams: Encodable, Sendable, Equatable {
    enum ModelSize: String, Encodable, Sendable { case tiny, small, basePlus = "base_plus", large }
    var input: Int
    var boxXyxy: [Float]
    var modelSize: ModelSize
}

nonisolated struct LWSam3ConceptParams: Encodable, Sendable, Equatable {
    var input: Int
    var concept: String
    var threshold: Float? = nil
    var maskThreshold: Float? = nil
}

nonisolated struct LWSam3BoxParams: Encodable, Sendable, Equatable {
    var input: Int
    var boxXyxy: [Float]
    var concept: String? = nil
    var threshold: Float? = nil
    var maskThreshold: Float? = nil
}

nonisolated struct LWInferenceRequest: Sendable {
    let json: Data

    private struct Envelope<P: Encodable>: Encodable {
        let version = 1
        let task: String
        let provider: String
        let weights: LWInferenceWeights
        let tokenizer: String?
        let load: LWInferenceLoadOptions
        let params: P
    }

    private static func make<P: Encodable>(_ task: String, _ provider: String, _ weights: LWInferenceWeights, _ load: LWInferenceLoadOptions,
                                           tokenizer: URL? = nil, _ params: P) -> LWInferenceRequest {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let envelope = Envelope(task: task, provider: provider, weights: weights, tokenizer: tokenizer?.path, load: load, params: params)
        return LWInferenceRequest(json: try! encoder.encode(envelope))
    }

    static func generate(provider: String, weights: LWInferenceWeights, load: LWInferenceLoadOptions = .init(), _ p: LWGenerateParams) -> Self {
        make("generate", provider, weights, load, p)
    }
    static func transform(provider: String, weights: LWInferenceWeights, load: LWInferenceLoadOptions = .init(), _ p: LWTransformParams) -> Self {
        make("transform", provider, weights, load, p)
    }
    static func caption(provider: String, weights: LWInferenceWeights, load: LWInferenceLoadOptions = .init(), _ p: LWCaptionParams) -> Self {
        make("caption", provider, weights, load, p)
    }
    static func embedImage(provider: String, weights: LWInferenceWeights, load: LWInferenceLoadOptions = .init(), _ p: LWEmbedImageParams) -> Self {
        make("embed_image", provider, weights, load, p)
    }
    static func embedText(provider: String, weights: LWInferenceWeights, load: LWInferenceLoadOptions = .init(), _ p: LWEmbedTextParams) -> Self {
        make("embed_text", provider, weights, load, p)
    }
    static func segmentSam2Box(weights: URL, load: LWInferenceLoadOptions = .init(), _ p: LWSam2BoxParams) -> Self {
        make("segment_sam2_box", "sam2", .file(weights), load, p)
    }
    static func segmentSam3Concept(weights: URL, tokenizer: URL, load: LWInferenceLoadOptions = .init(), _ p: LWSam3ConceptParams) -> Self {
        make("segment_sam3_concept", "sam3", .file(weights), load, tokenizer: tokenizer, p)
    }
    static func segmentSam3Box(weights: URL, tokenizer: URL, load: LWInferenceLoadOptions = .init(), _ p: LWSam3BoxParams) -> Self {
        make("segment_sam3_box", "sam3", .file(weights), load, tokenizer: tokenizer, p)
    }

    /// Escape hatch for a request already in the versioned JSON contract.
    init(json: Data) { self.json = json }
}

// MARK: - Events and results

nonisolated struct LWInferenceProgress: Decodable, Sendable, Equatable {
    let phase: String
    let current: Int?
    let total: Int?
    let component: String?
}

nonisolated struct LWInferenceUnsupported: Decodable, Sendable, Equatable {
    let control: String
    let reason: String
}

nonisolated struct LWInferenceFailure: Decodable, Sendable, Equatable {
    let kind: String
    let message: String
    let unsupported: [LWInferenceUnsupported]?
}

nonisolated struct LWInferenceOutputInfo: Decodable, Sendable, Equatable {
    let index: Int
    let score: Double?
    let boxXyxy: [Double]?
}

nonisolated struct LWInferenceResult: Decodable, Sendable, Equatable {
    let task: String
    let provider: String
    let inferenceRevision: String
    let weights: String?
    let quantize: String?
    let modelReused: Bool
    let inputConversions: [String]
    let images: Int?
    let masks: Int?
    let caption: String?
    let finishReason: String?
    let embeddings: [[Float]]?
    let embeddingDim: Int?
    let space: String?
    /// The metallib MLX was pinned to, or `mlx_search_order` for unbundled development builds.
    let metallib: String?
    /// MLX's measured unified-memory high-water mark for the job (load included unless reused).
    let memory: Memory?

    struct Memory: Decodable, Sendable, Equatable {
        let peakBytes: UInt64
        let activeBytes: UInt64
    }
}

nonisolated enum LWInferenceEvent: Sendable, Equatable {
    case started(modelReused: Bool)
    case progress(LWInferenceProgress)
    case image(LWInferenceImage, LWInferenceOutputInfo)
    case mask(LWInferenceImage, LWInferenceOutputInfo)
    case completed(LWInferenceResult)
    case failed(LWInferenceFailure)
    case cancelled

    var isTerminal: Bool {
        switch self { case .completed, .failed, .cancelled: true; default: false }
    }
}

// MARK: - Capabilities

nonisolated struct LWInferenceControl: Decodable, Sendable, Equatable {
    let supported: Bool
    let reason: String?
}

nonisolated struct LWInferenceRoute: Decodable, Sendable, Equatable {
    let id: String
    let task: String?
    let route: String
    let reason: String?
    let modality: String?
    let controls: [String: LWInferenceControl]?
    var isSupported: Bool { route == "supported" }
}

nonisolated struct LWInferenceNotRouted: Decodable, Sendable, Equatable {
    let surface: String
    let ids: [String]
    let reason: String
}

nonisolated struct LWInferenceCapabilities: Decodable, Sendable, Equatable {
    struct Execution: Decodable, Sendable, Equatable {
        let concurrency: String
        let metallib: String
    }
    let abiVersion: UInt32
    let execution: Execution
    let inferenceRevision: String
    let platform: String
    let backend: String
    let routes: [String: [LWInferenceRoute]]
    let notRouted: [LWInferenceNotRouted]
    /// The pinned runtime's checkpoint licence table (families and component rows).
    let modelLicenses: LWInferenceModelLicenses?
}

nonisolated struct LWInferenceModelLicenses: Decodable, Sendable, Equatable {
    struct Family: Decodable, Sendable, Equatable {
        let id: String
        let spdxId: String?
        let name: String
        let textUrl: String
    }
    struct Component: Decodable, Sendable, Equatable {
        let component: String
        let sourceUrl: String
        let gated: Bool
        let declared: String
        let family: String
        let attribution: String?
        let retrieved: String
    }
    let families: [Family]
    let components: [Component]
}

/// The weights-free GPU self-test report.
nonisolated struct LWInferenceSelfTest: Decodable, Sendable, Equatable {
    struct Op: Decodable, Sendable, Equatable {
        let op: String?
        let ok: Bool
        let maxRelError: Double?
        let tolerance: Double?
        let error: String?
    }
    let ok: Bool
    let thread: String
    /// The metallib MLX loaded (its strict path), or nil under MLX's own search order.
    let metallib: String?
    let metallibResolution: String
    let ops: [Op]
}

private nonisolated struct LWInferenceEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let error: LWInferenceFailure?
}

private nonisolated let lwInferenceDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

// MARK: - Runtime

nonisolated final class LWInferenceRuntime: @unchecked Sendable {
    static let expectedABI: UInt32 = 1
    static let libraryName = "liblensworks_inference.dylib"

    private typealias AbiFn = @convention(c) () -> UInt32
    private typealias CapsFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<lw_inference_event>?) -> Void
    private typealias StartFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<lw_inference_image>?, Int, Callback?,
                                                UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?
    fileprivate typealias JobFn = @convention(c) (OpaquePointer?) -> Void
    private typealias ReleaseModelsFn = @convention(c) () -> Int
    private typealias SelfTestFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

    private let freeString: FreeFn
    private let capabilitiesFn: CapsFn
    private let startFn: StartFn
    fileprivate let cancelFn: JobFn
    fileprivate let releaseFn: JobFn
    private let releaseModelsFn: ReleaseModelsFn
    private let selfTestFn: SelfTestFn
    let libraryURL: URL

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: LWInferenceRuntime] = [:]

    /// The library is never unloaded: Rust/MLX thread-local destructors make dlclose unsafe.
    static func load(libraryURL: URL) throws -> LWInferenceRuntime {
        lock.lock(); defer { lock.unlock() }
        if let runtime = loaded[libraryURL.path] { return runtime }
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw LWInferenceError.libraryUnavailable(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, as: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else { throw LWInferenceError.libraryUnavailable("missing symbol \(name)") }
            return unsafeBitCast(raw, to: T.self)
        }
        let abi = try symbol("lw_inference_abi_version", as: AbiFn.self)()
        guard abi == expectedABI else { throw LWInferenceError.abiMismatch(expected: expectedABI, found: abi) }
        let runtime = LWInferenceRuntime(
            libraryURL: libraryURL,
            freeString: try symbol("lw_inference_string_free", as: FreeFn.self),
            capabilitiesFn: try symbol("lw_inference_capabilities", as: CapsFn.self),
            startFn: try symbol("lw_inference_job_start", as: StartFn.self),
            cancelFn: try symbol("lw_inference_job_cancel", as: JobFn.self),
            releaseFn: try symbol("lw_inference_job_release", as: JobFn.self),
            releaseModelsFn: try symbol("lw_inference_release_models", as: ReleaseModelsFn.self),
            selfTestFn: try symbol("lw_inference_self_test", as: SelfTestFn.self))
        loaded[libraryURL.path] = runtime
        return runtime
    }

    /// The embedded runtime (`Contents/Helpers`). Debug builds (tests) may point
    /// `LW_INFERENCE_LIBRARY` at another copy; release builds only load the bundled one.
    static func installed() throws -> LWInferenceRuntime {
        #if DEBUG
        if let explicit = ProcessInfo.processInfo.environment["LW_INFERENCE_LIBRARY"], !explicit.isEmpty {
            return try load(libraryURL: URL(fileURLWithPath: explicit))
        }
        #endif
        guard let contents = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent() else {
            throw LWInferenceError.libraryUnavailable("The application bundle has no executable.")
        }
        return try load(libraryURL: contents.appendingPathComponent("Helpers").appendingPathComponent(libraryName))
    }

    private init(libraryURL: URL, freeString: @escaping FreeFn, capabilitiesFn: @escaping CapsFn, startFn: @escaping StartFn,
                 cancelFn: @escaping JobFn, releaseFn: @escaping JobFn, releaseModelsFn: @escaping ReleaseModelsFn,
                 selfTestFn: @escaping SelfTestFn) {
        self.libraryURL = libraryURL; self.freeString = freeString; self.capabilitiesFn = capabilitiesFn
        self.startFn = startFn; self.cancelFn = cancelFn; self.releaseFn = releaseFn; self.releaseModelsFn = releaseModelsFn
        self.selfTestFn = selfTestFn
    }

    private func takeString(_ raw: UnsafeMutablePointer<CChar>?) -> Data? {
        guard let raw else { return nil }
        defer { freeString(raw) }
        return Data(bytes: raw, count: strlen(raw))
    }

    private func decodeEnvelope<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?, as: T.Type, what: String) throws -> T {
        guard let data = takeString(raw) else { throw LWInferenceError.protocolViolation("No \(what) document.") }
        let envelope = try lwInferenceDecoder.decode(LWInferenceEnvelope<T>.self, from: data)
        if let result = envelope.result, envelope.ok { return result }
        throw LWInferenceError.rejected(kind: envelope.error?.kind ?? "unknown", message: envelope.error?.message ?? "")
    }

    /// Weights-free capability document. The first call builds the runtime catalog, so it
    /// runs off the caller's thread.
    func capabilities() async throws -> LWInferenceCapabilities {
        let fn = capabilitiesFn
        return try await Task.detached(priority: .userInitiated) { [self] in
            try decodeEnvelope(fn(), as: LWInferenceCapabilities.self, what: "capability")
        }.value
    }

    /// Weights-free GPU self-test on the executor thread (a steel GEMM and a Q4
    /// quantized_matmul against a CPU reference), reporting the metallib MLX loaded. The
    /// result carries `ok == false` when a kernel is wrong; a missing document throws.
    func selfTest() async throws -> LWInferenceSelfTest {
        let fn = selfTestFn
        return try await Task.detached(priority: .userInitiated) { [self] in
            guard let data = takeString(fn()) else { throw LWInferenceError.protocolViolation("No self-test document.") }
            let envelope = try lwInferenceDecoder.decode(LWInferenceEnvelope<LWInferenceSelfTest>.self, from: data)
            guard let result = envelope.result else {
                throw LWInferenceError.rejected(kind: envelope.error?.kind ?? "unknown", message: envelope.error?.message ?? "")
            }
            return result
        }.value
    }

    /// Validates and queues a job. Input buffers are copied (and premultiplied alpha
    /// converted) by the adapter before this returns, off the caller's thread.
    func start(_ request: LWInferenceRequest, inputs: [LWInferenceImage] = []) async throws -> LWInferenceJob {
        try await Task.detached(priority: .userInitiated) { [self] in try startBlocking(request, inputs: inputs) }.value
    }

    private func startBlocking(_ request: LWInferenceRequest, inputs: [LWInferenceImage]) throws -> LWInferenceJob {
        let box = LWInferenceCallbackBox()
        let context = Unmanaged.passRetained(box).toOpaque()
        var error: UnsafeMutablePointer<CChar>?
        var json = request.json
        json.append(0)
        let job: OpaquePointer? = Self.withPointers(inputs.map(\.pixels)) { pointers in
            var raw = zip(inputs, pointers).map { image, pointer in
                lw_inference_image(pixels: pointer, byte_length: image.pixels.count, width: UInt32(image.width), height: UInt32(image.height),
                                   row_bytes: UInt32(image.rowBytes), channels: UInt32(image.channels), alpha: image.alpha.rawValue,
                                   color_space: LW_INFERENCE_COLOR_SPACE_SRGB)
            }
            return json.withUnsafeBytes { bytes -> OpaquePointer? in
                raw.withUnsafeMutableBufferPointer { buffer in
                    startFn(bytes.bindMemory(to: CChar.self).baseAddress, buffer.isEmpty ? nil : UnsafePointer(buffer.baseAddress),
                            buffer.count, lwInferenceCallback, context, &error)
                }
            }
        }
        guard let job else {
            Unmanaged<LWInferenceCallbackBox>.fromOpaque(context).release()
            let failure = takeString(error).flatMap { try? lwInferenceDecoder.decode(LWInferenceFailure.self, from: $0) }
            throw LWInferenceError.rejected(kind: failure?.kind ?? "unknown", message: failure?.message ?? "")
        }
        return LWInferenceJob(runtime: self, handle: job, box: box, context: context)
    }

    /// Borrows every buffer's bytes (no copies) for the duration of `body`.
    private static func withPointers<R>(_ datas: [Data], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        pointers.reserveCapacity(datas.count)
        func next(_ index: Int) -> R {
            if index == datas.count { return body(pointers) }
            return datas[index].withUnsafeBytes { raw in
                pointers.append(raw.bindMemory(to: UInt8.self).baseAddress!)
                return next(index + 1)
            }
        }
        return next(0)
    }

    /// Drops resident models once queued jobs finish. Blocks, so it hops off the caller.
    func releaseModels() async -> Int {
        let fn = releaseModelsFn
        return await Task.detached(priority: .utility) { fn() }.value
    }
}

/// Receives callbacks on the executor thread. Owned (+1) by the adapter context until release.
nonisolated final class LWInferenceCallbackBox: @unchecked Sendable {
    let stream: AsyncStream<LWInferenceEvent>
    private let continuation: AsyncStream<LWInferenceEvent>.Continuation
    private let lock = NSLock()
    private var finished = false
    private(set) var deliveredOnMainThread = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: LWInferenceEvent.self, bufferingPolicy: .unbounded)
    }

    func deliver(_ event: LWInferenceEvent) {
        lock.lock(); defer { lock.unlock() }
        if Thread.isMainThread { deliveredOnMainThread = true }
        guard !finished else { return }
        continuation.yield(event)
        if event.isTerminal { finished = true; continuation.finish() }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !finished { finished = true; continuation.finish() }
    }
}

private nonisolated func lwInferenceDecodeEvent(_ e: lw_inference_event) -> LWInferenceEvent {
    let json = e.json.map { Data(bytes: $0, count: strlen($0)) } ?? Data("{}".utf8)
    func decode<T: Decodable>(_ type: T.Type) -> T? { try? lwInferenceDecoder.decode(T.self, from: json) }
    func image() -> LWInferenceImage? {
        guard let pixels = e.pixels, e.byte_length > 0 else { return nil }
        return try? LWInferenceImage(width: Int(e.width), height: Int(e.height), channels: Int(e.channels), rowBytes: Int(e.row_bytes),
                                     alpha: LWInferenceImage.Alpha(rawValue: e.alpha) ?? .none, pixels: Data(bytes: pixels, count: e.byte_length))
    }
    let violation = LWInferenceEvent.failed(LWInferenceFailure(kind: "protocol", message: "Undecodable inference event \(e.kind).", unsupported: nil))
    switch Int(e.kind) {
    case LW_INFERENCE_EVENT_STARTED:
        struct Started: Decodable { let modelReused: Bool }
        return decode(Started.self).map { .started(modelReused: $0.modelReused) } ?? violation
    case LW_INFERENCE_EVENT_PROGRESS: return decode(LWInferenceProgress.self).map { .progress($0) } ?? violation
    case LW_INFERENCE_EVENT_IMAGE:
        guard let image = image(), e.color_space == LW_INFERENCE_COLOR_SPACE_SRGB, let info = decode(LWInferenceOutputInfo.self) else { return violation }
        return .image(image, info)
    case LW_INFERENCE_EVENT_MASK:
        guard let image = image(), image.channels == 1, let info = decode(LWInferenceOutputInfo.self) else { return violation }
        return .mask(image, info)
    case LW_INFERENCE_EVENT_COMPLETED: return decode(LWInferenceResult.self).map { .completed($0) } ?? violation
    case LW_INFERENCE_EVENT_FAILED: return decode(LWInferenceFailure.self).map { .failed($0) } ?? violation
    case LW_INFERENCE_EVENT_CANCELLED: return .cancelled
    default: return violation
    }
}

private nonisolated let lwInferenceCallback: LWInferenceRuntime.Callback = { context, event in
    guard let context, let event else { return }
    let box = Unmanaged<LWInferenceCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliver(lwInferenceDecodeEvent(event.pointee))
}

/// One queued/running inference job. `events` yields typed events and finishes after the
/// terminal event (or on release). Releasing (or deinit) cancels a running job and guarantees
/// no further callbacks before the callback context is freed.
nonisolated final class LWInferenceJob: @unchecked Sendable {
    private let runtime: LWInferenceRuntime
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let box: LWInferenceCallbackBox
    private let context: UnsafeMutableRawPointer

    var events: AsyncStream<LWInferenceEvent> { box.stream }
    /// For tests: whether any callback ran on the main thread (it must not).
    var deliveredOnMainThread: Bool { box.deliveredOnMainThread }
    /// The callback context object; tests hold it weakly to prove teardown frees it.
    var callbackBox: LWInferenceCallbackBox { box }

    fileprivate init(runtime: LWInferenceRuntime, handle: OpaquePointer, box: LWInferenceCallbackBox, context: UnsafeMutableRawPointer) {
        self.runtime = runtime; self.handle = handle; self.box = box; self.context = context
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if let handle { runtime.cancelFn(handle) }
    }

    func release() {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        guard let handle else { return }
        runtime.releaseFn(handle)
        // No callback can run any more: drop the adapter's reference to the box.
        box.finish()
        Unmanaged<LWInferenceCallbackBox>.fromOpaque(context).release()
    }

    /// Collects events until the terminal one (or release).
    func collect() async -> [LWInferenceEvent] {
        var all: [LWInferenceEvent] = []
        for await event in events { all.append(event) }
        return all
    }

    deinit { release() }
}
