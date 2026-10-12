import AppKit
import Foundation
import Observation
import Security

/// Where the automation secret lives. The app uses the Keychain; tests inject an in-memory store or a Keychain store
/// bound to a temporary keychain so they never touch the person's own items.
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

/// A generic-password Keychain item. `keychain` pins a specific (test) keychain file; nil is the default keychain.
nonisolated final class LensWorksKeychainSecretStore: LensWorksAutomationSecretStore, @unchecked Sendable {
    static let appService = "net.trefry.lensworks.automation"
    static let appAccount = "mcp-bridge-secret"
    let service: String, account: String
    private let keychain: SecKeychain?
    init(service: String = appService, account: String = appAccount, keychain: SecKeychain? = nil) {
        self.service = service; self.account = account; self.keychain = keychain
    }
    private func query(_ extra: [CFString: Any] = [:]) -> CFDictionary {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if let keychain {
            query[kSecUseKeychain] = keychain
            query[kSecMatchSearchList] = [keychain]
        }
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

/// One in-app confirmation an agent's destructive command is waiting on.
struct LensWorksAgentConfirmation: Identifiable {
    let id = UUID()
    let commandID: LensWorksCommandID
    let title: String
    let message: String
    let actionTitle: String
}

/// Settings › Automation: off by default. When on, a secret (Keychain) authenticates the MCP bridge over a socket
/// only this Mac account can reach, and agents run registered commands through the same dispatcher as menus.
@Observable
final class LensWorksAutomation {
    static let enabledKey = "LensWorksAutomationEnabled"
    static let helperName = "LensWorksMCP"
    static let confirmationTimeout: Duration = .seconds(120)

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let secretStore: LensWorksAutomationSecretStore
    @ObservationIgnored let tools: LensWorksAgentTools
    @ObservationIgnored private(set) var server: LensWorksAutomationServer!
    private(set) var isEnabled: Bool
    private(set) var secret: String?
    private(set) var isListening = false
    private(set) var lastError: String?
    var showsSecret = false
    /// The destructive agent command waiting for the person's answer; the editor window shows it as a sheet.
    private(set) var pendingConfirmation: LensWorksAgentConfirmation?
    @ObservationIgnored private var confirmationReply: CheckedContinuation<Bool, Never>?

    init(defaults: UserDefaults = .standard, secretStore: LensWorksAutomationSecretStore = LensWorksKeychainSecretStore(),
         socketPath: String = LensWorksAutomationServer.defaultSocketPath(),
         session: @escaping () -> EditorSession?, catalog: @escaping () -> LensWorksCatalog?) {
        self.defaults = defaults; self.secretStore = secretStore
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        tools = LensWorksAgentTools(session: session, catalog: catalog)
        tools.automation = self
        server = LensWorksAutomationServer(socketPath: socketPath) { [weak self] request in
            await self?.handle(request) ?? LensWorksAgentTools.encodeError(id: nil, code: -32000, "LensWorks is quitting.")
        }
    }

    var socketPath: String { server.socketPath }
    /// The bridge an MCP client launches: Contents/Helpers/LensWorksMCP in this app.
    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + Self.helperName).path }

    /// Starts serving when the setting is on (at launch). Reads the Keychain only then.
    func startIfEnabled() {
        guard isEnabled else { return }
        do { secret = try secretStore.load() } catch { lastError = error.localizedDescription }
        startServer()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            do {
                secret = try secretStore.load()
                if secret == nil { try storeNewSecret() }
            } catch { lastError = error.localizedDescription }
            startServer()
        } else {
            server.stop(); isListening = false
            resolveConfirmation(false)
        }
    }

    /// A new secret: the old one stops working and every connected client is disconnected.
    func regenerateSecret() {
        do { try storeNewSecret(); lastError = nil } catch { lastError = error.localizedDescription }
    }

    /// No secret at all: every connection is refused until a new one is generated.
    func revokeSecret() {
        do { try secretStore.delete(); lastError = nil } catch { lastError = error.localizedDescription }
        secret = nil
        server.setSecretDigest(nil)
        resolveConfirmation(false)
    }

    func stop() { server.stop(); isListening = false; resolveConfirmation(false) }

    private func storeNewSecret() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LensWorksKeychainError(status: errSecAllocate) }
        let value = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try secretStore.save(value)
        secret = value
        server.setSecretDigest(LensWorksAutomationServer.digest(value))
        resolveConfirmation(false)
    }

    private func startServer() {
        server.setSecretDigest(secret.map(LensWorksAutomationServer.digest))
        do { try server.start(); isListening = true; if secret != nil { lastError = nil } }
        catch { isListening = false; lastError = error.localizedDescription }
    }

    /// The JSON an MCP client (Claude Code, Claude Desktop, …) needs to launch the bridge with the current secret.
    func clientConfiguration(secret: String) -> String {
        let configuration: [String: Any] = ["mcpServers": ["lensworks": ["command": helperPath, "args": [String](), "env": ["LENSWORKS_MCP_SECRET": secret]]]]
        let data = (try? JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Confirmations

    /// Asks the person in the app; false when they decline, when it times out, or when another confirmation is open.
    func confirm(_ confirmation: LensWorksAgentConfirmation) async -> Bool {
        guard pendingConfirmation == nil else { return false }
        pendingConfirmation = confirmation
        NSApp?.requestUserAttention(.criticalRequest)
        let id = confirmation.id
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationTimeout)
            guard !Task.isCancelled, self?.pendingConfirmation?.id == id else { return }
            self?.resolveConfirmation(false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in confirmationReply = continuation }
    }

    /// The person's answer to the pending confirmation (the sheet's Allow / Don't Allow).
    func resolveConfirmation(_ allowed: Bool) {
        guard pendingConfirmation != nil else { return }
        pendingConfirmation = nil
        let reply = confirmationReply; confirmationReply = nil
        reply?.resume(returning: allowed)
    }

    // MARK: Requests

    private func handle(_ request: Data) async -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            return LensWorksAgentTools.encodeError(id: nil, code: -32700, "The request was not a JSON object.")
        }
        let id = object["id"]
        guard isEnabled, isListening else { return LensWorksAgentTools.encodeError(id: id, code: -32000, "LensWorks automation is off.") }
        switch object["method"] as? String {
        case "tools/list": return LensWorksAgentTools.encodeResult(id: id, ["tools": LensWorksAgentTools.definitions])
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "tools/call needs a tool name.") }
            guard LensWorksAgentTools.toolNames.contains(name) else { return LensWorksAgentTools.encodeError(id: id, code: -32602, "Unknown tool: \(name)") }
            return LensWorksAgentTools.encodeResult(id: id, await tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:]))
        case let method: return LensWorksAgentTools.encodeError(id: id, code: -32601, "Unsupported method: \(method ?? "none")")
        }
    }
}
