import CryptoKit
import Darwin
import Foundation
import Metal

// LensWorks model store: admits compatible SceneWorks model files by reference (never copied,
// moved or written), keeps explicit downloads in a LensWorks-owned store, verifies integrity
// with identity-aware caching, admits models by measured memory need, and leases admitted
// models so active ones cannot be deleted or evicted. All file access to model libraries runs
// on bounded, abandonable probe threads: a library on a volume macOS privacy consent withholds
// can block a read indefinitely instead of failing, and that must never hang the app.

// MARK: - Manifest

nonisolated struct LWModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable, Hashable {
        let path: String
        let size: UInt64
        let sha256: String
    }
    struct Component: Decodable, Sendable, Hashable {
        let repository: String
        let revision: String
        let files: [File]
        var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
        /// `models--org--name`, the Hugging Face cache directory SceneWorks uses.
        var hubDirectoryName: String { "models--" + repository.replacingOccurrences(of: "/", with: "--") }
        /// LensWorks' managed layout: `<root>/<org>--<name>/<revision>/<file path>`.
        var managedDirectoryName: String { repository.replacingOccurrences(of: "/", with: "--") }
    }
    struct Route: Decodable, Sendable, Hashable {
        let task: String
        let provider: String
        var key: String { "\(task):\(provider)" }
    }
    struct Weights: Decodable, Sendable, Hashable {
        enum Kind: String, Decodable, Sendable { case dir, file }
        let kind: Kind
        /// Relative to the first component's root.
        let path: String
        let tokenizer: String?
    }
    struct LicenseComponent: Decodable, Sendable, Hashable {
        let key: String
        let declared: String
    }
    struct Memory: Decodable, Sendable, Hashable {
        let peakBytes: UInt64?
        let residentBytes: UInt64?
        let pixels: Int?
    }
    struct Model: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let summary: String
        let routes: [Route]
        let weights: Weights
        let licenseComponents: [LicenseComponent]
        let licenseNote: String?
        let memory: Memory
        let components: [Component]
        var totalBytes: UInt64 { components.reduce(0) { $0 + $1.totalBytes } }
    }

    let schemaVersion: Int
    let inferenceRevision: String
    let downloadBaseURL: URL
    let measurement: String
    let models: [Model]

    static let resourceName = "LensWorksModels"

    static func bundled(_ bundle: Bundle = .main) throws -> LWModelManifest {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LWModelStoreError.manifest("The model manifest is missing from the application bundle.")
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> LWModelManifest {
        let manifest = try JSONDecoder().decode(LWModelManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw LWModelStoreError.manifest("Unsupported model manifest schema \(schemaVersion).") }
        var ids = Set<String>()
        for model in models {
            guard ids.insert(model.id).inserted else { throw LWModelStoreError.manifest("Duplicate model id \(model.id).") }
            guard !model.components.isEmpty, !model.routes.isEmpty else {
                throw LWModelStoreError.manifest("\(model.id) needs at least one component and route.")
            }
            for component in model.components {
                guard Self.isRevision(component.revision), !component.files.isEmpty,
                      component.repository.split(separator: "/").count == 2 else {
                    throw LWModelStoreError.manifest("\(model.id) has an invalid component \(component.repository)@\(component.revision).")
                }
                for file in component.files {
                    guard Self.isSafeRelative(file.path), file.size > 0, Self.isSHA256(file.sha256) else {
                        throw LWModelStoreError.manifest("\(model.id) has an invalid file entry \(file.path).")
                    }
                }
            }
            for path in [model.weights.path, model.weights.tokenizer].compactMap({ $0 }) where !path.isEmpty {
                guard Self.isSafeRelative(path) else { throw LWModelStoreError.manifest("\(model.id) has an unsafe weights path.") }
            }
        }
    }

    static func isSHA256(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func isRevision(_ value: String) -> Bool { value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

// MARK: - Runtime facts

/// What the pinned inference runtime says about compatibility: its revision, the routes it
/// serves, and its checkpoint licence table.
nonisolated struct LWModelRuntimeFacts: Sendable, Equatable {
    struct License: Sendable, Hashable {
        let key: String
        let declared: String
        let familyName: String
        let spdxID: String?
        let textURL: URL?
        let sourceURL: URL?
        let gated: Bool
        let attribution: String?
    }
    let inferenceRevision: String
    let routes: Set<String>
    let licenses: [String: License]

    init(inferenceRevision: String, routes: Set<String>, licenses: [String: License]) {
        self.inferenceRevision = inferenceRevision; self.routes = routes; self.licenses = licenses
    }

    init(capabilities: LWInferenceCapabilities) {
        var routes = Set<String>()
        for (task, entries) in capabilities.routes {
            for entry in entries where entry.isSupported { routes.insert("\(entry.task ?? task):\(entry.id)") }
        }
        var licenses: [String: License] = [:]
        let table = capabilities.modelLicenses
        let families = Dictionary((table?.families ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in table?.components ?? [] {
            let family = families[row.family]
            licenses[row.component] = License(
                key: row.component, declared: row.declared, familyName: family?.name ?? row.family, spdxID: family?.spdxId,
                textURL: family.flatMap { URL(string: $0.textUrl) }, sourceURL: URL(string: row.sourceUrl), gated: row.gated,
                attribution: row.attribution)
        }
        self.init(inferenceRevision: capabilities.inferenceRevision, routes: routes, licenses: licenses)
    }
}

// MARK: - File access

nonisolated struct LWFileStatus: Sendable, Hashable, Codable {
    var isDirectory: Bool
    var size: UInt64
    var inode: UInt64
    var modifiedNanoseconds: Int64
    var changedNanoseconds: Int64

    /// Identity stamp. Excludes the device number: macOS can renumber an unchanged volume
    /// across mounts (the SceneWorks receipt stamp makes the same choice).
    var stamp: Stamp { Stamp(size: size, inode: inode, modifiedNanoseconds: modifiedNanoseconds, changedNanoseconds: changedNanoseconds) }

    struct Stamp: Sendable, Hashable, Codable {
        var size: UInt64
        var inode: UInt64
        var modifiedNanoseconds: Int64
        var changedNanoseconds: Int64
    }

    init(isDirectory: Bool, size: UInt64, inode: UInt64, modifiedNanoseconds: Int64, changedNanoseconds: Int64) {
        self.isDirectory = isDirectory; self.size = size; self.inode = inode
        self.modifiedNanoseconds = modifiedNanoseconds; self.changedNanoseconds = changedNanoseconds
    }

    init(_ st: stat) {
        self.init(isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, size: UInt64(max(0, st.st_size)), inode: UInt64(st.st_ino),
                  modifiedNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                  changedNanoseconds: Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec))
    }
}

nonisolated struct LWFileAccessError: Error, Equatable, CustomStringConvertible {
    let path: String
    let code: Int32
    /// EPERM is what macOS privacy consent (TCC) returns; EACCES is ordinary permissions.
    var isDenied: Bool { code == EPERM || code == EACCES }
    var description: String { "\(path): \(String(cString: strerror(code)))" }
}

/// Read-only access to model libraries. Missing paths are `nil`; denied or failing access throws.
/// Injectable so tests can simulate a privacy-blocked (hanging) or denied volume.
nonisolated protocol LWModelFileAccess: Sendable {
    func status(_ url: URL) throws -> LWFileStatus?
    func list(_ url: URL) throws -> [String]?
    func read(_ url: URL, _ body: (UnsafeRawBufferPointer) throws -> Void) throws
}

nonisolated struct LWPosixFileAccess: LWModelFileAccess {
    private static func missing(_ code: Int32) -> Bool { code == ENOENT || code == ENOTDIR }

    func status(_ url: URL) throws -> LWFileStatus? {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            let code = errno
            if Self.missing(code) { return nil }
            throw LWFileAccessError(path: url.path, code: code)
        }
        return LWFileStatus(st)
    }

    func list(_ url: URL) throws -> [String]? {
        guard let dir = opendir(url.path) else {
            let code = errno
            if Self.missing(code) { return nil }
            throw LWFileAccessError(path: url.path, code: code)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    func read(_ url: URL, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw LWFileAccessError(path: url.path, code: errno) }
        defer { close(fd) }
        let capacity = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(fd, buffer, capacity)
            if count < 0 {
                if errno == EINTR { continue }
                throw LWFileAccessError(path: url.path, code: errno)
            }
            if count == 0 { return }
            try body(UnsafeRawBufferPointer(start: buffer, count: count))
        }
    }
}

// MARK: - Bounded probes

nonisolated enum LWProbeError: Error, Equatable {
    /// No progress within the stall window: the read is blocked (typically macOS privacy consent).
    case timedOut(path: String)
    /// A previous probe of this library is still blocked in the kernel; no new thread is started.
    case stillBlocked(path: String)
}

/// Progress signal from a probe thread. The watchdog abandons a probe whose heartbeat stalls.
nonisolated final class LWProbeHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now().uptimeNanoseconds
    private var currentPath = ""
    private var abandoned = false

    /// Records progress (optionally the path about to be touched); throws once abandoned so a
    /// thread that finally unblocks stops instead of doing more work nobody waits for.
    func beat(_ path: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if abandoned { throw CancellationError() }
        last = DispatchTime.now().uptimeNanoseconds
        if let path { currentPath = path }
    }

    var path: String { lock.lock(); defer { lock.unlock() }; return currentPath }
    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
    func abandon() { lock.lock(); abandoned = true; lock.unlock() }
    func stalled(longerThan seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Double(DispatchTime.now().uptimeNanoseconds &- last) / 1e9 > seconds
    }
}

nonisolated enum LWBoundedProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked: Set<String> = []
    nonisolated(unsafe) private static var threadsStarted = 0

    /// Probe threads started so far (tests prove a blocked library does not spawn more).
    static var startedThreadCount: Int { lock.lock(); defer { lock.unlock() }; return threadsStarted }
    static func isBlocked(_ label: String) -> Bool { lock.lock(); defer { lock.unlock() }; return blocked.contains(label) }

    /// Runs `body` on its own thread. Returns its result, or throws `timedOut` when its
    /// heartbeat stalls for `stall` seconds, or `CancellationError` when the task is cancelled.
    /// A timed-out or cancelled thread is abandoned (never joined); while it stays blocked, later
    /// probes with the same `label` fail fast with `stillBlocked`.
    static func run<T: Sendable>(label: String, stall: TimeInterval, _ body: @escaping @Sendable (LWProbeHeartbeat) throws -> T) async throws -> T {
        lock.lock()
        if blocked.contains(label) { lock.unlock(); throw LWProbeError.stillBlocked(path: label) }
        threadsStarted += 1
        lock.unlock()
        let heartbeat = LWProbeHeartbeat()
        let once = LWResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.attach(continuation)
                let thread = Thread {
                    let result = Result { try body(heartbeat) }
                    if !once.resume(result) {
                        // Abandoned earlier: this thread is finally free, so the library may be probed again.
                        lock.lock(); blocked.remove(label); lock.unlock()
                    }
                }
                thread.name = "LensWorks model probe"
                thread.qualityOfService = .utility
                thread.start()
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
                timer.setEventHandler {
                    if once.isDone { timer.cancel(); return }
                    guard heartbeat.stalled(longerThan: stall) else { return }
                    heartbeat.abandon()
                    lock.lock(); blocked.insert(label); lock.unlock()
                    if !once.resume(.failure(LWProbeError.timedOut(path: heartbeat.path.isEmpty ? label : heartbeat.path))) {
                        lock.lock(); blocked.remove(label); lock.unlock()
                    }
                    timer.cancel()
                }
                timer.resume()
            }
        } onCancel: {
            heartbeat.abandon()
            once.resume(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, from whichever of completion, watchdog or cancellation
/// comes first (cancellation may arrive before the continuation is attached).
nonisolated final class LWResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending { lock.unlock(); continuation.resume(with: pending); return }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns whether this call delivered the result.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
        return true
    }
}

// MARK: - Ledger

/// LensWorks-owned record of verification results, measurements and use. It never lives in an
/// external library, whose ownership stays with SceneWorks.
nonisolated struct LWModelLedger: Codable, Sendable, Equatable {
    struct Verified: Codable, Sendable, Equatable {
        var stamp: LWFileStatus.Stamp
        var sha256: String
    }
    struct Measured: Codable, Sendable, Equatable {
        var peakBytes: UInt64
        var residentBytes: UInt64?
        var inferenceRevision: String
        var measuredAt: Date
    }
    var schemaVersion = 1
    /// Keyed by the absolute path of the file as named in its snapshot/managed tree.
    var verified: [String: Verified] = [:]
    /// Keyed by model id; the largest on-device measurement for the current runtime revision.
    var measured: [String: Measured] = [:]
    /// Keyed by managed component directory path.
    var lastUsed: [String: Date] = [:]

    static func load(_ url: URL) -> LWModelLedger {
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(LWModelLedger.self, from: data),
              ledger.schemaVersion == 1 else { return LWModelLedger() }
        return ledger
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - States

nonisolated enum LWModelSource: Sendable, Hashable {
    /// A SceneWorks (Hugging Face cache) library, admitted by reference.
    case sceneWorks(hub: URL)
    case managed
}

nonisolated enum LWLibraryUnavailableReason: Sendable, Hashable {
    case accessDenied
    case timedOut
    case stillBlocked
    case failed(String)
}

nonisolated enum LWModelState: Sendable, Hashable {
    case ready(root: URL, source: LWModelSource)
    case notInstalled
    case partiallyDownloaded(completedBytes: UInt64, totalBytes: UInt64)
    /// The runtime cannot serve this model (revision, route or licence terms disagree).
    case incompatible(String)
    /// A library holds this repository only at other revisions.
    case revisionMismatch(library: URL, found: [String])
    case incomplete(library: URL, missing: [String])
    case integrityFailed(library: URL, path: String, detail: String)
    case libraryUnavailable(library: URL, reason: LWLibraryUnavailableReason)
    case exceedsMemory(required: UInt64, available: UInt64)
    case memoryUnmeasured

    var isReady: Bool { if case .ready = self { return true }; return false }

    /// Whether an explicit user download can fix this state. Never started automatically.
    var canDownload: Bool {
        switch self {
        case .notInstalled, .partiallyDownloaded, .revisionMismatch, .incomplete, .integrityFailed, .libraryUnavailable: return true
        case .ready, .incompatible, .exceedsMemory, .memoryUnmeasured: return false
        }
    }

    var title: String {
        switch self {
        case .ready(_, .sceneWorks): return "Ready (SceneWorks library)"
        case .ready(_, .managed): return "Ready"
        case .notInstalled: return "Not installed"
        case .partiallyDownloaded: return "Download paused"
        case .incompatible: return "Incompatible"
        case .revisionMismatch: return "Different version in library"
        case .incomplete: return "Incomplete in library"
        case .integrityFailed: return "Failed verification"
        case .libraryUnavailable: return "Library unavailable"
        case .exceedsMemory: return "Needs more memory"
        case .memoryUnmeasured: return "Memory need not measured"
        }
    }

    /// What happened and what the person can do about it.
    var message: String {
        let memory = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
        let file = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch self {
        case .ready(let root, .sceneWorks):
            return "Using SceneWorks' copy at \(root.path) in place. LensWorks never modifies or duplicates it."
        case .ready(let root, .managed):
            return "Stored by LensWorks at \(root.path)."
        case .notInstalled:
            return "Not found in any SceneWorks library. Download it explicitly, or add the SceneWorks library that has it."
        case .partiallyDownloaded(let done, let total):
            return "\(file(done)) of \(file(total)) downloaded. Resume to continue from where it stopped."
        case .incompatible(let reason):
            return reason
        case .revisionMismatch(let library, let found):
            return "\(library.path) holds revision \(found.map { String($0.prefix(8)) }.joined(separator: ", ")), not the one LensWorks is qualified with. LensWorks leaves that copy untouched; update it in SceneWorks or download the qualified version explicitly."
        case .incomplete(let library, let missing):
            return "\(library.path) is missing \(missing.joined(separator: ", ")). LensWorks does not repair SceneWorks' library; finish the install in SceneWorks or download a copy explicitly."
        case .integrityFailed(let library, let path, let detail):
            return "\(path) in \(library.path) failed verification (\(detail)). It is not used and was left untouched."
        case .libraryUnavailable(let library, let reason):
            let grant = "Grant LensWorks access in System Settings › Privacy & Security › Files & Folders (or Full Disk Access), then choose Retry. LensWorks will not download a second copy unless you ask it to."
            switch reason {
            case .accessDenied: return "macOS denied access to \(library.path). \(grant)"
            case .timedOut: return "macOS blocked or did not answer a read of \(library.path) in time. \(grant)"
            case .stillBlocked: return "An earlier read of \(library.path) is still waiting on macOS. \(grant)"
            case .failed(let detail): return "\(library.path) could not be read (\(detail)). Check that the volume is connected, then choose Retry."
            }
        case .exceedsMemory(let required, let available):
            return "Needs \(memory(required)) of unified memory at peak; this Mac can give AI work \(memory(available))."
        case .memoryUnmeasured:
            return "This model's memory need has not been measured, so it is not admitted."
        }
    }
}

nonisolated struct LWModelStatus: Sendable, Hashable, Identifiable {
    let model: LWModelManifest.Model
    let state: LWModelState
    /// Measured peak unified-memory need (manifest or this Mac's own larger measurement).
    let requiredMemory: UInt64?
    /// Whether this Mac can admit the model at all. Hidden models are not offered to features.
    let isAdmissible: Bool
    var id: String { model.id }
}

nonisolated struct LWModelLicenseInfo: Sendable, Hashable {
    let key: String
    let declared: String
    let familyName: String
    let textURL: URL?
    let sourceURL: URL?
    let gated: Bool
    let attribution: String?
}

nonisolated struct LWDownloadPlan: Sendable, Hashable {
    let modelID: String
    /// Bytes still to transfer (partial files count as already transferred).
    let remainingBytes: UInt64
    let totalBytes: UInt64
    let destination: URL
    let licenses: [LWModelLicenseInfo]
    let licenseNote: String?
}

nonisolated struct LWDownloadProgress: Sendable, Hashable {
    enum Phase: Sendable, Hashable { case downloading, verifying, publishing }
    let modelID: String
    let phase: Phase
    let completedBytes: UInt64
    let totalBytes: UInt64
    let file: String
    var fraction: Double { totalBytes == 0 ? 0 : min(1, Double(completedBytes) / Double(totalBytes)) }
}

nonisolated enum LWModelStoreError: Error, Equatable, CustomStringConvertible {
    case manifest(String)
    case unknownModel(String)
    case notReady(String, LWModelState)
    case notAdmissible(String, LWModelState)
    case leased(String)
    case externallyOwned(String)
    case alreadyAvailable(String)
    case downloadInProgress(String)
    case licenseNotAccepted(String)
    case insufficientSpace(needed: UInt64, available: UInt64)
    case http(status: Int, path: String)
    case interrupted(path: String, detail: String)
    case integrity(path: String, detail: String)
    case io(String)

    var description: String {
        let file = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch self {
        case .manifest(let message), .io(let message): return message
        case .unknownModel(let id): return "Unknown model \(id)."
        case .notReady(let id, let state): return "\(id) is not ready: \(state.message)"
        case .notAdmissible(let id, let state): return "\(id) cannot be admitted on this Mac: \(state.message)"
        case .leased(let id): return "\(id) is in use by an AI task; it cannot be removed until the task finishes."
        case .externallyOwned(let id): return "\(id) is used from a SceneWorks library, which LensWorks never deletes."
        case .alreadyAvailable(let id): return "\(id) is already available; nothing to download."
        case .downloadInProgress(let id): return "\(id) is already downloading."
        case .licenseNotAccepted(let id): return "Review and accept the licence terms for \(id) before downloading."
        case .insufficientSpace(let needed, let available): return "Needs \(file(needed)) free; \(file(available)) available."
        case .http(let status, let path): return "The server answered \(status) for \(path)."
        case .interrupted(let path, let detail): return "The download of \(path) was interrupted (\(detail)). Resume to continue."
        case .integrity(let path, let detail): return "\(path) failed verification (\(detail)); the download was discarded and nothing was installed."
        }
    }
}

// MARK: - Memory budget

nonisolated enum LWMemoryBudget {
    /// Unified memory the GPU may use on this Mac (Metal's recommended working-set size), the
    /// ceiling a model's measured peak must fit under.
    static func current() -> UInt64 {
        if let device = MTLCreateSystemDefaultDevice(), device.recommendedMaxWorkingSetSize > 0 {
            return device.recommendedMaxWorkingSetSize
        }
        return ProcessInfo.processInfo.physicalMemory / 4 * 3
    }
}

// MARK: - Leases

nonisolated final class LWModelLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func acquire(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
    func release(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        guard let count = counts[path] else { return }
        counts[path] = count > 1 ? count - 1 : nil
    }
    func isLeased(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return counts[path] != nil }
}

/// An admitted model held by an AI task. While any lease exists the model's files cannot be
/// deleted or evicted. Released explicitly or on deinit.
nonisolated final class LWModelLease: @unchecked Sendable {
    let modelID: String
    let root: URL
    let source: LWModelSource
    let weights: LWInferenceWeights
    let tokenizer: URL?
    private let registry: LWModelLeaseRegistry
    private let lock = NSLock()
    private var released = false

    init(modelID: String, root: URL, source: LWModelSource, weights: LWInferenceWeights, tokenizer: URL?, registry: LWModelLeaseRegistry) {
        self.modelID = modelID; self.root = root; self.source = source; self.weights = weights; self.tokenizer = tokenizer
        self.registry = registry
        registry.acquire(root.path)
    }

    func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first { registry.release(root.path) }
    }

    deinit { release() }
}

// MARK: - Probing

nonisolated enum LWComponentOutcome: Sendable {
    case ready(root: URL, verified: [String: LWModelLedger.Verified])
    case absent
    case revisionMismatch([String])
    case incomplete([String])
    case integrity(path: String, detail: String)
}

nonisolated enum LWModelProbe {
    static func hubSnapshot(_ hub: URL, _ component: LWModelManifest.Component) -> URL {
        // Explicit `isDirectory: false` keeps root URLs byte-identical whether or not the directory
        // exists yet (the filesystem-probing overload would add a trailing slash once it does).
        hub.appendingPathComponent(component.hubDirectoryName).appendingPathComponent("snapshots")
            .appendingPathComponent(component.revision, isDirectory: false)
    }

    /// Probes one SceneWorks (Hugging Face cache) library for a component. Read-only.
    static func probeHub(_ hub: URL, _ component: LWModelManifest.Component, fs: any LWModelFileAccess,
                         verified: [String: LWModelLedger.Verified], heartbeat: LWProbeHeartbeat) throws -> LWComponentOutcome {
        try heartbeat.beat(hub.path)
        guard try fs.status(hub)?.isDirectory == true else { return .absent }
        let repository = hub.appendingPathComponent(component.hubDirectoryName)
        try heartbeat.beat(repository.path)
        guard try fs.status(repository)?.isDirectory == true else { return .absent }
        let snapshot = hubSnapshot(hub, component)
        try heartbeat.beat(snapshot.path)
        guard try fs.status(snapshot)?.isDirectory == true else {
            let others = (try fs.list(repository.appendingPathComponent("snapshots")) ?? [])
                .filter { $0 != component.revision && !$0.hasPrefix(".") }.sorted()
            return others.isEmpty ? .absent : .revisionMismatch(others)
        }
        return try verify(root: snapshot, component, fs: fs, verified: verified, heartbeat: heartbeat)
    }

    /// Verifies every file of a component under `root`: presence, size, then content hash,
    /// skipping the hash when the ledger holds a verification for the file's unchanged identity.
    static func verify(root: URL, _ component: LWModelManifest.Component, fs: any LWModelFileAccess,
                       verified: [String: LWModelLedger.Verified], heartbeat: LWProbeHeartbeat) throws -> LWComponentOutcome {
        var statuses: [(LWModelManifest.File, URL, LWFileStatus)] = []
        var missing: [String] = []
        for file in component.files {
            let url = root.appendingPathComponent(file.path)
            try heartbeat.beat(url.path)
            guard let status = try fs.status(url), !status.isDirectory else { missing.append(file.path); continue }
            guard status.size == file.size else {
                return .integrity(path: file.path, detail: "\(status.size) bytes, expected \(file.size)")
            }
            statuses.append((file, url, status))
        }
        if !missing.isEmpty { return .incomplete(missing) }
        var confirmed: [String: LWModelLedger.Verified] = [:]
        for (file, url, status) in statuses {
            if let record = verified[url.path], record.stamp == status.stamp, record.sha256 == file.sha256 {
                confirmed[url.path] = record
                continue
            }
            let digest = try sha256(url, fs: fs, heartbeat: heartbeat)
            guard digest == file.sha256 else { return .integrity(path: file.path, detail: "content hash differs from the qualified file") }
            // Re-stat after hashing: a file replaced while it was read must not be recorded.
            guard let after = try fs.status(url), after.stamp == status.stamp else {
                return .integrity(path: file.path, detail: "the file changed while it was verified")
            }
            confirmed[url.path] = .init(stamp: status.stamp, sha256: digest)
        }
        return .ready(root: root, verified: confirmed)
    }

    static func sha256(_ url: URL, fs: any LWModelFileAccess, heartbeat: LWProbeHeartbeat) throws -> String {
        var hasher = SHA256()
        try heartbeat.beat(url.path)
        try fs.read(url) { chunk in
            try heartbeat.beat()
            hasher.update(bufferPointer: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stats every file and reports whether all identities still match the ledger.
    static func identitiesUnchanged(root: URL, _ component: LWModelManifest.Component, fs: any LWModelFileAccess,
                                    verified: [String: LWModelLedger.Verified], heartbeat: LWProbeHeartbeat) throws -> Bool {
        for file in component.files {
            let url = root.appendingPathComponent(file.path)
            try heartbeat.beat(url.path)
            guard let status = try fs.status(url), let record = verified[url.path],
                  record.stamp == status.stamp, record.sha256 == file.sha256 else { return false }
        }
        return true
    }
}

// MARK: - Store

/// The model store. Admission never writes to, copies from, or deletes inside an external
/// SceneWorks library, and never starts a download on its own.
actor LWModelStore {
    struct Configuration: Sendable {
        var sceneWorksLibraries: [URL]
        var managedRoot: URL
        var ledgerURL: URL
        var availableMemory: UInt64
        var probeStall: TimeInterval = 15
        var downloadBaseURL: URL?
        var requestTimeout: TimeInterval = 60

        /// SceneWorks' Hugging Face cache (HF_HUB_CACHE, HF_HOME/hub, or ~/.cache/huggingface/hub)
        /// plus libraries the person added.
        static func defaultLibraries(environment: [String: String] = ProcessInfo.processInfo.environment, added: [URL] = []) -> [URL] {
            let hub: URL
            if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty {
                hub = URL(fileURLWithPath: cache, isDirectory: true)
            } else if let home = environment["HF_HOME"], !home.isEmpty {
                hub = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub")
            } else {
                hub = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub")
            }
            var seen = Set<String>()
            return ([hub] + added).filter { seen.insert($0.standardizedFileURL.path).inserted }
        }

        static func application(added: [URL] = []) -> Configuration {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LensWorks")
            return Configuration(sceneWorksLibraries: defaultLibraries(added: added), managedRoot: support.appendingPathComponent("Models"),
                                 ledgerURL: support.appendingPathComponent("ModelStore.json"), availableMemory: LWMemoryBudget.current())
        }
    }

    let manifest: LWModelManifest
    private(set) var configuration: Configuration
    private let facts: LWModelRuntimeFacts?
    private let factsError: String?
    private let fs: any LWModelFileAccess
    nonisolated let leases: LWModelLeaseRegistry
    private var ledger: LWModelLedger
    private var statuses: [String: LWModelStatus] = [:]
    private var downloading: Set<String> = []
    private let session: URLSession

    init(manifest: LWModelManifest, configuration: Configuration, facts: LWModelRuntimeFacts?, factsError: String? = nil,
         fileAccess: any LWModelFileAccess = LWPosixFileAccess(), leases: LWModelLeaseRegistry = LWModelLeaseRegistry()) {
        self.manifest = manifest
        self.configuration = configuration
        self.facts = facts
        self.factsError = factsError
        self.fs = fileAccess
        self.leases = leases
        self.ledger = LWModelLedger.load(configuration.ledgerURL)
        let session = URLSessionConfiguration.ephemeral
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.urlCache = nil
        session.timeoutIntervalForRequest = configuration.requestTimeout
        session.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: session)
    }

    deinit { session.invalidateAndCancel() }

    var ledgerSnapshot: LWModelLedger { ledger }

    func setSceneWorksLibraries(_ libraries: [URL]) {
        configuration.sceneWorksLibraries = libraries
        statuses = [:]
    }

    private func model(_ id: String) throws -> LWModelManifest.Model {
        guard let model = manifest.models.first(where: { $0.id == id }) else { throw LWModelStoreError.unknownModel(id) }
        return model
    }

    func managedRoot(_ component: LWModelManifest.Component) -> URL {
        configuration.managedRoot.appendingPathComponent(component.managedDirectoryName).appendingPathComponent(component.revision, isDirectory: false)
    }

    private func stagingRoot(_ component: LWModelManifest.Component) -> URL {
        configuration.managedRoot.appendingPathComponent(".staging").appendingPathComponent("\(component.managedDirectoryName)@\(component.revision)")
    }

    // MARK: Admission

    func requiredMemory(_ model: LWModelManifest.Model) -> UInt64? {
        let local = ledger.measured[model.id].flatMap { $0.inferenceRevision == facts?.inferenceRevision ? $0.peakBytes : nil }
        switch (model.memory.peakBytes, local) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return max(a, b)
        }
    }

    private func runtimeIncompatibility(_ model: LWModelManifest.Model) -> String? {
        guard let facts else { return "The AI runtime is unavailable\(factsError.map { ": \($0)" } ?? ".")" }
        if facts.inferenceRevision != manifest.inferenceRevision {
            return "Qualified for inference \(manifest.inferenceRevision.prefix(8)); this build runs \(facts.inferenceRevision.prefix(8)). Update LensWorks."
        }
        if let route = model.routes.first(where: { !facts.routes.contains($0.key) }) {
            return "The AI runtime does not serve \(route.task) with \(route.provider)."
        }
        for license in model.licenseComponents {
            guard let row = facts.licenses[license.key] else { return "The runtime has no licence terms for \(license.key)." }
            if row.declared != license.declared {
                return "Licence terms for \(license.key) changed (now \(row.declared), qualified as \(license.declared)); the model is not admitted until LensWorks is requalified."
            }
        }
        return nil
    }

    /// Re-probes every model. Models this Mac cannot admit are reported but never probed.
    @discardableResult
    func refresh() async -> [LWModelStatus] {
        var result: [LWModelStatus] = []
        for model in manifest.models {
            result.append(await refresh(model))
        }
        return result
    }

    func status(_ id: String) async throws -> LWModelStatus {
        if let status = statuses[id] { return status }
        return await refresh(try model(id))
    }

    /// Models this Mac can admit (the ones features may offer).
    func admissibleStatuses() async -> [LWModelStatus] {
        await refresh().filter(\.isAdmissible)
    }

    @discardableResult
    func refresh(_ model: LWModelManifest.Model) async -> LWModelStatus {
        let required = requiredMemory(model)
        let state: LWModelState
        if let reason = runtimeIncompatibility(model) {
            state = .incompatible(reason)
        } else if required == nil {
            state = .memoryUnmeasured
        } else if let required, required > configuration.availableMemory {
            state = .exceedsMemory(required: required, available: configuration.availableMemory)
        } else {
            state = await probe(model)
        }
        let admissible: Bool
        switch state {
        case .exceedsMemory, .memoryUnmeasured, .incompatible: admissible = false
        default: admissible = true
        }
        let status = LWModelStatus(model: model, state: state, requiredMemory: required, isAdmissible: admissible)
        statuses[model.id] = status
        return status
    }

    private func probe(_ model: LWModelManifest.Model) async -> LWModelState {
        var roots: [URL] = []
        var source: LWModelSource?
        for component in model.components {
            switch await probeComponent(component) {
            case .success(let found):
                roots.append(found.0)
                if source == nil || found.1 == .managed { source = found.1 }
            case .failure(let failure):
                return failure.state
            }
        }
        return .ready(root: roots[0], source: source ?? .managed)
    }

    private struct ProbeFailure: Error { let state: LWModelState }

    /// SceneWorks libraries first (reuse in place), then the managed store; otherwise the most
    /// actionable library state, then any partial download, then not installed.
    private func probeComponent(_ component: LWModelManifest.Component) async -> Result<(URL, LWModelSource), ProbeFailure> {
        var best: (LWModelState, Int)?
        func consider(_ state: LWModelState, _ rank: Int) { if best.map({ rank > $0.1 }) ?? true { best = (state, rank) } }
        for hub in configuration.sceneWorksLibraries {
            let verified = ledger.verified
            let fs = self.fs
            do {
                let outcome = try await LWBoundedProbe.run(label: hub.path, stall: configuration.probeStall) { heartbeat in
                    try LWModelProbe.probeHub(hub, component, fs: fs, verified: verified, heartbeat: heartbeat)
                }
                switch outcome {
                case .ready(let root, let confirmed):
                    record(confirmed)
                    return .success((root, .sceneWorks(hub: hub)))
                case .absent: break
                case .revisionMismatch(let found): consider(.revisionMismatch(library: hub, found: found), 1)
                case .incomplete(let missing): consider(.incomplete(library: hub, missing: missing), 2)
                case .integrity(let path, let detail):
                    forget(under: LWModelProbe.hubSnapshot(hub, component))
                    consider(.integrityFailed(library: hub, path: path, detail: detail), 3)
                }
            } catch {
                consider(.libraryUnavailable(library: hub, reason: Self.reason(error)), 4)
            }
        }
        let managed = managedRoot(component)
        let verified = ledger.verified
        let fs = self.fs
        do {
            let outcome = try await LWBoundedProbe.run(label: configuration.managedRoot.path, stall: configuration.probeStall) { heartbeat in
                try heartbeat.beat(managed.path)
                guard try fs.status(managed)?.isDirectory == true else { return LWComponentOutcome.absent }
                return try LWModelProbe.verify(root: managed, component, fs: fs, verified: verified, heartbeat: heartbeat)
            }
            switch outcome {
            case .ready(let root, let confirmed):
                record(confirmed)
                return .success((root, .managed))
            case .absent, .revisionMismatch: break
            case .incomplete(let missing): consider(.incomplete(library: configuration.managedRoot, missing: missing), 2)
            case .integrity(let path, let detail):
                forget(under: managed)
                consider(.integrityFailed(library: configuration.managedRoot, path: path, detail: detail), 3)
            }
        } catch {
            consider(.libraryUnavailable(library: configuration.managedRoot, reason: Self.reason(error)), 4)
        }
        if let best { return .failure(ProbeFailure(state: best.0)) }
        let partial = partialBytes(component)
        return .failure(ProbeFailure(state: partial > 0 ? .partiallyDownloaded(completedBytes: partial, totalBytes: component.totalBytes) : .notInstalled))
    }

    private static func reason(_ error: Error) -> LWLibraryUnavailableReason {
        switch error {
        case LWProbeError.timedOut: return .timedOut
        case LWProbeError.stillBlocked: return .stillBlocked
        case let error as LWFileAccessError where error.isDenied: return .accessDenied
        default: return .failed(String(describing: error))
        }
    }

    private func record(_ confirmed: [String: LWModelLedger.Verified]) {
        var changed = false
        for (path, record) in confirmed where ledger.verified[path] != record {
            ledger.verified[path] = record
            changed = true
        }
        if changed { persist() }
    }

    private func forget(under root: URL) {
        let prefix = root.path + "/"
        let before = ledger.verified.count
        ledger.verified = ledger.verified.filter { !$0.key.hasPrefix(prefix) }
        if ledger.verified.count != before { persist() }
    }

    private func persist() {
        try? ledger.save(configuration.ledgerURL)
    }

    // MARK: Leases

    /// Leases a ready model for an AI task. File identities are re-checked first; a file changed
    /// since verification is re-verified (or the lease is refused), never trusted.
    func lease(_ id: String) async throws -> LWModelLease {
        let model = try model(id)
        var status = try await status(id)
        if case .ready(let root, let source) = status.state {
            let verified = ledger.verified
            let fs = self.fs
            let components = model.components
            let roots: [URL] = [root] + components.dropFirst().map { component in
                if case .sceneWorks(let hub) = source { return LWModelProbe.hubSnapshot(hub, component) }
                return managedRoot(component)
            }
            let unchanged = (try? await LWBoundedProbe.run(label: root.path, stall: configuration.probeStall) { heartbeat in
                try zip(roots, components).allSatisfy { try LWModelProbe.identitiesUnchanged(root: $0, $1, fs: fs, verified: verified, heartbeat: heartbeat) }
            }) ?? false
            if !unchanged { status = await refresh(model) }
        } else {
            status = await refresh(model)
        }
        guard status.isAdmissible else { throw LWModelStoreError.notAdmissible(id, status.state) }
        guard case .ready(let root, let source) = status.state else { throw LWModelStoreError.notReady(id, status.state) }
        let weightsURL = model.weights.path.isEmpty ? root : root.appendingPathComponent(model.weights.path)
        let weights: LWInferenceWeights = model.weights.kind == .dir ? .dir(weightsURL) : .file(weightsURL)
        if source == .managed { ledger.lastUsed[root.path] = Date(); persist() }
        return LWModelLease(modelID: id, root: root, source: source, weights: weights,
                            tokenizer: model.weights.tokenizer.map { root.appendingPathComponent($0) }, registry: leases)
    }

    /// Records the measured memory of a completed fresh-load job, so admission uses this Mac's
    /// own measurement when it exceeds the manifest's.
    func recordMeasurement(modelID: String, peakBytes: UInt64, residentBytes: UInt64?, inferenceRevision: String) {
        guard manifest.models.contains(where: { $0.id == modelID }), inferenceRevision == facts?.inferenceRevision else { return }
        if let existing = ledger.measured[modelID], existing.inferenceRevision == inferenceRevision, existing.peakBytes >= peakBytes { return }
        ledger.measured[modelID] = .init(peakBytes: peakBytes, residentBytes: residentBytes, inferenceRevision: inferenceRevision, measuredAt: Date())
        persist()
        statuses[modelID] = nil
    }

    func recordMeasurement(modelID: String, result: LWInferenceResult) {
        guard !result.modelReused, let memory = result.memory else { return }
        recordMeasurement(modelID: modelID, peakBytes: memory.peakBytes, residentBytes: memory.activeBytes, inferenceRevision: result.inferenceRevision)
    }

    // MARK: Deletion and eviction

    /// Deletes LensWorks' own copy of a model. Never touches SceneWorks libraries; refused while leased.
    func deleteManagedCopy(_ id: String) async throws {
        let model = try model(id)
        let roots = model.components.map { managedRoot($0) }
        let present = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        if present.isEmpty, case .ready(_, .sceneWorks) = try await status(id).state { throw LWModelStoreError.externallyOwned(id) }
        if present.contains(where: { leases.isLeased($0.path) }) { throw LWModelStoreError.leased(id) }
        for root in present { try remove(root) }
        for component in model.components { try? FileManager.default.removeItem(at: stagingRoot(component)) }
        await refresh(model)
    }

    /// Frees at least `bytes` by deleting least-recently-used managed copies that are not leased.
    /// Returns the evicted model ids. SceneWorks libraries are never evicted.
    func evictManaged(toFree bytes: UInt64) async -> [String] {
        var candidates: [(model: LWModelManifest.Model, roots: [URL], used: Date)] = []
        for model in manifest.models {
            let roots = model.components.map { managedRoot($0) }
            guard roots.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
                  !roots.contains(where: { leases.isLeased($0.path) }) else { continue }
            let used = roots.compactMap { ledger.lastUsed[$0.path] }.max() ?? .distantPast
            candidates.append((model, roots, used))
        }
        var freed: UInt64 = 0
        var evicted: [String] = []
        for candidate in candidates.sorted(by: { $0.used < $1.used }) where freed < bytes {
            guard !candidate.roots.contains(where: { leases.isLeased($0.path) }) else { continue }
            do {
                for root in candidate.roots { try remove(root) }
                freed += candidate.model.totalBytes
                evicted.append(candidate.model.id)
                await refresh(candidate.model)
            } catch { continue }
        }
        return evicted
    }

    /// Moves a managed directory out of the published tree atomically, then deletes it.
    private func remove(_ root: URL) throws {
        let trash = configuration.managedRoot.appendingPathComponent(".trash").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(root.path, trash.path) == 0 else { throw LWModelStoreError.io("Could not remove \(root.path): \(String(cString: strerror(errno)))") }
        forget(under: root)
        ledger.lastUsed[root.path] = nil
        persist()
        try? FileManager.default.removeItem(at: trash)
    }

    // MARK: Downloads

    private func partialBytes(_ component: LWModelManifest.Component) -> UInt64 {
        let staging = stagingRoot(component)
        func size(_ path: String) -> UInt64? { (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 }
        return component.files.reduce(0) { total, file in
            let final = staging.appendingPathComponent(file.path).path
            return total + min(size(final) ?? size(final + ".part") ?? 0, file.size)
        }
    }

    func downloadPlan(_ id: String) throws -> LWDownloadPlan {
        let model = try model(id)
        let licenses = model.licenseComponents.map { license -> LWModelLicenseInfo in
            let row = facts?.licenses[license.key]
            return LWModelLicenseInfo(key: license.key, declared: row?.declared ?? license.declared, familyName: row?.familyName ?? license.declared,
                                      textURL: row?.textURL, sourceURL: row?.sourceURL, gated: row?.gated ?? false, attribution: row?.attribution)
        }
        let partial = model.components.reduce(0) { $0 + partialBytes($1) }
        return LWDownloadPlan(modelID: id, remainingBytes: model.totalBytes - min(partial, model.totalBytes), totalBytes: model.totalBytes,
                              destination: managedRoot(model.components[0]), licenses: licenses, licenseNote: model.licenseNote)
    }

    /// Explicitly downloads a model into the managed store. Cancel by cancelling the calling
    /// task: partial files stay for `download` to resume with HTTP Range requests. Each file is
    /// size- and hash-verified; the component directory is published by one atomic rename only
    /// when every file verified, so a failed, corrupt or interrupted download is never visible.
    @discardableResult
    func download(_ id: String, licenseAccepted: Bool,
                  progress: @escaping @Sendable (LWDownloadProgress) -> Void = { _ in }) async throws -> LWModelStatus {
        let model = try model(id)
        guard licenseAccepted else { throw LWModelStoreError.licenseNotAccepted(id) }
        guard !downloading.contains(id) else { throw LWModelStoreError.downloadInProgress(id) }
        downloading.insert(id)
        defer { downloading.remove(id) }
        let current = await refresh(model)
        guard current.isAdmissible else { throw LWModelStoreError.notAdmissible(id, current.state) }
        if current.state.isReady { throw LWModelStoreError.alreadyAvailable(id) }

        let plan = try downloadPlan(id)
        try FileManager.default.createDirectory(at: configuration.managedRoot, withIntermediateDirectories: true)
        let free = (try? configuration.managedRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        if let free, free < plan.remainingBytes { throw LWModelStoreError.insufficientSpace(needed: plan.remainingBytes, available: free) }

        let base = configuration.downloadBaseURL ?? manifest.downloadBaseURL
        let total = model.totalBytes
        var completedBefore: UInt64 = 0
        for component in model.components {
            let destination = managedRoot(component)
            if FileManager.default.fileExists(atPath: destination.path) {
                completedBefore += component.totalBytes
                continue
            }
            let staging = stagingRoot(component)
            for file in component.files {
                try Task.checkCancellation()
                let final = staging.appendingPathComponent(file.path)
                let part = URL(fileURLWithPath: final.path + ".part")
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let offset = completedBefore
                if !FileManager.default.fileExists(atPath: final.path) {
                    let url = base.appendingPathComponent(component.repository).appendingPathComponent("resolve")
                        .appendingPathComponent(component.revision).appendingPathComponent(file.path)
                    try await LWRangeDownload.fetch(session: session, url: url, part: part, expected: file.size, path: file.path) { written in
                        progress(.init(modelID: id, phase: .downloading, completedBytes: offset + written, totalBytes: total, file: file.path))
                    }
                    progress(.init(modelID: id, phase: .verifying, completedBytes: offset + file.size, totalBytes: total, file: file.path))
                    let digest = try await Self.hash(part)
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: part)
                        throw LWModelStoreError.integrity(path: file.path, detail: "content hash differs from the qualified file")
                    }
                    guard rename(part.path, final.path) == 0 else { throw LWModelStoreError.io("Could not finish \(file.path): \(String(cString: strerror(errno)))") }
                } else {
                    // Verified in an earlier (interrupted) run; re-verify before publishing.
                    let digest = try await Self.hash(final)
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: final)
                        throw LWModelStoreError.integrity(path: file.path, detail: "a staged file changed; it was discarded")
                    }
                }
                completedBefore += file.size
            }
            progress(.init(modelID: id, phase: .publishing, completedBytes: completedBefore, totalBytes: total, file: ""))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard rename(staging.path, destination.path) == 0 else {
                throw LWModelStoreError.io("Could not publish \(component.repository): \(String(cString: strerror(errno)))")
            }
            var confirmed: [String: LWModelLedger.Verified] = [:]
            for file in component.files {
                let url = destination.appendingPathComponent(file.path)
                if let status = try? fs.status(url) { confirmed[url.path] = .init(stamp: status.stamp, sha256: file.sha256) }
            }
            record(confirmed)
            ledger.lastUsed[destination.path] = Date()
            persist()
        }
        return await refresh(model)
    }

    private static func hash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            var hasher = SHA256()
            try LWPosixFileAccess().read(url) { chunk in
                if Task.isCancelled { throw CancellationError() }
                hasher.update(bufferPointer: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

// MARK: - Range download

/// One file transfer into `part`, resuming from its current size with an HTTP Range request.
nonisolated final class LWRangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let part: URL
    private let expected: UInt64
    private let path: String
    private let onBytes: @Sendable (UInt64) -> Void
    private var handle: FileHandle?
    private var written: UInt64
    private var failure: LWModelStoreError?
    private var alreadyComplete = false
    private let once = LWResumeOnce<Void>()

    private init(part: URL, offset: UInt64, expected: UInt64, path: String, onBytes: @escaping @Sendable (UInt64) -> Void) {
        self.part = part; self.written = offset; self.expected = expected; self.path = path; self.onBytes = onBytes
    }

    static func fetch(session: URLSession, url: URL, part: URL, expected: UInt64, path: String,
                      onBytes: @escaping @Sendable (UInt64) -> Void) async throws {
        func size() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? UInt64) ?? 0 }
        var offset = size()
        if offset > expected { try? FileManager.default.removeItem(at: part); offset = 0 }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        if offset == expected { return }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let transfer = LWRangeDownload(part: part, offset: offset, expected: expected, path: path, onBytes: onBytes)
        onBytes(offset)
        let task = session.dataTask(with: request)
        task.delegate = transfer
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transfer.once.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        let received = size()
        guard received == expected else {
            throw LWModelStoreError.interrupted(path: path, detail: "received \(received) of \(expected) bytes")
        }
    }

    private func fail(_ error: LWModelStoreError) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(.http(status: 0, path: path)); completionHandler(.cancel); return }
        lock.lock()
        let offset = written
        lock.unlock()
        switch http.statusCode {
        case 206:
            // Content-Range: bytes <start>-<end>/<total>
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }
            guard numbers.count == 3, numbers[0] == offset, numbers[2] == expected else {
                fail(.integrity(path: path, detail: "the server resumed at an unexpected range (\(range))"))
                completionHandler(.cancel); return
            }
        case 200:
            // The server ignored the range: start the file over.
            if http.expectedContentLength >= 0, UInt64(http.expectedContentLength) != expected {
                fail(.integrity(path: path, detail: "the server offered \(http.expectedContentLength) bytes, expected \(expected)"))
                completionHandler(.cancel); return
            }
            do {
                let truncate = try FileHandle(forWritingTo: part)
                try truncate.truncate(atOffset: 0)
                try truncate.close()
            } catch { fail(.io("Could not restart \(path): \(error)")); completionHandler(.cancel); return }
            lock.lock(); written = 0; lock.unlock()
            onBytes(0)
        case 416:
            lock.lock(); alreadyComplete = true; lock.unlock()
            completionHandler(.cancel); return
        default:
            fail(.http(status: http.statusCode, path: path))
            completionHandler(.cancel); return
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
            lock.lock(); self.handle = handle; lock.unlock()
        } catch { fail(.io("Could not write \(path): \(error)")); completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let handle, failure == nil else { lock.unlock(); return }
        if written + UInt64(data.count) > expected {
            lock.unlock()
            fail(.integrity(path: path, detail: "the server sent more than \(expected) bytes"))
            dataTask.cancel(); return
        }
        do { try handle.write(contentsOf: data) } catch {
            lock.unlock(); fail(.io("Could not write \(path): \(error)")); dataTask.cancel(); return
        }
        written += UInt64(data.count)
        let now = written
        lock.unlock()
        onBytes(now)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let failure = self.failure
        let alreadyComplete = self.alreadyComplete
        lock.unlock()
        if let failure {
            if case .integrity = failure { try? FileManager.default.removeItem(at: part) }
            once.resume(.failure(failure)); return
        }
        if alreadyComplete { once.resume(.success(())); return }
        if let error = error as? URLError {
            if error.code == .cancelled { once.resume(.failure(CancellationError())); return }
            once.resume(.failure(LWModelStoreError.interrupted(path: path, detail: error.localizedDescription))); return
        }
        if let error { once.resume(.failure(LWModelStoreError.interrupted(path: path, detail: error.localizedDescription))); return }
        once.resume(.success(()))
    }
}
