import Foundation
import Darwin
import ImageIO
import Security
import Testing
@testable import Compositor

/// S40: an MCP client drives the running app through the LensWorksMCP bridge. Every test uses an in-memory secret
/// store or a throwaway keychain file, a private socket path and a throwaway defaults suite: nothing touches the
/// person's own automation settings, socket or Keychain item.
@Suite(.serialized)
@MainActor
struct LensWorksAutomationTests {
    /// The bridge an MCP client launches, speaking MCP over stdio.
    final class Bridge {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private let lock = NSLock()
        private var buffer = Data()
        private var lines: [[String: Any]] = []
        private var nextID = 0
        init(secret: String?, socket: String) throws {
            let environment = ProcessInfo.processInfo.environment
            let path = environment["LW_MCP_BRIDGE"] ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LensWorksMCP").path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw LensWorksCommandRefusal(reason: "The LensWorksMCP bridge is required: set LW_MCP_BRIDGE or build it into Contents/Helpers (\(path)).")
            }
            process.executableURL = URL(fileURLWithPath: path)
            var env = ["LENSWORKS_MCP_SOCKET": socket, "PATH": "/usr/bin:/bin"]
            if let secret { env["LENSWORKS_MCP_SECRET"] = secret }
            process.environment = env
            process.standardInput = input; process.standardOutput = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty else { return }
                self.lock.withLock {
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 0x0a) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.lines.append(object) }
                    }
                }
            }
            try process.run()
        }
        deinit { output.fileHandleForReading.readabilityHandler = nil; if process.isRunning { process.terminate() } }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        /// Sends one JSON-RPC request and waits (yielding the main actor, which serves the app side) for its reply.
        func request(_ method: String, _ params: [String: Any]? = nil, timeout: Duration = .seconds(30)) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
            if let params { message["params"] = params }
            try send(message)
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let reply = lock.withLock({ () -> [String: Any]? in
                    guard let index = lines.firstIndex(where: { ($0["id"] as? Int) == id }) else { return nil }
                    return lines.remove(at: index)
                }) { return reply }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LensWorksCommandRefusal(reason: "The bridge did not answer \(method) in time.")
        }
        func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let reply = try await request("tools/call", ["name": tool, "arguments": arguments])
            return try #require(reply["result"] as? [String: Any], "\(reply)")
        }
        func close() { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
    }

    final class Harness {
        let root: URL, socket: String
        let defaults: UserDefaults, suite: String
        let store: LensWorksAutomationSecretStore
        var session: EditorSession?
        var catalog: LensWorksCatalog?
        private(set) var automation: LensWorksAutomation!
        init(store: LensWorksAutomationSecretStore = LensWorksMemorySecretStore()) throws {
            let tag = UUID().uuidString.prefix(8)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("lwa-\(tag)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            socket = root.appendingPathComponent("run/a.sock").path
            suite = "net.trefry.lensworks.tests.automation-\(tag)"
            defaults = try #require(UserDefaults(suiteName: suite))
            self.store = store
            automation = LensWorksAutomation(defaults: defaults, secretStore: store, socketPath: socket,
                                             session: { [unowned self] in self.session }, catalog: { [unowned self] in self.catalog })
        }
        func cleanUp() {
            automation.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func document() -> EditorSession {
        let session = EditorSession(); session.createDocument(width: 200, height: 100); session.addBlankLayer(); session.history.reset(); return session
    }
    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")
    }
    private func refusal(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any]).flatMap { ($0["code"] as? Int) == -32001 ? $0["message"] as? String : nil }
    }

    /// AC1: list commands, hide a layer, receive a rendered preview; Undo in the app reverts it and history says Agent.
    @Test func mcpClientListsCommandsHidesALayerAndReceivesAPreviewAndAppUndoRevertsTheAgentEntry() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID)
        #expect(!harness.automation.isEnabled && harness.defaults.object(forKey: LensWorksAutomation.enabledKey) == nil)
        harness.automation.setEnabled(true)
        let secret = try #require(harness.automation.secret)
        #expect(harness.automation.isListening && harness.automation.lastError == nil)
        let bridge = try Bridge(secret: secret, socket: harness.socket); defer { bridge.close() }

        let initialized = try await bridge.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "s40-test", "version": "1"]])
        let info = try #require(initialized["result"] as? [String: Any])
        #expect(info["protocolVersion"] as? String == "2025-06-18")
        #expect((info["capabilities"] as? [String: Any])?["tools"] != nil)
        try bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let listed = try #require((try await bridge.request("tools/list"))["result"] as? [String: Any])
        let tools = try #require(listed["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_commands", "get_state", "invoke_command", "render_preview"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let commands = try #require((try await bridge.call("list_commands"))["structuredContent"] as? [String: Any])["commands"] as? [[String: Any]]
        let rows = try #require(commands)
        #expect(rows.count == LensWorksCommandRegistry.descriptors.count)
        let hide = try #require(rows.first { $0["id"] as? String == "layer.visibility" })
        #expect(hide["available"] as? Bool == true && hide["agentInvocable"] as? Bool == true && hide["title"] as? String == "Hide/Show Layer")
        #expect(((hide["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["layers"] != nil)
        let save = try #require(rows.first { $0["id"] as? String == "file.save" })
        #expect(save["available"] as? Bool == false && (save["reason"] as? String)?.contains("Agents cannot run this command") == true)
        let toggle = try #require(rows.first { $0["id"] as? String == "automation.enabled" })
        #expect((toggle["reason"] as? String)?.contains("never available to agents") == true)
        #expect(rows.first { $0["id"] as? String == "catalog.virtualFolder.delete" }?["requiresConfirmation"] as? Bool == true)

        let state = try #require((try await bridge.call("get_state"))["structuredContent"] as? [String: Any])
        let layers = try #require((state["document"] as? [String: Any])?["layers"] as? [[String: Any]])
        #expect(layers.contains { $0["id"] as? String == layer.uuidString && $0["visible"] as? Bool == true })

        let hidden = try await bridge.call("invoke_command", ["command": "layer.visibility", "arguments": ["layers": [layer.uuidString], "visible": false]])
        #expect(hidden["isError"] as? Bool == false, "\(hidden)")
        #expect((hidden["structuredContent"] as? [String: Any])?["history"] as? String == "Hide Layer (Agent)")
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == false)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Hide Layer (Agent)")
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .visibility && LensWorksCommandDispatcher.lastOrigin == .agent)

        let preview = try await bridge.call("render_preview", ["maxDimension": 64])
        #expect(preview["isError"] as? Bool == false, "\(preview)")
        let image = try #require((preview["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" })
        #expect(image["mimeType"] as? String == "image/png")
        let encoded = try #require(image["data"] as? String)
        let png = try #require(Data(base64Encoded: encoded))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64 && decoded.height == 32)
        let tooBig = try await bridge.call("render_preview", ["maxDimension": 100_000])
        #expect(tooBig["isError"] as? Bool == true)

        // The person's Undo in the app reverts the agent's edit.
        session.undo()
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == true && session.history.undoCount == 0)
        #expect(session.history.redoName == "Hide Layer (Agent)")
    }

    /// AC2: refused with automation off, with a wrong secret, and after the secret was regenerated or revoked.
    @Test func connectionsAreRefusedWhenOffWithAWrongSecretAndAfterRegenerateOrRevoke() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.session = document()
        // Off (the default): nothing listens and the bridge says so.
        let early = try Bridge(secret: "anything", socket: harness.socket); defer { early.close() }
        #expect(refusal(try await early.request("tools/list"))?.contains("automation is off") == true)

        harness.automation.setEnabled(true)
        let original = try #require(harness.automation.secret)
        var info = stat()
        #expect(lstat(harness.socket, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFSOCK)
        #expect(lstat((harness.socket as NSString).deletingLastPathComponent, &info) == 0 && info.st_mode & 0o777 == 0o700)

        let wrong = try Bridge(secret: "not-the-secret", socket: harness.socket); defer { wrong.close() }
        #expect(refusal(try await wrong.request("tools/list"))?.contains("secret is not valid") == true)
        let missing = try Bridge(secret: nil, socket: harness.socket); defer { missing.close() }
        #expect(refusal(try await missing.request("tools/list"))?.contains("LENSWORKS_MCP_SECRET") == true)

        // A connected client using the original secret is dropped on regenerate and cannot reconnect with it.
        let stale = try Bridge(secret: original, socket: harness.socket); defer { stale.close() }
        #expect((try await stale.request("tools/list"))["result"] != nil)
        harness.automation.regenerateSecret()
        let renewed = try #require(harness.automation.secret)
        #expect(renewed != original)
        #expect(refusal(try await stale.request("tools/list"))?.contains("secret is not valid") == true)
        let current = try Bridge(secret: renewed, socket: harness.socket); defer { current.close() }
        #expect((try await current.request("tools/list"))["result"] != nil)

        // Revoked: the connected client is dropped and every new handshake is refused.
        harness.automation.revokeSecret()
        let stored = try harness.store.load()
        #expect(harness.automation.secret == nil && stored == nil)
        #expect(refusal(try await current.request("tools/list"))?.contains("revoked") == true)

        // Turned off again: the socket is gone and connections are refused.
        harness.automation.regenerateSecret()
        let again = try #require(harness.automation.secret)
        harness.automation.setEnabled(false)
        #expect(!harness.automation.isListening && lstat(harness.socket, &info) != 0)
        let off = try Bridge(secret: again, socket: harness.socket); defer { off.close() }
        #expect(refusal(try await off.request("tools/list"))?.contains("automation is off") == true)
        #expect(harness.defaults.bool(forKey: LensWorksAutomation.enabledKey) == false)
    }

    /// AC3: a permanent delete asks in the app; declining leaves the catalog unchanged and refuses the agent.
    @Test func permanentDeleteAsksInTheAppDeclineRefusesTheAgentAndAcceptDeletes() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { model in
            harness.catalog = model
            try await model.createGroup("Doomed")
            let folder = try model.group(named: "Doomed")
            harness.automation.setEnabled(true)
            let bridge = try Bridge(secret: try #require(harness.automation.secret), socket: harness.socket); defer { bridge.close() }
            let state = try #require((try await bridge.call("get_state"))["structuredContent"] as? [String: Any])
            #expect(((state["catalog"] as? [String: Any])?["virtualFolders"] as? [[String: Any]])?.contains { $0["id"] as? String == folder.id } == true)

            func deleteAnswering(_ allow: Bool) async throws -> [String: Any] {
                let call = Task { try await bridge.call("invoke_command", ["command": "catalog.virtualFolder.delete", "arguments": ["folder": folder.id]]) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while harness.automation.pendingConfirmation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                let pending = try #require(harness.automation.pendingConfirmation)
                #expect(pending.commandID == .deleteVirtualFolder && pending.title.contains("Doomed"))
                harness.automation.resolveConfirmation(allow)
                return try await call.value
            }
            let declined = try await deleteAnswering(false)
            #expect(declined["isError"] as? Bool == true && text(declined).contains("declined"))
            try await model.loadGroups()
            let kept = try model.group(named: "Doomed")
            #expect(kept.id == folder.id && kept.revision.value == folder.revision.value)

            let accepted = try await deleteAnswering(true)
            #expect(accepted["isError"] as? Bool == false, "\(accepted)")
            #expect(LensWorksCommandDispatcher.lastInvocation == .init(.deleteVirtualFolder, folder.id) && LensWorksCommandDispatcher.lastOrigin == .agent)
            try await model.loadGroups()
            #expect(!model.groups.contains { $0.id == folder.id })
            harness.catalog = nil
        }
    }

    /// An agent never joins a person's open layer interaction, and never runs commands without a typed agent path.
    @Test func agentRefusalsCarryTheirReasonsAndLeaveTheDocumentUnchanged() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID)
        let tools = harness.automation.tools
        let token = try session.beginCommandInteraction(.opacity([layer], 1))
        let joined = await tools.call("invoke_command", arguments: ["command": "layer.opacity", "arguments": ["opacity": 0.2]])
        #expect(joined["isError"] as? Bool == true && text(joined).contains("Finish the current layer interaction first."))
        try session.cancelCommandInteraction(token)
        let unsupported = await tools.call("invoke_command", arguments: ["command": "file.save"])
        #expect(unsupported["isError"] as? Bool == true && text(unsupported).contains("Agents cannot run this command"))
        let bad = await tools.call("invoke_command", arguments: ["command": "layer.opacity", "arguments": ["opacity": 3]])
        #expect(bad["isError"] as? Bool == true && text(bad).contains("Opacity must be"))
        let noCatalog = await tools.call("invoke_command", arguments: ["command": "catalog.virtualFolder.delete", "arguments": ["folder": "x"]])
        #expect(noCatalog["isError"] as? Bool == true && harness.automation.pendingConfirmation == nil)
        #expect(session.history.undoCount == 0 && session.activeLayer?.opacity == 1)
        let renamed = await tools.call("invoke_command", arguments: ["command": "layer.rename", "arguments": ["name": "From agent"]])
        #expect(renamed["isError"] as? Bool == false && session.history.undoName == "Rename Layer (Agent)" && session.activeLayer?.name == "From agent")
    }

    @Test func secretsCompareInConstantTimeAndTheDefaultSocketIsPerUser() {
        let a = LensWorksAutomationServer.digest("one"), b = LensWorksAutomationServer.digest("two")
        #expect(LensWorksAutomationServer.constantTimeEqual(a, a) && !LensWorksAutomationServer.constantTimeEqual(a, b))
        #expect(!LensWorksAutomationServer.constantTimeEqual(a, Array(a.prefix(31))))
        let path = LensWorksAutomationServer.defaultSocketPath()
        #expect(path.hasSuffix("/net.trefry.lensworks.automation/automation.sock"))
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) || path.hasPrefix(NSTemporaryDirectory()) || path.contains("/T/"))
    }

    /// The Keychain store against a throwaway keychain file with a test-only service: never the person's item.
    @Test func keychainStoreSavesReplacesAndDeletesInAThrowawayKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lwk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "s40-test"
        var keychain: SecKeychain?
        let created = SecKeychainCreate(directory.appendingPathComponent("s40.keychain").path, UInt32(password.utf8.count), password, false, nil, &keychain)
        #expect(created == errSecSuccess)
        let file = try #require(keychain)
        defer { SecKeychainDelete(file) }
        let store = LensWorksKeychainSecretStore(service: "net.trefry.lensworks.tests.automation", account: "s40-\(UUID().uuidString)", keychain: file)
        #expect(try store.load() == nil)
        try store.save("first"); #expect(try store.load() == "first")
        try store.save("second"); #expect(try store.load() == "second")
        try store.delete(); #expect(try store.load() == nil)
        try store.delete()
    }
}
