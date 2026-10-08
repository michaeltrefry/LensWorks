import SwiftUI

struct LensWorksPreviewSettingsView: View {
    let catalog: LensWorksCatalog
    let window: NSWindow?
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnailBytes = ""
    @State private var largeBytes = ""
    private func perform(_ body: () async throws -> Void) async {
        let scope = catalog.captureScope()
        do { try catalog.checkScope(scope); try await body() }
        catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
    }
    private func chooseRoots() async {
        let scope = catalog.captureScope()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Review Original Roots"
        guard await panel.begin() == .OK, catalog.scopeIsCurrent(scope) else { return }
        await perform {
            let roots = try panel.urls.map { try LWCatalogNativePath(fileURL: $0) }
            try await catalog.settings(.BeginOriginalRootReview(roots: roots))
            try catalog.checkScope(scope)
            catalog.resumeSettingsWork()
        }
    }
    private func relocate(_ tier: LWPreviewStoreTier) async {
        let scope = catalog.captureScope()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Move Preview Cache"
        panel.message = "Choose a preview folder outside every original-media root. Media files stay in place."
        guard await panel.begin() == .OK, catalog.scopeIsCurrent(scope), let url = panel.url else { return }
        await perform {
            try await catalog.settings(.BeginRelocation(tier: tier, destination: LWCatalogNativePath(fileURL: url)))
            try catalog.checkScope(scope)
            catalog.resumeSettingsWork()
        }
    }
    private func relocationSummary(_ state: LWApplicationPreviewSettingsStatus) -> String {
        let phase = state.relocation?.phase ?? "pending"
        let objects: UInt64 = state.relocation?.objects?.value ?? 0
        let bytes: UInt64 = state.relocation?.bytes?.value ?? 0
        return "Move \(phase) · objects \(objects) · bytes \(bytes)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preview Storage").font(.title2.weight(.semibold))
            if let state = catalog.previewSettings {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("Thumbnail budget (bytes)"); TextField("Canonical byte count", text: $thumbnailBytes) }
                    GridRow { Text("Large-preview budget (bytes)"); TextField("Canonical byte count", text: $largeBytes) }
                }
                Button("Apply Budgets") {
                    Task { await perform { try await catalog.settings(.SetBudgets(thumbnail_bytes: LWCatalogU64(decimal: thumbnailBytes), large_bytes: LWCatalogU64(decimal: largeBytes))) } }
                }.disabled(catalog.isSettingsWorking)
                Divider()
                Text("Thumbnail cache: " + ((try? state.thumbnail_root.localFileURL().path) ?? "Native path unavailable on this platform")).font(.caption).textSelection(.enabled)
                Text("Large-preview cache: " + ((try? state.large_root.localFileURL().path) ?? "Native path unavailable on this platform")).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Move Thumbnails…") { Task { await relocate(.Thumbnail) } }
                    Button("Move Large Previews…") { Task { await relocate(.Large) } }
                }.disabled(state.relocation_pending || catalog.isSettingsWorking)
                if state.relocation_pending {
                    Text(relocationSummary(state)).font(.caption)
                    Text("Pausing leaves the completed batches intact. Resume continues the pending move.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Original roots: " + state.original_roots.state).font(.headline)
                ForEach(Array(state.original_roots.roots.enumerated()), id: \.offset) { _, root in
                    Text((try? root.localFileURL().path) ?? "Native path unavailable on this platform").font(.caption).textSelection(.enabled)
                }
                Text("Checked directories: \(state.original_roots.checked_directories.value)").font(.caption)
                if let message = state.original_roots.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Button("Review Original Roots…") { Task { await chooseRoots() } }.disabled(catalog.isSettingsWorking)
                HStack {
                    if catalog.isSettingsWorking {
                        ProgressView().controlSize(.small)
                        Button("Pause After Current Batch") { catalog.pauseSettingsWork() }
                    } else if state.relocation_pending || state.original_roots.state == "reviewing" {
                        Button("Resume") { catalog.resumeSettingsWork() }
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                }
            } else { ProgressView() }
        }.padding(20).frame(width: 580)
            .task {
                let scope = catalog.captureScope()
                await perform {
                    try await catalog.suspendPreviews(); try catalog.checkScope(scope)
                    try await catalog.settings(); try catalog.checkScope(scope)
                    thumbnailBytes = String(catalog.previewSettings?.thumbnail_bytes.value ?? 0)
                    largeBytes = String(catalog.previewSettings?.large_bytes.value ?? 0)
                }
            }
    }
}
