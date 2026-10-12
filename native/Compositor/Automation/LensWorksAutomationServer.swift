import CryptoKit
import Darwin
import Foundation

/// The connection a request arrived on, as its handler may ask about it.
nonisolated struct LensWorksAutomationCaller: Sendable {
    let connection: ObjectIdentifier?
    /// False once the connection was dropped: its secret was regenerated or revoked, automation stopped, or the
    /// client hung up. A request must not run, and a running one must not go on, once this is false.
    let isCurrent: @Sendable () -> Bool
    /// A call made inside the app (tests), on no connection.
    static let inProcess = LensWorksAutomationCaller(connection: nil, isCurrent: { true })
}

/// The automation transport: a Unix domain socket that only this Mac account can reach, a secret handshake on every
/// connection, then newline-delimited JSON requests answered by `handler`. The MCP bridge helper
/// (Contents/Helpers/LensWorksMCP) is the client; it speaks MCP on stdio to the agent.
///
/// Handshake: the client sends `{"type":"hello","secret":"…"}`; the server answers `{"type":"welcome",…}` or
/// `{"type":"refused","reason":"…"}` and closes. Requests: `{"id":…,"method":"tools/list"|"tools/call","params":{…}}`,
/// one per line, answered in order by `{"id":…,"result":{…}}` or `{"id":…,"error":{"code":…,"message":"…"}}`.
/// A client that closes its side while a request is pending has hung up: nothing more is run or answered for it.
nonisolated final class LensWorksAutomationServer: @unchecked Sendable {
    static let protocolVersion = 1
    static let helloLimit = 4096
    static let requestLimit = 1 << 20
    /// The whole handshake must arrive within this long of the connection opening, however it is paced.
    static let helloTimeout: TimeInterval = 10
    /// How often a connection waiting on its request's answer looks for its client hanging up.
    static let hangUpPoll: TimeInterval = 0.2
    /// Open connections (authenticated or still in their handshake) served at once; further ones are closed.
    static let connectionLimit = 16

    enum ServerError: LocalizedError {
        case path(String), system(String, Int32), alreadyServing
        var errorDescription: String? {
            switch self {
            case .path(let reason): reason
            case .system(let call, let code): "Automation socket \(call) failed: \(String(cString: strerror(code)))."
            case .alreadyServing: "Another LensWorks is already serving automation for this Mac account."
            }
        }
    }

    /// `$TMPDIR` for this user (confstr, so it matches the bridge even when the agent's environment differs), then a
    /// private directory: `<user temp>/net.trefry.lensworks.automation/automation.sock`.
    static func defaultSocketPath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let base = length > 0 && length <= buffer.count ? String(cString: buffer) : NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("net.trefry.lensworks.automation/automation.sock").path
    }

    static func digest(_ secret: String) -> [UInt8] { Array(SHA256.hash(data: Data(secret.utf8))) }
    /// Compares two digests in time independent of where they differ.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    let socketPath: String
    private let handler: @Sendable (Data, LensWorksAutomationCaller) async -> Data
    private let hungUp: @Sendable (ObjectIdentifier) -> Void
    var handshakeTimeout = LensWorksAutomationServer.helloTimeout
    private let lock = NSLock()
    private var secretDigest: [UInt8]?
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var authenticatedCount = 0

    private var dispatchedCount = 0

    init(socketPath: String, handler: @escaping @Sendable (Data, LensWorksAutomationCaller) async -> Data,
         hungUp: @escaping @Sendable (ObjectIdentifier) -> Void = { _ in }) {
        self.socketPath = socketPath; self.handler = handler; self.hungUp = hungUp
    }

    var isListening: Bool { lock.withLock { listener != nil } }
    var authenticatedConnections: Int { lock.withLock { authenticatedCount } }
    /// Connections being served, authenticated or still in their handshake.
    var openConnections: Int { lock.withLock { connections.count } }
    /// Requests handed to the handler since the server was made.
    var dispatchedRequests: Int { lock.withLock { dispatchedCount } }

    /// Replaces the accepted secret (nil: revoked, every handshake is refused) and drops every open connection, which
    /// authenticated with the previous one.
    func setSecretDigest(_ digest: [UInt8]?) {
        let open = lock.withLock { () -> [Connection] in secretDigest = digest; return Array(connections.values) }
        for connection in open { connection.terminate() }
    }

    func start() throws {
        guard !isListening else { return }
        // A client that disconnects mid-reply must cost a failed write, never the app (SIGPIPE's default is to exit).
        signal(SIGPIPE, SIG_IGN)
        let directory = (socketPath as NSString).deletingLastPathComponent
        try Self.preparePrivateDirectory(directory)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ServerError.path("The automation socket path is too long: \(socketPath)") }
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw ServerError.path("\(socketPath) exists and is not this account’s automation socket.") }
            if let probe = try? Self.connect(socketPath) { close(probe); throw ServerError.alreadyServing }
            unlink(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        do {
            var address = try Self.address(socketPath)
            let previous = umask(0o177)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            umask(previous)
            guard bound == 0 else { throw ServerError.system("bind", errno) }
            guard chmod(socketPath, 0o600) == 0 else { throw ServerError.system("chmod", errno) }
            guard listen(fd, Int32(Self.connectionLimit)) == 0 else { throw ServerError.system("listen", errno) }
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw ServerError.system("fcntl", errno) }
        } catch { close(fd); unlink(socketPath); throw error }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "net.trefry.lensworks.automation.accept"))
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        lock.withLock { listener = source }
        source.resume()
    }

    /// Stops listening, removes the socket and closes every connection.
    func stop() {
        let (source, open) = lock.withLock { () -> (DispatchSourceRead?, [Connection]) in
            defer { listener = nil }
            return (listener, Array(connections.values))
        }
        guard let source else { return }
        source.cancel()
        unlink(socketPath)
        for connection in open { connection.terminate() }
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            // Only this Mac account: the directory is 0700 and the socket 0600, and the peer must also prove it.
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            // Fails when the peer already hung up (a probe from a second LensWorks): there is nobody to serve.
            guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(client); continue }
            let connection = Connection(fd: client)
            let admitted = lock.withLock { () -> Bool in
                guard connections.count < Self.connectionLimit else { return false }
                connections[ObjectIdentifier(connection)] = connection; return true
            }
            guard admitted else {
                connection.write(["type": "refused", "reason": "LensWorks is already serving \(Self.connectionLimit) automation connections."])
                connection.close(); continue
            }
            let thread = Thread { [weak self] in
                self?.serve(connection)
                connection.close()
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            }
            thread.name = "LensWorks automation connection"
            thread.start()
        }
    }

    private func serve(_ connection: Connection) {
        guard let hello = connection.readLine(limit: Self.helloLimit, deadline: Date().addingTimeInterval(handshakeTimeout)),
              let object = try? JSONSerialization.jsonObject(with: hello) as? [String: Any],
              object["type"] as? String == "hello", let secret = object["secret"] as? String else {
            connection.write(["type": "refused", "reason": "The automation handshake was malformed."]); return
        }
        let expected = lock.withLock { secretDigest }
        guard let expected else {
            connection.write(["type": "refused", "reason": "Automation access was revoked in LensWorks Settings › Automation. Generate a new secret there and update the client configuration."]); return
        }
        guard Self.constantTimeEqual(Self.digest(secret), expected) else {
            connection.write(["type": "refused", "reason": "The automation secret is not valid. Copy the current secret from LensWorks Settings › Automation."]); return
        }
        // A secret change between the comparison and here drops this connection through setSecretDigest.
        let admitted = lock.withLock { () -> Bool in
            guard let current = secretDigest, Self.constantTimeEqual(current, expected), connections[ObjectIdentifier(connection)] != nil else { return false }
            authenticatedCount += 1; return true
        }
        guard admitted else { connection.write(["type": "refused", "reason": "The automation secret changed during the handshake."]); return }
        defer { lock.withLock { authenticatedCount -= 1 } }
        guard connection.write(["type": "welcome", "app": "LensWorks", "protocol": Self.protocolVersion]) else { return }
        let caller = LensWorksAutomationCaller(connection: ObjectIdentifier(connection)) { connection.isCurrent }
        while let line = connection.readLine(limit: Self.requestLimit) {
            lock.withLock { dispatchedCount += 1 }
            let reply = Box()
            let done = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task { reply.value = await handler(line, caller); done.signal() }
            // A client that hangs up while its request waits (on the person's confirmation, say) is dropped: the
            // handler is told, so nothing more runs and no confirmation stays up for nobody.
            while done.wait(timeout: .now() + Self.hangUpPoll) == .timedOut {
                guard connection.peerHungUp() else { continue }
                connection.terminate()
                hungUp(ObjectIdentifier(connection))
                done.wait()
                break
            }
            guard connection.isCurrent, connection.write(raw: reply.value) else { return }
        }
    }

    private final class Box: @unchecked Sendable { var value = Data() }

    /// One accepted client. Its serving thread owns the descriptor and closes it; any other thread may only shut it
    /// down (which wakes a blocked read), never after it closed.
    final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var closed = false
        private var terminated = false
        private var buffer = Data()
        init(fd: Int32) { self.fd = fd }
        /// False once the connection was dropped or closed: nothing more is read from it, run for it or written to it.
        var isCurrent: Bool { lock.withLock { !terminated && !closed } }
        func terminate() { lock.withLock { terminated = true; if !closed { shutdown(fd, SHUT_RDWR) } } }
        func close() { lock.withLock { if !closed { closed = true; Darwin.close(fd) } } }
        /// Zero or less waits without limit.
        private func setReceiveTimeout(_ seconds: TimeInterval) {
            let clamped = max(0, seconds), whole = clamped.rounded(.down)
            var value = timeval(tv_sec: Int(whole), tv_usec: Int32((clamped - whole) * 1_000_000))
            if seconds > 0, value.tv_sec == 0, value.tv_usec == 0 { value.tv_usec = 1 }
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        }
        /// Whether the client closed its side (called by the serving thread while a request is pending).
        func peerHungUp() -> Bool {
            var descriptor = pollfd(fd: fd, events: Int16(POLLHUP), revents: 0)
            return poll(&descriptor, 1, 0) > 0 && descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
        }
        /// The next newline-terminated line without its newline, or nil at end of stream, on error, past `limit`,
        /// once the connection was dropped, or when the whole line has not arrived by `deadline`.
        func readLine(limit: Int, deadline: Date? = nil) -> Data? {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            defer { if deadline != nil { setReceiveTimeout(0) } }
            while true {
                guard isCurrent else { return nil }
                if let newline = buffer.firstIndex(of: 0x0a) {
                    let line = buffer[buffer.startIndex..<newline]
                    guard line.count <= limit else { return nil }
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return Data(line)
                }
                guard buffer.count <= limit else { return nil }
                if let deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { return nil }
                    setReceiveTimeout(remaining)
                }
                let count = read(fd, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno == EAGAIN && deadline != nil { continue }
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
        @discardableResult func write(_ object: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return write(raw: data)
        }
        @discardableResult func write(raw: Data) -> Bool {
            var data = raw; data.append(0x0a)
            return data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }
    }

    // MARK: Socket plumbing

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.path("The automation socket path is too long: \(path)") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        return address
    }

    /// A connected client descriptor, for probing whether another process is serving `path`.
    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        var address = try address(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { let code = errno; close(fd); throw ServerError.system("connect", code) }
        return fd
    }

    /// Creates `path` owner-only, or accepts an existing directory only when it is a real directory this account owns.
    static func preparePrivateDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw ServerError.system("mkdir", errno) }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ServerError.system("lstat", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw ServerError.path("\(path) is not a private directory owned by this account.") }
        guard chmod(path, 0o700) == 0 else { throw ServerError.system("chmod", errno) }
    }
}
