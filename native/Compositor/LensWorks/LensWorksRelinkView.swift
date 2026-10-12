import SwiftUI
import AppKit

/// What the Locate Originals sheet opens on.
enum LensWorksRelinkFocus: Equatable {
    case general
    case folder(LWApplicationDtoFolder)
    case original
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.general, .general), (.original, .original): true
        case (.folder(let a), .folder(let b)): a.id == b.id
        default: false
        }
    }
}

@MainActor enum LensWorksRelinkPicker {
    static func choose(folder: Bool, window: NSWindow?) async -> LWCatalogNativePath? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = false
        panel.prompt = folder ? "Use Folder" : "Use File"
        panel.message = folder ? "Choose where the moved folder’s originals are now. Files are only read and verified; nothing moves." : "Choose the original’s current file. It is only read and verified; nothing moves."
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        return try? LWCatalogNativePath(fileURL: url)
    }
}

/// Destination folders or candidate files for a review, chosen with the open panel or typed.
struct LensWorksRelinkDestinations: View {
    let folder: Bool
    @Binding var paths: [LWCatalogNativePath]
    let window: NSWindow?
    var identifier = "LensWorks.relinkDestination"
    @State private var typed = ""
    @State private var picking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                HStack {
                    Text(LensWorksRelinkPaths.label(path)).font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Remove") { paths.remove(at: index) }.accessibilityLabel("Remove destination \(index + 1)")
                }
            }
            HStack {
                Button(picking ? "Choosing…" : folder ? "Choose Destination Folder…" : "Choose Original File…") {
                    picking = true
                    Task { if let path = await LensWorksRelinkPicker.choose(folder: folder, window: window) { paths.append(path) }; picking = false }
                }.disabled(picking || paths.count >= 32)
                TextField(folder ? "/Volumes/New Drive/Photos" : "/Volumes/New Drive/Photos/IMG_0001.CR3", text: $typed)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier(identifier + "Path")
                Button("Add Path") {
                    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.hasPrefix("/"), let path = try? LWCatalogNativePath(fileURL: URL(fileURLWithPath: text)) else { return }
                    paths.append(path); typed = ""
                }.disabled(!typed.hasPrefix("/") || paths.count >= 32).accessibilityIdentifier(identifier + "Add")
            }
        }
    }
}

/// An old folder path entered by the user (the prefix whose originals moved).
struct LensWorksRelinkEnteredFolder: View {
    @Binding var reference: LWCatalogStoragePathReference?
    @State private var text = ""
    @State private var windows = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Existing folder path, e.g. /Volumes/Previous Drive/Raw", text: $text)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("LensWorks.relinkFromPath")
                .onChange(of: text) { _, _ in update() }
            Picker("Path format", selection: $windows) {
                Text("macOS / Linux").tag(false)
                Text("Windows").tag(true)
            }.pickerStyle(.segmented).fixedSize().onChange(of: windows) { _, _ in update() }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }
    private func update() {
        do { reference = try LensWorksRelinkPaths.entered(text, windows: windows); problem = nil }
        catch { reference = nil; problem = text.isEmpty ? nil : error.localizedDescription }
    }
}

struct LensWorksRelinkSheet: View {
    let catalog: LensWorksCatalog
    let window: NSWindow?
    let focus: LensWorksRelinkFocus
    @Environment(\.dismiss) private var dismiss
    @State private var from: LWCatalogStoragePathReference?
    @State private var destinations: [LWCatalogNativePath] = []
    @State private var files: [LWCatalogNativePath] = []
    @State private var nestedFrom: LWCatalogStoragePathReference?
    @State private var nestedDestinations: [LWCatalogNativePath] = []
    @State private var acknowledged = false
    @State private var problem: String?
    @State private var working = false
    private var review: LensWorksRelinkReview { catalog.relink }
    private var busy: Bool { working || review.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Locate Originals").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.registeredCommandShortcut(.cancel, role: .cancelAction).accessibilityIdentifier("LensWorks.relinkDone")
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Point the catalog at originals that moved or whose drive was renamed. Reviews read and verify candidate files; Apply changes only catalog associations, in one step that Undo reverses. Originals never move, and photo identities, copies, metadata and working versions are kept.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("LensWorks.relinkProblem") }
                    operationStatus
                    folderSection
                    if catalog.selectedAsset != nil { originalSection }
                    savedReviews
                    if let plan = review.plan { planSection(plan) }
                }.padding()
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 720)
        // A container, so the sheet's own control identifiers are not overwritten.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("LensWorks.relinkSheet")
        .task {
            if case .folder(let folder) = focus { from = .Native(folder.locator) }
            try? await review.recoverStatus()
        }
    }

    private func attempt(_ body: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; problem = nil
        Task {
            do { try await body() } catch { if !(error is CancellationError) { problem = error.localizedDescription } }
            working = false
        }
    }

    @ViewBuilder private var operationStatus: some View {
        if let operation = review.operation {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(operation.action.rawValue.capitalized): \(operation.phase.rawValue.replacingOccurrences(of: "_", with: " ")) · \(operation.progress.value) processed" + (operation.boundary.map { " · " + $0.replacingOccurrences(of: "_", with: " ") } ?? ""))
                    .font(.caption).accessibilityIdentifier("LensWorks.relinkOperation")
                if operation.write_hold { Text("Catalog writes and new original rendering are held until this operation finishes. Cached browsing remains available.").font(.caption).foregroundStyle(.secondary) }
                if let error = operation.error { Text(error).font(.caption).foregroundStyle(.red) }
                if !LensWorksRelinkReview.terminal(operation) {
                    Button("Cancel Storage Operation") { Task { try? await review.cancel() } }
                }
            }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var folderSection: some View {
        GroupBox("Locate a Moved Folder") {
            VStack(alignment: .leading, spacing: 6) {
                if case .folder(let folder) = focus {
                    Text("Catalog folder: " + LensWorksRelinkPaths.label(folder.locator)).font(.caption).textSelection(.enabled)
                        .accessibilityIdentifier("LensWorks.relinkFromFolder")
                } else {
                    LensWorksRelinkEnteredFolder(reference: $from)
                }
                Text("Every original under this folder, including subfolders, is matched by content at the same relative path in a destination.").font(.caption).foregroundStyle(.secondary)
                LensWorksRelinkDestinations(folder: true, paths: $destinations, window: window)
                Button("Review Folder") {
                    guard let from else { return }
                    let targets = destinations
                    attempt { try await review.beginFolder(from: from, destinations: targets) }
                }.disabled(busy || from == nil || destinations.isEmpty).accessibilityIdentifier("LensWorks.relinkReviewFolder")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var originalSection: some View {
        if let asset = catalog.selectedAsset, let key = asset.key {
            GroupBox("Locate " + asset.filename) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Check Selected Original") {
                        attempt { _ = try await review.observeOriginal(key); await catalog.observeSelectedOriginal() }
                    }.disabled(busy)
                    if let status = catalog.originalStatus(asset) ?? (review.original?.key.asset_id == key.asset_id ? review.original?.status : nil) {
                        Text(LensWorksOriginalAvailability.headline(status) + ": " + status.detail).font(.caption)
                        Text(LensWorksRelinkPaths.label(status.current)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let candidate = status.candidate { Text("Observed candidate: " + LensWorksRelinkPaths.label(candidate)).font(.caption) }
                        if let volume = status.logical_volume { volumeSection(volume) }
                    }
                    LensWorksRelinkDestinations(folder: false, paths: $files, window: window, identifier: "LensWorks.relinkFile")
                    Button("Review Selected Original") {
                        let targets = files
                        attempt { try await review.beginOriginal(assetID: key.asset_id, destinations: targets) }
                    }.disabled(busy || files.isEmpty).accessibilityIdentifier("LensWorks.relinkReviewOriginal")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func volumeSection(_ volume: String) -> some View {
        Button("Check Connected Storage") { attempt { try await review.observeMounts() } }.disabled(busy)
        if let mounts = review.mounts {
            if !mounts.complete { Text("Storage enumeration is incomplete; it does not establish that a drive is offline.").font(.caption) }
            ForEach(Array(mounts.issues.enumerated()), id: \.offset) { _, issue in
                Text("\(issue.kind.rawValue): \(issue.detail)" + (issue.path.map { " · " + LensWorksRelinkPaths.label($0) } ?? "")).font(.caption)
            }
            ForEach(mounts.rows, id: \.token) { row in
                HStack {
                    Text(LensWorksRelinkPaths.label(row.path) + " · " + row.filesystem).font(.caption)
                    Button("Review Reconnect to This Volume") { attempt { try await review.beginVolume(logicalVolume: volume, mountToken: row.token) } }
                        .disabled(busy || !mounts.complete || !mounts.issues.isEmpty || !row.identity_available || row.token.isEmpty)
                }
            }
        }
    }

    private var savedReviews: some View {
        DisclosureGroup("Saved Relink Reviews") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(review.plans, id: \.id) { row in
                    HStack {
                        Text(row.state + " · " + (row.summary_complete ? "\(row.total.value) originals" : "Counts unavailable")).font(.caption)
                        Spacer()
                        Button("Open") { attempt { try await review.openPlan(row.id) } }.disabled(busy)
                    }.help(row.id)
                }
                if review.plans.isEmpty { Text("No saved reviews on this page.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("First Page / Refresh") { attempt { try await review.loadPlans() } }.disabled(busy)
                    Button("Next Page") { if let next = review.plansNext { attempt { try await review.loadPlans(after: next) } } }.disabled(busy || review.plansNext == nil)
                }
            }.task { try? await review.loadPlans() }
        }
    }

    private func count(_ value: LWCatalogI64) -> Int64 { value.value }

    @ViewBuilder private func planSection(_ plan: LWApplicationRelinkPlan) -> some View {
        GroupBox("Relink Review") {
            VStack(alignment: .leading, spacing: 8) {
                Text("State: \(plan.state) · revision \(plan.revision.value)").font(.caption).help(plan.id)
                if plan.summary_complete {
                    Text("\(count(plan.total)) originals · \(count(plan.matched)) matched · \(count(plan.unverified)) need confirmation · \(count(plan.user_confirmed)) confirmed · \(count(plan.excluded)) excluded · \(count(plan.unresolved)) unresolved originals · \(count(plan.unresolved_sources)) unresolved metadata sources")
                        .font(.callout).accessibilityIdentifier("LensWorks.relinkSummary")
                } else {
                    Text("Aggregate counts are unavailable for this older review. Create a fresh review to prepare or apply it. An applied review can still be undone after lineage validation.").font(.caption)
                }
                HStack {
                    Button("Prepare Review") { attempt { try await review.prepare() } }
                        .disabled(busy || !["preparing", "checking"].contains(plan.state))
                    Button("Create Fresh Review with These Mappings") { attempt { try await review.revise([]) } }.disabled(busy || plan.state == "applied")
                }
                if plan.summary_complete, plan.state == "ready", plan.confirmation_token != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This confirmation covers all \(count(plan.unverified)) unverified associations in this review, including rows outside the visible page. No retained original digest proves they are the historic originals.").font(.caption)
                        Toggle("I reviewed these associations.", isOn: $acknowledged).disabled(busy)
                        Button("Confirm Reviewed Associations") { attempt { try await review.confirm(); acknowledged = false } }.disabled(busy || !acknowledged)
                    }
                }
                if !review.chosenCandidates.isEmpty {
                    Button("Revise with \(review.chosenCandidates.count) Chosen Candidate(s)") { attempt { try await review.reviseChosen() } }
                        .disabled(busy || plan.state == "applied").accessibilityIdentifier("LensWorks.relinkReviseChosen")
                }
                let reason = review.applyUnavailableReason
                HStack {
                    Button("Apply Relink" + (reason.map { " — " + $0 } ?? "")) { attempt { try await review.apply() } }
                        .disabled(reason != nil).help(reason ?? "Change the catalog’s associations for every reviewed original at once.")
                        .accessibilityIdentifier("LensWorks.relinkApply")
                    Button("Undo This Relink") { attempt { try await review.undo(plan) } }
                        .disabled(busy || plan.state != "applied").accessibilityIdentifier("LensWorks.relinkUndo")
                }
                Text("Apply changes catalog associations only. Originals stay on disk. Undo validates that later catalog changes still permit reversal.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Folder Mappings and Exceptions") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(review.rules.enumerated()), id: \.offset) { _, row in ruleDescription(row) }
                        if review.rules.isEmpty { Text("No mappings on this page.").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("First Page / Refresh") { attempt { try await review.loadRules() } }.disabled(busy)
                            Button("Next Page") { if let next = review.rulesNext { attempt { try await review.loadRules(after: next) } } }.disabled(busy || review.rulesNext == nil)
                        }
                    }
                }
                DisclosureGroup("Add a Nested Folder Mapping") {
                    VStack(alignment: .leading, spacing: 4) {
                        LensWorksRelinkEnteredFolder(reference: $nestedFrom)
                        LensWorksRelinkDestinations(folder: true, paths: $nestedDestinations, window: window, identifier: "LensWorks.relinkNested")
                        Button("Create Revised Folder Review") {
                            guard let nestedFrom else { return }
                            let targets = nestedDestinations
                            attempt { try await review.revise([.Prefix(from: nestedFrom, destinations: targets)]) }
                        }.disabled(busy || nestedFrom == nil || nestedDestinations.isEmpty)
                    }
                }
                Text("Originals in This Review").font(.headline)
                ForEach(review.items, id: \.sequence.value) { item in itemRow(item) }
                if review.items.isEmpty { Text(review.itemsNext == nil ? "No entries on this page." : "No matching entries in this batch. Continue to the next page.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("First Page / Refresh") { attempt { try await review.loadItems() } }.disabled(busy)
                    Button("Next Page") { attempt { try await review.nextItems() } }.disabled(busy || review.itemsNext == nil)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func ruleDescription(_ row: LWApplicationRelinkRuleRow) -> some View {
        switch row.rule {
        case .Scope(.Prefix(let from, let destinations)):
            Text("Folder: " + LensWorksRelinkPaths.label(from)).font(.caption)
            ForEach(Array(destinations.enumerated()), id: \.offset) { _, path in Text("Destination: " + LensWorksRelinkPaths.label(path)).font(.caption) }
        case .Scope(.Asset(let asset, let destinations)):
            Text("Original: " + (row.label ?? "Saved original association")).font(.caption).help(asset)
            ForEach(Array(destinations.enumerated()), id: \.offset) { _, path in Text("Destination: " + LensWorksRelinkPaths.label(path)).font(.caption) }
        case .Scope(.Volume(let volume, let mount, let filesystem)):
            Text("Reconnect volume to " + LensWorksRelinkPaths.label(mount) + " · " + filesystem).font(.caption).help(volume)
        case .Override(let change):
            switch change {
            case .Prefix(let from, let destinations):
                Text("Nested folder: " + LensWorksRelinkPaths.label(from)).font(.caption)
                ForEach(Array(destinations.enumerated()), id: \.offset) { _, path in Text("Destination: " + LensWorksRelinkPaths.label(path)).font(.caption) }
            case .Asset(let asset, let candidates):
                Text("Original: " + (row.label ?? "Retained association") + (candidates.isEmpty ? " · Excluded from this review" : "")).font(.caption).help(asset)
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, path in Text("Candidate: " + LensWorksRelinkPaths.label(path)).font(.caption) }
            case .Source(let source, let candidates):
                Text("Metadata source: " + (row.label ?? "Retained association") + (candidates.isEmpty ? " · Excluded from this review" : "")).font(.caption).help(String(source.value))
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, path in Text("Candidate: " + LensWorksRelinkPaths.label(path)).font(.caption) }
            }
        }
    }

    private func itemRow(_ item: LWApplicationRelinkItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LensWorksRelinkPaths.label(item.original)).font(.caption.weight(.semibold)).textSelection(.enabled)
            Text(LensWorksRelinkPaths.status(item.status) + ": " + item.detail).font(.caption)
                .foregroundStyle(["matched", "user_confirmed"].contains(item.status) ? Color.green : item.status == "excluded" ? Color.secondary : Color.orange)
                .accessibilityIdentifier("LensWorks.relinkItemStatus")
            Text(LensWorksRelinkPaths.identity(item.identity_basis)).font(.caption2).foregroundStyle(.secondary)
            if let destination = item.destination { Text("Reviewed destination: " + LensWorksRelinkPaths.label(destination)).font(.caption2) }
            ForEach(Array(item.candidates.enumerated()), id: \.offset) { _, candidate in
                HStack {
                    Text(LensWorksRelinkPaths.label(candidate.path) + " · " + LensWorksRelinkPaths.status(candidate.status) + ": " + candidate.detail).font(.caption2)
                    Spacer()
                    if candidate.status != .Mismatch {
                        let chosen = review.chosenCandidates[item.asset_id] == candidate.path
                        Button(chosen ? "Chosen ✓" : "Use This Candidate") { review.choose(assetID: item.asset_id, candidate: chosen ? nil : candidate.path) }
                            .font(.caption2).disabled(busy).accessibilityIdentifier("LensWorks.relinkUseCandidate")
                    }
                }
            }
            LensWorksRelinkCandidateChange(busy: busy, window: window) { candidates in
                attempt { try await review.revise([.Asset(asset_id: item.asset_id, candidates: candidates)]) }
            }
            DisclosureGroup("Related Metadata Sources") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(review.sources[item.sequence.value] ?? [], id: \.source_id.value) { source in
                        Text(LensWorksRelinkPaths.label(source.original)).font(.caption2)
                        Text(LensWorksRelinkPaths.status(source.status) + ": " + source.detail).font(.caption2)
                        if let destination = source.destination { Text("Destination: " + LensWorksRelinkPaths.label(destination)).font(.caption2) }
                        ForEach(Array(source.candidates.enumerated()), id: \.offset) { _, candidate in
                            Text(LensWorksRelinkPaths.label(candidate.path) + " · " + LensWorksRelinkPaths.status(candidate.status) + ": " + candidate.detail).font(.caption2)
                        }
                        LensWorksRelinkCandidateChange(busy: busy, window: window) { candidates in
                            attempt { try await review.revise([.Source(source_id: source.source_id, candidates: candidates)]) }
                        }
                    }
                    HStack {
                        Button("First Page / Refresh") { attempt { try await review.loadSources(sequence: item.sequence) } }.disabled(busy)
                        Button("Next Page") {
                            if let next = review.sourcesNext[item.sequence.value] { attempt { try await review.loadSources(sequence: item.sequence, after: next) } }
                        }.disabled(busy || review.sourcesNext[item.sequence.value] == nil)
                    }
                }
            }.font(.caption)
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("LensWorks.relinkItem." + URL(fileURLWithPath: LensWorksRelinkPaths.label(item.original)).lastPathComponent)
    }
}

/// Explicit candidate choice for one association, or its exclusion from the revised review.
private struct LensWorksRelinkCandidateChange: View {
    let busy: Bool
    let window: NSWindow?
    let apply: ([LWCatalogNativePath]) -> Void
    @State private var paths: [LWCatalogNativePath] = []
    var body: some View {
        DisclosureGroup("Change This Association") {
            VStack(alignment: .leading, spacing: 4) {
                LensWorksRelinkDestinations(folder: false, paths: $paths, window: window, identifier: "LensWorks.relinkCandidate")
                HStack {
                    Button("Revise with These Candidates") { apply(paths) }.disabled(busy || paths.isEmpty)
                    Button("Exclude from Revised Review") { apply([]) }.disabled(busy)
                }
            }
        }.font(.caption)
    }
}
