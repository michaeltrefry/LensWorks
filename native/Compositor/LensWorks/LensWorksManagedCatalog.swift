import Foundation

/// Runtime authority is the LensWorks-owned catalog file-ledger digest; the upstream commit is provenance only.
nonisolated enum LWManagedAuthority {
    static let sourceRevision = "15a88c514f83e25852161d68bdd859a8252677c87dd4790d90c835d4819144ba"
    static let protocolVersion: UInt32 = 2
    static func validate(sourceRevision: String, protocolVersion: UInt32 = Self.protocolVersion) throws {
        guard sourceRevision == Self.sourceRevision, protocolVersion == Self.protocolVersion else {
            throw LensWorksManagedError.protocolViolation("The catalog result does not match the approved source revision and protocol.")
        }
    }
}

nonisolated struct LWManagedSessionConfig: Encodable, Sendable {
    var worker_executable: LWCatalogNativePath
    var decode_worker_executable: LWCatalogNativePath?
    var cache_root: LWCatalogNativePath?
    var original_roots: [LWCatalogNativePath]
    var payload_bytes: LWCatalogU64? = nil
    var worker_bytes: LWCatalogU64? = nil
    var limits: LWApplicationLimits?
    var preview_policy: LWPreviewServicePreviewPolicy?
    var preview_limits: LWPreviewServiceServiceLimits?

    /// Production resolves only installed helpers, never an ambient working-directory binary.
    static func installed(originalRoots: [LWCatalogNativePath], cacheRoot: LWCatalogNativePath? = nil) throws -> Self {
        guard let helpers = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent().appendingPathComponent("Helpers") ?? Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers") else {
            throw LensWorksManagedError.protocolViolation("The installed catalog helper directory is missing.")
        }
        return Self(worker_executable: try LWCatalogNativePath(fileURL: helpers.appendingPathComponent("PhotoCatalogWorker")), decode_worker_executable: try LWCatalogNativePath(fileURL: helpers.appendingPathComponent("LensWorksDecodeWorker")), cache_root: cacheRoot, original_roots: originalRoots, limits: nil, preview_policy: nil, preview_limits: nil)
    }
}

nonisolated enum LWManagedSessionPhase: String, Decodable, Sendable { case starting, ready, draining, failed, closed, retained_startup }
nonisolated struct LWManagedSessionStatus: Decodable, Sendable {
    let phase: LWManagedSessionPhase
    let pending: UInt
    let outcome_unknown: Bool
    let message: String?
    let pid: UInt32
}
nonisolated enum LWManagedJobPhase: String, Decodable, Sendable { case pending, complete, taken }
nonisolated struct LWManagedJobStatus: Decodable, Sendable {
    let phase: LWManagedJobPhase
    let cancel_requested: Bool
    let failed: Bool
}
nonisolated struct LWManagedFloatDescriptor: Codable, Sendable {
    let source_revision: String
    let `protocol`: UInt32
    let kind: String
    let mime: String
    let width: UInt32
    let height: UInt32
    let row_stride: LWCatalogU64
    let byte_length: LWCatalogU64
    let channels: UInt8
    let sample: String
    let color_space: String
    let alpha: String
    let orientation: String
    let metadata: LWMediaMetadata
    let provenance: LWMediaFullRenderProvenance
    let source_identity: LWApplicationExportsDtoRenderIdentity
    let original: LWCatalogNativePath
    let original_revision: LWApplicationExportsDtoFileRevision
    let plan_authority: String
    let memory_enforcement: String

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        source_revision = try c.decode(String.self, forKey: .init("source_revision"))
        `protocol` = try c.decode(UInt32.self, forKey: .init("protocol"))
        try LWManagedAuthority.validate(sourceRevision: source_revision, protocolVersion: `protocol`)
        kind = try c.decode(String.self, forKey: .init("kind"))
        mime = try c.decode(String.self, forKey: .init("mime"))
        width = try c.decode(UInt32.self, forKey: .init("width"))
        height = try c.decode(UInt32.self, forKey: .init("height"))
        row_stride = try c.decode(LWCatalogU64.self, forKey: .init("row_stride"))
        byte_length = try c.decode(LWCatalogU64.self, forKey: .init("byte_length"))
        channels = try c.decode(UInt8.self, forKey: .init("channels"))
        sample = try c.decode(String.self, forKey: .init("sample"))
        color_space = try c.decode(String.self, forKey: .init("color_space"))
        alpha = try c.decode(String.self, forKey: .init("alpha"))
        orientation = try c.decode(String.self, forKey: .init("orientation"))
        metadata = try c.decode(LWMediaMetadata.self, forKey: .init("metadata"))
        provenance = try c.decode(LWMediaFullRenderProvenance.self, forKey: .init("provenance"))
        source_identity = try c.decode(LWApplicationExportsDtoRenderIdentity.self, forKey: .init("source_identity"))
        original = try c.decode(LWCatalogNativePath.self, forKey: .init("original"))
        original_revision = try c.decode(LWApplicationExportsDtoFileRevision.self, forKey: .init("original_revision"))
        plan_authority = try c.decode(String.self, forKey: .init("plan_authority"))
        memory_enforcement = try c.decode(String.self, forKey: .init("memory_enforcement"))
        try validate(length: byte_length.value)
    }

    func validate(length: UInt64) throws {
        try LWManagedAuthority.validate(sourceRevision: source_revision, protocolVersion: `protocol`)
        let stride = UInt64(width) * 16
        let (expected, overflow) = stride.multipliedReportingOverflow(by: UInt64(height))
        guard kind == "float", mime == "application/x-lensworks-rgba-f32le", width > 0, height > 0,
              !overflow, channels == 4, sample == "float32_le", color_space == "linear_srgb",
              alpha == "straight", orientation == "applied", row_stride.value == stride,
              byte_length.value == expected, length == expected else {
            throw LensWorksManagedError.protocolViolation("The full-resolution surface descriptor has inconsistent geometry or color semantics.")
        }
    }
}
nonisolated enum LWManagedResultDescriptor: Decodable, Sendable {
    case json(mime: String), preview(mime: String), float(LWManagedFloatDescriptor)
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let kind = try c.decode(String.self, forKey: .init("kind"))
        let mime = try c.decode(String.self, forKey: .init("mime"))
        switch kind {
        case "json": guard mime == "application/json" else { throw LensWorksManagedError.protocolViolation("Unexpected JSON media type.") }; self = .json(mime: mime)
        case "preview": self = .preview(mime: mime)
        case "float": self = .float(try LWManagedFloatDescriptor(from: decoder))
        default: throw LensWorksManagedError.protocolViolation("Unknown result descriptor kind.")
        }
    }
}

nonisolated private struct LWManagedCall<Arguments: Encodable & Sendable>: Encodable, Sendable {
    let op: String
    let arguments: Arguments
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: LWCatalogCodingKey.self)
        try c.encode(2, forKey: .init("version")); try c.encode(op, forKey: .init("op"))
        try arguments.encode(to: encoder)
    }
}
nonisolated private struct LWManagedEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct Failure: Decodable, Sendable { let code: String; let message: String }
    let version: Int
    let ok: Bool
    let result: Value?
    let error: Failure?
    func get() throws -> Value {
        guard version == 2 else { throw LensWorksManagedError.protocolViolation("Unexpected managed catalog envelope version.") }
        if !ok { guard let error else { throw LensWorksManagedError.protocolViolation("Missing managed catalog failure.") }; throw LensWorksManagedError.native(code: error.code, message: error.message) }
        guard error == nil, let result else { throw LensWorksManagedError.protocolViolation("Missing managed catalog result.") }
        return result
    }
}
nonisolated private struct LWSessionArguments: Encodable, Sendable { let session: LWCatalogSessionHandle }
nonisolated private struct LWJobArguments: Encodable, Sendable { let job: LWCatalogJobHandle }
nonisolated private struct LWCreateArguments: Encodable, Sendable { let config: LWManagedSessionConfig }
nonisolated struct LWManagedSessionAdmission: Decodable, Sendable {
    let owner: LWManagedSession
    let phase: LWManagedSessionPhase
    let source_revision: String
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        // Acquire the exact owner first: even a malformed source header must retire startup resources.
        owner = LWManagedSession(handle: try c.decode(LWCatalogSessionHandle.self, forKey: .init("session")))
        phase = try c.decode(LWManagedSessionPhase.self, forKey: .init("phase"))
        source_revision = try c.decode(String.self, forKey: .init("source_revision"))
        try LWManagedAuthority.validate(sourceRevision: source_revision)
        owner.installSourceRevision(source_revision)
    }
}
nonisolated private struct LWCreatedJob: Decodable, Sendable { let job: LWCatalogJobHandle }
nonisolated private struct LWReleased: Decodable, Sendable { let released: Bool }
nonisolated private struct LWClosed: Decodable, Sendable { let phase: LWManagedSessionPhase }
nonisolated private struct LWCancelled: Decodable, Sendable { let cancel_requested: Bool }
nonisolated private struct LWSubmitArguments: Encodable, Sendable { let session: LWCatalogSessionHandle; let request: LWApplicationRequest }
nonisolated private struct LWPreviewArguments: Encodable, Sendable { let session: LWCatalogSessionHandle; let catalog: String; let ticket: String; let foreground: Bool }
nonisolated private struct LWSourceArguments: Encodable, Sendable { let session: LWCatalogSessionHandle; let catalog: String; let export_job: String; let sequence: LWCatalogI64 }
nonisolated private struct LWDecodeArguments: Encodable, Sendable {
    let session: LWCatalogSessionHandle; let catalog: String; let export_job: String; let sequence: LWCatalogI64
    let limits: LWApplicationExportsDtoDecodeLimits; let worker_bytes: LWCatalogU64; let max_output_bytes: LWCatalogU64
}
nonisolated private struct LWResultWire: Decodable, Sendable {
    let buffer: LWManagedBuffer
    let length: LWCatalogU64
    let descriptor: LWManagedResultDescriptor
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        // Acquire ownership before decoding any descriptor field. Malformed metadata cannot orphan its buffer.
        buffer = try LWManagedBuffer(handle: c.decode(LWCatalogBufferHandle.self, forKey: .init("buffer")))
        length = try c.decode(LWCatalogU64.self, forKey: .init("length"))
        descriptor = try c.decode(LWManagedResultDescriptor.self, forKey: .init("descriptor"))
    }
}

/// The queue is concurrent: session shutdown and a blocked worker can never serialize cancellation.
nonisolated enum LWManagedTransport {
    static func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private final class DigestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        func cancel() { lock.withLock { canceled = true } }
        func check() throws { if lock.withLock({ canceled }) { throw CancellationError() } }
    }
    private enum DigestSource: Sendable { case bytes(Data), file(URL) }
    static func blake3(_ data: Data) async throws -> String { try await blake3(.bytes(data)) }
    static func blake3(fileURL: URL) async throws -> String {
        guard fileURL.isFileURL else { throw LensWorksManagedError.protocolViolation("Digest preparation requires a local file URL.") }
        return try await blake3(.file(fileURL))
    }
    /// The retained digest algorithm seals complete documents using bounded chunks.
    private static func blake3(_ source: DigestSource) async throws -> String {
        try Task.checkCancellation()
        let cancellation = DigestCancellation()
        return try await withTaskCancellationHandler {
            let value = try await background {
                var handle: UInt64 = 0
                let admission = lw_catalog_blake3_init(&handle)
                guard admission == 0 else { throw LensWorksManagedError.abi(status: admission, operation: "blake3_init") }
                defer { _ = lw_catalog_blake3_release(handle) }
                func update(_ bytes: UnsafeRawBufferPointer) throws {
                    try cancellation.check()
                    let status = lw_catalog_blake3_update(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
                    guard status == 0 else { throw LensWorksManagedError.abi(status: status, operation: "blake3_update") }
                }
                switch source {
                case .bytes(let data):
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let count = min(4 * 1024 * 1024, bytes.count - offset)
                            try update(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]))
                            offset += count
                        }
                    }
                case .file(let url):
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    while true {
                        try cancellation.check()
                        guard let bytes = try file.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty else { break }
                        try bytes.withUnsafeBytes(update)
                    }
                }
                try cancellation.check()
                var digest = [UInt8](repeating: 0, count: 32)
                let status = digest.withUnsafeMutableBufferPointer { lw_catalog_blake3_finalize(handle, $0.baseAddress) }
                guard status == 0 else { throw LensWorksManagedError.abi(status: status, operation: "blake3_finalize") }
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            try Task.checkCancellation()
            return value
        } onCancel: { cancellation.cancel() }
    }
    static func request<Arguments: Encodable & Sendable, Result: Decodable & Sendable>(_ op: String, _ arguments: Arguments, as: Result.Type) async throws -> Result {
        try await background { try requestSync(op, arguments, as: Result.self) }
    }
    static func requestSync<Arguments: Encodable & Sendable, Result: Decodable & Sendable>(_ op: String, _ arguments: Arguments, as: Result.Type) throws -> Result {
        let data = try LWCatalogCodec.encode(LWManagedCall(op: op, arguments: arguments))
        guard data.count <= 4 * 1024 * 1024 else { throw LensWorksManagedError.resourceLimit("The catalog request exceeds four MiB.") }
        var handle: UInt64 = 0
        let status = data.withUnsafeBytes { bytes in lw_catalog_managed_request(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &handle) }
        guard status == 0 else { throw LensWorksManagedError.abi(status: status, operation: op) }
        let buffer = try LWManagedBuffer(handle: LWCatalogBufferHandle(handle))
        defer { buffer.release() }
        let output = try buffer.copySync(maximumBytes: 4 * 1024 * 1024)
        return try LWCatalogCodec.decode(LWManagedEnvelope<Result>.self, from: output).get()
    }
}

/// No pointer into Rust memory escapes. Copies and release share a lock; release is idempotent.
nonisolated final class LWManagedBuffer: @unchecked Sendable {
    let handle: LWCatalogBufferHandle
    private let lock = NSLock()
    private var released = false
    init(handle: LWCatalogBufferHandle) throws { self.handle = handle }
    deinit { release() }
    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            _ = lw_catalog_buffer_release(handle.value)
        }
    }
    func copy(maximumBytes: Int, expectedLength: UInt64? = nil) async throws -> Data {
        try await LWManagedTransport.background { try self.copySync(maximumBytes: maximumBytes, expectedLength: expectedLength) }
    }
    func copySync(maximumBytes: Int, expectedLength: UInt64? = nil) throws -> Data {
        try lock.withLock {
            guard !released else { throw LensWorksManagedError.closed }
            guard maximumBytes >= 0, expectedLength == nil || expectedLength! <= UInt64(maximumBytes) else { throw LensWorksManagedError.resourceLimit("The result exceeds the caller's copy budget.") }
            var data = Data(); var offset = 0
            let requestedLength = expectedLength.flatMap(Int.init(exactly:))
            while requestedLength == nil || offset < requestedLength! {
                let remaining = maximumBytes - offset
                // A one-byte probe distinguishes an exactly full buffer from an oversized result.
                let capacity = min(64 * 1024, requestedLength.map { $0 - offset } ?? max(1, remaining))
                var chunk = [UInt8](repeating: 0, count: capacity); var count = 0
                let status = chunk.withUnsafeMutableBufferPointer { lw_catalog_buffer_copy(handle.value, offset, $0.baseAddress, capacity, &count) }
                guard status == 0 else { throw LensWorksManagedError.abi(status: status, operation: "buffer_copy") }
                guard count <= capacity, count <= remaining else { throw LensWorksManagedError.resourceLimit("The result exceeds the caller's copy budget.") }
                data.append(contentsOf: chunk.prefix(count)); offset += count
                if count < capacity { break }
            }
            guard requestedLength == nil || offset == requestedLength else { throw LensWorksManagedError.protocolViolation("The result buffer length differs from its descriptor.") }
            return data
        }
    }
}

nonisolated struct LWManagedResult: Sendable {
    let buffer: LWManagedBuffer
    let length: UInt64
    let descriptor: LWManagedResultDescriptor
    func decode<Value: Decodable & Sendable>(_ type: Value.Type, maximumBytes: Int = 4 * 1024 * 1024) async throws -> Value {
        guard case .json = descriptor else { throw LensWorksManagedError.protocolViolation("Expected a JSON job result.") }
        return try LWCatalogCodec.decode(Value.self, from: await buffer.copy(maximumBytes: maximumBytes, expectedLength: length))
    }
    /// Preserves negative and greater-than-one RGB values; no clipping, gamma conversion, or premultiplication.
    func floatSamples(maximumBytes: Int) async throws -> [Float] {
        guard case .float(let descriptor) = descriptor else { throw LensWorksManagedError.protocolViolation("Expected a full-resolution float result.") }
        try descriptor.validate(length: length)
        let data = try await buffer.copy(maximumBytes: maximumBytes, expectedLength: length)
        return stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}

nonisolated final class LWManagedJob: @unchecked Sendable {
    let handle: LWCatalogJobHandle
    private let lock = NSLock()
    private var released = false
    init(handle: LWCatalogJobHandle) { self.handle = handle }
    private func admitted() throws { try lock.withLock { if released { throw LensWorksManagedError.closed } } }
    func status() async throws -> LWManagedJobStatus { try admitted(); return try await LWManagedTransport.request("job_status", LWJobArguments(job: handle), as: LWManagedJobStatus.self) }
    func cancel() async throws { try admitted(); let _: LWCancelled = try await LWManagedTransport.request("job_cancel", LWJobArguments(job: handle), as: LWCancelled.self) }
    func takeResult() async throws -> LWManagedResult {
        try admitted()
        let wire = try await LWManagedTransport.request("job_result", LWJobArguments(job: handle), as: LWResultWire.self)
        let buffer = wire.buffer
        do {
            if case .float(let descriptor) = wire.descriptor { try descriptor.validate(length: wire.length.value) }
            return LWManagedResult(buffer: buffer, length: wire.length.value, descriptor: wire.descriptor)
        } catch { buffer.release(); throw error }
    }
    func wait() async throws -> LWManagedResult {
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let state = try await status()
                if state.phase != .pending { return try await takeResult() }
                try await Task.sleep(for: .milliseconds(10))
            }
        } onCancel: {
            let handle = self.handle
            Task.detached { let _: LWCancelled? = try? await LWManagedTransport.request("job_cancel", LWJobArguments(job: handle), as: LWCancelled.self) }
        }
    }
    /// A pending job cannot be discarded. Cancel, await terminal receiver state, then release its authority.
    func close() async throws {
        if lock.withLock({ released }) { return }
        if try await status().phase == .pending { try await cancel() }
        while try await status().phase == .pending { try await Task.sleep(for: .milliseconds(10)) }
        let _: LWReleased = try await LWManagedTransport.request("job_release", LWJobArguments(job: handle), as: LWReleased.self)
        lock.withLock { released = true }
    }
    deinit {
        guard !lock.withLock({ released }) else { return }
        let handle = handle
        Task.detached {
            let _: LWCancelled? = try? await LWManagedTransport.request("job_cancel", LWJobArguments(job: handle), as: LWCancelled.self)
            while true {
                do {
                    let _: LWReleased = try await LWManagedTransport.request("job_release", LWJobArguments(job: handle), as: LWReleased.self)
                    return
                } catch LensWorksManagedError.native(let code, _) where code == "busy" || code == "resource_limit" {
                    let _: LWCancelled? = try? await LWManagedTransport.request("job_cancel", LWJobArguments(job: handle), as: LWCancelled.self)
                    try? await Task.sleep(for: .milliseconds(25))
                } catch LensWorksManagedError.abi(let status, _) where status == 2 || status == 3 || status == 6 {
                    try? await Task.sleep(for: .milliseconds(25))
                } catch { return }
            }
        }
    }
}

nonisolated final class LWManagedSession: @unchecked Sendable {
    let handle: LWCatalogSessionHandle
    private let lock = NSLock()
    private var released = false
    private var closing = false
    private var closeInFlight = false
    private var subscriptions: [LWManagedSubscription] = []
    private var approvedRevision: String?
    var sourceRevision: String { lock.withLock { approvedRevision ?? "" } }
    fileprivate func installSourceRevision(_ revision: String) { lock.withLock { approvedRevision = revision } }
    fileprivate init(handle: LWCatalogSessionHandle) { self.handle = handle }
    static func create(config: LWManagedSessionConfig) async throws -> LWManagedSession {
        let created = try await LWManagedTransport.request("session_create", LWCreateArguments(config: config), as: LWManagedSessionAdmission.self)
        return created.owner
    }
    private func admitted() throws { try lock.withLock { if released || closing { throw LensWorksManagedError.closed } } }
    func status() async throws -> LWManagedSessionStatus { if lock.withLock({ released }) { throw LensWorksManagedError.closed }; return try await LWManagedTransport.request("session_status", LWSessionArguments(session: handle), as: LWManagedSessionStatus.self) }
    /// Every retained public family is represented by LWApplicationRequest and its typed LWApplicationReply.
    func submit(_ request: LWApplicationRequest) async throws -> LWManagedJob {
        try admitted()
        let created = try await LWManagedTransport.request("submit", LWSubmitArguments(session: handle, request: request), as: LWCreatedJob.self)
        return LWManagedJob(handle: created.job)
    }
    func perform(_ request: LWApplicationRequest) async throws -> LWApplicationResponse {
        let job = try await submit(request)
        do {
            let result = try await job.wait()
            defer { result.buffer.release() }
            let reply = try await result.decode(LWApplicationReply.self)
            try await job.close()
            switch reply {
            case .Ok(let value): return value
            case .Error(let error): throw LensWorksManagedError.native(code: error.code.rawValue, message: error.message)
            }
        } catch { try? await job.close(); throw error }
    }
    func preview(catalog: String, ticket: String, foreground: Bool) async throws -> LWManagedJob {
        try admitted()
        let created = try await LWManagedTransport.request("preview_bytes", LWPreviewArguments(session: handle, catalog: catalog, ticket: ticket, foreground: foreground), as: LWCreatedJob.self)
        return LWManagedJob(handle: created.job)
    }
    /// Uses an explicitly prepared durable export plan. No hidden export or source-path re-resolution occurs.
    func sourceIdentity(catalog: String, exportJob: String, sequence: LWCatalogI64) async throws -> LWManagedJob {
        try admitted()
        let created = try await LWManagedTransport.request("source_identity", LWSourceArguments(session: handle, catalog: catalog, export_job: exportJob, sequence: sequence), as: LWCreatedJob.self)
        return LWManagedJob(handle: created.job)
    }
    func decodeFull(catalog: String, exportJob: String, sequence: LWCatalogI64, limits: LWApplicationExportsDtoDecodeLimits, workerBytes: LWCatalogU64, maximumOutputBytes: LWCatalogU64) async throws -> LWManagedJob {
        try admitted()
        let caps = [limits.max_encoded_bytes.value, limits.max_intermediate_pixels.value, limits.max_allocation_bytes.value, workerBytes.value, maximumOutputBytes.value]
        guard caps.allSatisfy({ $0 > 0 && $0 < UInt64.max }), limits.max_allocation_bytes.value <= workerBytes.value, maximumOutputBytes.value <= workerBytes.value else {
            throw LensWorksManagedError.resourceLimit("Decode requires finite positive caps within the worker allowance.")
        }
        let created = try await LWManagedTransport.request("decode_full", LWDecodeArguments(session: handle, catalog: catalog, export_job: exportJob, sequence: sequence, limits: limits, worker_bytes: workerBytes, max_output_bytes: maximumOutputBytes), as: LWCreatedJob.self)
        return LWManagedJob(handle: created.job)
    }
    func subscribe(_ completion: @escaping @Sendable (LWCatalogSessionHandle, LWCatalogJobHandle) -> Void) async throws -> LWManagedSubscription {
        try admitted()
        let subscription = try await LWManagedSubscription.create(session: handle, completion: completion)
        let retained = lock.withLock {
            guard !released && !closing else { return false }
            subscriptions.removeAll { $0.isDrained }
            subscriptions.append(subscription)
            return true
        }
        guard retained else { try await subscription.drain(); throw LensWorksManagedError.closed }
        return subscription
    }
    /// Transient drain stays off the UI thread. Timeout or cancellation retains
    /// the closing owner and callback contexts for an explicit checked retry.
    func close(timeoutMilliseconds: UInt32 = 30000) async throws {
        guard timeoutMilliseconds <= 60000 else { throw LensWorksManagedError.protocolViolation("Catalog close timeout exceeds 60 seconds.") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        let needsClose = try lock.withLock {
            if released { return false }
            guard !closeInFlight else { throw LensWorksManagedError.native(code: "busy", message: "Catalog shutdown is already running.") }
            closing = true; closeInFlight = true
            return true
        }
        guard needsClose else { return }
        defer { lock.withLock { closeInFlight = false } }
        while true {
            try Task.checkCancellation()
            do {
                let closed = try await LWManagedTransport.request("session_shutdown", LWSessionArguments(session: handle), as: LWClosed.self)
                guard closed.phase == .closed else { throw LensWorksManagedError.protocolViolation("Shutdown did not close the session.") }
                break
            } catch LensWorksManagedError.native(let code, let message) where code == "draining" {
                guard ContinuousClock.now < deadline else {
                    throw LensWorksManagedError.native(code: "draining", message: "Catalog close timed out; its owner is retained for retry. \(message)")
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                try await Task.sleep(for: min(.milliseconds(25), remaining))
            }
        }
        let callbacks = lock.withLock { subscriptions }
        for subscription in callbacks {
            try Task.checkCancellation()
            let remaining = max(.zero, ContinuousClock.now.duration(to: deadline))
            let parts = remaining.components
            let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
            try await subscription.drain(timeoutMilliseconds: UInt32(clamping: milliseconds))
        }
        try Task.checkCancellation()
        let _: LWReleased = try await LWManagedTransport.request("session_release", LWSessionArguments(session: handle), as: LWReleased.self)
        lock.withLock { released = true; subscriptions = [] }
    }
    deinit {
        guard !lock.withLock({ released }) else { return }
        let handle = handle
        let callbacks = subscriptions
        Task.detached {
            while true {
                do {
                    let _: LWClosed = try await LWManagedTransport.request("session_shutdown", LWSessionArguments(session: handle), as: LWClosed.self)
                    for callback in callbacks { try await callback.drain() }
                    let _: LWReleased = try await LWManagedTransport.request("session_release", LWSessionArguments(session: handle), as: LWReleased.self)
                    return
                } catch LensWorksManagedError.native(let code, _) where code == "draining" || code == "busy" || code == "resource_limit" {
                    try? await Task.sleep(for: .milliseconds(25))
                } catch LensWorksManagedError.abi(let status, _) where status == 2 || status == 3 || status == 6 {
                    try? await Task.sleep(for: .milliseconds(25))
                } catch { return }
            }
        }
    }
}

nonisolated private final class LWCompletionContext: @unchecked Sendable {
    let completion: @Sendable (LWCatalogSessionHandle, LWCatalogJobHandle) -> Void
    init(_ completion: @escaping @Sendable (LWCatalogSessionHandle, LWCatalogJobHandle) -> Void) { self.completion = completion }
}
nonisolated private let lwCompletionTrampoline: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Void = { pointer, session, job in
    guard let pointer, let session = try? LWCatalogSessionHandle(session), let job = try? LWCatalogJobHandle(job) else { return }
    Unmanaged<LWCompletionContext>.fromOpaque(pointer).takeUnretainedValue().completion(session, job)
}

nonisolated final class LWManagedSubscription: @unchecked Sendable {
    let handle: LWCatalogSubscriptionHandle
    private let context: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var drained = false
    private var drainInFlight = false
    private init(handle: LWCatalogSubscriptionHandle, context: UnsafeMutableRawPointer) { self.handle = handle; self.context = context }
    fileprivate static func create(session: LWCatalogSessionHandle, completion: @escaping @Sendable (LWCatalogSessionHandle, LWCatalogJobHandle) -> Void) async throws -> LWManagedSubscription {
        // Context lifetime begins before Rust admits callbacks, and ends only after a successful drain.
        try await LWManagedTransport.background {
            let pointer = Unmanaged.passRetained(LWCompletionContext(completion)).toOpaque()
            var handle: UInt64 = 0
            let status = lw_catalog_subscribe(session.value, lwCompletionTrampoline, pointer, &handle)
            guard status == 0 else { Unmanaged<LWCompletionContext>.fromOpaque(pointer).release(); throw LensWorksManagedError.abi(status: status, operation: "subscribe") }
            return LWManagedSubscription(handle: try LWCatalogSubscriptionHandle(handle), context: pointer)
        }
    }
    fileprivate var isDrained: Bool { lock.withLock { drained } }
    func drain(timeoutMilliseconds: UInt32 = 1000) async throws {
        guard timeoutMilliseconds <= 60000 else { throw LensWorksManagedError.protocolViolation("Callback drain timeout exceeds 60 seconds.") }
        try await LWManagedTransport.background {
            let needsDrain = try self.lock.withLock {
                if self.drained { return false }
                guard !self.drainInFlight else { throw LensWorksManagedError.abi(status: 6, operation: "unsubscribe_and_drain") }
                self.drainInFlight = true
                return true
            }
            guard needsDrain else { return }
            defer { self.lock.withLock { self.drainInFlight = false } }
            let status = lw_catalog_unsubscribe_and_drain(self.handle.value, timeoutMilliseconds)
            guard status == 0 else { throw LensWorksManagedError.abi(status: status, operation: "unsubscribe_and_drain") }
            self.lock.withLock {
                self.drained = true
                Unmanaged<LWCompletionContext>.fromOpaque(self.context).release()
            }
        }
    }
    deinit {
        guard !lock.withLock({ drained }) else { return }
        let handle = handle; let address = UInt(bitPattern: context)
        Task.detached {
            while true {
                let status = lw_catalog_unsubscribe_and_drain(handle.value, 1000)
                if status == 0 { Unmanaged<LWCompletionContext>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).release(); return }
                // Timeout and reentrant-busy retain context. No callback can observe freed Swift storage.
                if status != 2 && status != 3 && status != 6 { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
}
