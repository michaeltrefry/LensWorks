import AppKit
import Foundation
import Darwin
import ImageIO
import Security
import Testing
@testable import Compositor

/// S40: an MCP client drives the running app through the LensWorksMCP bridge. Every test uses an in-memory secret
/// store, a private socket path, a throwaway defaults suite and its own pasteboard: nothing touches the person's own
/// automation settings, socket, Keychain or clipboard. Confirmation sheets are raised invisible (fully transparent,
/// ignoring the mouse) on an invisible test window, and every answer is given by the test itself.
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
        /// Ends the bridge now, even when it is still waiting on a reply (a failed test must not wait that out).
        func close() { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
    }

    final class Harness {
        let root: URL, socket: String
        let defaults: UserDefaults, suite: String
        let store: LensWorksAutomationSecretStore
        var session: EditorSession?
        var catalog: LensWorksCatalog?
        private(set) var automation: LensWorksAutomation!
        static let windowTitle = "LensWorks automated test — no action needed"
        /// Nothing a test raises is shown to the person at this Mac or takes their clicks.
        static func hide(_ window: NSWindow) { window.alphaValue = 0; window.ignoresMouseEvents = true; window.title = windowTitle }
        /// The window confirmation sheets attach to, standing in for the app's editor window.
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
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
            window.isReleasedWhenClosed = false
            Self.hide(window)
            automation.confirmationWindow = { [unowned self] in self.window }
            automation.prepareConfirmationPanel = { Harness.hide($0) }
            automation.requestsAttention = false
        }
        /// Orders the invisible test window in so a sheet can attach to it.
        func showWindow() { window.orderFront(nil) }
        /// A second app launch over the same settings, Keychain item and socket path.
        func relaunched() -> LensWorksAutomation {
            LensWorksAutomation(defaults: defaults, secretStore: store, socketPath: socket,
                                session: { [unowned self] in self.session }, catalog: { [unowned self] in self.catalog })
        }
        /// A raw client connection to the automation socket.
        func connect() throws -> Int32 {
            let fd = try LensWorksAutomationServer.connect(socket)
            var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
        /// A raw connection that completed the secret handshake.
        func authenticated() async throws -> Int32 {
            let fd = try connect()
            LensWorksAutomationTests.send(fd, #"{"type":"hello","secret":"\#(try #require(automation.secret))"}"#)
            #expect((await LensWorksAutomationTests.line(fd))?["type"] as? String == "welcome")
            return fd
        }
        func cleanUp() {
            automation.stop()
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The next line a raw connection receives, or nil when it closed first.
    nonisolated static func line(_ fd: Int32) async -> [String: Any]? {
        await Task.detached { () -> Data? in
            var bytes = [UInt8](), byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 { if byte == 0x0a { return Data(bytes) }; bytes.append(byte) }
            return nil
        }.value.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    nonisolated static func send(_ fd: Int32, _ text: String) { let data = Array((text + "\n").utf8); _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    /// One tools/call request line for a raw connection.
    private func toolCall(_ id: Int, _ tool: String, _ arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]), as: UTF8.self)
    }
    /// A store whose Keychain item cannot be removed (and, with `failsSave`, cannot be rewritten either).
    final class StuckStore: LensWorksAutomationSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secret: String?
        var failsDelete = false, failsSave = false
        func load() throws -> String? { lock.withLock { secret } }
        func save(_ secret: String) throws {
            if failsSave { throw LensWorksKeychainError(status: errSecInteractionNotAllowed) }
            lock.withLock { self.secret = secret }
        }
        func delete() throws {
            if failsDelete { throw LensWorksKeychainError(status: errSecInteractionNotAllowed) }
            lock.withLock { secret = nil }
        }
    }
    /// The sheet's real AppKit button titled `title`.
    private func button(_ title: String, in sheet: NSWindow) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return sheet.contentView.flatMap(find)
    }
    /// Waits for the confirmation a request raised on the test window and returns it with its sheet.
    private func pendingSheet(_ harness: Harness) async throws -> (confirmation: LensWorksAgentConfirmation, sheet: NSWindow) {
        #expect(try await eventually { harness.automation.pendingConfirmation != nil && harness.window.attachedSheet != nil })
        let pending = try #require(harness.automation.pendingConfirmation)
        let sheet = try #require(harness.window.attachedSheet)
        #expect(sheet === harness.automation.confirmationPanel)
        #expect(sheet.alphaValue == 0 && sheet.ignoresMouseEvents && harness.window.alphaValue == 0, "Test windows must stay invisible.")
        return (pending, sheet)
    }
    /// Answers the pending sheet as the person would: Allow is a click on its real Allow button, Don’t Allow is
    /// Escape, which that button owns.
    private func answer(_ harness: Harness, allow: Bool) async throws {
        let sheet = try await pendingSheet(harness).sheet
        if allow {
            guard try await eventually(.seconds(5)) { button("Allow", in: sheet) != nil }, let allow = button("Allow", in: sheet) else {
                harness.automation.resolveConfirmation(false) // Never leave a sheet waiting on a failed test.
                throw LensWorksCommandRefusal(reason: "The sheet has no Allow button to click.")
            }
            allow.performClick(nil)
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == .automationAllow)
        } else {
            #expect(try pressEscape(in: sheet), "Escape did not reach the sheet's Don’t Allow button.")
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == .automationDecline)
        }
        #expect(try await eventually { harness.automation.pendingConfirmation == nil && harness.window.attachedSheet == nil })
    }

    private func document() -> EditorSession {
        let session = EditorSession(); session.createDocument(width: 200, height: 100); session.addBlankLayer(); session.history.reset(); return session
    }
    /// A 200×100 document whose one layer is opaque red, so a preview shows whether that layer is visible.
    private func paintedDocument() throws -> EditorSession {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.history.reset()
        return session
    }
    /// The decoded size and center pixel (RGBA) of a render_preview result's PNG.
    private func previewImage(_ result: [String: Any]) throws -> (width: Int, height: Int, center: [UInt8]) {
        #expect(result["isError"] as? Bool == false, "\(result)")
        let image = try #require((result["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" })
        #expect(image["mimeType"] as? String == "image/png")
        let encoded = try #require(image["data"] as? String)
        let png = try #require(Data(base64Encoded: encoded))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
        let context = try #require(CGContext(data: &pixels, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let offset = ((decoded.height / 2) * decoded.width + decoded.width / 2) * 4
        return (decoded.width, decoded.height, Array(pixels[offset..<offset + 4]))
    }
    /// Presses Escape in `sheet` as the person would: the key event goes to the sheet, whose Don’t Allow button owns
    /// the registered cancel shortcut. (SwiftUI builds no accessibility tree in a unit-test host, and ignores
    /// synthesized mouse events, so the key press is the one real input a hosted test can deliver.)
    private func pressEscape(in sheet: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        return sheet.performKeyEquivalent(with: event)
    }
    private func eventually(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() { guard ContinuousClock.now < deadline else { return false }; try await Task.sleep(for: .milliseconds(10)) }
        return true
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
        let session = try paintedDocument(); harness.session = session
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
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_commands", "get_state", "invoke_command", "batch", "render_preview"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let commands = try #require((try await bridge.call("list_commands"))["structuredContent"] as? [String: Any])["commands"] as? [[String: Any]]
        let rows = try #require(commands)
        // Every built-in command; an installed plugin's own command (plugin.run.<id>) would follow them.
        #expect(rows.filter { ($0["id"] as? String)?.hasPrefix(LensWorksCommandRegistry.pluginCommandPrefix) != true }.count == LensWorksCommandRegistry.descriptors.count)
        let hide = try #require(rows.first { $0["id"] as? String == "layer.visibility" })
        #expect(hide["available"] as? Bool == true && hide["agentInvocable"] as? Bool == true && hide["title"] as? String == "Hide/Show Layer")
        #expect(((hide["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["layers"] != nil)
        // A command agents never run says why in its own terms; one they can run says what it needs now.
        let fit = try #require(rows.first { $0["id"] as? String == "view.fit" })
        #expect(fit["agentInvocable"] as? Bool == false && fit["available"] as? Bool == false && fit["reason"] as? String == LensWorksAgentExclusion.canvasZoom.rawValue)
        let export = try #require(rows.first { $0["id"] as? String == "file.exportPNG" })
        #expect(export["agentInvocable"] as? Bool == true && export["available"] as? Bool == false && (export["reason"] as? String)?.contains("No folders are granted to automation") == true)
        let undo = try #require(rows.first { $0["id"] as? String == "edit.undo" })
        #expect(undo["agentInvocable"] as? Bool == true && undo["available"] as? Bool == false && undo["reason"] as? String == "There is nothing to undo.")
        let toggle = try #require(rows.first { $0["id"] as? String == "automation.enabled" })
        #expect((toggle["reason"] as? String)?.contains("never available to agents") == true)
        #expect(rows.first { $0["id"] as? String == "catalog.virtualFolder.delete" }?["requiresConfirmation"] as? Bool == true)

        let state = try #require((try await bridge.call("get_state"))["structuredContent"] as? [String: Any])
        let layers = try #require((state["document"] as? [String: Any])?["layers"] as? [[String: Any]])
        #expect(layers.contains { $0["id"] as? String == layer.uuidString && $0["visible"] as? Bool == true })

        let before = try previewImage(try await bridge.call("render_preview", ["maxDimension": 64]))
        #expect(before.width == 64 && before.height == 32 && before.center[0] > 200 && before.center[1] < 60 && before.center[2] < 60 && before.center[3] == 255, "\(before)")

        let hidden = try await bridge.call("invoke_command", ["command": "layer.visibility", "arguments": ["layers": [layer.uuidString], "visible": false]])
        #expect(hidden["isError"] as? Bool == false, "\(hidden)")
        #expect((hidden["structuredContent"] as? [String: Any])?["history"] as? String == "Hide Layer (Agent)")
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == false)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Hide Layer (Agent)" && session.history.undoOrigin == .agent)
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .visibility && LensWorksCommandDispatcher.lastOrigin == .agent)

        // The rendered preview shows the document as it now stands: the red layer is gone from it.
        let after = try previewImage(try await bridge.call("render_preview", ["maxDimension": 64]))
        #expect(after.width == 64 && after.height == 32 && after.center != before.center, "\(after)")
        let full = try previewImage(try await bridge.call("render_preview"))
        #expect(full.width == 200 && full.height == 100) // Never enlarged.
        let tooBig = try await bridge.call("render_preview", ["maxDimension": 100_000])
        #expect(tooBig["isError"] as? Bool == true && text(tooBig).contains("maxDimension must be from 64 through 2048"))

        // The person's Undo in the app reverts the agent's edit, and Redo names it as the agent's.
        session.undo()
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == true && session.history.undoCount == 0)
        #expect(session.history.redoName == "Hide Layer (Agent)")
        session.redo()
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == false && session.history.undoName == "Hide Layer (Agent)")

        // The agent's own Undo over MCP reverts it too, through the same document history.
        let labeled = try #require((try await bridge.call("get_state"))["structuredContent"] as? [String: Any])["document"] as? [String: Any]
        #expect(labeled?["undoName"] as? String == "Hide Layer (Agent)" && labeled?["canUndo"] as? Bool == true && labeled?["undoOrigin"] as? String == "agent")
        let undone = try await bridge.call("invoke_command", ["command": "edit.undo"])
        #expect(undone["isError"] as? Bool == false && (undone["structuredContent"] as? [String: Any])?["history"] as? String == "Hide Layer (Agent)", "\(undone)")
        #expect(session.document?.layers.first { $0.id == layer }?.isVisible == true && session.history.undoCount == 0)
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .undo && LensWorksCommandDispatcher.lastOrigin == .agent)
        #expect(try previewImage(try await bridge.call("render_preview", ["maxDimension": 64])).center == before.center)
        let nothing = try await bridge.call("invoke_command", ["command": "edit.undo"])
        #expect(nothing["isError"] as? Bool == true && text(nothing) == "There is nothing to undo.")
        let redone = try await bridge.call("invoke_command", ["command": "edit.redo"])
        #expect(redone["isError"] as? Bool == false && session.document?.layers.first { $0.id == layer }?.isVisible == false)
        #expect(session.history.undoName == "Hide Layer (Agent)" && session.history.undoCount == 1)
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

    /// AC2 and E22: off by default without touching the Keychain, and one persistent secret that survives a relaunch.
    @Test func automationIsOffByDefaultAndItsOneSecretPersistsAcrossRelaunches() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.session = document()
        harness.automation.startIfEnabled()
        #expect(!harness.automation.isEnabled && !harness.automation.isListening && harness.automation.secret == nil)
        #expect(try harness.store.load() == nil && !FileManager.default.fileExists(atPath: harness.socket))

        harness.automation.setEnabled(true)
        let secret = try #require(harness.automation.secret)
        #expect(try harness.store.load() == secret && secret.utf8.count >= 43)
        harness.automation.setEnabled(false); harness.automation.setEnabled(true)
        #expect(harness.automation.secret == secret) // Turning it off and on keeps the secret.
        harness.automation.stop() // Quit.

        let relaunched = harness.relaunched(); defer { relaunched.stop() }
        #expect(relaunched.isEnabled && relaunched.secret == nil && !relaunched.isListening)
        relaunched.startIfEnabled()
        #expect(relaunched.isListening && relaunched.secret == secret && relaunched.lastError == nil)
        let bridge = try Bridge(secret: secret, socket: harness.socket); defer { bridge.close() }
        #expect((try await bridge.request("tools/list"))["result"] != nil)
        // A second LensWorks never takes over the socket the first is serving.
        let second = harness.relaunched(); second.startIfEnabled()
        #expect(!second.isListening && second.lastError?.contains("already serving") == true && relaunched.isListening)
        #expect((try await bridge.request("tools/list"))["result"] != nil)
    }

    /// E22 bounded sizes: an oversized handshake or request closes the connection, and connections are capped.
    @Test func theSocketBoundsHandshakesRequestsAndConnections() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.automation.setEnabled(true)
        let secret = try #require(harness.automation.secret)
        let line = Self.line, send = Self.send
        func open() throws -> Int32 { try harness.connect() }
        // A handshake longer than the limit is refused, whatever it says.
        let long = try open(); defer { close(long) }
        send(long, #"{"type":"hello","secret":""# + String(repeating: "x", count: LensWorksAutomationServer.helloLimit * 2) + #""}"#)
        #expect((await line(long))?["type"] as? String == "refused")
        // An authenticated request longer than the limit closes the connection unanswered; nothing ran.
        let big = try open(); defer { close(big) }
        send(big, #"{"type":"hello","secret":"\#(secret)"}"#)
        #expect((await line(big))?["type"] as? String == "welcome")
        send(big, #"{"id":1,"method":"tools/call","params":{"name":"get_state","arguments":{"pad":""# + String(repeating: "x", count: LensWorksAutomationServer.requestLimit + 1) + #""}}}"#)
        #expect(await line(big) == nil)
        // Connections past the cap are refused.
        var held: [Int32] = []; defer { held.forEach { close($0) } }
        #expect(try await eventually { harness.automation.server.openConnections == 0 })
        for count in 1...LensWorksAutomationServer.connectionLimit {
            held.append(try open())
            #expect(try await eventually { harness.automation.server.openConnections == count })
        }
        let extra = try open(); defer { close(extra) }
        let refused = await line(extra)
        #expect(refused?["type"] as? String == "refused" && (refused?["reason"] as? String)?.contains("already serving") == true)
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

            harness.showWindow()
            // The request shows a sheet on the app window. Declining is the person's Escape on that sheet (its
            // Don’t Allow button); allowing is a click on its Allow button.
            @MainActor func deleteAnswering(_ allow: Bool) async throws -> [String: Any] {
                let call = Task { try await bridge.call("invoke_command", ["command": "catalog.virtualFolder.delete", "arguments": ["folder": folder.id]]) }
                let pending = try await pendingSheet(harness).confirmation
                // The folder's name is the app's own data in its own field; it never words the question.
                #expect(pending.items.map(\.name) == ["Doomed"] && pending.items.map(\.action) == ["Delete Empty Folder"]
                        && !pending.title.contains("Doomed") && !pending.message.contains("Doomed") && pending.message.contains("cannot be undone"))
                // Nothing is deleted while the sheet waits.
                try await model.loadGroups()
                #expect(model.groups.contains { $0.id == folder.id })
                try await answer(harness, allow: allow)
                return try await call.value
            }
            let declined = try await deleteAnswering(false)
            #expect(declined["isError"] as? Bool == true && text(declined).contains("declined") && text(declined).contains("nothing was run or deleted"))
            try await model.loadGroups()
            let kept = try model.group(named: "Doomed")
            #expect(kept.id == folder.id && kept.revision.value == folder.revision.value)

            // The client hangs up while the person is being asked: the sheet goes away unanswered and nothing is deleted.
            let gone = try await harness.authenticated()
            Self.send(gone, try toolCall(1, "invoke_command", ["command": "catalog.virtualFolder.delete", "arguments": ["folder": folder.id]]))
            _ = try await pendingSheet(harness)
            close(gone)
            let dismissed = try await eventually(.seconds(5)) { harness.automation.pendingConfirmation == nil && harness.window.attachedSheet == nil }
            try await model.loadGroups()
            #expect(dismissed && model.groups.contains { $0.id == folder.id }, "The sheet stayed up for a client that hung up.")
            harness.automation.resolveConfirmation(false) // Only matters when the expectation above failed.

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
        let stepped = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        #expect(stepped["isError"] as? Bool == true && text(stepped) == "Finish the current layer interaction first.")
        try session.cancelCommandInteraction(token)
        let unsupported = await tools.call("invoke_command", arguments: ["command": "view.fit"])
        #expect(unsupported["isError"] as? Bool == true && text(unsupported) == "Agents cannot run view.fit. " + LensWorksAgentExclusion.canvasZoom.rawValue)
        let bad = await tools.call("invoke_command", arguments: ["command": "layer.opacity", "arguments": ["opacity": 3]])
        #expect(bad["isError"] as? Bool == true && text(bad).contains("Opacity must be"))
        let noCatalog = await tools.call("invoke_command", arguments: ["command": "catalog.virtualFolder.delete", "arguments": ["folder": "x"]])
        #expect(noCatalog["isError"] as? Bool == true && harness.automation.pendingConfirmation == nil)
        #expect(session.history.undoCount == 0 && session.activeLayer?.opacity == 1)
        // A misspelled argument is refused by name: it never turns "hide" into a toggle.
        let misspelled = await tools.call("invoke_command", arguments: ["command": "layer.visibility", "arguments": ["visble": false]])
        #expect(misspelled["isError"] as? Bool == true && text(misspelled) == "Unknown argument “visble” for layer.visibility. Its arguments are: layers, visible.")
        let misplaced = await tools.call("invoke_command", arguments: ["command": "layer.visibility", "argumnts": ["visible": false]])
        #expect(misplaced["isError"] as? Bool == true && text(misplaced) == "Unknown argument “argumnts” for a command. Its arguments are: arguments, command.")
        let preview = await tools.call("render_preview", arguments: ["maxDimention": 64])
        #expect(preview["isError"] as? Bool == true && text(preview) == "Unknown argument “maxDimention” for render_preview. Its arguments are: maxDimension.")
        #expect(session.history.undoCount == 0 && session.activeLayer?.isVisible == true)
        let renamed = await tools.call("invoke_command", arguments: ["command": "layer.rename", "arguments": ["name": "From agent"]])
        #expect(renamed["isError"] as? Bool == false && session.history.undoName == "Rename Layer (Agent)" && session.activeLayer?.name == "From agent")
    }

    /// Only Allow lets a confirmed command run: a second request, a timeout, a revoked secret and turning automation
    /// off all end without it, and with no app window the confirmation still appears on its own.
    @Test func confirmationsEndWithoutAllowingOnTimeoutRevokeOffAndASecondRequest() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.automation.setEnabled(true)
        harness.automation.confirmationWindow = { nil }
        func ask() -> Task<LensWorksAgentConfirmationAnswer, Never> {
            Task { await harness.automation.confirm(.init(title: "Automated test — no action needed", message: "This cannot be undone.")) }
        }
        let first = ask()
        #expect(try await eventually { harness.automation.pendingConfirmation != nil })
        let panel = try #require(harness.automation.confirmationPanel)
        #expect(panel.isVisible && panel.sheetParent == nil && panel.alphaValue == 0)
        #expect(await ask().value == .busy && harness.automation.pendingConfirmation != nil)
        harness.automation.revokeSecret()
        #expect(await first.value == .unanswered && !panel.isVisible && harness.automation.confirmationPanel == nil)

        harness.automation.regenerateSecret()
        let off = ask()
        #expect(try await eventually { harness.automation.pendingConfirmation != nil })
        harness.automation.setEnabled(false)
        #expect(await off.value == .unanswered)

        harness.automation.setEnabled(true)
        harness.automation.confirmationTimeout = .milliseconds(50)
        #expect(await ask().value == .unanswered && harness.automation.pendingConfirmation == nil)
        let allowed = ask()
        #expect(try await eventually { harness.automation.pendingConfirmation != nil })
        harness.automation.resolveConfirmation(true)
        #expect(await allowed.value == .allowed)
    }

    @Test func secretsCompareInConstantTimeAndTheDefaultSocketIsPerUser() {
        let a = LensWorksAutomationServer.digest("one"), b = LensWorksAutomationServer.digest("two")
        #expect(LensWorksAutomationServer.constantTimeEqual(a, a) && !LensWorksAutomationServer.constantTimeEqual(a, b))
        #expect(!LensWorksAutomationServer.constantTimeEqual(a, Array(a.prefix(31))))
        let path = LensWorksAutomationServer.defaultSocketPath()
        #expect(path.hasSuffix("/net.trefry.lensworks.automation/automation.sock"))
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) || path.hasPrefix(NSTemporaryDirectory()) || path.contains("/T/"))
    }

    // MARK: Review hardening

    /// An agent steps history only over its own entries: undoing the person's edits and then editing would discard
    /// the person's redo history.
    @Test func agentUndoAndRedoStepOnlyOverTheAgentsOwnEntries() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID), tools = harness.automation.tools
        session.runCommand(.opacity([layer], 0.5))
        let undo = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        #expect(undo["isError"] as? Bool == true && text(undo) == "The last edit is the person’s own: an agent undoes only its own edits."
                && session.history.undoCount == 1 && session.activeLayer?.opacity == 0.5 && !session.canRedo
                && tools.listCommands().first { $0["id"] as? String == "edit.undo" }?["reason"] as? String == "The last edit is the person’s own: an agent undoes only its own edits.")

        // The agent's entry is under the person's undone one: Redo would replay the person's edit, so it is refused.
        session.undo()
        _ = await tools.call("invoke_command", arguments: ["command": "layer.rename", "arguments": ["name": "Agent name"]])
        session.runCommand(.opacity([layer], 0.25))
        session.undo()
        let redo = await tools.call("invoke_command", arguments: ["command": "edit.redo"])
        #expect(redo["isError"] as? Bool == true && text(redo) == "The next edit to redo is the person’s own: an agent redoes only its own edits."
                && session.canRedo && session.history.redoOrigin == .user && session.activeLayer?.opacity == 1 && session.history.undoCount == 1 && session.activeLayer?.name == "Agent name")

        // Its own entry it may undo and redo.
        let own = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        let undone = session.activeLayer?.name
        let again = await tools.call("invoke_command", arguments: ["command": "edit.redo"])
        #expect(own["isError"] as? Bool == false && undone != "Agent name" && again["isError"] as? Bool == false && session.activeLayer?.name == "Agent name", "\(own) \(again)")
    }

    /// An agent never steps history under the person's pending crop or open adjustment: Undo would discard them.
    @Test func agentHistoryIsRefusedUnderAPendingCropOrOpenAdjustment() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let tools = harness.automation.tools
        _ = await tools.call("invoke_command", arguments: ["command": "layer.rename", "arguments": ["name": "Agent name"]])
        session.cropRect = CGRect(x: 10, y: 10, width: 50, height: 40)
        let cropping = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        #expect(cropping["isError"] as? Bool == true && text(cropping) == "Finish the current edit in LensWorks first."
                && session.cropRect == CGRect(x: 10, y: 10, width: 50, height: 40) && session.history.undoCount == 1 && session.activeLayer?.name == "Agent name")
        session.cropRect = nil
        session.adjustmentEditingID = UUID()
        let adjusting = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        #expect(adjusting["isError"] as? Bool == true && text(adjusting) == "Finish the current edit in LensWorks first."
                && session.history.undoCount == 1 && session.activeLayer?.name == "Agent name")
        session.adjustmentEditingID = nil
        // With nothing open the same undo runs: the refusals above were the open edits'.
        let free = await tools.call("invoke_command", arguments: ["command": "edit.undo"])
        #expect(free["isError"] as? Bool == false && session.history.undoCount == 0, "\(free)")
    }

    /// A request the connection thread already read never runs once the secret was revoked or regenerated.
    @Test func aRequestReadBeforeTheSecretChangedNeverRuns() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        harness.automation.setEnabled(true)
        let server = try #require(harness.automation.server)
        let changes: [@MainActor () -> Void] = [{ harness.automation.revokeSecret(); harness.automation.regenerateSecret() }, { harness.automation.regenerateSecret() }]
        for (round, change) in changes.enumerated() {
            let fd = try await harness.authenticated(); defer { close(fd) }
            let edits = session.history.undoCount, dispatched = server.dispatchedRequests
            // The first request runs.
            Self.send(fd, try toolCall(1, "invoke_command", ["command": "layer.opacity", "arguments": ["opacity": round == 0 ? 0.5 : 0.75]]))
            _ = await Self.line(fd)
            // The second is read by the connection thread while this test holds the main actor, so it cannot run
            // yet; the secret changes before it can.
            Self.send(fd, try toolCall(2, "invoke_command", ["command": "layer.rename", "arguments": ["name": "After the secret changed \(round)"]]))
            let limit = Date().addingTimeInterval(10)
            while server.dispatchedRequests < dispatched + 2, Date() < limit { Thread.sleep(forTimeInterval: 0.005) }
            let read = server.dispatchedRequests - dispatched
            change()
            _ = try await eventually { server.openConnections == 0 }
            #expect(read == 2 && session.activeLayer?.name != "After the secret changed \(round)" && session.history.undoCount == edits + 1
                    && LensWorksCommandDispatcher.lastInvocation?.id == .opacity && server.openConnections == 0, "round \(round)")
        }
    }

    /// Scripted launches (catalog plans, evidence runs, fixture imports) and test hosts never serve automation.
    @Test func scriptedLaunchesAndTestHostsNeverServeAutomationAtLaunch() {
        let serves = LensWorksAutomation.servesAtLaunch
        let scripted = ["--lensworks-quit", "--lensworks-catalog-plan", "--lensworks-evidence", "--lensworks-defaults-suite", "--lensworks-output", "--lensworks-catalog", "--lensworks-anything-later"]
        #expect(serves(["/Applications/LensWorks.app/Contents/MacOS/LensWorks"], [:])
                && serves(["LensWorks", "-NSDocumentRevisionsDebugMode", "YES", "/Users/someone/photo.lwproj"], ["HOME": "/Users/someone"])
                && scripted.allSatisfy { !serves(["LensWorks", $0, "value"], [:]) }
                // The exact launches of scripts/run-installed-catalog-plan.py and scripts/verify-installed-raster.py.
                && !serves(["LensWorks", "--lensworks-catalog-plan", "/tmp/plan.json", "--lensworks-evidence", "/tmp/evidence.json", "--lensworks-quit"], [:])
                && !serves(["LensWorks", "--lensworks-output", "/tmp/out", "--lensworks-catalog", "/tmp/catalog"], [:]))
        #expect(!serves(["LensWorks"], ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    /// Listed availability does not depend on a selection an agent does not need: it may name layers by id.
    @Test func layerCommandsAreListedAvailableWithoutASelectionAndRunWithIds() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID), tools = harness.automation.tools
        session.activeLayerID = nil
        let rows = tools.listCommands().filter { ["layer.visibility", "layer.opacity", "layer.rename"].contains($0["id"] as? String ?? "") }
        let unnamed = await tools.call("invoke_command", arguments: ["command": "layer.visibility", "arguments": ["visible": false]])
        let named = await tools.call("invoke_command", arguments: ["command": "layer.visibility", "arguments": ["layers": [layer.uuidString], "visible": false]])
        #expect(rows.count == 3 && rows.allSatisfy { $0["available"] as? Bool == true && $0["reason"] == nil && $0["note"] as? String == "No layer is selected: pass layer ids from get_state." }
                && unnamed["isError"] as? Bool == true && text(unnamed) == "Select a layer first, or pass layer ids from get_state."
                && named["isError"] as? Bool == false && session.document?.layers.first { $0.id == layer }?.isVisible == false, "\(rows)")
    }

    /// The handshake has one deadline from the moment the connection opens: trickling bytes does not extend it.
    @Test func aTrickledHandshakeIsDroppedAtItsDeadline() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.automation.server.handshakeTimeout = 0.5
        harness.automation.setEnabled(true)
        let fd = try harness.connect(); defer { close(fd) }
        let opened = try await eventually { harness.automation.server.openConnections == 1 }
        // One byte every 100 ms for 4 s, never a whole line: each read succeeds well inside any per-read timeout.
        let trickle = Task.detached { for _ in 0..<40 { var byte = UInt8(ascii: "{"); if write(fd, &byte, 1) != 1 { return }; try? await Task.sleep(for: .milliseconds(100)) } }
        defer { trickle.cancel() }
        let dropped = try await eventually(.seconds(2)) { harness.automation.server.openConnections == 0 }
        #expect(opened && dropped, "The trickled handshake still holds its slot.")
    }

    /// A revoked secret stays revoked across relaunches even when its Keychain item could not be removed.
    @Test func aRevokedSecretStaysRevokedWhenItsKeychainItemCannotBeRemoved() async throws {
        // The item cannot be deleted: its value is replaced with one nobody was given.
        let stuck = StuckStore()
        let harness = try Harness(store: stuck); defer { harness.cleanUp() }
        harness.automation.setEnabled(true)
        let original = try #require(harness.automation.secret)
        stuck.failsDelete = true
        harness.automation.revokeSecret()
        let left = try stuck.load()
        #expect(harness.automation.secret == nil && harness.automation.lastError?.contains("Keychain error") == true && left != nil && left != original, "The revoked secret is still in the store.")
        harness.automation.stop()

        // The item can be neither deleted nor rewritten: the revocation itself is remembered.
        let frozen = StuckStore()
        let second = try Harness(store: frozen); defer { second.cleanUp() }
        second.automation.setEnabled(true)
        let kept = try #require(second.automation.secret)
        frozen.failsDelete = true; frozen.failsSave = true
        second.automation.revokeSecret()
        second.automation.stop()
        let relaunched = second.relaunched(); defer { relaunched.stop() }
        relaunched.startIfEnabled()
        let old = try Bridge(secret: kept, socket: second.socket); defer { old.close() }
        let refused = refusal(try await old.request("tools/list"))
        let frozenValue = try frozen.load()
        #expect(frozenValue == kept && relaunched.isListening && relaunched.secret == nil && refused?.contains("revoked") == true, "\(refused ?? "the revoked secret was accepted after a relaunch")")
        // A new secret ends the revocation, in this launch and the next.
        frozen.failsSave = false
        relaunched.regenerateSecret()
        let renewed = try #require(relaunched.secret)
        relaunched.stop()
        let next = second.relaunched(); defer { next.stop() }
        next.startIfEnabled()
        let current = try Bridge(secret: renewed, socket: second.socket); defer { current.close() }
        let served = try await current.request("tools/list")
        #expect(renewed != kept && next.secret == renewed && served["result"] != nil)
    }

    /// A second LensWorks that serves nobody never rewrites the secret the serving one accepts.
    @Test func aLensWorksThatIsNotServingCannotRegenerateOrRevokeTheSharedSecret() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        harness.automation.setEnabled(true)
        let secret = try #require(harness.automation.secret)
        let second = harness.relaunched(); second.startIfEnabled()
        second.regenerateSecret()
        let afterRegenerate = try harness.store.load()
        #expect(!second.isListening && harness.automation.secretChangeReason == nil
                && second.secretChangeReason == "Another LensWorks is serving automation for this Mac account. Change the secret there."
                && afterRegenerate == secret && second.secret == secret)
        second.revokeSecret()
        let afterRevoke = try harness.store.load()
        let bridge = try Bridge(secret: secret, socket: harness.socket); defer { bridge.close() }
        let served = try await bridge.request("tools/list")
        #expect(afterRevoke == secret && second.secret == secret && harness.defaults.object(forKey: LensWorksAutomation.revokedKey) == nil && served["result"] != nil)
    }

    /// A copied secret is marked concealed, so clipboard managers do not keep it.
    @Test func copiedSecretsAreMarkedConcealedOnThePasteboard() throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        harness.automation.copyToPasteboard("the-secret", pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == "the-secret" && pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }

    /// Which commands ask the person first is the registry's own flag, and a confirmation's names are clipped.
    @Test func confirmationIsDrivenByTheRegistryAndItsNamesAreClipped() throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let rows = harness.automation.tools.listCommands()
        let confirmed: Set<LensWorksCommandID> = [.deleteVirtualFolder, .deleteKeyword, .save, .saveAs, .exportPNG, .exportJPEG, .locateFolder, .openCatalog, .newCatalog]
        #expect(Set(LensWorksCommandRegistry.descriptors.filter(\.requiresAgentConfirmation).map(\.id)) == confirmed
                && Set(rows.filter { $0["requiresConfirmation"] as? Bool == true }.compactMap { $0["id"] as? String }) == Set(confirmed.map(\.rawValue)))
        // Document and catalog commands batch; history steps and project-file commands run one at a time.
        #expect(Set(rows.filter { $0["batchable"] as? Bool == true }.compactMap { $0["id"] as? String })
                == Set(LensWorksAgentTools.agentCommands.filter { $0.agentAccess.kind != .standalone }.map(\.rawValue)))
        #expect(LensWorksAgentConfirmation.Item(action: "Delete", name: String(repeating: "n", count: 5_000)).name.count == 256)
    }

    // MARK: Batch

    /// Counts how often a connection was asked whether it is still current.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
    private func batchResults(_ result: [String: Any]) -> [[String: Any]] { (result["structuredContent"] as? [String: Any])?["results"] as? [[String: Any]] ?? [] }

    /// Every member is checked before any runs: one bad member refuses the whole batch and nothing is dispatched.
    @Test func aBatchIsRefusedWholeWhenAnyMemberCannotRun() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID), tools = harness.automation.tools
        let hide: [String: Any] = ["command": "layer.visibility", "arguments": ["layers": [layer.uuidString], "visible": false]]
        func refused(_ members: [[String: Any]], _ expected: String, _ comment: Comment) async {
            LensWorksCommandDispatcher.perform(.init(.fitCanvas)) {}
            let result = await tools.call("batch", arguments: ["commands": members])
            // Refused with the reason, and nothing was dispatched, changed or recorded: not even the valid first member.
            #expect(result["isError"] as? Bool == true && text(result) == expected
                    && LensWorksCommandDispatcher.lastInvocation?.id == .fitCanvas && session.activeLayer?.isVisible == true && session.history.undoCount == 0 && !session.isModified, comment)
        }
        await refused([hide, ["command": "layer.nope"]], "Command 2: Name a command id from list_commands. Nothing was run.", "unknown command")
        await refused([hide, ["command": "view.fit"]], "Command 2: Agents cannot run view.fit. " + LensWorksAgentExclusion.canvasZoom.rawValue + " Nothing was run.", "a command agents cannot run")
        await refused([hide, ["command": "file.closeProject"]], "Command 2: file.closeProject cannot be part of a batch (it opens, saves or switches projects or the catalog); run it with invoke_command. Nothing was run.", "a project command in a batch")
        await refused([hide, ["command": "layer.opacity", "arguments": ["opacity": "half"]]], "Command 2: opacity must be a number from 0 through 1. Nothing was run.", "a bad argument")
        await refused([hide, ["command": "layer.opacity", "arguments": ["opacity": 3]]], "Command 2 (layer.opacity): Opacity must be a finite value from 0 through 1. Nothing was run.", "an argument the app does not admit")
        await refused([hide, ["command": "layer.opacity", "arguments": ["opacity": 0.5, "layers": [UUID().uuidString]]]], "Command 2 (layer.opacity): The requested layer is no longer in this document. Nothing was run.", "a layer that is not there")
        await refused([hide, ["command": "layer.visibility", "arguments": ["visble": true]]], "Command 2: Unknown argument “visble” for layer.visibility. Its arguments are: layers, visible. Nothing was run.", "an unknown key")
        await refused([hide, ["command": "edit.undo"]], "Command 2: edit.undo and edit.redo cannot be part of a batch; run them with invoke_command. Nothing was run.", "undo in a batch")
        await refused([hide, ["command": "catalog.rating", "arguments": ["rating": 3]]], "A batch cannot mix document commands with catalog commands: the catalog cannot roll back with the document. Send them as two batches. Nothing was run.", "a mixed batch")
        await refused(Array(repeating: hide, count: LensWorksAgentTools.batchLimit + 1), "A batch carries at most 64 commands; this one has 65. Nothing was run.", "too many members")
        await refused([], "commands must list at least one {command, arguments} object.", "an empty batch")
        // Exactly the limit runs.
        let full = await tools.call("batch", arguments: ["commands": Array(repeating: ["command": "layer.visibility", "arguments": ["layers": [layer.uuidString]]] as [String: Any], count: LensWorksAgentTools.batchLimit)])
        #expect(full["isError"] as? Bool == false && batchResults(full).count == 64, "\(text(full))")
    }

    /// A document batch is one agent history entry: one Undo, the agent's or the person's, reverts all of it.
    @Test func aDocumentBatchIsOneAgentHistoryEntryThatOneUndoReverts() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); session.addBlankLayer(); session.history.reset(); harness.session = session
        let layers = try #require(session.document?.layers), starting = try #require(session.document)
        let first = layers[0].id, second = layers[1].id
        harness.automation.setEnabled(true)
        let bridge = try Bridge(secret: try #require(harness.automation.secret), socket: harness.socket); defer { bridge.close() }
        let result = try await bridge.call("batch", ["commands": [
            ["command": "layer.visibility", "arguments": ["layers": [first.uuidString], "visible": false]],
            ["command": "layer.opacity", "arguments": ["layers": [second.uuidString], "opacity": 0.5]],
            ["command": "layer.rename", "arguments": ["layer": first.uuidString, "name": "Batched"]]
        ]])
        let content = result["structuredContent"] as? [String: Any]
        #expect(result["isError"] as? Bool == false && content?["kind"] as? String == "document" && content?["completed"] as? Bool == true && content?["changed"] as? Bool == true
                && content?["history"] as? String == "3 Document Commands (Agent)"
                && batchResults(result).map { $0["command"] as? String } == ["layer.visibility", "layer.opacity", "layer.rename"]
                && batchResults(result).allSatisfy { $0["status"] as? String == "ran" && $0["changed"] as? Bool == true } && batchResults(result).map { $0["index"] as? Int } == [1, 2, 3], "\(result)")
        func applied() -> Bool { session.document?.layers[0].isVisible == false && session.document?.layers[0].name == "Batched" && session.document?.layers[1].opacity == 0.5 }
        #expect(applied() && session.history.undoCount == 1 && session.history.undoName == "3 Document Commands (Agent)")
        // The agent may undo its own batch: the one entry is its own.
        let undone = try await bridge.call("invoke_command", ["command": "edit.undo"])
        #expect(undone["isError"] as? Bool == false && session.document == starting && session.history.undoCount == 0, "\(undone)")
        // And one Undo in the app reverts all of it.
        session.redo()
        let redone = applied()
        session.undo()
        #expect(redone && session.document == starting && session.history.undoCount == 0 && session.history.redoName == "3 Document Commands (Agent)")
    }

    /// A document batch that fails part-way is rolled back whole, and the connection is checked before every member.
    @Test func aDocumentBatchStoppedPartWayIsRolledBackWhole() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID), tools = harness.automation.tools
        session.runCommand(.opacity([layer], 0.9))
        let starting = try #require(session.document), revision = session.history.currentRevision, own = session.history.undoName
        let members: [[String: Any]] = [
            ["command": "layer.visibility", "arguments": ["visible": false]],
            ["command": "layer.rename", "arguments": ["name": "Half done"]],
            ["command": "layer.opacity", "arguments": ["opacity": 0.1]]
        ]
        // The connection is dropped (its secret revoked, say) after the second member ran: one check before the
        // batch and one before each member, so the fourth check is the one that fails.
        let checks = Counter()
        let dropped = LensWorksAutomationCaller(connection: nil) { checks.next() <= 3 }
        let result = await tools.call("batch", arguments: ["commands": members], caller: dropped)
        #expect(result["isError"] as? Bool == true && text(result) == "The automation connection or its secret changed before command 3. The whole batch was rolled back: the document, its history, the selection and the palette colors are as they were (anything a cut or copy put on the clipboard stays there)."
                && checks.value == 4 && LensWorksCommandDispatcher.lastInvocation?.id == .rename)
        #expect(session.document == starting && session.history.currentRevision == revision && session.history.undoCount == 1 && session.history.undoName == own
                && session.history.undoOrigin == .user && !session.canRedo && session.activeLayerID == layer && session.selectedLayerIDs == [layer])
        // The same batch on a live connection runs: the rollback left no transaction open.
        let ran = await tools.call("batch", arguments: ["commands": members])
        #expect(ran["isError"] as? Bool == false && session.activeLayer?.name == "Half done" && session.history.undoCount == 2, "\(text(ran))")
    }

    /// No batch runs under the person's open interaction, whichever kind of batch it is.
    @Test func aBatchIsRefusedWhileThePersonHasAModalInteractionOpen() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let session = document(); harness.session = session
        let layer = try #require(session.activeLayerID), tools = harness.automation.tools
        let catalogBatch: [String: Any] = ["commands": [["command": "catalog.rating", "arguments": ["rating": 3]]]]
        let documentBatch: [String: Any] = ["commands": [["command": "layer.visibility", "arguments": ["visible": false]]]]
        session.cropRect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let cropping = [await tools.call("batch", arguments: catalogBatch), await tools.call("batch", arguments: documentBatch)]
        let kept = session.cropRect != nil && session.history.undoCount == 0
        session.cropRect = nil
        let token = try session.beginCommandInteraction(.opacity([layer], 1))
        let interacting = await tools.call("batch", arguments: catalogBatch)
        try session.cancelCommandInteraction(token)
        // With nothing open the document batch runs: the refusals were the open interactions'.
        let free = await tools.call("batch", arguments: documentBatch)
        #expect(cropping.allSatisfy { $0["isError"] as? Bool == true && text($0) == "Finish the current edit in LensWorks first. Nothing was run." } && kept
                && interacting["isError"] as? Bool == true && text(interacting) == "Finish the current layer interaction first. Nothing was run."
                && free["isError"] as? Bool == false && session.activeLayer?.isVisible == false, "\(cropping.map(text)) \(text(interacting)) \(text(free))")
    }

    /// Permanent members are confirmed once, for the whole batch, before anything runs; anything but Allow refuses
    /// the whole batch, and what the person approved is re-admitted after Allow.
    @Test func aBatchOfPermanentDeletesIsConfirmedOnceAndOnlyAllowRunsIt() async throws {
        let harness = try Harness(); defer { harness.cleanUp() }
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { model in
            harness.catalog = model
            try await model.createGroup("Doomed A"); try await model.createGroup("Doomed B")
            let a = try model.group(named: "Doomed A"), b = try model.group(named: "Doomed B")
            harness.automation.setEnabled(true)
            harness.showWindow()
            let tools = harness.automation.tools
            func delete(_ folders: [String]) -> [String: Any] { ["commands": folders.map { ["command": "catalog.virtualFolder.delete", "arguments": ["folder": $0]] as [String: Any] }] }
            @MainActor func remaining() async throws -> Set<String> {
                try await model.loadGroups()
                return Set(model.groups.map(\.id)).intersection([a.id, b.id])
            }
            /// Sends the batch and waits for its one sheet: both folders named from the app's own rows, never in
            /// the question, and nothing deleted while it waits.
            @MainActor func ask(caller: LensWorksAutomationCaller = .inProcess) async throws -> Task<[String: Any], Never> {
                let call = Task { await tools.call("batch", arguments: delete([a.id, b.id]), caller: caller) }
                let pending = try await pendingSheet(harness).confirmation
                #expect(pending.items.map(\.name) == ["Doomed A", "Doomed B"] && !pending.title.contains("Doomed") && !pending.message.contains("Doomed"), "\(pending.title)")
                let waiting = try await remaining()
                #expect(waiting == [a.id, b.id], "deleted while the sheet waits")
                return call
            }
            // The same folder twice, and a folder that is not there, are refused before anyone is asked.
            harness.automation.confirmationTimeout = .seconds(2) // Only matters when an expectation below fails.
            let twice = await tools.call("batch", arguments: delete([a.id, a.id]))
            #expect(twice["isError"] as? Bool == true && text(twice) == "Command 2 (catalog.virtualFolder.delete): The same virtual folder is deleted twice. Nothing was run." && harness.automation.pendingConfirmation == nil)
            let missing = await tools.call("batch", arguments: delete([a.id, "no-such-folder"]))
            #expect(missing["isError"] as? Bool == true && text(missing) == "Command 2 (catalog.virtualFolder.delete): The virtual folder is not on the current folder page. Nothing was run." && harness.automation.pendingConfirmation == nil)
            harness.automation.confirmationTimeout = LensWorksAutomation.confirmationTimeout

            // Declined.
            var call = try await ask()
            try await answer(harness, allow: false)
            var result = await call.value
            var left = try await remaining()
            #expect(result["isError"] as? Bool == true && text(result) == "The person declined in LensWorks: nothing was run or deleted." && left == [a.id, b.id])

            // Busy: a second batch while the first is being asked is refused, and the first is still asked.
            call = try await ask()
            let busy = await tools.call("batch", arguments: delete([a.id, b.id]))
            left = try await remaining()
            #expect(busy["isError"] as? Bool == true && text(busy).contains("already asking the person") && harness.automation.pendingConfirmation != nil && left == [a.id, b.id])
            // The secret changes while the person is being asked.
            harness.automation.regenerateSecret()
            result = await call.value
            left = try await remaining()
            #expect(result["isError"] as? Bool == true && text(result).contains("did not answer the confirmation") && left == [a.id, b.id], "the secret changed")

            // Timed out.
            harness.automation.confirmationTimeout = .seconds(1)
            call = try await ask()
            result = await call.value
            left = try await remaining()
            #expect(result["isError"] as? Bool == true && text(result).contains("did not answer the confirmation") && harness.automation.pendingConfirmation == nil && left == [a.id, b.id], "timed out")
            harness.automation.confirmationTimeout = LensWorksAutomation.confirmationTimeout

            // Allowed, but a folder changed while the sheet was open: what the person approved is no longer there.
            call = try await ask()
            try await model.renameGroup(b, name: "Doomed B renamed")
            try await answer(harness, allow: true)
            result = await call.value
            left = try await remaining()
            #expect(result["isError"] as? Bool == true && text(result) == "A virtual folder changed while waiting for confirmation: nothing was run or deleted." && left == [a.id, b.id])
            if let renamed = model.groups.first(where: { $0.id == b.id }) { try await model.renameGroup(renamed, name: "Doomed B") }

            // Allowed, but the connection was dropped before the second member: the first stays deleted (the catalog
            // cannot roll back) and the reply says exactly what ran. The checks: the batch, the answer, each member.
            let checks = Counter()
            let dropped = LensWorksAutomationCaller(connection: nil) { checks.next() <= 3 }
            call = try await ask(caller: dropped)
            try await answer(harness, allow: true)
            result = await call.value
            left = try await remaining()
            #expect(result["isError"] as? Bool == true && batchResults(result).map { $0["status"] as? String } == ["ran", "notRun"]
                    && (result["structuredContent"] as? [String: Any])?["completed"] as? Bool == false && checks.value == 4 && left == [b.id], "\(result)")

            // Allowed: one confirmation, then every member runs. (Its own folders, whatever happened above.)
            try await model.createGroup("Allowed A"); try await model.createGroup("Allowed B")
            let final = [try model.group(named: "Allowed A").id, try model.group(named: "Allowed B").id]
            let allowed = Task { await tools.call("batch", arguments: delete(final)) }
            try await answer(harness, allow: true)
            result = await allowed.value
            try await model.loadGroups()
            #expect(result["isError"] as? Bool == false && batchResults(result).map { $0["status"] as? String } == ["ran", "ran"]
                    && !model.groups.contains { final.contains($0.id) } && harness.automation.pendingConfirmation == nil, "\(result)")
            harness.catalog = nil
        }
    }
}
