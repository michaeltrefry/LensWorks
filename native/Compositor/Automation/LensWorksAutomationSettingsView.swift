import SwiftUI

/// Settings › Automation: the on/off switch (off by default), the secret and the MCP client configuration.
struct LensWorksAutomationSettingsView: View {
    @Bindable var automation: LensWorksAutomation
    var body: some View {
        TabView {
            Form {
                Section {
                    LensWorksCommandToggle(.automationEnabled, isOn: Binding(get: { automation.isEnabled }, set: { automation.setEnabled($0) }))
                        .accessibilityIdentifier(LensWorksCommandID.automationEnabled.rawValue)
                    Text("AI agents connected through the LensWorks MCP bridge can list and run commands, read the open document and catalog, and render previews. Their edits are labeled “(Agent)” in history, and permanent deletes ask you first.")
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
                            LensWorksCommandButton(.automationRegenerateSecret) { automation.regenerateSecret() }
                            LensWorksCommandButton(.automationRevokeSecret, role: .destructive) { automation.revokeSecret() }
                        }
                    } else {
                        Text(automation.isEnabled ? "Revoked: every connection is refused until you generate a new secret." : "A secret is created when automation is turned on.")
                            .font(.caption)
                        LensWorksCommandButton(.automationRegenerateSecret, title: "Generate Secret",
                                               reason: LensWorksCommandRegistry.unavailable(!automation.isEnabled, "Turn automation on first.")) { automation.regenerateSecret() }
                    }
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
        }
        .frame(width: 620, height: 520)
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
            Text(confirmation.message)
            HStack {
                Spacer()
                LensWorksCommandButton(.automationDecline) { automation.resolveConfirmation(false) }
                    .registeredCommandShortcut(.cancel, role: .cancelAction)
                    .accessibilityIdentifier(LensWorksCommandID.automationDecline.rawValue)
                LensWorksCommandButton(.automationAllow, title: confirmation.actionTitle, role: .destructive) { automation.resolveConfirmation(true) }
                    .accessibilityIdentifier(LensWorksCommandID.automationAllow.rawValue)
            }
        }
        .padding(20).frame(width: 440)
        .interactiveDismissDisabled()
    }
}
