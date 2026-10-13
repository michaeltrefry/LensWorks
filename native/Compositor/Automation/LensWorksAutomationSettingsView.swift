import SwiftUI

/// Settings › Automation: the on/off switch (off by default), the secret and the MCP client configuration.
struct LensWorksAutomationSettingsView: View {
    @Bindable var automation: LensWorksAutomation
    var plugins: LensWorksPluginStore = .shared
    var body: some View {
        TabView {
            Form {
                Section {
                    LensWorksCommandToggle(.automationEnabled, isOn: Binding(get: { automation.isEnabled }, set: { automation.setEnabled($0) }))
                        .accessibilityIdentifier(LensWorksCommandID.automationEnabled.rawValue)
                    Text("AI agents connected through the LensWorks MCP bridge can list and run commands, read the open document and catalog, and render previews. Their edits are labeled “(Agent)” in history; permanent deletes and replacing a file ask you first; and they name files only inside the folders you grant below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.caption).accessibilityIdentifier("LensWorks.automation.status")
                }
                Section("Secret") {
                    if let secret = automation.secret {
                        Text(automation.showsSecret ? secret : String(repeating: "•", count: 24))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("LensWorks.automation.secret")
                        HStack {
                            LensWorksCommandToggle(.automationShowSecret, isOn: $automation.showsSecret)
                            LensWorksCommandButton(.automationCopySecret) { automation.copyToPasteboard(secret) }
                            LensWorksCommandButton(.automationRegenerateSecret, reason: automation.secretChangeReason) { automation.regenerateSecret() }
                            LensWorksCommandButton(.automationRevokeSecret, reason: automation.secretChangeReason, role: .destructive) { automation.revokeSecret() }
                        }
                    } else {
                        Text(automation.isEnabled ? "Revoked: every connection is refused until you generate a new secret." : "A secret is created when automation is turned on.")
                            .font(.caption)
                        LensWorksCommandButton(.automationRegenerateSecret, title: "Generate Secret",
                                               reason: LensWorksCommandRegistry.unavailable(!automation.isEnabled, "Turn automation on first.") ?? automation.secretChangeReason) { automation.regenerateSecret() }
                    }
                }
                Section("Granted Folders") {
                    Text("Agents can open, import, save and export files only inside the folders listed here. With none granted, no agent command can name a file.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(automation.folders.grants) { grant in
                        HStack {
                            Text(verbatim: grant.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("LensWorks.automation.folder")
                            Spacer()
                            LensWorksCommandButton(.automationRevokeFolder, argument: grant.path, role: .destructive) { automation.folders.revoke(grant.id) }
                        }
                    }
                    LensWorksCommandButton(.automationGrantFolder) { automation.chooseGrantedFolder() }
                        .accessibilityIdentifier(LensWorksCommandID.automationGrantFolder.rawValue)
                }
                Section("MCP client configuration") {
                    if let secret = automation.secret {
                        Text(automation.clientConfiguration(secret: automation.showsSecret ? secret : "<copy the secret above>"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        LensWorksCommandButton(.automationCopyConfiguration) { automation.copyToPasteboard(automation.clientConfiguration(secret: secret)) }
                        Text("Claude Code: claude mcp add lensworks --env LENSWORKS_MCP_SECRET=<secret> -- \"\(automation.helperPath)\"")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("Turn automation on to create a secret.").font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Automation", systemImage: "point.3.connected.trianglepath.dotted") }
            LensWorksPluginSettingsView(store: plugins)
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 640)
    }
    private var status: String {
        if let error = automation.lastError { return "Error: " + error }
        guard automation.isEnabled else { return "Off. No agent can connect." }
        return automation.isListening ? "On. Listening at \(automation.socketPath) (this Mac account only)." : "On, but not listening."
    }
}

/// The in-app confirmation a destructive agent command waits on.
struct LensWorksAgentConfirmationSheet: View {
    let automation: LensWorksAutomation
    let confirmation: LensWorksAgentConfirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(confirmation.title, systemImage: "exclamationmark.triangle").font(.headline)
                .accessibilityIdentifier("LensWorks.automation.confirmation.title")
            Text(confirmation.message).fixedSize(horizontal: false, vertical: true)
            // Each name is the app's own data in its own one-line field: it can never reword the question.
            if confirmation.items.count > 6 { ScrollView { items }.frame(height: 160) } else { items }
            HStack {
                Spacer()
                LensWorksCommandButton(.automationDecline) { automation.resolveConfirmation(false) }
                    .registeredCommandShortcut(.cancel, role: .cancelAction)
                    .accessibilityIdentifier(LensWorksCommandID.automationDecline.rawValue)
                LensWorksAgentAllowButton { automation.resolveConfirmation(true) }.fixedSize()
            }
        }
        .padding(20).frame(width: 440)
    }
    private var items: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(confirmation.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.action).foregroundStyle(.secondary).fixedSize()
                    Text(verbatim: item.name).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("LensWorks.automation.confirmation.item")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sheet's Allow button as an AppKit control: the person's click on it (and nothing else — it has no key
/// equivalent, so no stray Return allows a permanent change) runs the registered Allow command.
private struct LensWorksAgentAllowButton: NSViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: LensWorksCommandRegistry.descriptor(.automationAllow).label, target: context.coordinator, action: #selector(Coordinator.run))
        button.bezelStyle = .push
        button.hasDestructiveAction = true
        button.setAccessibilityIdentifier(LensWorksCommandID.automationAllow.rawValue)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { LensWorksCommandDispatcher.perform(.init(.automationAllow), action) }
    }
}
