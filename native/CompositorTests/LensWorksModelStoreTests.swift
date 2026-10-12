import CryptoKit
import Darwin
import Foundation
import Network
import Testing
@testable import Compositor

// MARK: - Fixtures

private nonisolated func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private nonisolated func payload(_ count: Int, seed: UInt8) -> Data {
    var state = UInt32(seed) &* 2_654_435_761 &+ 1
    return Data((0..<count).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: state >> 24) })
}

private nonisolated struct FixtureFile { let path: String; let data: Data }

private nonisolated struct FixtureModel {
    var id: String
    var repository: String
    var revision: String
    var files: [FixtureFile]
    var peak: UInt64? = 1 << 30
    var weightsPath = ""
    var routes: [(String, String)] = [("generate", "fixture_provider")]
    var licenses: [(String, String)] = [("fixture_license", "apache-2.0")]
    var resident: UInt64? = nil
    var pixels: Int? = 1 << 20
    /// (name, nonCommercial) as SceneWorks' licence manifest declares it.
    var sceneWorksLicense: (String, Bool)? = nil
    var licenseNote: String? = nil
    /// Further components (repository, files), each its own Hugging Face repository.
    var extra: [(String, [FixtureFile])] = []
}

private nonisolated let revisionA = String(repeating: "a", count: 40)
private nonisolated let revisionB = String(repeating: "b", count: 40)

/// A temporary SceneWorks-layout library (Hugging Face cache: blobs named by sha256, snapshot
/// symlinks), a LensWorks managed root and ledger.
private nonisolated final class Fixture: @unchecked Sendable {
    let root: URL
    let hub: URL
    let managed: URL
    let ledger: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lw-models-\(UUID().uuidString)")
        hub = root.appendingPathComponent("huggingface/hub")
        managed = root.appendingPathComponent("support/Models")
        ledger = root.appendingPathComponent("support/ModelStore.json")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
    }

    deinit {
        _ = chmod(hub.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func manifest(_ models: [FixtureModel], base: String = "https://example.invalid") throws -> LWModelManifest {
        let json: [String: Any] = [
            "schemaVersion": 1, "inferenceRevision": revisionA, "downloadBaseURL": base, "measurement": "fixture",
            "models": models.map { model -> [String: Any] in
                var memory: [String: Any] = [:]
                if let peak = model.peak { memory["peakBytes"] = peak }
                if let resident = model.resident { memory["residentBytes"] = resident }
                if let pixels = model.pixels { memory["pixels"] = pixels }
                func component(_ repository: String, _ files: [FixtureFile]) -> [String: Any] {
                    ["repository": repository, "revision": model.revision,
                     "files": files.map { ["path": $0.path, "size": $0.data.count, "sha256": sha256Hex($0.data)] }]
                }
                var entry: [String: Any] = [
                    "id": model.id, "name": model.id.capitalized, "summary": "Fixture model.",
                    "routes": model.routes.map { ["task": $0.0, "provider": $0.1] }, "weights": ["kind": "dir", "path": model.weightsPath],
                    "licenseComponents": model.licenses.map { ["key": $0.0, "declared": $0.1] }, "memory": memory,
                    "components": [component(model.repository, model.files)] + model.extra.map { component($0.0, $0.1) },
                ]
                if let (name, nonCommercial) = model.sceneWorksLicense {
                    entry["sceneWorksLicense"] = ["id": model.id, "name": name, "homepage": "https://example.invalid/\(model.id)", "nonCommercial": nonCommercial]
                }
                if let note = model.licenseNote { entry["licenseNote"] = note }
                return entry
            },
        ]
        return try LWModelManifest.decode(JSONSerialization.data(withJSONObject: json))
    }

    func facts(_ models: [FixtureModel], revision: String = revisionA, family: String = "Apache License 2.0") -> LWModelRuntimeFacts {
        var licenses: [String: LWModelRuntimeFacts.License] = [:]
        for (key, declared) in models.flatMap(\.licenses) {
            licenses[key] = .init(key: key, declared: declared, familyName: family, spdxID: "Apache-2.0",
                                  textURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"),
                                  sourceURL: URL(string: "https://example.invalid/card"), gated: false, attribution: "Fixture © Example")
        }
        return LWModelRuntimeFacts(inferenceRevision: revision, routes: Set(models.flatMap { $0.routes.map { "\($0.0):\($0.1)" } }), licenses: licenses)
    }

    /// Writes files into the hub the way huggingface_hub does: content in blobs/<sha256>,
    /// snapshots/<revision>/<path> a relative symlink to it.
    func installInHub(_ model: FixtureModel, revision: String? = nil, skip: Set<String> = []) throws {
        try installInHub(repository: model.repository, files: model.files, revision: revision ?? model.revision, skip: skip)
    }

    func installInHub(repository: String, files: [FixtureFile], revision: String, skip: Set<String> = []) throws {
        let repo = hub.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"))
        let snapshot = repo.appendingPathComponent("snapshots/\(revision)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try revision.write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        for file in files where !skip.contains(file.path) {
            let blob = repo.appendingPathComponent("blobs/\(sha256Hex(file.data))")
            try file.data.write(to: blob)
            let link = snapshot.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = file.path.split(separator: "/").count + 1
            let target = String(repeating: "../", count: depth) + "blobs/\(sha256Hex(file.data))"
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
    }

    func snapshotFile(_ model: FixtureModel, _ path: String) -> URL {
        hub.appendingPathComponent("models--" + model.repository.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots/\(model.revision)/\(path)")
    }

    func configuration(memory: UInt64 = 64 << 30, stall: TimeInterval = 5, base: URL? = nil, libraries: [URL]? = nil) -> LWModelStore.Configuration {
        LWModelStore.Configuration(sceneWorksLibraries: libraries ?? [hub], managedRoot: managed, ledgerURL: ledger, availableMemory: memory,
                                   probeStall: stall, downloadBaseURL: base, requestTimeout: 10)
    }

    /// Writes a component straight into the managed layout (as a finished download would leave it).
    func installManaged(repository: String, files: [FixtureFile], revision: String = revisionA) throws {
        let root = managed.appendingPathComponent(repository.replacingOccurrences(of: "/", with: "--")).appendingPathComponent(revision)
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    /// Every entry under `url` (symlinks not followed) with inode, size, times and content hash.
    func tree(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return result }
        for case let relative as String in walker {
            let path = url.appendingPathComponent(relative).path
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            var line = "ino=\(st.st_ino) size=\(st.st_size) mtime=\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) ctime=\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec) mode=\(st.st_mode)"
            if (st.st_mode & S_IFMT) == S_IFREG, let data = FileManager.default.contents(atPath: path) { line += " sha=\(sha256Hex(data))" }
            if (st.st_mode & S_IFMT) == S_IFLNK { line += " -> \((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")" }
            result[relative] = line
        }
        return result
    }

    func managedFiles() -> [String] {
        (FileManager.default.enumerator(atPath: managed.path)?.allObjects as? [String] ?? []).filter { !$0.hasPrefix(".trash") }.sorted()
    }
}

private nonisolated func smallModel(_ id: String = "fixture", repository: String = "SceneWorks/fixture-mlx", seed: UInt8 = 1, size: Int = 96 * 1024) -> FixtureModel {
    FixtureModel(id: id, repository: repository, revision: revisionA, files: [
        FixtureFile(path: "q4/transformer/model.safetensors", data: payload(size, seed: seed)),
        FixtureFile(path: "q4/tokenizer.json", data: Data("{\"fixture\":\(seed)}".utf8)),
    ], weightsPath: "q4")
}

/// Counts reads (hash work) and can block or deny chosen paths, standing in for a volume macOS
/// privacy consent withholds.
private nonisolated final class InstrumentedAccess: LWModelFileAccess, @unchecked Sendable {
    let base = LWPosixFileAccess()
    private let lock = NSLock()
    private var _reads = 0
    private var _statsOfBlocked = 0
    var blockPrefix: String?
    var denyPrefix: String?
    let gate = DispatchSemaphore(value: 0)

    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    var blockedCalls: Int { lock.lock(); defer { lock.unlock() }; return _statsOfBlocked }

    private func intercept(_ url: URL) throws {
        if let denyPrefix, url.path.hasPrefix(denyPrefix) { throw LWFileAccessError(path: url.path, code: EPERM) }
        if let blockPrefix, url.path.hasPrefix(blockPrefix) {
            lock.lock(); _statsOfBlocked += 1; lock.unlock()
            gate.wait()  // blocks like a TCC-withheld read until the test releases it
            gate.signal()
        }
    }
    func status(_ url: URL) throws -> LWFileStatus? { try intercept(url); return try base.status(url) }
    func list(_ url: URL) throws -> [String]? { try intercept(url); return try base.list(url) }
    func read(_ url: URL, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        try intercept(url)
        lock.lock(); _reads += 1; lock.unlock()
        try base.read(url, body)
    }
}

// MARK: - Local HTTP server

/// A loopback HTTP/1.1 file server for download tests: Range requests, and one-shot behaviours
/// that truncate, stall, corrupt or ignore ranges. No network access is involved.
private nonisolated final class TestHTTPServer: @unchecked Sendable {
    enum Behavior { case normal, truncateAfter(Int), stallAfter(Int), corrupt, ignoreRange, status(Int) }
    struct Request: Equatable { let path: String; let range: String?; var authorization: String? = nil }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "lw.test.http")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var behaviors: [String: [Behavior]] = [:]
    private var _requests: [Request] = []
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = port
    }

    deinit {
        listener.cancel()
        for connection in held { connection.cancel() }
    }

    func serve(_ model: FixtureModel) {
        lock.lock(); defer { lock.unlock() }
        for file in model.files { files["/\(model.repository)/resolve/\(model.revision)/\(file.path)"] = file.data }
    }

    func next(_ behavior: Behavior, for model: FixtureModel, file: String) {
        lock.lock(); behaviors["/\(model.repository)/resolve/\(model.revision)/\(file)", default: []].append(behavior); lock.unlock()
    }

    func releaseStalled() { lock.lock(); let connections = held; held = []; lock.unlock(); connections.forEach { $0.cancel() } }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !complete && error == nil {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst(14)).trimmingCharacters(in: .whitespaces) }
        lock.lock()
        _requests.append(Request(path: path, range: range, authorization: authorization))
        let data = files[path]
        let behavior = behaviors[path]?.isEmpty == false ? behaviors[path]!.removeFirst() : .normal
        lock.unlock()
        guard let data else {
            send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
            return
        }
        if case .status(let code) = behavior {
            send(connection, Data("HTTP/1.1 \(code) Refused\r\nContent-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
            return
        }
        var start = 0
        if case .ignoreRange = behavior {} else if let range, range.hasPrefix("bytes="), let value = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = value
        }
        if start >= data.count && start > 0 {
            send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
            return
        }
        var body = data.subdata(in: start..<data.count)
        if case .corrupt = behavior, !body.isEmpty { body[body.startIndex + body.count / 2] ^= 0xFF }
        var header = start > 0
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(data.count - 1)/\(data.count)\r\n"
            : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        switch behavior {
        case .truncateAfter(let count):
            send(connection, Data(header.utf8) + body.prefix(count), close: true)
        case .stallAfter(let count):
            lock.lock(); held.append(connection); lock.unlock()
            send(connection, Data(header.utf8) + body.prefix(count), close: false)
        default:
            send(connection, Data(header.utf8) + body, close: true)
        }
    }

    private func send(_ connection: NWConnection, _ data: Data, close: Bool) {
        // A closing send ends the stream gracefully (FIN after every byte), so a truncated body
        // arrives exactly as sent before the connection drops.
        connection.send(content: data, contentContext: close ? .finalMessage : .defaultMessage, isComplete: close,
                        completion: .contentProcessed { _ in
                            if close { self.queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() } }
                        })
    }
}

private nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LWDownloadProgress] = []
    func append(_ value: LWDownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [LWDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private nonisolated func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// A scripted inference runtime: jobs stay running until the test completes them.
private nonisolated final class ScriptedRuntime: LWInferenceJobStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<LWInferenceEvent>.Continuation] = []
    private var _requests: [Data] = []
    private var _released = 0

    var requests: [Data] { lock.lock(); defer { lock.unlock() }; return _requests }
    var releasedModels: Int { lock.lock(); defer { lock.unlock() }; return _released }

    func startJob(_ request: LWInferenceRequest, inputs: [LWInferenceImage]) async throws -> LWStartedInferenceJob {
        let (stream, continuation) = AsyncStream.makeStream(of: LWInferenceEvent.self, bufferingPolicy: .unbounded)
        lock.lock(); continuations.append(continuation); _requests.append(request.json); lock.unlock()
        continuation.yield(.started(modelReused: false))
        return LWStartedInferenceJob(events: stream, cancel: { continuation.yield(.cancelled); continuation.finish() }, release: {})
    }

    func complete(_ index: Int, peak: UInt64) {
        let json = #"{"task":"generate","provider":"fixture_provider","inference_revision":"\#(revisionA)","model_reused":false,"input_conversions":[],"memory":{"peak_bytes":\#(peak),"active_bytes":\#(peak / 2)}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try! decoder.decode(LWInferenceResult.self, from: Data(json.utf8))
        lock.lock(); let continuation = continuations[index]; lock.unlock()
        continuation.yield(.completed(result))
        continuation.finish()
    }

    func releaseModels() async -> Int { lock.lock(); _released += 1; lock.unlock(); return 1 }
}

// MARK: - Tests

@Suite(.serialized) nonisolated struct LensWorksModelStoreTests {
    @Test func bundledManifestIsValidAndMeasured() async throws {
        let manifest = try LWModelManifest.bundled()
        let fixture = try Fixture()
        let store = LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: nil)
        let sana = try await store.licenseTerms("sana_sprint_1600m_q4")
        #expect(sana.sources.map(\.origin) == [.runtime, .runtime, .sceneWorks], "runtime rows and SceneWorks' declaration are all listed")
        #expect(sana.nonCommercial && sana.conflict != nil, "SANA-Sprint's non-commercial SceneWorks terms govern over the runtime's apache-2.0 row")
        let clip = try await store.licenseTerms("clip_vit_l14")
        #expect(!clip.runtimeDeclared && clip.sources.isEmpty && clip.note != nil && !clip.nonCommercial)
        #expect(try await !store.licenseTerms("sam2_hiera_large").nonCommercial)
        #expect(manifest.schemaVersion == 1 && LWModelManifest.isRevision(manifest.inferenceRevision))
        #expect(Set(manifest.models.map(\.id)) == ["sana_sprint_1600m_q4", "clip_vit_l14", "sam2_hiera_large", "sam3"])
        for model in manifest.models {
            #expect((model.memory.peakBytes ?? 0) > 0, "\(model.id) carries a measured peak")
            #expect(model.licenseComponents.isEmpty == (model.licenseNote != nil), "\(model.id) states licence terms or why there are none")
        }
        #expect(throws: LWModelStoreError.self) {
            try LWModelManifest.decode(Data(#"{"schemaVersion":1,"inferenceRevision":"x","downloadBaseURL":"https://a","measurement":"","models":[{"id":"m","name":"m","summary":"","routes":[{"task":"t","provider":"p"}],"weights":{"kind":"dir","path":""},"licenseComponents":[],"memory":{},"components":[{"repository":"a/b","revision":"\#(revisionA)","files":[{"path":"../x","size":1,"sha256":"\#(String(repeating: "0", count: 64))"}]}]}]}"#.utf8))
        }
    }

    @Test func compatibleSceneWorksFilesAreAdmittedByReferenceWithoutTouchingTheLibrary() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        try fixture.installInHub(model)
        let before = fixture.tree(fixture.hub)
        let store = LWModelStore(manifest: try fixture.manifest([model]), configuration: fixture.configuration(), facts: fixture.facts([model]))
        let status = try #require(await store.refresh().first)
        let snapshot = fixture.hub.appendingPathComponent("models--SceneWorks--fixture-mlx/snapshots/\(revisionA)", isDirectory: false)
        #expect(status.state == .ready(root: snapshot, source: .sceneWorks(hub: fixture.hub)))
        #expect(status.isAdmissible)
        let lease = try await store.lease(model.id)
        #expect(lease.weights == .dir(snapshot.appendingPathComponent("q4")), "the runtime reads SceneWorks' files in place")
        lease.release()
        #expect(fixture.tree(fixture.hub) == before, "no byte, inode, time or entry in the SceneWorks library changed")
        #expect(fixture.managedFiles().isEmpty, "nothing was copied into the LensWorks store")
        await #expect(throws: LWModelStoreError.alreadyAvailable(model.id)) { try await store.acceptedDownload(model.id) }
        await #expect(throws: LWModelStoreError.externallyOwned(model.id)) { try await store.deleteManagedCopy(model.id) }
        #expect(fixture.tree(fixture.hub) == before)
    }

    @Test func verificationIsCachedByFileIdentityAndRedoneWhenAFileChanges() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        try fixture.installInHub(model)
        let access = InstrumentedAccess()
        let manifest = try fixture.manifest([model])
        let store = LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model]), fileAccess: access)
        #expect(await store.refresh().first?.state.isReady == true)
        #expect(access.reads == 2, "first admission hashes every file")
        #expect(await store.refresh().first?.state.isReady == true)
        #expect(access.reads == 2, "an unchanged identity is not re-hashed")
        // A fresh store reads the persisted ledger and still skips the hash.
        let reopened = LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model]), fileAccess: access)
        #expect(await reopened.refresh().first?.state.isReady == true)
        #expect(access.reads == 2)

        // Same bytes rewritten (new identity) -> re-verified and still admitted.
        let tokenizer = fixture.snapshotFile(model, "q4/tokenizer.json").resolvingSymlinksInPath()
        try model.files[1].data.write(to: tokenizer)
        #expect(await store.refresh().first?.state.isReady == true)
        #expect(access.reads == 3, "only the changed file is re-hashed")

        // Same size, different bytes -> refused, and a lease is refused too.
        var tampered = model.files[1].data
        tampered[tampered.startIndex] ^= 0x01
        try tampered.write(to: tokenizer)
        let lease = try? await store.lease(model.id)
        #expect(lease == nil, "a lease re-checks identities and refuses a changed file")
        guard case .integrityFailed(_, let path, _) = try await store.status(model.id).state else { Issue.record("expected integrity failure"); return }
        #expect(path == "q4/tokenizer.json")
        #expect(FileManager.default.contents(atPath: tokenizer.path) == tampered, "the external file is left as found")
    }

    @Test func incompatibleRevisionMissingFileAndHashMismatchAreActionableAndNeverDownload() async throws {
        let server = try TestHTTPServer()
        let models = [smallModel("other_revision", repository: "SceneWorks/one", seed: 1),
                      smallModel("missing_file", repository: "SceneWorks/two", seed: 2),
                      smallModel("bad_hash", repository: "SceneWorks/three", seed: 3)]
        for model in models { server.serve(model) }
        let fixture = try Fixture()
        try fixture.installInHub(models[0], revision: revisionB)
        try fixture.installInHub(models[1], skip: ["q4/tokenizer.json"])
        try fixture.installInHub(models[2])
        let blob = fixture.snapshotFile(models[2], "q4/transformer/model.safetensors").resolvingSymlinksInPath()
        var corrupted = models[2].files[0].data
        corrupted[100] ^= 0xFF
        try corrupted.write(to: blob)
        let before = fixture.tree(fixture.hub)
        let store = LWModelStore(manifest: try fixture.manifest(models), configuration: fixture.configuration(base: server.baseURL), facts: fixture.facts(models))
        let states = Dictionary(uniqueKeysWithValues: await store.refresh().map { ($0.id, $0.state) })
        #expect(states["other_revision"] == .revisionMismatch(library: fixture.hub, found: [revisionB]))
        #expect(states["missing_file"] == .incomplete(library: fixture.hub, missing: ["q4/tokenizer.json"]))
        guard case .integrityFailed(let library, let path, _)? = states["bad_hash"] else { Issue.record("expected integrity failure"); return }
        #expect(library == fixture.hub && path == "q4/transformer/model.safetensors")
        for state in states.values {
            #expect(state.canDownload, "an explicit download is offered")
            #expect(!state.message.isEmpty)
        }
        #expect(states["other_revision"]?.message.contains("leaves that copy untouched") == true)
        #expect(server.requests.isEmpty, "admission never downloads")
        #expect(fixture.managedFiles().isEmpty)
        #expect(fixture.tree(fixture.hub) == before, "SceneWorks' copies are not repaired or replaced")
    }

    @Test func runtimeRevisionRouteOrLicenceDriftIsNotAdmitted() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        try fixture.installInHub(model)
        let manifest = try fixture.manifest([model])
        func state(_ facts: LWModelRuntimeFacts?) async -> LWModelStatus {
            await LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: facts, factsError: "dlopen failed").refresh()[0]
        }
        let good = fixture.facts([model])
        let revision = await state(fixture.facts([model], revision: revisionB))
        let route = await state(LWModelRuntimeFacts(inferenceRevision: revisionA, routes: [], licenses: good.licenses))
        var drifted = good.licenses
        drifted["fixture_license"] = .init(key: "fixture_license", declared: "other", familyName: "Other", spdxID: nil, textURL: nil, sourceURL: nil, gated: true, attribution: nil)
        let license = await state(LWModelRuntimeFacts(inferenceRevision: revisionA, routes: good.routes, licenses: drifted))
        let missing = await state(nil)
        for (status, needle) in [(revision, "Update LensWorks"), (route, "does not serve"), (license, "changed"), (missing, "dlopen failed")] {
            guard case .incompatible(let reason) = status.state else { Issue.record("expected incompatible: \(status.state)"); continue }
            #expect(reason.contains(needle), "\(reason)")
            #expect(!status.isAdmissible && !status.state.canDownload)
        }
    }

    @Test func aBlockedLibraryTimesOutWithAnActionableStateAndDoesNotPileUpThreads() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        try fixture.installInHub(model)
        let access = InstrumentedAccess()
        access.blockPrefix = fixture.hub.path
        let store = LWModelStore(manifest: try fixture.manifest([model]), configuration: fixture.configuration(stall: 0.4),
                                 facts: fixture.facts([model]), fileAccess: access)
        let started = Date()
        let first = try #require(await store.refresh().first)
        #expect(Date().timeIntervalSince(started) < 5, "the probe gave up instead of hanging")
        #expect(first.state == .libraryUnavailable(library: fixture.hub, reason: .timedOut))
        #expect(first.state.message.contains("System Settings › Privacy & Security"))
        #expect(first.state.message.contains("will not download"))
        #expect(LWBoundedProbe.isBlocked(fixture.hub.path))
        let threads = LWBoundedProbe.startedThreadCount
        let second = try #require(await store.refresh().first)
        #expect(second.state == .libraryUnavailable(library: fixture.hub, reason: .stillBlocked))
        #expect(access.blockedCalls == 1, "no second read was sent into the blocked volume")
        #expect(LWBoundedProbe.startedThreadCount == threads + 1, "only the managed-store probe started a thread")
        #expect(fixture.managedFiles().isEmpty)
        // macOS answers (access granted): the abandoned thread drains and Retry admits the library.
        access.blockPrefix = nil
        access.gate.signal()
        #expect(await waitUntil { !LWBoundedProbe.isBlocked(fixture.hub.path) })
        #expect(await store.refresh().first?.state.isReady == true)
    }

    @Test func cancellingAProbeReturnsImmediately() async throws {
        let gate = DispatchSemaphore(value: 0)
        let label = "cancel-\(UUID().uuidString)"
        let task = Task { try await LWBoundedProbe.run(label: label, stall: 60) { heartbeat -> Int in
            try heartbeat.beat()
            gate.wait()
            return 1
        } }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 1)
        gate.signal()
    }

    @Test func deniedAccessReportsThePrivacySettingsAction() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        try fixture.installInHub(model)
        let access = InstrumentedAccess()
        access.denyPrefix = fixture.hub.path
        let manifest = try fixture.manifest([model])
        let denied = await LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model]), fileAccess: access).refresh()[0]
        #expect(denied.state == .libraryUnavailable(library: fixture.hub, reason: .accessDenied))
        #expect(denied.state.message.contains("macOS denied access"))

        // Real permission denial on the library directory (EACCES), no injection.
        let repo = fixture.hub.appendingPathComponent("models--SceneWorks--fixture-mlx")
        #expect(chmod(repo.path, 0o000) == 0)
        defer { _ = chmod(repo.path, 0o755) }
        let real = await LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model])).refresh()[0]
        #expect(real.state == .libraryUnavailable(library: fixture.hub, reason: .accessDenied))
    }

    @Test func aKernelBlockedReadIsAbandonedAtTheDeadline() async throws {
        let fixture = try Fixture()
        let fifo = fixture.root.appendingPathComponent("blocked.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let started = Date()
        // open(O_RDONLY) on a FIFO blocks in the kernel until a writer appears, like a read of a
        // privacy-withheld volume.
        await #expect(throws: LWProbeError.timedOut(path: fifo.path)) {
            try await LWBoundedProbe.run(label: fifo.path, stall: 0.3) { heartbeat in
                try LWModelProbe.sha256(fifo, fs: LWPosixFileAccess(), heartbeat: heartbeat)
            }
        }
        #expect(Date().timeIntervalSince(started) < 3)
        await #expect(throws: LWProbeError.stillBlocked(path: fifo.path)) {
            try await LWBoundedProbe.run(label: fifo.path, stall: 0.3) { _ in 0 }
        }
        // Unblock the abandoned thread (a writer opens and closes) so it can exit.
        // A non-blocking writer open succeeds once the reader is parked in open(); retry until the
        // abandoned thread has drained.
        #expect(await waitUntil {
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            return !LWBoundedProbe.isBlocked(fifo.path)
        })
    }

    @Test func explicitDownloadShowsPlanAndProgressAndPublishesOnlyVerifiedFiles() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 512 * 1024)
        server.serve(model)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        #expect(await store.refresh()[0].state == .notInstalled)
        #expect(server.requests.isEmpty, "nothing downloads until asked")
        let plan = try await store.downloadPlan(model.id)
        let destination = fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx/\(revisionA)", isDirectory: false)
        #expect(plan.remainingBytes == UInt64(model.files.map(\.data.count).reduce(0, +)) && plan.totalBytes == plan.remainingBytes)
        #expect(plan.destination == destination)
        #expect(plan.license.sources.map(\.name) == ["Apache License 2.0"] && plan.license.sources[0].attribution == "Fixture © Example")
        #expect(!plan.licenseAccepted && plan.license.runtimeDeclared && !plan.license.nonCommercial)
        await #expect(throws: LWModelStoreError.licenseNotAccepted(model.id)) { try await store.download(model.id) }
        #expect(server.requests.isEmpty)

        let log = ProgressLog()
        let status = try await store.acceptedDownload(model.id) { log.append($0) }
        #expect(status.state == .ready(root: destination, source: .managed))
        let values = log.all
        #expect(values.contains { $0.phase == .downloading && $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes })
        #expect(values.contains { $0.phase == .verifying } && values.last?.phase == .publishing)
        let downloading = values.filter { $0.phase == .downloading }.map(\.completedBytes)
        #expect(downloading == downloading.sorted(), "progress is monotonic")
        for file in model.files {
            #expect(FileManager.default.contents(atPath: destination.appendingPathComponent(file.path).path) == file.data)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent(".staging/SceneWorks--fixture-mlx@\(revisionA)").path))
        let lease = try await store.lease(model.id)
        #expect(lease.weights == .dir(destination.appendingPathComponent("q4")))
    }

    @Test func cancelKeepsThePartialAndResumeUsesARangeRequest() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 1 << 20)
        let big = model.files[0]
        server.serve(model)
        server.next(.stallAfter(300 * 1024), for: model, file: big.path)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        let log = ProgressLog()
        let id = model.id
        let task = Task { try await store.acceptedDownload(id) { log.append($0) } }
        #expect(await waitUntil { log.all.contains { $0.completedBytes >= 300 * 1024 } })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        server.releaseStalled()
        let paused = await store.refresh()[0]
        guard case .partiallyDownloaded(let done, let total) = paused.state else { Issue.record("expected paused: \(paused.state)"); return }
        #expect(done == 300 * 1024 && total == model.totalBytesForTest)
        #expect(fixture.managedFiles().allSatisfy { $0.hasPrefix(".staging") }, "nothing published")
        #expect(try await store.downloadPlan(model.id).remainingBytes == total - done)

        let resumed = try await store.acceptedDownload(model.id)
        #expect(resumed.state.isReady)
        let bigRequests = server.requests.filter { $0.path.hasSuffix(big.path) }
        #expect(bigRequests.map(\.range) == [nil, "bytes=\(300 * 1024)-"], "the second request resumed from the partial")
    }

    @Test func anInterruptedTransferKeepsItsBytesAndResumes() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 640 * 1024)
        let big = model.files[0]
        server.serve(model)
        server.next(.truncateAfter(200 * 1024), for: model, file: big.path)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        do {
            try await store.acceptedDownload(model.id)
            Issue.record("expected an interruption")
        } catch let error as LWModelStoreError {
            guard case .interrupted(let path, _) = error else { Issue.record("\(error)"); return }
            #expect(path == big.path)
        }
        // URLSession may drop bytes it buffered when the connection is lost, so the kept partial
        // is whatever reached disk: never more than was sent, always a prefix of the real file.
        let paused = await store.refresh()[0].state
        let kept: UInt64
        switch paused {
        case .partiallyDownloaded(let done, _): kept = done
        case .notInstalled: kept = 0
        default: Issue.record("expected a paused or empty download: \(paused)"); return
        }
        #expect(kept <= 200 * 1024)
        let part = fixture.managed.appendingPathComponent(".staging/SceneWorks--fixture-mlx@\(revisionA)/\(big.path).part")
        let partial = FileManager.default.contents(atPath: part.path) ?? Data()
        #expect(UInt64(partial.count) == kept && partial == big.data.prefix(partial.count))
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx").path), "nothing published")
        #expect(try await store.acceptedDownload(model.id).state.isReady)
        #expect(server.requests.filter { $0.path.hasSuffix(big.path) }.last?.range == (kept > 0 ? "bytes=\(kept)-" : nil))
    }

    @Test func aCorruptPayloadIsDiscardedAndNeverPublished() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 256 * 1024)
        server.serve(model)
        server.next(.corrupt, for: model, file: model.files[0].path)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        await #expect(throws: LWModelStoreError.integrity(path: model.files[0].path, detail: "content hash differs from the qualified file")) {
            try await store.acceptedDownload(model.id)
        }
        #expect(await store.refresh()[0].state == .notInstalled, "the corrupt bytes were discarded, not kept as a partial")
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx").path))
        #expect(try await store.acceptedDownload(model.id).state.isReady, "a retry fetches clean bytes")
    }

    @Test func aServerThatIgnoresRangeRestartsTheFileCleanly() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 512 * 1024)
        let big = model.files[0]
        server.serve(model)
        server.next(.truncateAfter(100 * 1024), for: model, file: big.path)
        server.next(.ignoreRange, for: model, file: big.path)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        _ = try? await store.acceptedDownload(model.id)
        let status = try await store.acceptedDownload(model.id)
        #expect(status.state.isReady)
        guard case .ready(let root, _) = status.state else { return }
        #expect(FileManager.default.contents(atPath: root.appendingPathComponent(big.path).path) == big.data)
    }

    @Test func modelsAppearOnlyWhenTheirMeasuredMemoryFits() async throws {
        let fixture = try Fixture()
        var large = smallModel("large", repository: "SceneWorks/large", seed: 4)
        large.peak = 20 << 30
        var small = smallModel("small", repository: "SceneWorks/small", seed: 5)
        small.peak = 3 << 30
        var unmeasured = smallModel("unmeasured", repository: "SceneWorks/unmeasured", seed: 6)
        unmeasured.peak = nil
        let models = [large, small, unmeasured]
        for model in models { try fixture.installInHub(model) }
        let manifest = try fixture.manifest(models)
        let access = InstrumentedAccess()
        let sixteen = LWModelStore(manifest: manifest, configuration: fixture.configuration(memory: 10_700_000_000), facts: fixture.facts(models), fileAccess: access)
        let statuses = Dictionary(uniqueKeysWithValues: await sixteen.refresh().map { ($0.id, $0) })
        #expect(statuses["large"]?.state == .exceedsMemory(required: 20 << 30, available: 10_700_000_000))
        #expect(statuses["large"]?.isAdmissible == false && statuses["unmeasured"]?.isAdmissible == false)
        #expect(statuses["unmeasured"]?.state == .memoryUnmeasured)
        #expect(statuses["small"]?.state.isReady == true)
        #expect(await sixteen.admissibleStatuses().map(\.id) == ["small"], "a 16 GB Mac is offered only what it can admit")
        #expect(access.reads == 2, "models that cannot be admitted are not even probed")
        await #expect(throws: LWModelStoreError.self) { try await sixteen.lease("large") }

        let big = LWModelStore(manifest: manifest, configuration: fixture.configuration(memory: 96 << 30), facts: fixture.facts(models))
        #expect(await big.admissibleStatuses().map(\.id) == ["large", "small"])

        // This Mac's own larger measurement of a fresh load raises the requirement.
        await sixteen.recordMeasurement(modelID: "small", peakBytes: 12 << 30, residentBytes: 2 << 30, inferenceRevision: revisionA)
        await sixteen.recordMeasurement(modelID: "small", peakBytes: 1 << 30, residentBytes: nil, inferenceRevision: revisionA)
        let remeasured = try await sixteen.status("small")
        #expect(remeasured.requiredMemory == 12 << 30 && !remeasured.isAdmissible)
        await sixteen.recordMeasurement(modelID: "large", peakBytes: 40 << 30, residentBytes: nil, inferenceRevision: revisionB)
        #expect(await sixteen.ledgerSnapshot.measured["large"] == nil, "a measurement from another runtime revision is ignored")
    }

    @Test func activeLeasesPreventDeletionAndEviction() async throws {
        let server = try TestHTTPServer()
        let first = smallModel("first", repository: "SceneWorks/first", seed: 7)
        let second = smallModel("second", repository: "SceneWorks/second", seed: 8)
        server.serve(first); server.serve(second)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([first, second], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([first, second]))
        try await store.acceptedDownload(first.id)
        try await store.acceptedDownload(second.id)
        let firstRoot = fixture.managed.appendingPathComponent("SceneWorks--first/\(revisionA)")
        let secondRoot = fixture.managed.appendingPathComponent("SceneWorks--second/\(revisionA)")

        var lease: LWModelLease? = try await store.lease(first.id)
        await #expect(throws: LWModelStoreError.leased(first.id)) { try await store.deleteManagedCopy(first.id) }
        #expect(await store.evictManaged(toFree: UInt64.max) == [second.id], "only the unleased copy is evicted")
        #expect(FileManager.default.fileExists(atPath: firstRoot.path) && !FileManager.default.fileExists(atPath: secondRoot.path))
        #expect(await store.evictManaged(toFree: UInt64.max).isEmpty)

        lease = nil  // released on deinit
        #expect(lease == nil)
        try await store.deleteManagedCopy(first.id)
        #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
        #expect(await store.refresh().allSatisfy { $0.state == .notInstalled })

        // Least-recently-used goes first.
        try await store.acceptedDownload(first.id)
        try await store.acceptedDownload(second.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.lease(first.id).release()
        #expect(await store.evictManaged(toFree: 1) == [second.id])
    }

    // MARK: Review fixes

    @Test func aCorruptManagedCopyCanBeRemovedOrRepairedByDownloading() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 256 * 1024)
        server.serve(model)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        guard case .ready(let root, .managed) = try await store.acceptedDownload(model.id).state else { Issue.record("expected a managed copy"); return }
        let big = root.appendingPathComponent(model.files[0].path)
        var corrupted = model.files[0].data
        corrupted[10] ^= 0xFF
        try corrupted.write(to: big)
        let broken = await store.refresh()[0]
        guard case .integrityFailed(let library, let path, _) = broken.state else { Issue.record("expected an integrity failure: \(broken.state)"); return }
        #expect(library == fixture.managed && path == model.files[0].path && broken.state.canDownload)
        #expect(broken.hasManagedCopy, "Remove is offered for a managed copy in any state")
        let repaired = try await store.download(model.id)
        #expect(repaired.state == .ready(root: root, source: .managed), "an explicit download repairs our own corrupt copy")
        #expect(FileManager.default.contents(atPath: big.path) == model.files[0].data)
        #expect(server.requests.filter { $0.path.hasSuffix(model.files[0].path) }.count == 2)

        try corrupted.write(to: big)
        #expect(await store.refresh()[0].hasManagedCopy)
        try await store.deleteManagedCopy(model.id)
        let removed = await store.refresh()[0]
        #expect(removed.state == .notInstalled && !removed.hasManagedCopy, "a broken copy can be removed too")
    }

    @Test func aLeaseIsHeldBeforeItsIdentityCheckSoAConcurrentDeleteIsRefused() async throws {
        let server = try TestHTTPServer()
        let model = smallModel()
        server.serve(model)
        let fixture = try Fixture()
        let access = InstrumentedAccess()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]), fileAccess: access)
        try await store.acceptedDownload(model.id)
        #expect(try await store.status(model.id).state.isReady)
        let root = fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx/\(revisionA)", isDirectory: false)
        access.blockPrefix = root.path  // the lease's identity check stalls on its first stat
        let id = model.id
        let leasing = Task { try await store.lease(id) }
        #expect(await waitUntil { access.blockedCalls > 0 })
        await #expect(throws: LWModelStoreError.leased(model.id)) { try await store.deleteManagedCopy(id) }
        #expect(await store.evictManaged(toFree: .max).isEmpty, "eviction during the check is refused too")
        access.blockPrefix = nil
        access.gate.signal()
        let lease = try await leasing.value
        #expect(FileManager.default.fileExists(atPath: root.path) && lease.roots.map(\.root) == [root])
        lease.release()
    }

    @Test func aMixedSceneWorksAndManagedModelLeasesEveryComponentRoot() async throws {
        let fixture = try Fixture()
        var model = smallModel()
        let encoder = [FixtureFile(path: "encoder.safetensors", data: payload(64 * 1024, seed: 9))]
        model.extra = [("SceneWorks/fixture-encoder", encoder)]
        try fixture.installInHub(model)
        try fixture.installManaged(repository: "SceneWorks/fixture-encoder", files: encoder)
        let before = fixture.tree(fixture.hub)
        let store = LWModelStore(manifest: try fixture.manifest([model]), configuration: fixture.configuration(), facts: fixture.facts([model]))
        let status = try #require(await store.refresh().first)
        let snapshot = fixture.hub.appendingPathComponent("models--SceneWorks--fixture-mlx/snapshots/\(revisionA)", isDirectory: false)
        let managed = fixture.managed.appendingPathComponent("SceneWorks--fixture-encoder/\(revisionA)", isDirectory: false)
        #expect(status.roots == [LWComponentRoot(root: snapshot, source: .sceneWorks(hub: fixture.hub)), LWComponentRoot(root: managed, source: .managed)])
        let lease = try await store.lease(model.id)
        #expect(store.leases.isLeased(snapshot.path) && store.leases.isLeased(managed.path), "every component root is leased")
        await #expect(throws: LWModelStoreError.leased(model.id)) { try await store.deleteManagedCopy(model.id) }
        #expect(await store.evictManaged(toFree: .max).isEmpty)
        #expect(await store.ledgerSnapshot.lastUsed.keys.sorted() == [managed.path], "last use is recorded only for LensWorks' own directory")
        lease.release()
        #expect(!store.leases.isLeased(snapshot.path) && !store.leases.isLeased(managed.path))
        try await store.deleteManagedCopy(model.id)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(fixture.tree(fixture.hub) == before)
    }

    @Test func conflictingDeclaredLicencesGovernByTheMostRestrictiveAndNeedVersionedAcknowledgement() async throws {
        let fixture = try Fixture()
        var model = smallModel()
        model.licenses = [("fixture_weights", "apache-2.0"), ("fixture_encoder", "gemma")]
        model.sceneWorksLicense = ("Fixture Open Model License", true)
        try fixture.installInHub(model)
        let manifest = try fixture.manifest([model])
        let store = LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model]))
        let status = try #require(await store.refresh().first)
        let terms = status.license
        #expect(terms.sources.map(\.origin) == [.runtime, .runtime, .sceneWorks] && terms.sources.map(\.key) == ["fixture_weights", "fixture_encoder", model.id])
        #expect(terms.nonCommercial && terms.governing == "Non-commercial use only.")
        #expect(terms.conflict?.contains("most restrictive") == true && terms.conflict?.contains("SceneWorks licence manifest") == true)
        #expect(status.state.isReady && status.needsLicenseAcknowledgement)
        await #expect(throws: LWModelStoreError.licenseNotAcknowledged(model.id)) { try await store.lease(model.id) }
        await #expect(throws: LWModelStoreError.licenseChanged(model.id)) { try await store.acceptLicense(model.id, version: "stale") }
        try await store.acceptLicense(model.id)
        #expect(try await !store.status(model.id).needsLicenseAcknowledgement)
        try await store.lease(model.id).release()

        // Persisted: the next launch still has the acceptance.
        let reopened = LWModelStore(manifest: manifest, configuration: fixture.configuration(), facts: fixture.facts([model]))
        #expect(try await reopened.status(model.id).licenseAccepted)
        try await reopened.lease(model.id).release()

        // Any changed declared source is a new licence version that needs accepting again.
        let runtimeChanged = LWModelStore(manifest: manifest, configuration: fixture.configuration(),
                                          facts: fixture.facts([model], family: "Apache License, Version 2.0"))
        #expect(try await !runtimeChanged.status(model.id).licenseAccepted)
        await #expect(throws: LWModelStoreError.licenseNotAcknowledged(model.id)) { try await runtimeChanged.lease(model.id) }
        var revised = model
        revised.sceneWorksLicense = ("Fixture Open Model License v2", true)
        let sceneWorksChanged = LWModelStore(manifest: try fixture.manifest([revised]), configuration: fixture.configuration(), facts: fixture.facts([model]))
        await #expect(throws: LWModelStoreError.licenseNotAcknowledged(model.id)) { try await sceneWorksChanged.lease(model.id) }
        try await sceneWorksChanged.acceptLicense(model.id)
        try await sceneWorksChanged.lease(model.id).release()
    }

    @Test func undeclaredAndPermissiveLicencesAreShownAndNeedNoUseAcknowledgement() async throws {
        let fixture = try Fixture()
        var clip = smallModel("clip", repository: "SceneWorks/clip", seed: 3)
        clip.licenses = []
        clip.licenseNote = "The model card declares no licence."
        var sam = smallModel("sam", repository: "SceneWorks/sam", seed: 4)
        sam.sceneWorksLicense = ("Apache-2.0", false)
        for model in [clip, sam] { try fixture.installInHub(model) }
        let store = LWModelStore(manifest: try fixture.manifest([clip, sam]), configuration: fixture.configuration(), facts: fixture.facts([clip, sam]))
        let statuses = Dictionary(uniqueKeysWithValues: await store.refresh().map { ($0.id, $0) })
        let clipTerms = try #require(statuses["clip"]?.license)
        #expect(!clipTerms.runtimeDeclared && clipTerms.governing == "Licence not declared by the AI runtime." && clipTerms.note == clip.licenseNote)
        let samTerms = try #require(statuses["sam"]?.license)
        #expect(samTerms.sources.map(\.origin) == [.runtime, .sceneWorks] && samTerms.conflict == nil && !samTerms.nonCommercial)
        for id in ["clip", "sam"] {
            #expect(statuses[id]?.needsLicenseAcknowledgement == false)
            try await store.lease(id).release()
            await #expect(throws: LWModelStoreError.licenseNotAccepted(id), "downloading still needs the terms accepted") { try await store.download(id) }
        }
    }

    @Test func concurrentLeasesAndResidentsPushAModelOutOfAdmission() async throws {
        let fixture = try Fixture()
        let models = (1...3).map { index -> FixtureModel in
            var model = smallModel("m\(index)", repository: "SceneWorks/m\(index)", seed: UInt8(10 + index))
            model.peak = 4 << 30
            model.resident = 4 << 30
            return model
        }
        for model in models { try fixture.installInHub(model) }
        let store = LWModelStore(manifest: try fixture.manifest(models), configuration: fixture.configuration(memory: 12 << 30), facts: fixture.facts(models))
        #expect(await store.admissibleStatuses().count == 3, "each model fits on its own")
        let first = try await store.lease("m1")
        let second = try await store.lease("m2")
        do {
            _ = try await store.lease("m3")
            Issue.record("expected the third model to be refused")
        } catch LWModelStoreError.memoryBusy(let id, let required, let inUse, let available, let holders) {
            #expect(id == "m3" && required == 4 << 30 && inUse == 8 << 30 && available == 12 << 30 && holders == ["m1", "m2"])
        }
        second.release()
        try await store.lease("m3").release()

        // A keep_loaded job leaves m2 resident; it still counts, and runJob unloads idle residents
        // when they are what blocks admission.
        let runtime = ScriptedRuntime()
        let job = try await store.runJob("m2", pixels: nil, runtime: runtime) { lease in
            .generate(provider: "fixture_provider", weights: lease.weights, load: .init(residency: .keepLoaded), LWGenerateParams(prompt: "x", width: 512, height: 512))
        }
        runtime.complete(0, peak: 1 << 30)
        _ = await job.collect()
        #expect(await store.residentModels == ["m2"])
        await #expect(throws: LWModelStoreError.self) { try await store.lease("m3") }
        let third = try await store.runJob("m3", pixels: nil, runtime: runtime) { lease in
            .generate(provider: "fixture_provider", weights: lease.weights, LWGenerateParams(prompt: "x", width: 512, height: 512))
        }
        #expect(runtime.releasedModels == 1, "the idle resident was unloaded to admit m3")
        #expect(await store.residentModels.isEmpty)
        third.cancel()
        _ = await third.collect()
        first.release()
    }

    @Test func requestsLargerThanTheMeasuredSizeAreRefused() async throws {
        let fixture = try Fixture()
        let model = smallModel()
        var unmeasured = smallModel("unmeasured", repository: "SceneWorks/unmeasured", seed: 6)
        unmeasured.pixels = nil
        for item in [model, unmeasured] { try fixture.installInHub(item) }
        let store = LWModelStore(manifest: try fixture.manifest([model, unmeasured]), configuration: fixture.configuration(), facts: fixture.facts([model, unmeasured]))
        await #expect(throws: LWModelStoreError.exceedsMeasuredSize(model.id, requested: 2048 * 1024, measured: 1 << 20)) {
            try await store.lease(model.id, pixels: 2048 * 1024)
        }
        await #expect(throws: LWModelStoreError.exceedsMeasuredSize(model.id, requested: 2048 * 1024, measured: 1 << 20)) {
            try await store.runJob(model.id, pixels: 2048 * 1024, runtime: ScriptedRuntime()) { lease in
                .generate(provider: "fixture_provider", weights: lease.weights, LWGenerateParams(prompt: "x", width: 2048, height: 1024))
            }
        }
        try await store.lease(model.id, pixels: 1 << 20).release()
        try await store.lease(model.id).release()
        await #expect(throws: LWModelStoreError.exceedsMeasuredSize("unmeasured", requested: 512 * 512, measured: nil)) {
            try await store.lease("unmeasured", pixels: 512 * 512)
        }
    }

    @Test func aJobHoldsItsLeaseRecordsItsMemoryAndKeepLoadedStaysLeasedUntilUnloaded() async throws {
        let server = try TestHTTPServer()
        let model = smallModel()
        server.serve(model)
        let fixture = try Fixture()
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        try await store.acceptedDownload(model.id)
        let root = fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx/\(revisionA)", isDirectory: false)
        let runtime = ScriptedRuntime()
        let job = try await store.runJob(model.id, pixels: 512 * 512, runtime: runtime) { lease in
            .generate(provider: "fixture_provider", weights: lease.weights, LWGenerateParams(prompt: "x", width: 512, height: 512))
        }
        #expect(runtime.requests.count == 1 && job.lease.weights == .dir(root.appendingPathComponent("q4")), "the job reads the leased copy")
        await #expect(throws: LWModelStoreError.leased(model.id), "a running job blocks deletion") { try await store.deleteManagedCopy(model.id) }
        #expect(await store.evictManaged(toFree: .max).isEmpty)
        runtime.complete(0, peak: 3 << 30)
        let events = await job.collect()
        guard case .completed? = events.last else { Issue.record("expected completion: \(events)"); return }
        let measured = try #require(await store.ledgerSnapshot.measured[model.id])
        #expect(measured.peakBytes == 3 << 30 && measured.pixels == 512 * 512, "the completed result's memory is recorded")
        try await store.deleteManagedCopy(model.id)

        try await store.acceptedDownload(model.id)
        let resident = try await store.runJob(model.id, pixels: nil, runtime: runtime) { lease in
            .generate(provider: "fixture_provider", weights: lease.weights, load: .init(residency: .keepLoaded), LWGenerateParams(prompt: "x", width: 512, height: 512))
        }
        runtime.complete(1, peak: 2 << 30)
        _ = await resident.collect()
        #expect(await store.residentModels == [model.id])
        await #expect(throws: LWModelStoreError.leased(model.id), "a resident model stays leased") { try await store.deleteManagedCopy(model.id) }
        await store.releaseResidents(runtime)
        #expect(runtime.releasedModels == 1)
        try await store.deleteManagedCopy(model.id)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aDownloadShortOfSpaceEvictsTheLeastRecentlyUsedUnleasedCopy() async throws {
        let server = try TestHTTPServer()
        let models = ["first", "second", "third"].enumerated().map { smallModel($1, repository: "SceneWorks/\($1)", seed: UInt8(20 + $0)) }
        for model in models { server.serve(model) }
        let fixture = try Fixture()
        let managed = fixture.managed
        var configuration = fixture.configuration()
        // The volume has room for one model.
        configuration.freeSpace = { _ in
            ["first", "second", "third"].contains { FileManager.default.fileExists(atPath: managed.appendingPathComponent("SceneWorks--\($0)").appendingPathComponent(revisionA).path) } ? 0 : .max
        }
        let store = LWModelStore(manifest: try fixture.manifest(models, base: server.baseURL.absoluteString), configuration: configuration, facts: fixture.facts(models))
        try await store.acceptedDownload("first")
        try await store.acceptedDownload("second")
        #expect(!FileManager.default.fileExists(atPath: managed.appendingPathComponent("SceneWorks--first/\(revisionA)").path), "the older copy made room")
        let lease = try await store.lease("second")
        await #expect(throws: LWModelStoreError.insufficientSpace(needed: models[2].totalBytesForTest, available: 0), "a leased copy is never evicted") {
            try await store.acceptedDownload("third")
        }
        lease.release()
        try await store.acceptedDownload("third")
    }

    @Test func cancellingDuringVerificationReturnsPromptly() async throws {
        let server = try TestHTTPServer()
        let model = smallModel()
        server.serve(model)
        let fixture = try Fixture()
        let access = InstrumentedAccess()
        access.blockPrefix = fixture.managed.appendingPathComponent(".staging").path  // the hash read blocks
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(stall: 30), facts: fixture.facts([model]), fileAccess: access)
        try await store.acceptLicense(model.id)
        let log = ProgressLog()
        let id = model.id
        let task = Task { try await store.download(id) { log.append($0) } }
        #expect(await waitUntil { access.blockedCalls > 0 })
        #expect(log.all.last?.phase == .verifying)
        let gate = access.gate
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { gate.signal() }  // never hang the suite
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 1, "cancel did not wait for the hash")
        access.blockPrefix = nil
        gate.signal()
        #expect(await store.refresh()[0].state.isReady == false, "nothing was published")
    }

    @Test func aRefusedResumeRestartsTheFileFromZero() async throws {
        let server = try TestHTTPServer()
        let model = smallModel(size: 512 * 1024)
        let big = model.files[0]
        server.serve(model)
        server.next(.status(416), for: model, file: big.path)
        let fixture = try Fixture()
        let part = fixture.managed.appendingPathComponent(".staging/SceneWorks--fixture-mlx@\(revisionA)/\(big.path).part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try big.data.prefix(100 * 1024).write(to: part)
        let store = LWModelStore(manifest: try fixture.manifest([model], base: server.baseURL.absoluteString),
                                 configuration: fixture.configuration(), facts: fixture.facts([model]))
        #expect(try await store.acceptedDownload(model.id).state.isReady)
        #expect(server.requests.filter { $0.path.hasSuffix(big.path) }.map(\.range) == ["bytes=\(100 * 1024)-", nil], "416 truncated the partial and restarted")
    }

    @Test func storeInitSweepsOrphanedTrashAndStaleStaging() throws {
        let fixture = try Fixture()
        let model = smallModel()
        let published = smallModel("published", repository: "SceneWorks/published", seed: 2)
        let staging = fixture.managed.appendingPathComponent(".staging")
        func write(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let trash = fixture.managed.appendingPathComponent(".trash/\(UUID().uuidString)/model.safetensors")
        let superseded = staging.appendingPathComponent("SceneWorks--fixture-mlx@\(revisionB)/q4/tokenizer.json.part")
        let unknown = staging.appendingPathComponent("Other--repo@\(revisionA)/x.part")
        let leftover = staging.appendingPathComponent("SceneWorks--published@\(revisionA)/q4/tokenizer.json.part")
        let resumable = staging.appendingPathComponent("SceneWorks--fixture-mlx@\(revisionA)/q4/transformer/model.safetensors.part")
        for url in [trash, superseded, unknown, leftover, resumable] { try write(url) }
        try fixture.installManaged(repository: published.repository, files: published.files)
        _ = LWModelStore(manifest: try fixture.manifest([model, published]), configuration: fixture.configuration(), facts: fixture.facts([model, published]))
        #expect((try FileManager.default.contentsOfDirectory(atPath: fixture.managed.appendingPathComponent(".trash").path)).isEmpty)
        for url in [superseded, unknown, leftover] { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path) was swept") }
        #expect(FileManager.default.fileExists(atPath: resumable.path), "a resumable partial is kept")
    }

    @Test func aGatedRepositoryExplainsHowToGetAccess() async throws {
        let server = try TestHTTPServer()
        let model = smallModel()
        server.serve(model)
        server.next(.status(401), for: model, file: model.files[0].path)
        server.next(.status(403), for: model, file: model.files[0].path)
        let fixture = try Fixture()
        var configuration = fixture.configuration()
        configuration.accessToken = "hf_explicit"
        let manifest = try fixture.manifest([model], base: server.baseURL.absoluteString)
        let store = LWModelStore(manifest: manifest, configuration: configuration, facts: fixture.facts([model]))
        for status in [401, 403] {
            do {
                try await store.acceptedDownload(model.id)
                Issue.record("expected a gated refusal")
            } catch let error as LWModelStoreError {
                #expect(error == .gated(status: status, repository: model.repository, page: server.baseURL.appendingPathComponent(model.repository)))
                #expect(error.description.contains("accept the model's terms") && error.description.contains("access token"), "\(error)")
            }
        }
        #expect(server.requests.allSatisfy { $0.authorization == "Bearer hf_explicit" })
        // The token `hf auth login` saved is used when none is given explicitly.
        let tokenFile = fixture.root.appendingPathComponent("token")
        try Data("hf_saved\n".utf8).write(to: tokenFile)
        configuration.accessToken = nil
        configuration.tokenFile = tokenFile
        let saved = LWModelStore(manifest: manifest, configuration: configuration, facts: fixture.facts([model]))
        #expect(try await saved.download(model.id).state.isReady)
        #expect(server.requests.last?.authorization == "Bearer hf_saved")
    }

    @Test func evictingOrDeletingAManagedCopyNeverTouchesTheSceneWorksCopy() async throws {
        let server = try TestHTTPServer()
        let model = smallModel()
        server.serve(model)
        let fixture = try Fixture()
        let manifest = try fixture.manifest([model], base: server.baseURL.absoluteString)
        // A managed copy downloaded while SceneWorks had none...
        let empty = LWModelStore(manifest: manifest, configuration: fixture.configuration(base: server.baseURL, libraries: []), facts: fixture.facts([model]))
        try await empty.acceptedDownload(model.id)
        // ...and later SceneWorks installs the same model in its hub.
        try fixture.installInHub(model)
        let before = fixture.tree(fixture.hub)
        #expect(before.values.contains { $0.contains(" -> ") } && before.values.contains { $0.contains("sha=") }, "the hub tree has symlinks and blobs")
        let root = fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx/\(revisionA)")
        let store = LWModelStore(manifest: manifest, configuration: fixture.configuration(base: server.baseURL), facts: fixture.facts([model]))
        guard case .ready(_, .sceneWorks) = await store.refresh()[0].state else { Issue.record("expected the SceneWorks copy to be used"); return }
        #expect(await store.evictManaged(toFree: .max) == [model.id])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(fixture.tree(fixture.hub) == before, "eviction left every hub file, inode, byte and symlink unchanged")

        try fixture.installManaged(repository: model.repository, files: model.files)
        try await store.deleteManagedCopy(model.id)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(fixture.tree(fixture.hub) == before, "deletion left every hub file, inode, byte and symlink unchanged")
        #expect(await store.refresh()[0].state.isReady, "the SceneWorks copy is still admitted")
        await #expect(throws: LWModelStoreError.externallyOwned(model.id)) { try await store.deleteManagedCopy(model.id) }
        #expect(fixture.tree(fixture.hub) == before)
    }
}

private extension LWModelStore {
    func acceptLicense(_ id: String) throws { try acceptLicense(id, version: licenseTerms(id).version) }

    @discardableResult
    func acceptedDownload(_ id: String, progress: @escaping @Sendable (LWDownloadProgress) -> Void = { _ in }) async throws -> LWModelStatus {
        try acceptLicense(id)
        return try await download(id, progress: progress)
    }
}

private extension FixtureModel {
    nonisolated var totalBytesForTest: UInt64 { UInt64(files.map(\.data.count).reduce(0, +)) }
}
