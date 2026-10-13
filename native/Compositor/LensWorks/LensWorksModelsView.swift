import AppKit
import SwiftUI

/// The AI Models window: every model this Mac can admit, its state, and explicit download,
/// cancel, resume and removal. Nothing here downloads on its own.
@MainActor @Observable
final class LWModelCenter {
    static let shared = LWModelCenter()
    static let librariesKey = "LensWorks.modelLibraries"

    struct DownloadState: Equatable {
        var progress: LWDownloadProgress?
        var running: Bool
        var error: String?
    }

    private(set) var statuses: [LWModelStatus] = []
    private(set) var downloads: [String: DownloadState] = [:]
    private(set) var isRefreshing = false
    private(set) var setupError: String?
    private(set) var libraries: [URL] = []
    var actionError: String?
    var downloadSheetModel: String?

    @ObservationIgnored private var store: LWModelStore?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let panel = FloatingPanelController(name: "aiModels")

    var admissible: [LWModelStatus] { statuses.filter(\.isAdmissible) }
    var hiddenCount: Int { statuses.count - admissible.count }

    init() {}

    /// For tests and previews: drive the center with an explicit store.
    init(store: LWModelStore) { self.store = store }

    func show() {
        panel.show(title: "AI Models", content: LWModelsView(center: self))
        Task { await refresh() }
    }

    private static func addedLibraries() -> [URL] {
        (LensWorksUserState.defaults.stringArray(forKey: librariesKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func makeStore() async -> LWModelStore? {
        if let store { return store }
        do {
            let manifest = try LWModelManifest.bundled()
            var facts: LWModelRuntimeFacts?
            var factsError: String?
            do { facts = LWModelRuntimeFacts(capabilities: try await LWInferenceRuntime.installed().capabilities()) } catch {
                factsError = String(describing: error)
            }
            let created = LWModelStore(manifest: manifest, configuration: .application(added: Self.addedLibraries()), facts: facts, factsError: factsError)
            store = created
            return created
        } catch {
            setupError = String(describing: error)
            return nil
        }
    }

    func refresh() async {
        guard !isRefreshing, let store = await makeStore() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        libraries = await store.configuration.sceneWorksLibraries
        statuses = await store.refresh()
    }

    func addLibrary() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.message = "Choose a SceneWorks model library (a Hugging Face cache “hub” folder)."
        guard open.runModal() == .OK, let url = open.url else { return }
        var added = Self.addedLibraries()
        guard !added.contains(url) else { return }
        added.append(url)
        LensWorksUserState.defaults.set(added.map(\.path), forKey: Self.librariesKey)
        Task {
            await store?.setSceneWorksLibraries(LWModelStore.Configuration.defaultLibraries(added: added))
            await refresh()
        }
    }

    func plan(_ id: String) async -> LWDownloadPlan? { try? await store?.downloadPlan(id) }

    /// Records (or withdraws) acceptance of exactly this version of a model's licence terms.
    func setLicenseAccepted(_ id: String, version: String, _ accepted: Bool) async {
        guard let store else { return }
        do {
            if accepted { try await store.acceptLicense(id, version: version) } else { await store.revokeLicense(id) }
        } catch { actionError = String(describing: error) }
        await refresh()
    }

    /// The production inference job path: admits and leases the model for the whole job,
    /// records its measured memory, and keeps keep_loaded models leased while resident.
    func runJob(_ id: String, pixels: Int?, inputs: [LWInferenceImage] = [],
                request: @escaping @Sendable (LWModelLease) -> LWInferenceRequest) async throws -> LWModelJob {
        guard let store = await makeStore() else { throw LWModelStoreError.manifest(setupError ?? "The model store is unavailable.") }
        return try await store.runJob(id, pixels: pixels, inputs: inputs, runtime: try LWInferenceRuntime.installed(), request: request)
    }

    func startDownload(_ id: String) {
        guard let store, tasks[id] == nil else { return }
        downloads[id] = DownloadState(progress: nil, running: true, error: nil)
        tasks[id] = Task { [weak self] in
            do {
                try await store.download(id) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[id]?.running == true else { return }
                        self.downloads[id]?.progress = progress
                    }
                }
                self?.downloads[id] = nil
            } catch is CancellationError {
                self?.downloads[id] = DownloadState(progress: self?.downloads[id]?.progress, running: false, error: nil)
            } catch {
                self?.downloads[id] = DownloadState(progress: self?.downloads[id]?.progress, running: false, error: String(describing: error))
            }
            self?.tasks[id] = nil
            await self?.refresh()
        }
    }

    /// Stops the transfer; downloaded bytes stay for Resume.
    func cancelDownload(_ id: String) { tasks[id]?.cancel() }

    func delete(_ id: String) {
        Task {
            do { try await store?.deleteManagedCopy(id) } catch { actionError = String(describing: error) }
            await refresh()
        }
    }
}

struct LWModelsView: View {
    @Bindable var center: LWModelCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = center.setupError {
                Text(error).foregroundStyle(.red)
            }
            List(center.admissible) { status in
                LWModelRow(center: center, status: status)
            }
            .accessibilityIdentifier("LensWorks.models.list")
            .frame(minHeight: 260)
            if center.hiddenCount > 0 {
                Text("\(center.hiddenCount) model\(center.hiddenCount == 1 ? " is" : "s are") not offered: \(center.statuses.filter { !$0.isAdmissible }.map { "\($0.model.name) — \($0.state.message)" }.joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("LensWorks.models.hidden")
            }
            if let error = center.actionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("SceneWorks libraries: \(center.libraries.map(\.path).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Add SceneWorks Library…") { center.addLibrary() }
                Button(center.isRefreshing ? "Checking…" : "Retry") { Task { await center.refresh() } }
                    .disabled(center.isRefreshing)
                    .accessibilityIdentifier("LensWorks.models.retry")
            }
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 380)
        .sheet(item: Binding(get: { center.downloadSheetModel.map(LWSheetID.init) }, set: { center.downloadSheetModel = $0?.id })) { item in
            LWModelDownloadSheet(center: center, modelID: item.id)
        }
    }
}

private struct LWSheetID: Identifiable { let id: String }

private struct LWModelRow: View {
    let center: LWModelCenter
    let status: LWModelStatus

    var body: some View {
        let download = center.downloads[status.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.model.name).font(.headline)
                Text(status.state.title).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(status.state.isReady ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                    .accessibilityIdentifier("LensWorks.models.state.\(status.id)")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(status.model.totalBytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if let memory = status.requiredMemory {
                    Text("peak \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(status.model.summary).font(.caption)
            Text(status.state.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            LWLicenseSummary(terms: status.license, compact: true)
                .accessibilityIdentifier("LensWorks.models.license.\(status.id)")
            if let download, let progress = download.progress {
                ProgressView(value: progress.fraction)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = download?.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if download?.running == true {
                    Button("Cancel") { center.cancelDownload(status.id) }
                } else if status.state.canDownload {
                    Button(downloadLabel) { center.downloadSheetModel = status.id }
                        .accessibilityIdentifier("LensWorks.models.download.\(status.id)")
                }
                if status.state.isReady && status.needsLicenseAcknowledgement {
                    Button("Review Licence…") { center.downloadSheetModel = status.id }
                        .accessibilityIdentifier("LensWorks.models.acknowledge.\(status.id)")
                }
                if case .ready(let root, _) = status.state {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                }
                if status.hasManagedCopy && download?.running != true {
                    // Offered for any state, so a corrupt or incomplete copy of our own can be removed.
                    Button("Remove Download") { center.delete(status.id) }
                        .accessibilityIdentifier("LensWorks.models.remove.\(status.id)")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var downloadLabel: String {
        if case .partiallyDownloaded = status.state { return "Resume…" }
        if center.downloads[status.id]?.progress != nil { return "Resume…" }
        return "Download…"
    }
}

/// Every declared licence source, the governing terms and any conflict between sources.
struct LWLicenseSummary: View {
    let terms: LWModelLicenseTerms
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !terms.runtimeDeclared {
                Text("Licence not declared by runtime").font(.caption).bold()
                    .accessibilityIdentifier("LensWorks.license.undeclared")
            }
            if terms.nonCommercial {
                Text("Governing terms: \(terms.governing)").font(.caption).bold().foregroundStyle(.orange)
                    .accessibilityIdentifier("LensWorks.license.noncommercial")
            }
            ForEach(terms.sources, id: \.self) { source in
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.summary).font(.caption)
                    if !compact {
                        if let attribution = source.attribution { Text(attribution).font(.caption2).foregroundStyle(.secondary) }
                        HStack {
                            if let url = source.textURL { Link("Licence text", destination: url) }
                            if let url = source.sourceURL { Link("Source", destination: url) }
                        }.font(.caption2)
                    }
                }
                .accessibilityIdentifier(source.origin == .runtime ? "LensWorks.download.license.\(source.key)" : "LensWorks.download.license.sceneworks.\(source.key)")
            }
            if let conflict = terms.conflict {
                Text(conflict).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("LensWorks.license.conflict")
            }
            if let note = terms.note, !compact { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Explicit download confirmation: size, location, licence terms and live progress.
struct LWModelDownloadSheet: View {
    let center: LWModelCenter
    let modelID: String
    @State private var plan: LWDownloadPlan?
    @Environment(\.dismiss) private var dismiss

    private var status: LWModelStatus? { center.statuses.first { $0.id == modelID } }
    /// Opened only to acknowledge the terms of a model that is already available.
    private var acknowledgeOnly: Bool { status?.state.isReady == true }

    var body: some View {
        let download = center.downloads[modelID]
        let accepted = plan?.licenseAccepted == true
        VStack(alignment: .leading, spacing: 10) {
            Text("\(acknowledgeOnly ? "Licence for" : "Download") \(status?.model.name ?? modelID)").font(.title3)
            if let plan {
                LabeledContent("Size", value: "\(ByteCountFormatter.string(fromByteCount: Int64(plan.remainingBytes), countStyle: .file)) to download (\(ByteCountFormatter.string(fromByteCount: Int64(plan.totalBytes), countStyle: .file)) total)")
                    .accessibilityIdentifier("LensWorks.download.size")
                LabeledContent("Location", value: plan.destination.path)
                    .accessibilityIdentifier("LensWorks.download.location")
                Text("Licence").font(.headline)
                LWLicenseSummary(terms: plan.license)
                Toggle(plan.license.nonCommercial ? "I acknowledge these terms allow non-commercial use only" : "I have reviewed these licence terms",
                       isOn: Binding(get: { accepted }, set: { value in
                           Task {
                               await center.setLicenseAccepted(modelID, version: plan.license.version, value)
                               self.plan = await center.plan(modelID)
                           }
                       }))
                    .accessibilityIdentifier("LensWorks.download.accept")
            } else {
                ProgressView()
            }
            if let progress = download?.progress {
                ProgressView(value: progress.fraction) {
                    Text(progress.phase == .downloading ? "Downloading \(progress.file)" : progress.phase == .verifying ? "Verifying \(progress.file)" : "Installing")
                        .font(.caption)
                }
                .accessibilityIdentifier("LensWorks.download.progress")
            }
            if let error = download?.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if download?.running == true {
                    Button("Cancel Download") { center.cancelDownload(modelID) }
                        .accessibilityIdentifier("LensWorks.download.cancel")
                } else if !acknowledgeOnly {
                    Button((plan?.remainingBytes ?? 0) < (plan?.totalBytes ?? 0) ? "Resume" : "Download") {
                        center.startDownload(modelID)
                    }
                    .registeredCommandShortcut(.apply, role: .defaultAction)
                    .disabled(!accepted || plan == nil)
                    .accessibilityIdentifier("LensWorks.download.start")
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .task { plan = await center.plan(modelID) }
        .onChange(of: download?.running) { _, _ in Task { plan = await center.plan(modelID) } }
    }
}
