import SwiftUI

/// How much undo history a document keeps: the most steps, and the most disk its saved history may take. Both
/// belong to the person, not to a document.
nonisolated struct LWHistorySettings: Equatable, Sendable {
    static let storageChoices: [Int64] = [256, 1024, 4096, 16384].map { $0 * 1024 * 1024 } + [0]
    static let stepRange = 10...1000
    /// The most a document's History folder may take; zero is no limit. The oldest steps are pruned to fit;
    /// checkpoints and the current state never are.
    var storageLimitBytes: Int64 = 1024 * 1024 * 1024
    var stepLimit = 100

    private static let storageKey = "history.storageLimitBytes", stepKey = "history.stepLimit"
    init(storageLimitBytes: Int64 = 1024 * 1024 * 1024, stepLimit: Int = 100) {
        self.storageLimitBytes = max(0, storageLimitBytes)
        self.stepLimit = min(max(stepLimit, Self.stepRange.lowerBound), Self.stepRange.upperBound)
    }
    init(defaults: UserDefaults) {
        self.init(storageLimitBytes: (defaults.object(forKey: Self.storageKey) as? NSNumber)?.int64Value ?? 1024 * 1024 * 1024,
                  stepLimit: defaults.object(forKey: Self.stepKey) as? Int ?? 100)
    }
    func save(to defaults: UserDefaults) {
        defaults.set(NSNumber(value: storageLimitBytes), forKey: Self.storageKey)
        defaults.set(stepLimit, forKey: Self.stepKey)
    }
    static func label(_ bytes: Int64) -> String { bytes == 0 ? "No limit" : bytes.formatted(.byteCount(style: .memory)) }
}

/// Edit › History Storage…
@MainActor @Observable
final class LWHistorySettingsCenter {
    /// The person's settings, through the one accessor for their preferences: under XCTest those are kept in memory
    /// for the test process, so no test reads or writes the person's own.
    static let shared = LWHistorySettingsCenter(defaults: LensWorksUserState.defaults)
    private(set) var settings: LWHistorySettings
    /// Where these settings are kept.
    @ObservationIgnored let settingsDefaults: UserDefaults
    @ObservationIgnored private let panel = FloatingPanelController(name: "historyStorage")
    init(defaults: UserDefaults) {
        settingsDefaults = defaults
        settings = LWHistorySettings(defaults: defaults)
    }
    func update(_ change: (inout LWHistorySettings) -> Void) {
        var next = settings; change(&next)
        next = LWHistorySettings(storageLimitBytes: next.storageLimitBytes, stepLimit: next.stepLimit)
        guard next != settings else { return }
        settings = next
        next.save(to: settingsDefaults)
    }
    func show(session: EditorSession) {
        panel.show(title: "History Storage", content: HistoryStorageView(center: self, session: session))
    }
}

struct HistoryStorageView: View {
    let center: LWHistorySettingsCenter
    let session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Saved history per document", selection: Binding(get: { center.settings.storageLimitBytes }, set: { value in center.update { $0.storageLimitBytes = value } })) {
                ForEach(LWHistorySettings.storageChoices, id: \.self) { Text(LWHistorySettings.label($0)).tag($0) }
            }
                .accessibilityIdentifier("LensWorks.historyStorageLimit")
            Stepper("Undo steps kept: \(center.settings.stepLimit)", value: Binding(get: { center.settings.stepLimit }, set: { value in center.update { $0.stepLimit = value } }),
                    in: LWHistorySettings.stepRange, step: 10)
                .accessibilityIdentifier("LensWorks.historyStepLimit")
            Text("Undo history and checkpoints are saved inside each document. When a document’s saved history passes the limit, its oldest undo steps are removed the next time it is saved. Checkpoints, and the pixels any kept step needs, are never removed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let usage = session.historyUsage {
                Text("This document: \(usage.bytes.formatted(.byteCount(style: .file))) of saved history, \(usage.protectedBytes.formatted(.byteCount(style: .file))) of it protected by checkpoints.")
                    .font(.callout).accessibilityIdentifier("LensWorks.historyUsage")
            } else {
                Text(session.document == nil ? "No document is open." : "This document has no saved history yet.").font(.callout).foregroundStyle(.secondary)
            }
            if let notice = session.historyPruneNotice, session.historyStorageWarning == nil {
                Label(notice.message, systemImage: "clock.arrow.circlepath").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("LensWorks.historyPruneNotice")
            }
            if let warning = session.historyStorageWarning {
                Label(warning.message, systemImage: "exclamationmark.triangle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("LensWorks.historyStorageWarning")
            }
        }
        .padding(16).frame(width: 380)
    }
}
