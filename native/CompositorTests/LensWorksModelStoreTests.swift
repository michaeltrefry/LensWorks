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
                return [
                    "id": model.id, "name": model.id.capitalized, "summary": "Fixture model.",
                    "routes": model.routes.map { ["task": $0.0, "provider": $0.1] }, "weights": ["kind": "dir", "path": model.weightsPath],
                    "licenseComponents": model.licenses.map { ["key": $0.0, "declared": $0.1] }, "memory": memory,
                    "components": [["repository": model.repository, "revision": model.revision,
                                    "files": model.files.map { ["path": $0.path, "size": $0.data.count, "sha256": sha256Hex($0.data)] }]],
                ]
            },
        ]
        return try LWModelManifest.decode(JSONSerialization.data(withJSONObject: json))
    }

    func facts(_ models: [FixtureModel], revision: String = revisionA) -> LWModelRuntimeFacts {
        var licenses: [String: LWModelRuntimeFacts.License] = [:]
        for (key, declared) in models.flatMap(\.licenses) {
            licenses[key] = .init(key: key, declared: declared, familyName: "Apache License 2.0", spdxID: "Apache-2.0",
                                  textURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"),
                                  sourceURL: URL(string: "https://example.invalid/card"), gated: false, attribution: "Fixture © Example")
        }
        return LWModelRuntimeFacts(inferenceRevision: revision, routes: Set(models.flatMap { $0.routes.map { "\($0.0):\($0.1)" } }), licenses: licenses)
    }

    /// Writes files into the hub the way huggingface_hub does: content in blobs/<sha256>,
    /// snapshots/<revision>/<path> a relative symlink to it.
    func installInHub(_ model: FixtureModel, revision: String? = nil, skip: Set<String> = []) throws {
        let repo = hub.appendingPathComponent("models--" + model.repository.replacingOccurrences(of: "/", with: "--"))
        let snapshot = repo.appendingPathComponent("snapshots/\(revision ?? model.revision)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try (revision ?? model.revision).write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        for file in model.files where !skip.contains(file.path) {
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
    enum Behavior { case normal, truncateAfter(Int), stallAfter(Int), corrupt, ignoreRange }
    struct Request: Equatable { let path: String; let range: String? }

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
        lock.lock()
        _requests.append(Request(path: path, range: range))
        let data = files[path]
        let behavior = behaviors[path]?.isEmpty == false ? behaviors[path]!.removeFirst() : .normal
        lock.unlock()
        guard let data else {
            send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
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

// MARK: - Tests

@Suite(.serialized) nonisolated struct LensWorksModelStoreTests {
    @Test func bundledManifestIsValidAndMeasured() throws {
        let manifest = try LWModelManifest.bundled()
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
        await #expect(throws: LWModelStoreError.alreadyAvailable(model.id)) { try await store.download(model.id, licenseAccepted: true) }
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
        #expect(plan.licenses.map(\.familyName) == ["Apache License 2.0"] && plan.licenses[0].attribution == "Fixture © Example")
        await #expect(throws: LWModelStoreError.licenseNotAccepted(model.id)) { try await store.download(model.id, licenseAccepted: false) }
        #expect(server.requests.isEmpty)

        let log = ProgressLog()
        let status = try await store.download(model.id, licenseAccepted: true) { log.append($0) }
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
        let task = Task { try await store.download(id, licenseAccepted: true) { log.append($0) } }
        #expect(await waitUntil { log.all.contains { $0.completedBytes >= 300 * 1024 } })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        server.releaseStalled()
        let paused = await store.refresh()[0]
        guard case .partiallyDownloaded(let done, let total) = paused.state else { Issue.record("expected paused: \(paused.state)"); return }
        #expect(done == 300 * 1024 && total == model.totalBytesForTest)
        #expect(fixture.managedFiles().allSatisfy { $0.hasPrefix(".staging") }, "nothing published")
        #expect(try await store.downloadPlan(model.id).remainingBytes == total - done)

        let resumed = try await store.download(model.id, licenseAccepted: true)
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
            try await store.download(model.id, licenseAccepted: true)
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
        #expect(try await store.download(model.id, licenseAccepted: true).state.isReady)
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
            try await store.download(model.id, licenseAccepted: true)
        }
        #expect(await store.refresh()[0].state == .notInstalled, "the corrupt bytes were discarded, not kept as a partial")
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("SceneWorks--fixture-mlx").path))
        #expect(try await store.download(model.id, licenseAccepted: true).state.isReady, "a retry fetches clean bytes")
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
        _ = try? await store.download(model.id, licenseAccepted: true)
        let status = try await store.download(model.id, licenseAccepted: true)
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
        try await store.download(first.id, licenseAccepted: true)
        try await store.download(second.id, licenseAccepted: true)
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
        try await store.download(first.id, licenseAccepted: true)
        try await store.download(second.id, licenseAccepted: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.lease(first.id).release()
        #expect(await store.evictManaged(toFree: 1) == [second.id])
    }
}

private extension FixtureModel {
    nonisolated var totalBytesForTest: UInt64 { UInt64(files.map(\.data.count).reduce(0, +)) }
}
