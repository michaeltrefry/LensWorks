import AppKit
import Foundation
import Observation
import Security
import SwiftUI

/// Where the automation secret lives. The app uses the Keychain; tests inject an in-memory store so they never touch
/// the person's own items or keychain search list.
nonisolated protocol LensWorksAutomationSecretStore: AnyObject, Sendable {
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

nonisolated struct LensWorksKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain error \(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")
    }
}

/// A generic-password item in the account's default keychain.
nonisolated final class LensWorksKeychainSecretStore: LensWorksAutomationSecretStore, @unchecked Sendable {
    static let appService = "net.trefry.lensworks.automation"
    static let appAccount = "mcp-bridge-secret"
    let service: String, account: String
    init(service: String = appService, account: String = appAccount) {
        self.service = service; self.account = account
    }
    private func query(_ extra: [CFString: Any] = [:]) -> CFDictionary {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        return query.merging(extra) { $1 } as CFDictionary
    }
    func load() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LensWorksKeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }
    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(), [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query([kSecValueData: data, kSecAttrLabel: "LensWorks automation secret",
                                          kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]), nil)
            guard added == errSecSuccess else { throw LensWorksKeychainError(status: added) }
        } else if status != errSecSuccess { throw LensWorksKeychainError(status: status) }
    }
    func delete() throws {
        let status = SecItemDelete(query())
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LensWorksKeychainError(status: status) }
    }
}

nonisolated final class LensWorksMemorySecretStore: LensWorksAutomationSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    init(_ secret: String? = nil) { self.secret = secret }
    func load() throws -> String? { lock.withLock { secret } }
    func save(_ secret: String) throws { lock.withLock { self.secret = secret } }
    func delete() throws { lock.withLock { secret = nil } }
}

/// One in-app confirmation an agent's permanent commands are waiting on. `items` names each change from the app's
/// own data; the names never become part of the title or message.
struct LensWorksAgentConfirmation: Identifiable {
    struct Item: Identifiable {
        static let nameLimit = 256
        let id = UUID()
        /// The registered command's label.
        let action: String
        /// What it acts on, clipped; the sheet shows it in its own one-line field.
        let name: String
        init(action: String, name: String) { self.action = action; self.name = Self.clipped(name) }
        /// At most `nameLimit` characters, cut in the middle: a long path keeps the folder it starts in and the file
        /// name it ends with, which is what the person is asked to let go of.
        static func clipped(_ name: String) -> String {
            guard name.count > nameLimit else { return name }
            let head = (nameLimit - 1) / 2
            return name.prefix(head) + "…" + name.suffix(nameLimit - 1 - head)
        }
    }
    let id = UUID()
    let title: String
    let message: String
    var items: [Item] = []
}
/// How a confirmation ended: the person's answer, no answer (timed out, automation turned off, secret changed), or
/// never asked because another confirmation was already open.
enum LensWorksAgentConfirmationAnswer: Equatable { case allowed, declined, unanswered, busy }

/// Settings › Automation: off by default. When on, a secret (Keychain) authenticates the MCP bridge over a socket
/// only this Mac account can reach, and agents run registered commands through the same dispatcher as menus.
@Observable
final class LensWorksAutomation {
    static let enabledKey = "LensWorksAutomationEnabled"
    /// Set by Revoke and cleared by a new secret, so a revoked secret stays revoked across relaunches even when its
    /// Keychain item could not be removed.
    static let revokedKey = "LensWorksAutomationSecretRevoked"
    static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let helperName = "LensWorksMCP"
    static let confirmationTimeout: Duration = .seconds(120)

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let secretStore: LensWorksAutomationSecretStore
    @ObservationIgnored let tools: LensWorksAgentTools
    /// Sessions that own a catalog and editor state without adding a tab or opening a window.
    @ObservationIgnored let headless: LensWorksHeadlessSessions
    /// The folders the person granted to automation: the only places an agent's command may name a file.
    let folders: LensWorksGrantedFolders
    @ObservationIgnored private(set) var server: LensWorksAutomationServer!
    private(set) var isEnabled: Bool
    private(set) var secret: String?
    private(set) var isListening = false
    private(set) var lastError: String?
    /// Another LensWorks of this Mac account serves the socket: this one accepts nobody.
    private(set) var isServedElsewhere = false
    var showsSecret = false
    /// The destructive agent command waiting for the person's answer, shown as a sheet on the app's window.
    private(set) var pendingConfirmation: LensWorksAgentConfirmation?
    @ObservationIgnored private var confirmationReply: CheckedContinuation<LensWorksAgentConfirmationAnswer, Never>?
    /// The connection whose request the pending confirmation belongs to: when it hangs up, nobody is left to answer for.
    @ObservationIgnored private var confirmationOwner: ObjectIdentifier?
    /// The sheet asking `pendingConfirmation`, and the window it is attached to (nil: shown on its own).
    @ObservationIgnored private(set) var confirmationPanel: NSWindow?
    @ObservationIgnored private weak var confirmationParent: NSWindow?
    /// The window a confirmation sheet attaches to: the app's main window, else any visible one.
    @ObservationIgnored var confirmationWindow: () -> NSWindow? = {
        NSApp?.mainWindow ?? NSApp?.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }
    @ObservationIgnored var confirmationTimeout = LensWorksAutomation.confirmationTimeout
    /// Adjusts a confirmation's window before it is shown (tests keep theirs invisible).
    @ObservationIgnored var prepareConfirmationPanel: (NSWindow) -> Void = { _ in }
    /// Whether a confirmation asks for the person's attention in the Dock.
    @ObservationIgnored var requestsAttention = true

    init(defaults: UserDefaults = LensWorksUserState.defaults, secretStore: LensWorksAutomationSecretStore = LensWorksUserState.secretStore(),
         socketPath: String = LensWorksAutomationServer.defaultSocketPath(),
         session: @escaping () -> EditorSession?, catalog: @escaping () -> LensWorksCatalog?) {
        self.defaults = defaults; self.secretStore = secretStore
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        folders = LensWorksGrantedFolders(defaults: defaults)
        tools = LensWorksAgentTools(session: session, catalog: catalog, folders: folders)
        headless = LensWorksHeadlessSessions(folders: folders, attachedCatalog: catalog)
        tools.automation = self
        server = LensWorksAutomationServer(socketPath: socketPath, handler: { [weak self] request, caller in
            await self?.handle(request, caller: caller) ?? LensWorksAgentTools.encodeError(id: nil, code: -32000, "LensWorks is quitting.")
        }, hungUp: { [weak self] connection in
            Task { @MainActor in self?.connectionHungUp(connection) }
        })
    }

    var socketPath: String { server.socketPath }
    /// The bridge an MCP client launches: Contents/Helpers/LensWorksMCP in this app.
    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + Self.helperName).path }

    /// Whether a launch with these arguments and environment serves automation without being asked. A unit-test host
    /// and every scripted launch (any `--lensworks-…` argument: catalog plans, evidence runs, fixture imports) never
    /// serve the person's automation socket or read their Keychain item.
    nonisolated static func servesAtLaunch(arguments: [String], environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil && !arguments.contains { $0.hasPrefix("--lensworks-") }
    }

    /// Starts serving when the setting is on (at launch). Reads the Keychain only then.
    func startIfEnabled() {
        guard isEnabled else { return }
        do { secret = try loadSecret() } catch { lastError = error.localizedDescription }
        startServer()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            do { secret = try loadSecret() } catch { lastError = error.localizedDescription }
            startServer()
            // A LensWorks that serves nobody never rewrites the secret the serving one accepts.
            if secret == nil, !isServedElsewhere {
                do { try storeNewSecret(); if isListening { lastError = nil } } catch { lastError = error.localizedDescription }
            }
        } else {
            server.stop(); isListening = false; isServedElsewhere = false
            endConfirmation(.unanswered)
        }
    }

    /// The stored secret, or none while it is revoked.
    private func loadSecret() throws -> String? {
        defaults.bool(forKey: Self.revokedKey) ? nil : try secretStore.load()
    }

    /// Why the secret cannot be regenerated or revoked here, or nil when it can: another LensWorks serves automation
    /// and would keep accepting the secret this one replaced.
    var secretChangeReason: String? {
        isServedElsewhere ? "Another LensWorks is serving automation for this Mac account. Change the secret there." : nil
    }

    /// A new secret: the old one stops working and every connected client is disconnected.
    func regenerateSecret() {
        guard secretChangeReason == nil else { return }
        do { try storeNewSecret(); lastError = nil } catch { lastError = error.localizedDescription }
    }

    /// No secret at all: every connection is refused until a new one is generated, in this launch and later ones.
    func revokeSecret() {
        guard secretChangeReason == nil else { return }
        defaults.set(true, forKey: Self.revokedKey)
        do { try secretStore.delete(); lastError = nil } catch {
            lastError = error.localizedDescription
            // The item could not be removed: replace its value with one nobody was given.
            if let unknown = try? Self.randomSecret() { try? secretStore.save(unknown) }
        }
        secret = nil
        server.setSecretDigest(nil)
        endConfirmation(.unanswered)
    }

    func stop() { server.stop(); isListening = false; endConfirmation(.unanswered) }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LensWorksKeychainError(status: errSecAllocate) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func storeNewSecret() throws {
        let value = try Self.randomSecret()
        try secretStore.save(value)
        defaults.removeObject(forKey: Self.revokedKey)
        secret = value
        server.setSecretDigest(LensWorksAutomationServer.digest(value))
        endConfirmation(.unanswered)
    }

    private func startServer() {
        server.setSecretDigest(secret.map(LensWorksAutomationServer.digest))
        do { try server.start(); isListening = true; isServedElsewhere = false; if secret != nil { lastError = nil } }
        catch {
            isListening = false; lastError = error.localizedDescription
            if case LensWorksAutomationServer.ServerError.alreadyServing = error { isServedElsewhere = true } else { isServedElsewhere = false }
        }
    }

    /// The JSON an MCP client (Claude Code, Claude Desktop, …) needs to launch the bridge with the current secret.
    func clientConfiguration(secret: String) -> String {
        let configuration: [String: Any] = ["mcpServers": ["lensworks": ["command": helperPath, "args": [String](), "env": ["LENSWORKS_MCP_SECRET": secret]]]]
        let data = (try? JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Copies a secret (or a configuration carrying it), marked concealed so clipboard managers do not keep it.
    func copyToPasteboard(_ text: String, pasteboard: NSPasteboard = LensWorksUserState.pasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedPasteboardType)
    }

    /// Settings › Automation › Grant Folder…: the person picks a folder agents may read and write files in.
    func chooseGrantedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Grant"; panel.message = "AI agents will be able to open, import, save and export files inside this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try folders.grant(url); lastError = nil } catch { lastError = error.localizedDescription }
    }

    // MARK: Confirmations

    /// Asks the person in the app with a sheet and waits for Allow or Don’t Allow. Nothing but Allow lets the
    /// command run: no answer in time, automation turned off and a changed secret all end it unanswered.
    /// `owner` is the connection that asked: when it hangs up the confirmation ends unanswered.
    func confirm(_ confirmation: LensWorksAgentConfirmation, owner: ObjectIdentifier? = nil) async -> LensWorksAgentConfirmationAnswer {
        guard pendingConfirmation == nil else { return .busy }
        pendingConfirmation = confirmation; confirmationOwner = owner
        presentConfirmation(confirmation)
        if requestsAttention { NSApp?.requestUserAttention(.criticalRequest) }
        let id = confirmation.id, limit = confirmationTimeout
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, self?.pendingConfirmation?.id == id else { return }
            self?.endConfirmation(.unanswered)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in confirmationReply = continuation }
    }

    /// The person's answer to the pending confirmation (the sheet's Allow / Don’t Allow).
    func resolveConfirmation(_ allowed: Bool) { endConfirmation(allowed ? .allowed : .declined) }

    /// A client hung up: a confirmation it was waiting on has nobody left to answer for.
    private func connectionHungUp(_ connection: ObjectIdentifier) {
        if confirmationOwner == connection { endConfirmation(.unanswered) }
    }

    private func endConfirmation(_ answer: LensWorksAgentConfirmationAnswer) {
        guard pendingConfirmation != nil else { return }
        pendingConfirmation = nil; confirmationOwner = nil
        if let panel = confirmationPanel {
            if let parent = confirmationParent { parent.endSheet(panel) } else { panel.close() }
        }
        confirmationPanel = nil; confirmationParent = nil
        let reply = confirmationReply; confirmationReply = nil
        reply?.resume(returning: answer)
    }

    /// The confirmation as a sheet on the app's window, or as its own window when none is open.
    private func presentConfirmation(_ confirmation: LensWorksAgentConfirmation) {
        let panel = NSPanel(contentViewController: NSHostingController(rootView: LensWorksAgentConfirmationSheet(automation: self, confirmation: confirmation)))
        panel.styleMask = [.titled]
        panel.title = "LensWorks Automation"
        panel.isReleasedWhenClosed = false
        confirmationPanel = panel
        prepareConfirmationPanel(panel)
        if let parent = confirmationWindow() {
            confirmationParent = parent
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.orderFrontRegardless()
        }
    }

    // MARK: Requests

    private func handle(_ request: Data, caller: LensWorksAutomationCaller) async -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            return LensWorksAgentTools.encodeError(id: nil, code: -32700, "The request was not a JSON object.")
        }
        let id = object["id"]
        guard isEnabled, isListening else { return LensWorksAgentTools.encodeError(id: id, code: -32000, "LensWorks automation is off.") }
        // A request read before its connection was dropped (secret regenerated or revoked, client gone) never runs.
        guard caller.isCurrent() else { return LensWorksAgentTools.encodeError(id: id, code: -32000, "This automation connection was closed: its secret changed or the client disconnected.") }
        switch object["method"] as? String {
        case "tools/list": return LensWorksAgentTools.encodeResult(id: id, ["tools": LensWorksAgentTools.definitions + LensWorksHeadlessSessions.definitions])
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "tools/call needs a tool name.") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if LensWorksAgentTools.toolNames.contains(name) {
                return LensWorksAgentTools.encodeResult(id: id, await tools.call(name, arguments: arguments, caller: caller))
            }
            guard LensWorksHeadlessSessions.toolNames.contains(name) else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "Unknown tool: \(name)") }
            return LensWorksAgentTools.encodeResult(id: id, await headless.call(name, arguments: arguments))
        case let method: return LensWorksAgentTools.encodeError(id: id, code: -32601, "Unsupported method: \(method ?? "none")")
        }
    }
}

/// A windowless catalog/document owner for MCP. It adds lifetime and jobs, but all command execution still passes
/// through `LensWorksAgentTools` and the registry used by attached mode.
@MainActor
final class LensWorksHeadlessSessions {
    static let toolNames: Set<String> = ["headless_open", "headless_close", "headless_run", "catalog_query", "catalog_select", "develop_controls", "develop_get", "develop_set", "headless_export", "jobs_list", "jobs_cancel"]
    static var definitions: [[String: Any]] {
        func schema(_ required: [String] = [], _ properties: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties]
            if !required.isEmpty { value["required"] = required }
            return value
        }
        return [
            ["name": "headless_open", "description": "Open an existing granted catalog without a window. A catalog already open in attached mode is refused.", "inputSchema": schema(["catalog"], ["catalog": ["type": "string"]])],
            ["name": "headless_close", "description": "Close a headless session and release its catalog worker.", "inputSchema": schema(["session"], ["session": ["type": "string"]])],
            ["name": "headless_run", "description": "Run one registered command headlessly. Irreversible commands are refused headlessly.", "inputSchema": schema(["session", "command"], ["session": ["type": "string"], "command": ["type": "string"], "arguments": ["type": "object"]])],
            ["name": "catalog_query", "description": "Query the current page of a headless catalog.", "inputSchema": schema(["session"], ["session": ["type": "string"], "text": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 256]])],
            ["name": "catalog_select", "description": "Select a photo id returned by catalog_query and load its develop recipe.", "inputSchema": schema(["session", "photo"], ["session": ["type": "string"], "photo": ["type": "string"]])],
            ["name": "develop_controls", "description": "List stable develop control ids, ranges and current values.", "inputSchema": schema(["session"], ["session": ["type": "string"]])],
            ["name": "develop_get", "description": "Read one develop setting by control id.", "inputSchema": schema(["session", "control"], ["session": ["type": "string"], "control": ["type": "string"]])],
            ["name": "develop_set", "description": "Write one develop setting through the normal registered recipe command.", "inputSchema": schema(["session", "control", "value"], ["session": ["type": "string"], "control": ["type": "string"], "value": ["type": "number"]])],
            ["name": "headless_export", "description": "Export the selected photo into a granted folder as a cancellable PNG job. Existing files are never overwritten.", "inputSchema": schema(["session", "path"], ["session": ["type": "string"], "path": ["type": "string"], "wait": ["type": "boolean"]])],
            ["name": "jobs_list", "description": "List headless jobs with progress.", "inputSchema": schema(), "annotations": ["readOnlyHint": true]],
            ["name": "jobs_cancel", "description": "Cancel a queued or running headless job and remove its unpublished output.", "inputSchema": schema(["job"], ["job": ["type": "string"]])]
        ]
    }

    private final class Session {
        let id = UUID().uuidString
        let catalog: LensWorksCatalog
        let editor: EditorSession
        let controller: ProjectController
        let tools: LensWorksAgentTools
        init(folders: LensWorksGrantedFolders) {
            let catalog = LensWorksCatalog(), editor = EditorSession()
            self.catalog = catalog; self.editor = editor
            controller = ProjectController(session: editor)
            controller.recordsRecentProjects = false
            tools = LensWorksAgentTools(session: { editor }, catalog: { catalog }, folders: folders)
            let controller = controller
            tools.projects = { controller }
        }
    }
    private final class Job {
        enum State: String { case queued, running, completed, cancelled, failed }
        let id = UUID().uuidString
        let session: String
        let destination: URL
        var state: State = .queued
        var progress = 0.0
        var message = "Queued."
        var task: Task<Void, Never>?
        init(session: String, destination: URL) { self.session = session; self.destination = destination }
        var response: [String: Any] { ["id": id, "session": session, "state": state.rawValue, "progress": progress, "message": message] }
    }

    let folders: LensWorksGrantedFolders
    private let attachedCatalog: () -> LensWorksCatalog?
    private var sessions: [String: Session] = [:]
    private var jobs: [String: Job] = [:]
    init(folders: LensWorksGrantedFolders, attachedCatalog: @escaping () -> LensWorksCatalog?) {
        self.folders = folders; self.attachedCatalog = attachedCatalog
    }

    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            let result: [String: Any]
            switch name {
            case "headless_open": result = try await open(arguments)
            case "headless_close": result = try await close(arguments)
            case "headless_run": result = try await run(arguments)
            case "catalog_query": result = try query(arguments)
            case "catalog_select": result = try await select(arguments)
            case "develop_controls": result = try controls(arguments)
            case "develop_get": result = try get(arguments)
            case "develop_set": result = try await set(arguments)
            case "headless_export": result = try await export(arguments)
            case "jobs_list":
                try LensWorksAgentTools.rejectUnknown(arguments, allowed: [], in: name)
                result = ["jobs": jobs.values.map(\.response).sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }]
            case "jobs_cancel": result = try cancel(arguments)
            default: throw LensWorksCommandRefusal(reason: "Unknown headless tool: \(name).")
            }
            return try LensWorksAgentTools.bounded(result)
        } catch {
            return ["content": [["type": "text", "text": String(error.localizedDescription.prefix(4096))]], "isError": true]
        }
    }

    private func text(_ name: String, _ values: [String: Any]) throws -> String {
        guard let value = values[name] as? String, !value.isEmpty else { throw LensWorksCommandRefusal(reason: "\(name) must be a nonempty string.") }
        return value
    }
    private func session(_ values: [String: Any], _ allowed: [String], _ name: String) throws -> Session {
        try LensWorksAgentTools.rejectUnknown(values, allowed: allowed, in: name)
        guard let found = sessions[try text("session", values)] else { throw LensWorksCommandRefusal(reason: "That headless session is no longer open.") }
        return found
    }

    private func open(_ values: [String: Any]) async throws -> [String: Any] {
        try LensWorksAgentTools.rejectUnknown(values, allowed: ["catalog"], in: "headless_open")
        let path = try folders.admit(try text("catalog", values))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw LensWorksCommandRefusal(reason: "There is no catalog folder at that path.") }
        if let attached = attachedCatalog()?.catalogPath, (try? LensWorksGrantedFolders.realPath(attached)) == path.path {
            throw LensWorksCommandRefusal(reason: "That catalog is already open in attached mode, so it cannot also be opened headlessly.")
        }
        guard !sessions.values.contains(where: { $0.catalog.catalogPath == path.path }) else { throw LensWorksCommandRefusal(reason: "That catalog is already open in another headless session.") }
        let made = Session(folders: folders)
        try await folders.withAccess(to: path) { await made.catalog.connect(path.path) }
        guard made.catalog.catalogPath == path.path else { throw LensWorksCommandRefusal(reason: made.catalog.error ?? "The catalog could not be opened.") }
        sessions[made.id] = made
        return ["session": made.id, "catalog": path.path, "mode": "headless"]
    }

    private func close(_ values: [String: Any]) async throws -> [String: Any] {
        let opened = try session(values, ["session"], "headless_close")
        let active = jobs.values.filter { $0.session == opened.id && [.queued, .running].contains($0.state) }
        active.forEach { $0.task?.cancel() }
        for job in active { await job.task?.value }
        try await opened.catalog.close()
        sessions.removeValue(forKey: opened.id)
        return ["session": opened.id, "closed": true]
    }

    private func run(_ values: [String: Any]) async throws -> [String: Any] {
        let opened = try session(values, ["session", "command", "arguments"], "headless_run")
        let raw = try text("command", values)
        guard let id = LensWorksCommandID(rawValue: raw) else { throw LensWorksCommandRefusal(reason: "Name a command id from list_commands.") }
        guard !LensWorksCommandRegistry.descriptor(id).requiresAgentConfirmation else { throw LensWorksCommandRefusal(reason: "\(raw) is irreversible and is refused in headless mode.") }
        if [.exposure, .undoRecipe, .redoRecipe].contains(id) { try await admitSelectedOriginal(opened) }
        let result = try await opened.tools.invoke(["command": raw, "arguments": values["arguments"] as? [String: Any] ?? [:]])
        return ["session": opened.id, "result": result]
    }

    /// A catalog recipe edit reads the selected full-resolution original even though its command has no path argument.
    /// Headless mode applies the same grant rule to that implicit file reach as it does to an explicit export path.
    private func admitSelectedOriginal(_ opened: Session) async throws {
        guard let asset = opened.catalog.selectedAsset else { throw LensWorksCommandRefusal(reason: "Select a catalog photo first.") }
        let original = try await opened.catalog.service.resolve(asset).originalURL
        _ = try folders.admit(original.path)
    }

    private func query(_ values: [String: Any]) throws -> [String: Any] {
        let opened = try session(values, ["session", "text", "limit"], "catalog_query")
        let needle = values["text"] as? String
        let limit = min(256, max(1, (values["limit"] as? NSNumber)?.intValue ?? 100))
        let photos: [[String: Any]] = opened.catalog.assets.filter { asset in
            needle.map { asset.filename.localizedCaseInsensitiveContains($0) } ?? true
        }.prefix(limit).map { asset in
            ["id": asset.id, "filename": asset.filename, "selected": opened.catalog.selection.contains(asset.id)]
        }
        return ["session": opened.id, "photos": photos, "hasMore": opened.catalog.hasMore]
    }

    private func select(_ values: [String: Any]) async throws -> [String: Any] {
        let opened = try session(values, ["session", "photo"], "catalog_select")
        let photo = try text("photo", values)
        guard let asset = opened.catalog.assets.first(where: { $0.id == photo }) else { throw LensWorksCommandRefusal(reason: "Photo \(photo.prefix(64)) is not on the current catalog page.") }
        await opened.catalog.select(asset); try await opened.catalog.loadCatalogVariants()
        guard opened.catalog.selectedAsset?.id == asset.id, opened.catalog.currentCatalogVariant != nil else { throw LensWorksCommandRefusal(reason: opened.catalog.error ?? "The photo could not be selected.") }
        return ["session": opened.id, "photo": asset.id]
    }

    private let exposureControl = "develop.exposure"
    private func checkControl(_ value: String) throws {
        guard [exposureControl, "raw.exposure", "exposure"].contains(value) else { throw LensWorksCommandRefusal(reason: "Unknown develop control “\(value.prefix(64))”. Use develop.exposure.") }
    }
    private func current(_ opened: Session) throws -> LWApplicationDtoVariant {
        guard let value = opened.catalog.currentCatalogVariant else { throw LensWorksCommandRefusal(reason: "Select a catalog photo first.") }
        return value
    }
    private func exposure(_ value: LWApplicationDtoVariant) -> Double { if case .V1(let recipe) = value.recipe { return Double(recipe.exposure_ev.value) }; return 0 }
    private func controls(_ values: [String: Any]) throws -> [String: Any] {
        let opened = try session(values, ["session"], "develop_controls")
        return ["session": opened.id, "controls": [["id": exposureControl, "label": "Exposure", "minimum": -5, "maximum": 5, "value": exposure(try current(opened))]]]
    }
    private func get(_ values: [String: Any]) throws -> [String: Any] {
        let opened = try session(values, ["session", "control"], "develop_get")
        try checkControl(text("control", values))
        return ["session": opened.id, "control": exposureControl, "value": exposure(try current(opened))]
    }
    private func set(_ values: [String: Any]) async throws -> [String: Any] {
        let opened = try session(values, ["session", "control", "value"], "develop_set")
        try checkControl(text("control", values))
        guard let value = (values["value"] as? NSNumber)?.doubleValue, value.isFinite, (-5...5).contains(value) else { throw LensWorksCommandRefusal(reason: "develop.exposure must be a finite number from -5 through 5.") }
        try await admitSelectedOriginal(opened)
        let result = try await opened.tools.invoke(["command": LensWorksCommandID.exposure.rawValue, "arguments": ["exposureEV": value]])
        if result["isError"] as? Bool == true { throw LensWorksCommandRefusal(reason: ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "The develop setting could not be changed.") }
        return ["session": opened.id, "control": exposureControl, "value": value, "result": result]
    }

    private func export(_ values: [String: Any]) async throws -> [String: Any] {
        let opened = try session(values, ["session", "path", "wait"], "headless_export")
        let destination = try folders.admit(try text("path", values))
        guard destination.pathExtension.lowercased() == "png" else { throw LensWorksCommandRefusal(reason: "headless_export currently writes PNG files; path must end in .png.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LensWorksCommandRefusal(reason: "Headless export never overwrites an existing file; choose a new path.") }
        let job = Job(session: opened.id, destination: destination); jobs[job.id] = job
        job.task = Task { @MainActor [weak self, weak opened, weak job] in
            guard let self, let opened, let job else { return }
            job.state = .running; job.progress = 0.1; job.message = "Preparing export."
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".lensworks-export-\(job.id).png")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                // Publish the job before it begins expensive work, so a client can reliably observe and cancel it.
                try await Task.sleep(for: .milliseconds(10))
                try Task.checkCancellation()
                guard let asset = opened.catalog.selectedAsset else { throw LensWorksCommandRefusal(reason: "Select a catalog photo before exporting.") }
                let original = try await opened.catalog.service.resolve(asset).originalURL
                _ = try self.folders.admit(original.path)
                job.progress = 0.25; job.message = "Opening source."
                let imported = try await opened.tools.invoke(["command": LensWorksCommandID.importImages.rawValue, "arguments": ["paths": [original.path]]])
                if imported["isError"] as? Bool == true { throw LensWorksCommandRefusal(reason: ((imported["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "The source could not be opened.") }
                // The catalog recipe and headless export share the same selected variant. Apply its RAW exposure through
                // the regular Camera Raw filter command before exporting the transient document.
                let developed = try await opened.tools.invoke(["command": LensWorksCommandID.filter.rawValue, "arguments": ["kind": FilterKind.cameraRaw.rawValue, "settings": ["exposure": self.exposure(try self.current(opened))]]])
                if developed["isError"] as? Bool == true { throw LensWorksCommandRefusal(reason: ((developed["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "The develop recipe could not be rendered.") }
                try Task.checkCancellation()
                job.progress = 0.6; job.message = "Rendering export."
                let exported = try await opened.tools.invoke(["command": LensWorksCommandID.exportPNG.rawValue, "arguments": ["path": temporary.path]])
                if exported["isError"] as? Bool == true { throw LensWorksCommandRefusal(reason: ((exported["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "The export could not be rendered.") }
                try Task.checkCancellation()
                job.progress = 0.9; job.message = "Publishing export."
                try FileManager.default.moveItem(at: temporary, to: destination)
                job.state = .completed; job.progress = 1; job.message = "Exported \(destination.lastPathComponent)."
            } catch is CancellationError {
                job.state = .cancelled; job.message = "Cancelled; no output was published."
            } catch { job.state = .failed; job.message = String(error.localizedDescription.prefix(512)) }
        }
        if (values["wait"] as? Bool) == true { await job.task?.value }
        return ["job": job.response]
    }

    private func cancel(_ values: [String: Any]) throws -> [String: Any] {
        try LensWorksAgentTools.rejectUnknown(values, allowed: ["job"], in: "jobs_cancel")
        guard let job = jobs[try text("job", values)] else { throw LensWorksCommandRefusal(reason: "That job does not exist.") }
        guard [.queued, .running].contains(job.state) else { throw LensWorksCommandRefusal(reason: "That job is already \(job.state.rawValue).") }
        job.task?.cancel(); job.state = .cancelled; job.message = "Cancellation requested; no output will be published."
        return ["job": job.response]
    }
}
