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

    init(defaults: UserDefaults = .standard, secretStore: LensWorksAutomationSecretStore = LensWorksKeychainSecretStore(),
         socketPath: String = LensWorksAutomationServer.defaultSocketPath(),
         session: @escaping () -> EditorSession?, catalog: @escaping () -> LensWorksCatalog?) {
        self.defaults = defaults; self.secretStore = secretStore
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        folders = LensWorksGrantedFolders(defaults: defaults)
        tools = LensWorksAgentTools(session: session, catalog: catalog, folders: folders)
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
    func copyToPasteboard(_ text: String, pasteboard: NSPasteboard = .general) {
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
        case "tools/list": return LensWorksAgentTools.encodeResult(id: id, ["tools": LensWorksAgentTools.definitions])
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "tools/call needs a tool name.") }
            guard LensWorksAgentTools.toolNames.contains(name) else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "Unknown tool: \(name)") }
            return LensWorksAgentTools.encodeResult(id: id, await tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:], caller: caller))
        case let method: return LensWorksAgentTools.encodeError(id: id, code: -32601, "Unsupported method: \(method ?? "none")")
        }
    }
}
