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
        /// The output pixel count the peak was measured at; larger requests are refused.
        let pixels: Int?
    }
    /// The licence SceneWorks' own licence manifest (apps/desktop/licenses/manifest.json)
    /// declares for the model, a second declared source next to the runtime's table.
    struct SceneWorksLicense: Decodable, Sendable, Hashable {
        let id: String
        let name: String
        let homepage: String?
        let nonCommercial: Bool
    }
    struct Model: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let summary: String
        let routes: [Route]
        let weights: Weights
        let licenseComponents: [LicenseComponent]
        let licenseNote: String?
        let sceneWorksLicense: SceneWorksLicense?
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
        var pixels: Int?
    }
    var schemaVersion = 1
    /// Keyed by the absolute path of the file as named in its snapshot/managed tree.
    var verified: [String: Verified] = [:]
    /// Keyed by model id; the largest on-device measurement for the current runtime revision.
    var measured: [String: Measured] = [:]
    /// Keyed by managed component directory path.
    var lastUsed: [String: Date] = [:]
    /// Keyed by model id: the licence-terms version the person accepted. A changed version
    /// (any declared source changed) is not accepted until the person accepts it again.
    var licenseAcceptances: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, verified, measured, lastUsed, licenseAcceptances }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        verified = try c.decodeIfPresent([String: Verified].self, forKey: .verified) ?? [:]
        measured = try c.decodeIfPresent([String: Measured].self, forKey: .measured) ?? [:]
        lastUsed = try c.decodeIfPresent([String: Date].self, forKey: .lastUsed) ?? [:]
        licenseAcceptances = try c.decodeIfPresent([String: String].self, forKey: .licenseAcceptances) ?? [:]
    }

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
            return "Needs \(memory(required)) of unified memory at peak plus \(memory(LWMemoryBudget.headroom(available))) headroom; this Mac can give AI work \(memory(available))."
        case .memoryUnmeasured:
            return "This model's memory need has not been measured, so it is not admitted."
        }
    }
}

/// Where one component of a ready model lives.
nonisolated struct LWComponentRoot: Sendable, Hashable {
    let root: URL
    let source: LWModelSource
}

nonisolated struct LWModelStatus: Sendable, Hashable, Identifiable {
    let model: LWModelManifest.Model
    let state: LWModelState
    /// Measured peak unified-memory need (manifest or this Mac's own larger measurement).
    let requiredMemory: UInt64?
    /// Whether this Mac can admit the model at all. Hidden models are not offered to features.
    let isAdmissible: Bool
    /// Every component's root when ready (components may come from different libraries).
    let roots: [LWComponentRoot]
    /// Whether any LensWorks-managed component directory exists (ready or not), so it can be removed.
    let hasManagedCopy: Bool
    let license: LWModelLicenseTerms
    /// Whether the person accepted the current version of the licence terms.
    let licenseAccepted: Bool
    var id: String { model.id }
    /// Non-commercial terms must be acknowledged before the model is used.
    var needsLicenseAcknowledgement: Bool { license.nonCommercial && !licenseAccepted }
}

/// One declared licence source for a model: a runtime licence-table row or SceneWorks' licence manifest.
nonisolated struct LWModelLicenseSource: Sendable, Hashable {
    enum Origin: String, Sendable, Hashable {
        case runtime = "AI runtime licence table"
        case sceneWorks = "SceneWorks licence manifest"
    }
    let origin: Origin
    let key: String
    let name: String
    let declared: String?
    let textURL: URL?
    let sourceURL: URL?
    let gated: Bool
    let attribution: String?
    let nonCommercial: Bool

    var summary: String {
        var text = name
        if let declared, declared != name { text += " (declared “\(declared)”)" }
        if nonCommercial { text += " — non-commercial" }
        if gated { text += " — gated upstream" }
        return "\(text) [\(origin.rawValue): \(key)]"
    }
}

/// Every declared licence for a model and the terms LensWorks treats as governing.
nonisolated struct LWModelLicenseTerms: Sendable, Hashable {
    let sources: [LWModelLicenseSource]
    /// The model's own note (for example why no licence is declared).
    let note: String?
    /// Identifies these exact terms; acceptance is recorded against it.
    let version: String

    var runtimeDeclared: Bool { sources.contains { $0.origin == .runtime } }
    /// The most restrictive declared terms govern: any non-commercial source makes the model non-commercial.
    var nonCommercial: Bool { sources.contains(where: \.nonCommercial) }
    /// Declared sources disagree about commercial use.
    var conflict: String? {
        guard nonCommercial, sources.contains(where: { !$0.nonCommercial }) else { return nil }
        let restrictive = sources.filter(\.nonCommercial).map { "\($0.name) (\($0.origin.rawValue))" }
        let permissive = sources.filter { !$0.nonCommercial }.map { "\($0.name) (\($0.origin.rawValue))" }
        return "The declared licences conflict: \(permissive.joined(separator: ", ")) versus \(restrictive.joined(separator: ", ")). LensWorks treats the most restrictive terms — non-commercial use only — as governing."
    }
    var governing: String {
        if nonCommercial { return "Non-commercial use only." }
        return runtimeDeclared ? "As declared below." : "Licence not declared by the AI runtime."
    }

    init(sources: [LWModelLicenseSource], note: String?) {
        self.sources = sources
        self.note = note
        let canonical = sources.map { "\($0.origin.rawValue)|\($0.key)|\($0.name)|\($0.declared ?? "")|\($0.nonCommercial)|\($0.gated)" }
            .joined(separator: "\n") + "\n" + (note ?? "")
        version = SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isNonCommercial(_ texts: String?...) -> Bool {
        texts.compactMap { $0?.lowercased() }.contains { text in
            text.contains("non-commercial") || text.contains("noncommercial") || text.contains("-nc-") || text.hasSuffix("-nc")
                || text.contains("research license") || text.contains("research-only")
        }
    }
}

nonisolated struct LWDownloadPlan: Sendable, Hashable {
    let modelID: String
    /// Bytes still to transfer (partial files count as already transferred).
    let remainingBytes: UInt64
    let totalBytes: UInt64
    let destination: URL
    let license: LWModelLicenseTerms
    let licenseAccepted: Bool
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
    case licenseNotAcknowledged(String)
    case licenseChanged(String)
    case memoryBusy(String, required: UInt64, inUse: UInt64, available: UInt64, holders: [String])
    case exceedsMeasuredSize(String, requested: Int, measured: Int?)
    case insufficientSpace(needed: UInt64, available: UInt64)
    case http(status: Int, path: String)
    case gated(status: Int, repository: String, page: URL)
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
        case .licenseNotAcknowledged(let id):
            return "\(id) is licensed for non-commercial use only. Acknowledge its licence terms in AI Models before using it."
        case .licenseChanged(let id): return "The licence terms for \(id) changed; review the current terms and accept them again."
        case .memoryBusy(let id, let required, let inUse, let available, let holders):
            let memory = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
            return "\(id) needs \(memory(required)) at peak, but \(holders.joined(separator: ", ")) already hold \(memory(inUse)) of the \(memory(available)) this Mac can give AI work (with \(memory(LWMemoryBudget.headroom(available))) headroom). Wait for them to finish or unload them, then try again."
        case .exceedsMeasuredSize(let id, let requested, let measured):
            guard let measured else { return "\(id) has no measured image size, so a \(requested)-pixel request is not admitted." }
            return "\(id) was measured at \(measured) pixels; a \(requested)-pixel request could exceed its measured memory need. Use a smaller size."
        case .gated(let status, let repository, let page):
            return "\(repository) is gated by its host (HTTP \(status)). Sign in at \(page.absoluteString), accept the model's terms there, then make an access token available to LensWorks (sign in with `hf auth login`, or set HF_TOKEN) and choose Resume."
        case .insufficientSpace(let needed, let available): return "Needs \(file(needed)) free; \(file(available)) available."
        case .http(let status, let path): return "The server answered \(status) for \(path)."
        case .interrupted(let path, let detail): return "The download of \(path) was interrupted (\(detail)). Resume to continue."
        case .integrity(let path, let detail): return "\(path) failed verification (\(detail)); the download was discarded and nothing was installed."
        }
    }
}

// MARK: - Memory budget

nonisolated enum LWMemoryBudget {
    /// Margin kept free above every admitted model's measured peak: measurements vary from run
    /// to run and the rest of the app shares the same unified memory.
    static func headroom(_ available: UInt64) -> UInt64 { max(512 << 20, available / 20) }

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
    private var models: [String: Int] = [:]

    func acquire(model: String, paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        models[model, default: 0] += 1
        for path in paths { counts[path, default: 0] += 1 }
    }
    func release(model: String, paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        if let count = models[model] { models[model] = count > 1 ? count - 1 : nil }
        for path in paths {
            guard let count = counts[path] else { continue }
            counts[path] = count > 1 ? count - 1 : nil
        }
    }
    func isLeased(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return counts[path] != nil }
    /// Live lease count per model id.
    var modelLeaseCounts: [String: Int] { lock.lock(); defer { lock.unlock() }; return models }
}

/// An admitted model held by an AI task (or kept resident). While any lease exists none of the
/// model's component directories can be deleted or evicted. Released explicitly or on deinit.
nonisolated final class LWModelLease: @unchecked Sendable {
    let modelID: String
    /// The first component's root, which `weights` and `tokenizer` are relative to.
    let root: URL
    let source: LWModelSource
    /// Every component root this lease protects.
    let roots: [LWComponentRoot]
    let weights: LWInferenceWeights
    let tokenizer: URL?
    private let registry: LWModelLeaseRegistry
    private let lock = NSLock()
    private var released = false

    init(modelID: String, roots: [LWComponentRoot], weights: LWInferenceWeights, tokenizer: URL?, registry: LWModelLeaseRegistry) {
        self.modelID = modelID; self.roots = roots; self.root = roots[0].root; self.source = roots[0].source
        self.weights = weights; self.tokenizer = tokenizer
        self.registry = registry
        registry.acquire(model: modelID, paths: roots.map(\.root.path))
    }

    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }

    func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first { registry.release(model: modelID, paths: roots.map(\.root.path)) }
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

/// Starts inference jobs. `LWInferenceRuntime` is the production implementation; tests
/// substitute a scripted one.
nonisolated protocol LWInferenceJobStarting: Sendable {
    func startJob(_ request: LWInferenceRequest, inputs: [LWInferenceImage]) async throws -> LWStartedInferenceJob
    /// Drops resident (keep_loaded) models once queued jobs finish.
    func releaseModels() async -> Int
}

nonisolated struct LWStartedInferenceJob: Sendable {
    let events: AsyncStream<LWInferenceEvent>
    let cancel: @Sendable () -> Void
    let release: @Sendable () -> Void
}

extension LWInferenceRuntime: LWInferenceJobStarting {
    nonisolated func startJob(_ request: LWInferenceRequest, inputs: [LWInferenceImage]) async throws -> LWStartedInferenceJob {
        let job = try await start(request, inputs: inputs)
        return LWStartedInferenceJob(events: job.events, cancel: { job.cancel() }, release: { job.release() })
    }
}

/// An inference job running on an admitted model. It holds the model's lease until its terminal
/// event, so the model cannot be deleted or evicted while it runs.
nonisolated final class LWModelJob: Sendable {
    let lease: LWModelLease
    let events: AsyncStream<LWInferenceEvent>
    private let cancelJob: @Sendable () -> Void

    init(lease: LWModelLease, events: AsyncStream<LWInferenceEvent>, cancel: @escaping @Sendable () -> Void) {
        self.lease = lease; self.events = events; self.cancelJob = cancel
    }

    func cancel() { cancelJob() }

    func collect() async -> [LWInferenceEvent] {
        var all: [LWInferenceEvent] = []
        for await event in events { all.append(event) }
        return all
    }
}

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
        /// Hugging Face access token for gated models (explicit, or HF_TOKEN).
        var accessToken: String?
        /// The token file `hf auth login` writes; read through a bounded probe when downloading.
        var tokenFile: URL?
        /// Free bytes on the managed store's volume (injectable for tests).
        var freeSpace: (@Sendable (URL) -> UInt64?)?

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

        /// HF_TOKEN_PATH, else HF_HOME/token, else ~/.cache/huggingface/token (huggingface_hub's order).
        static func defaultTokenFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            if let path = environment["HF_TOKEN_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
            if let home = environment["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent("token") }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/token")
        }

        static func application(added: [URL] = []) -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            var support = LensWorksUserState.applicationSupport
            #if DEBUG
            // UI tests point the managed store and ledger at a private folder.
            if let root = environment["LW_MODEL_STORE_ROOT"], !root.isEmpty {
                support = URL(fileURLWithPath: root, isDirectory: true)
            }
            #endif
            let token = [environment["HF_TOKEN"], environment["HUGGING_FACE_HUB_TOKEN"]].compactMap { $0 }.first { !$0.isEmpty }
            return Configuration(sceneWorksLibraries: defaultLibraries(added: added), managedRoot: support.appendingPathComponent("Models"),
                                 ledgerURL: support.appendingPathComponent("ModelStore.json"), availableMemory: LWMemoryBudget.current(),
                                 accessToken: token, tokenFile: defaultTokenFile())
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
    /// Models a keep_loaded job left resident in the runtime, each held by a lease until released.
    private var residents: [String: LWModelLease] = [:]
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
        Self.sweep(managedRoot: configuration.managedRoot, manifest: manifest)
    }

    deinit { session.invalidateAndCancel() }

    /// Removes what an interrupted removal or an abandoned download left in LensWorks' own store:
    /// every `.trash` entry, and staging folders no current component can resume (unknown or
    /// superseded revisions, or components already published). Resumable partials stay.
    private static func sweep(managedRoot: URL, manifest: LWModelManifest) {
        let files = FileManager.default
        let trash = managedRoot.appendingPathComponent(".trash")
        for name in (try? files.contentsOfDirectory(atPath: trash.path)) ?? [] {
            try? files.removeItem(at: trash.appendingPathComponent(name))
        }
        let staging = managedRoot.appendingPathComponent(".staging")
        var resumable: [String: URL] = [:]
        for component in manifest.models.flatMap(\.components) {
            resumable["\(component.managedDirectoryName)@\(component.revision)"] = managedRoot.appendingPathComponent(component.managedDirectoryName)
                .appendingPathComponent(component.revision, isDirectory: false)
        }
        for name in (try? files.contentsOfDirectory(atPath: staging.path)) ?? [] {
            if let published = resumable[name], !files.fileExists(atPath: published.path) { continue }
            try? files.removeItem(at: staging.appendingPathComponent(name))
        }
    }

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

    // MARK: Licence

    /// Every declared licence source: the runtime's table rows and SceneWorks' licence manifest.
    func licenseTerms(_ model: LWModelManifest.Model) -> LWModelLicenseTerms {
        var sources: [LWModelLicenseSource] = model.licenseComponents.map { component in
            let row = facts?.licenses[component.key]
            let name = row?.familyName ?? component.declared
            let declared = row?.declared ?? component.declared
            return LWModelLicenseSource(origin: .runtime, key: component.key, name: name, declared: declared, textURL: row?.textURL,
                                        sourceURL: row?.sourceURL, gated: row?.gated ?? false, attribution: row?.attribution,
                                        nonCommercial: LWModelLicenseTerms.isNonCommercial(name, declared, row?.spdxID))
        }
        if let declared = model.sceneWorksLicense {
            sources.append(LWModelLicenseSource(origin: .sceneWorks, key: declared.id, name: declared.name, declared: nil, textURL: nil,
                                                sourceURL: declared.homepage.flatMap(URL.init(string:)), gated: false, attribution: nil,
                                                nonCommercial: declared.nonCommercial || LWModelLicenseTerms.isNonCommercial(declared.name)))
        }
        return LWModelLicenseTerms(sources: sources, note: model.licenseNote)
    }

    func licenseTerms(_ id: String) throws -> LWModelLicenseTerms { licenseTerms(try model(id)) }

    private func isLicenseAccepted(_ model: LWModelManifest.Model) -> Bool {
        ledger.licenseAcceptances[model.id] == licenseTerms(model).version
    }

    /// Records that the person accepted exactly `version` of a model's licence terms.
    func acceptLicense(_ id: String, version: String) throws {
        let model = try model(id)
        guard version == licenseTerms(model).version else { throw LWModelStoreError.licenseChanged(id) }
        ledger.licenseAcceptances[id] = version
        persist()
        statuses[id] = nil
    }

    func revokeLicense(_ id: String) {
        ledger.licenseAcceptances[id] = nil
        persist()
        statuses[id] = nil
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

    /// Memory an idle resident model keeps occupied.
    private func residentMemory(_ model: LWModelManifest.Model) -> UInt64 {
        let local = ledger.measured[model.id].flatMap { $0.inferenceRevision == facts?.inferenceRevision ? $0.residentBytes : nil }
        return [model.memory.residentBytes, local].compactMap { $0 }.max() ?? requiredMemory(model) ?? 0
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
        let available = configuration.availableMemory
        let state: LWModelState
        var roots: [LWComponentRoot] = []
        if let reason = runtimeIncompatibility(model) {
            state = .incompatible(reason)
        } else if required == nil {
            state = .memoryUnmeasured
        } else if let required, required + LWMemoryBudget.headroom(available) > available {
            state = .exceedsMemory(required: required, available: available)
        } else {
            (state, roots) = await probe(model)
        }
        let admissible: Bool
        switch state {
        case .exceedsMemory, .memoryUnmeasured, .incompatible: admissible = false
        default: admissible = true
        }
        let managed = model.components.contains { FileManager.default.fileExists(atPath: managedRoot($0).path) }
        let status = LWModelStatus(model: model, state: state, requiredMemory: required, isAdmissible: admissible, roots: roots,
                                   hasManagedCopy: managed, license: licenseTerms(model), licenseAccepted: isLicenseAccepted(model))
        statuses[model.id] = status
        return status
    }

    private func probe(_ model: LWModelManifest.Model) async -> (LWModelState, [LWComponentRoot]) {
        var roots: [LWComponentRoot] = []
        for component in model.components {
            switch await probeComponent(component) {
            case .success(let found): roots.append(found)
            case .failure(let failure): return (failure.state, [])
            }
        }
        let source = roots.contains { $0.source == .managed } ? LWModelSource.managed : roots[0].source
        return (.ready(root: roots[0].root, source: source), roots)
    }

    private struct ProbeFailure: Error { let state: LWModelState }

    /// SceneWorks libraries first (reuse in place), then the managed store; otherwise the most
    /// actionable library state, then any partial download, then not installed.
    private func probeComponent(_ component: LWModelManifest.Component) async -> Result<LWComponentRoot, ProbeFailure> {
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
                    return .success(LWComponentRoot(root: root, source: .sceneWorks(hub: hub)))
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
        do {
            switch try await probeManaged(component) {
            case .ready(let root, _):
                return .success(LWComponentRoot(root: root, source: .managed))
            case .absent, .revisionMismatch: break
            case .incomplete(let missing): consider(.incomplete(library: configuration.managedRoot, missing: missing), 2)
            case .integrity(let path, let detail): consider(.integrityFailed(library: configuration.managedRoot, path: path, detail: detail), 3)
            }
        } catch {
            consider(.libraryUnavailable(library: configuration.managedRoot, reason: Self.reason(error)), 4)
        }
        if let best { return .failure(ProbeFailure(state: best.0)) }
        let partial = partialBytes(component)
        return .failure(ProbeFailure(state: partial > 0 ? .partiallyDownloaded(completedBytes: partial, totalBytes: component.totalBytes) : .notInstalled))
    }

    /// Verifies LensWorks' own copy of a component (recording or forgetting its verification).
    private func probeManaged(_ component: LWModelManifest.Component) async throws -> LWComponentOutcome {
        let managed = managedRoot(component)
        let verified = ledger.verified
        let fs = self.fs
        let outcome = try await LWBoundedProbe.run(label: configuration.managedRoot.path, stall: configuration.probeStall) { heartbeat in
            try heartbeat.beat(managed.path)
            guard try fs.status(managed)?.isDirectory == true else { return LWComponentOutcome.absent }
            return try LWModelProbe.verify(root: managed, component, fs: fs, verified: verified, heartbeat: heartbeat)
        }
        switch outcome {
        case .ready(_, let confirmed): record(confirmed)
        case .integrity: forget(under: managed)
        default: break
        }
        return outcome
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

    /// Leases a ready model for an AI task. Admission checks the measured image size, the
    /// licence acknowledgement, and the model's measured peak plus headroom against this Mac's
    /// memory less what other leased or resident models hold. The lease is taken before the
    /// file identities are re-checked, so a deletion or eviction either happened first (and the
    /// check fails) or is refused by the lease; a changed file is re-verified, never trusted.
    func lease(_ id: String, pixels: Int? = nil) async throws -> LWModelLease {
        let model = try model(id)
        if let pixels {
            guard let measured = model.memory.pixels, pixels <= measured else {
                throw LWModelStoreError.exceedsMeasuredSize(id, requested: pixels, measured: model.memory.pixels)
            }
        }
        var status = try await status(id)
        for attempt in 0..<2 {
            if attempt > 0 || !status.state.isReady { status = await refresh(model) }
            guard status.isAdmissible else { throw LWModelStoreError.notAdmissible(id, status.state) }
            guard status.state.isReady, !status.roots.isEmpty else { throw LWModelStoreError.notReady(id, status.state) }
            if status.license.nonCommercial && !isLicenseAccepted(model) { throw LWModelStoreError.licenseNotAcknowledged(id) }
            try checkMemoryNow(model)
            let weightsURL = model.weights.path.isEmpty ? status.roots[0].root : status.roots[0].root.appendingPathComponent(model.weights.path)
            let lease = LWModelLease(modelID: id, roots: status.roots, weights: model.weights.kind == .dir ? .dir(weightsURL) : .file(weightsURL),
                                     tokenizer: model.weights.tokenizer.map { status.roots[0].root.appendingPathComponent($0) }, registry: leases)
            let verified = ledger.verified
            let fs = self.fs
            let pairs = Array(zip(status.roots.map(\.root), model.components))
            let unchanged = (try? await LWBoundedProbe.run(label: status.roots[0].root.path, stall: configuration.probeStall) { heartbeat in
                try pairs.allSatisfy { try LWModelProbe.identitiesUnchanged(root: $0, $1, fs: fs, verified: verified, heartbeat: heartbeat) }
            }) ?? false
            if unchanged {
                let now = Date()
                for root in status.roots where root.source == .managed { ledger.lastUsed[root.root.path] = now }
                if status.roots.contains(where: { $0.source == .managed }) { persist() }
                return lease
            }
            lease.release()
        }
        throw LWModelStoreError.notReady(id, status.state)
    }

    /// Refuses a model whose peak, with headroom, does not fit beside the models already leased
    /// or resident.
    private func checkMemoryNow(_ model: LWModelManifest.Model) throws {
        guard let required = requiredMemory(model) else { throw LWModelStoreError.notAdmissible(model.id, .memoryUnmeasured) }
        let counts = leases.modelLeaseCounts
        var holders: [String] = []
        var inUse: UInt64 = 0
        for other in manifest.models where other.id != model.id {
            // A resident model holds one lease of its own; any more means a job is running on it.
            if (counts[other.id] ?? 0) > (residents[other.id] == nil ? 0 : 1) {
                inUse += requiredMemory(other) ?? 0; holders.append(other.id)
            } else if residents[other.id] != nil {
                inUse += residentMemory(other); holders.append(other.id)
            }
        }
        let available = configuration.availableMemory
        if required + inUse + LWMemoryBudget.headroom(available) > available {
            throw LWModelStoreError.memoryBusy(model.id, required: required, inUse: inUse, available: available, holders: holders)
        }
    }

    /// Model ids a keep_loaded job left resident.
    var residentModels: Set<String> { Set(residents.keys) }

    /// Unloads resident models from the runtime and drops their leases.
    func releaseResidents(_ runtime: any LWInferenceJobStarting) async {
        guard !residents.isEmpty else { return }
        _ = await runtime.releaseModels()
        for lease in residents.values { lease.release() }
        residents = [:]
    }

    /// Runs one inference job on an admitted model. The model is leased for the whole job (and,
    /// for a keep_loaded request, for as long as it stays resident); the completed result's
    /// measured memory is recorded; idle residents are unloaded when they are what stands in the
    /// way of admission. `pixels` is the job's output (or largest input) pixel count.
    func runJob(_ id: String, pixels: Int?, inputs: [LWInferenceImage] = [], runtime: any LWInferenceJobStarting,
                request: @Sendable (LWModelLease) -> LWInferenceRequest) async throws -> LWModelJob {
        let lease: LWModelLease
        do {
            lease = try await self.lease(id, pixels: pixels)
        } catch let error as LWModelStoreError {
            guard case .memoryBusy(_, _, _, _, let holders) = error, holders.contains(where: { residents[$0] != nil }) else { throw error }
            await releaseResidents(runtime)
            lease = try await self.lease(id, pixels: pixels)
        }
        let built = request(lease)
        let started: LWStartedInferenceJob
        do { started = try await runtime.startJob(built, inputs: inputs) } catch { lease.release(); throw error }
        if Self.keepsLoaded(built), residents[id] == nil {
            residents[id] = LWModelLease(modelID: id, roots: lease.roots, weights: lease.weights, tokenizer: lease.tokenizer, registry: leases)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: LWInferenceEvent.self, bufferingPolicy: .unbounded)
        let forwarder = Task { [self] in
            var finished = false
            for await event in started.events {
                if case .completed(let result) = event { recordMeasurement(modelID: id, result: result, pixels: pixels) }
                if event.isTerminal {
                    // Released before the terminal event is delivered, so whoever sees it may delete the model.
                    started.release(); lease.release()
                    finished = true
                }
                continuation.yield(event)
            }
            if !finished { started.release(); lease.release() }
            continuation.finish()
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { started.cancel(); forwarder.cancel() }
        }
        return LWModelJob(lease: lease, events: stream, cancel: started.cancel)
    }

    private static func keepsLoaded(_ request: LWInferenceRequest) -> Bool {
        struct Envelope: Decodable { struct Load: Decodable { let residency: String? }; let load: Load? }
        return (try? JSONDecoder().decode(Envelope.self, from: request.json))?.load?.residency == LWInferenceLoadOptions.Residency.keepLoaded.rawValue
    }

    /// Records the measured memory of a completed fresh-load job, so admission uses this Mac's
    /// own measurement when it exceeds the manifest's.
    func recordMeasurement(modelID: String, peakBytes: UInt64, residentBytes: UInt64?, inferenceRevision: String, pixels: Int? = nil) {
        guard manifest.models.contains(where: { $0.id == modelID }), inferenceRevision == facts?.inferenceRevision else { return }
        if let existing = ledger.measured[modelID], existing.inferenceRevision == inferenceRevision, existing.peakBytes >= peakBytes { return }
        ledger.measured[modelID] = .init(peakBytes: peakBytes, residentBytes: residentBytes, inferenceRevision: inferenceRevision,
                                         measuredAt: Date(), pixels: pixels)
        persist()
        statuses[modelID] = nil
    }

    func recordMeasurement(modelID: String, result: LWInferenceResult, pixels: Int? = nil) {
        guard !result.modelReused, let memory = result.memory else { return }
        recordMeasurement(modelID: modelID, peakBytes: memory.peakBytes, residentBytes: memory.activeBytes,
                          inferenceRevision: result.inferenceRevision, pixels: pixels)
    }

    // MARK: Deletion and eviction

    /// Deletes LensWorks' own copy of a model. Never touches SceneWorks libraries; refused while leased.
    func deleteManagedCopy(_ id: String) async throws {
        let model = try model(id)
        let roots = model.components.map { managedRoot($0) }
        if roots.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }), case .ready(_, .sceneWorks) = try await status(id).state {
            throw LWModelStoreError.externallyOwned(id)
        }
        // Checked and removed with no suspension in between, so a lease cannot slip in.
        let present = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        if present.contains(where: { leases.isLeased($0.path) }) { throw LWModelStoreError.leased(id) }
        for root in present { try remove(root) }
        for component in model.components { try? FileManager.default.removeItem(at: stagingRoot(component)) }
        await refresh(model)
    }

    /// Frees at least `bytes` by deleting least-recently-used managed copies that are not leased.
    /// Returns the evicted model ids. SceneWorks libraries are never evicted.
    func evictManaged(toFree bytes: UInt64, excluding: Set<String> = []) async -> [String] {
        var candidates: [(model: LWModelManifest.Model, roots: [URL], used: Date)] = []
        for model in manifest.models where !excluding.contains(model.id) {
            let roots = model.components.map { managedRoot($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !roots.isEmpty, !roots.contains(where: { leases.isLeased($0.path) }) else { continue }
            let used = roots.compactMap { ledger.lastUsed[$0.path] }.max() ?? .distantPast
            candidates.append((model, roots, used))
        }
        var freed: UInt64 = 0
        var evicted: [String] = []
        for candidate in candidates.sorted(by: { $0.used < $1.used }) where freed < bytes {
            // Re-checked after every suspension: a lease taken meanwhile wins.
            let roots = candidate.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !roots.isEmpty, !roots.contains(where: { leases.isLeased($0.path) }) else { continue }
            do {
                for root in roots { try remove(root) }
                freed += candidate.model.components.filter { roots.contains(managedRoot($0)) }.reduce(0) { $0 + $1.totalBytes }
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
        let partial = model.components.reduce(0) { $0 + partialBytes($1) }
        return LWDownloadPlan(modelID: id, remainingBytes: model.totalBytes - min(partial, model.totalBytes), totalBytes: model.totalBytes,
                              destination: managedRoot(model.components[0]), license: licenseTerms(model), licenseAccepted: isLicenseAccepted(model))
    }

    private func freeSpace() -> UInt64? {
        if let probe = configuration.freeSpace { return probe(configuration.managedRoot) }
        return (try? configuration.managedRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    /// The explicit token, else the one `hf auth login` saved (read with a deadline: the file may
    /// sit on a volume macOS privacy consent withholds).
    private func accessToken() async -> String? {
        if let token = configuration.accessToken, !token.isEmpty { return token }
        guard let file = configuration.tokenFile else { return nil }
        let fs = self.fs
        let data = try? await LWBoundedProbe.run(label: file.path, stall: min(configuration.probeStall, 5)) { heartbeat -> Data? in
            try heartbeat.beat(file.path)
            guard try fs.status(file) != nil else { return nil }
            var data = Data()
            try fs.read(file) { data.append(contentsOf: $0) }
            return data
        }
        guard let bytes = data ?? nil, let text = String(data: bytes, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Explicitly downloads a model into the managed store, after its current licence terms were
    /// accepted. Cancel by cancelling the calling task: partial files stay for `download` to
    /// resume with HTTP Range requests. Each file is size- and hash-verified; the component
    /// directory is published by one atomic rename only when every file verified, so a failed,
    /// corrupt or interrupted download is never visible. A managed copy that no longer verifies
    /// is moved aside and replaced. When the volume is short of space, least-recently-used
    /// managed copies that are not leased are evicted first.
    @discardableResult
    func download(_ id: String, progress: @escaping @Sendable (LWDownloadProgress) -> Void = { _ in }) async throws -> LWModelStatus {
        let model = try model(id)
        guard isLicenseAccepted(model) else { throw LWModelStoreError.licenseNotAccepted(id) }
        guard !downloading.contains(id) else { throw LWModelStoreError.downloadInProgress(id) }
        downloading.insert(id)
        defer { downloading.remove(id) }
        let current = await refresh(model)
        guard current.isAdmissible else { throw LWModelStoreError.notAdmissible(id, current.state) }
        if current.state.isReady { throw LWModelStoreError.alreadyAvailable(id) }

        let plan = try downloadPlan(id)
        try FileManager.default.createDirectory(at: configuration.managedRoot, withIntermediateDirectories: true)
        if let free = freeSpace(), free < plan.remainingBytes {
            _ = await evictManaged(toFree: plan.remainingBytes - free, excluding: [id])
            if let after = freeSpace(), after < plan.remainingBytes {
                throw LWModelStoreError.insufficientSpace(needed: plan.remainingBytes, available: after)
            }
        }

        let base = configuration.downloadBaseURL ?? manifest.downloadBaseURL
        let token = await accessToken()
        let total = model.totalBytes
        var completedBefore: UInt64 = 0
        for component in model.components {
            let destination = managedRoot(component)
            if FileManager.default.fileExists(atPath: destination.path) {
                if case .ready = try await probeManaged(component) {
                    completedBefore += component.totalBytes
                    continue
                }
                // A corrupt or incomplete copy of our own: move it aside and stage a fresh one.
                guard !leases.isLeased(destination.path) else { throw LWModelStoreError.leased(id) }
                try remove(destination)
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
                    try await LWRangeDownload.fetch(session: session, url: url, part: part, expected: file.size, path: file.path,
                                                    token: token, repository: component.repository,
                                                    page: base.appendingPathComponent(component.repository)) { written in
                        progress(.init(modelID: id, phase: .downloading, completedBytes: offset + written, totalBytes: total, file: file.path))
                    }
                    progress(.init(modelID: id, phase: .verifying, completedBytes: offset + file.size, totalBytes: total, file: file.path))
                    let digest = try await hash(part)
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: part)
                        throw LWModelStoreError.integrity(path: file.path, detail: "content hash differs from the qualified file")
                    }
                    guard rename(part.path, final.path) == 0 else { throw LWModelStoreError.io("Could not finish \(file.path): \(String(cString: strerror(errno)))") }
                } else {
                    // Verified in an earlier (interrupted) run; re-verify before publishing.
                    progress(.init(modelID: id, phase: .verifying, completedBytes: offset + file.size, totalBytes: total, file: file.path))
                    let digest = try await hash(final)
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: final)
                        throw LWModelStoreError.integrity(path: file.path, detail: "a staged file changed; it was discarded")
                    }
                }
                completedBefore += file.size
            }
            try Task.checkCancellation()
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

    /// Hashes a downloaded file on an abandonable probe thread: cancelling the download returns
    /// at once instead of waiting for a multi-gigabyte hash (or a blocked read) to finish.
    private func hash(_ url: URL) async throws -> String {
        let fs = self.fs
        return try await LWBoundedProbe.run(label: url.path, stall: configuration.probeStall) { heartbeat in
            try LWModelProbe.sha256(url, fs: fs, heartbeat: heartbeat)
        }
    }
}

// MARK: - Range download

/// One file transfer into `part`, resuming from its current size with an HTTP Range request.
nonisolated final class LWRangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let part: URL
    private let expected: UInt64
    private let path: String
    private let repository: String
    private let page: URL
    private let onBytes: @Sendable (UInt64) -> Void
    private var handle: FileHandle?
    private var written: UInt64
    private var failure: LWModelStoreError?
    private var rangeRejected = false
    private let once = LWResumeOnce<Void>()

    private init(part: URL, offset: UInt64, expected: UInt64, path: String, repository: String, page: URL,
                 onBytes: @escaping @Sendable (UInt64) -> Void) {
        self.part = part; self.written = offset; self.expected = expected; self.path = path
        self.repository = repository; self.page = page; self.onBytes = onBytes
    }

    static func fetch(session: URLSession, url: URL, part: URL, expected: UInt64, path: String, token: String? = nil,
                      repository: String = "", page: URL? = nil, onBytes: @escaping @Sendable (UInt64) -> Void) async throws {
        func size() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? UInt64) ?? 0 }
        var offset = size()
        if offset > expected { try? FileManager.default.removeItem(at: part); offset = 0 }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        if offset == expected { return }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let transfer = LWRangeDownload(part: part, offset: offset, expected: expected, path: path, repository: repository,
                                       page: page ?? url.deletingLastPathComponent(), onBytes: onBytes)
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
        if transfer.didRejectRange {
            // The server refused to resume a partial it should hold (416): the kept bytes cannot be
            // trusted as a prefix, so start the file over from byte zero once.
            guard offset > 0 else { throw LWModelStoreError.http(status: 416, path: path) }
            try FileHandle(forWritingTo: part).truncate(atOffset: 0)
            try await fetch(session: session, url: url, part: part, expected: expected, path: path, token: token,
                            repository: repository, page: page, onBytes: onBytes)
            return
        }
        let received = size()
        guard received == expected else {
            throw LWModelStoreError.interrupted(path: path, detail: "received \(received) of \(expected) bytes")
        }
    }

    private func fail(_ error: LWModelStoreError) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
    private var didRejectRange: Bool { lock.lock(); defer { lock.unlock() }; return rangeRejected }

    /// A redirect to another host (a CDN) must not carry the access token.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(redirected)
    }

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
            lock.lock(); rangeRejected = true; lock.unlock()
            completionHandler(.cancel); return
        case 401, 403:
            fail(.gated(status: http.statusCode, repository: repository, page: page))
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
        let rangeRejected = self.rangeRejected
        lock.unlock()
        if let failure {
            if case .integrity = failure { try? FileManager.default.removeItem(at: part) }
            once.resume(.failure(failure)); return
        }
        if rangeRejected { once.resume(.success(())); return }
        if let error = error as? URLError {
            if error.code == .cancelled { once.resume(.failure(CancellationError())); return }
            once.resume(.failure(LWModelStoreError.interrupted(path: path, detail: error.localizedDescription))); return
        }
        if let error { once.resume(.failure(LWModelStoreError.interrupted(path: path, detail: error.localizedDescription))); return }
        once.resume(.success(()))
    }
}
