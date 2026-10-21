import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct LensWorksCatalogWorkspace: View {
    let applicationDelegate: CompositorApplicationDelegate
    private var catalog: LensWorksCatalog { applicationDelegate.catalog }
    private var workspace: ProjectWorkspace { applicationDelegate.workspace }
    @State private var groupName = ""
    @State private var editingGroup: LWApplicationOrganizationCollection?
    @State private var groupPrompt = false
    @State private var showingSettings = false
    @State private var settingsScope: LensWorksCatalogScope?
    @State private var movingGroup: LWApplicationOrganizationCollection?
    @State private var largePhoto: LensWorksCatalogAsset?
    @State private var keywordName = ""
    @State private var keywordPrompt = false
    /// The keyword a rename/move/synonym prompt edits, and which prompt is open.
    @State private var editingKeyword: LWApplicationOrganizationKeyword?
    @State private var keywordEdit: KeywordEdit?
    @State private var relinkFocus: LensWorksRelinkFocus = .general
    @State private var showingRelink = false
    enum KeywordEdit: String, Identifiable { case rename = "Rename Keyword", move = "Move Keyword", synonym = "Add Synonym"; var id: String { rawValue } }
    static let labels = ["Red", "Yellow", "Green", "Blue", "Purple"]

    var body: some View {
        HStack(spacing: 0) {
            navigation.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Button("Catalog", systemImage: "square.grid.2x2") { catalog.showingCatalog = true }
                        .accessibilityIdentifier("LensWorks.catalogTab")
                    Button("Editor", systemImage: "slider.horizontal.3") { catalog.showingCatalog = false }
                        .accessibilityIdentifier("LensWorks.editorTab")
                    Spacer()
                    Text("\(catalog.assets.count) shown").foregroundStyle(.secondary)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
                }.padding(8)
                relinkBanner
                Divider()
                if catalog.showingCatalog { grid }
                else {
                    VStack(spacing: 0) {
                        ContentView(session: workspace.current.session, applicationDelegate: applicationDelegate)
                            .id(workspace.current.id)
                            .disabled(workspace.isManaging)
                            .psdConversionSheet(workspace.current.session)
                            .rawDevelopSheet(workspace.current.session)
                            .background { ProjectWindowBridge(controller: workspace.current.controller).frame(width: 0, height: 0) }
                            // A container element, so the editor's own control identifiers are not overwritten.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("LensWorks.editorContent")
                        if let identity = loadedEditorIdentity() {
                            Text(identity)
                                .accessibilityIdentifier("LensWorks.loadedEditorDocument")
                                .accessibilityValue(identity)
                                .accessibilityLabel("Loaded LensWorks editor document " + identity)
                        }
                    }
                }
                Divider()
                HStack {
                    Button("First") { Task { await catalog.refresh() } }.disabled(catalog.isBusy)
                    Button("Previous") { Task { await catalog.previousPage() } }.disabled(!catalog.hasPrevious || catalog.isBusy)
                    Button("Next") { Task { await catalog.nextPage() } }.disabled(!catalog.hasMore || catalog.isBusy)
                    if !catalog.pageComplete { Text("Continue to browse more matches.").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(6)
                filmstrip
            }
        }
        .task {
            LensWorksLaunchTrace.record("catalog.workspace.task.begin", details: ["canceled": String(Task.isCancelled)])
            await catalog.restore(workspace: workspace)
            LensWorksLaunchTrace.record("catalog.workspace.task.end", details: ["canceled": String(Task.isCancelled)])
        }
        .onChange(of: catalog.catalogEpoch) { _, _ in
            showingSettings = false; movingGroup = nil; largePhoto = nil; groupPrompt = false; editingGroup = nil; keywordPrompt = false; keywordEdit = nil; editingKeyword = nil; showingRelink = false
        }
        .onChange(of: workspace.selectedID) { _, _ in
            if let version = workspace.current.controller.workingVersion, version.catalogPath == catalog.catalogPath {
                catalog.selectedPhotoID = catalog.assets.first { $0.photoID == version.photoID && $0.key?.variant_id == version.sourceVariantID }?.id
            }
        }
        .onChange(of: workspace.current.session.projectURL) { _, _ in Task { await catalog.refreshVersions() } }
        .alert("LensWorks", isPresented: Binding(get: { catalog.presentedError != nil }, set: { if !$0 { catalog.dismissPresentedError() } })) {
            Button("OK") { catalog.dismissPresentedError() }
        } message: { Text(catalog.presentedError ?? "") }
        .alert(editingGroup == nil ? "New Virtual Folder" : "Rename Virtual Folder", isPresented: $groupPrompt) {
            TextField("Name", text: $groupName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task { await action { if let editingGroup { try await catalog.renameGroup(editingGroup, name: groupName) } else { try await catalog.createGroup(groupName) } } }
            }
        }
        .alert("New Keyword", isPresented: $keywordPrompt) {
            TextField("People/Ada", text: $keywordName)
            Button("Cancel", role: .cancel) { }
            Button("Create") { let text = keywordName; Task { await action { try await catalog.createKeyword(text) } } }
        } message: { Text(catalog.keywordKind == .Flat ? "A flat keyword has a single level." : catalog.keywordParent.map { "Nested under " + $0.path.joined(separator: " > ") + ". Use “/” for deeper levels." } ?? "Use “/” to nest levels, for example People/Ada.") }
        .alert(keywordEdit?.rawValue ?? "", isPresented: Binding(get: { keywordEdit != nil }, set: { if !$0 { keywordEdit = nil } })) {
            TextField(keywordEdit == .move ? "New parent, e.g. Places/Europe (empty for top level)" : "Name", text: $keywordName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let keyword = editingKeyword, let edit = keywordEdit else { return }
                let text = keywordName
                Task { await action {
                    switch edit {
                    case .rename: try await catalog.renameKeyword(keyword, to: text)
                    case .move: try await catalog.moveKeyword(keyword, under: LensWorksCatalog.keywordPath(text))
                    case .synonym: try await catalog.addKeywordSynonym(keyword, text)
                    }
                } }
            }
        } message: { Text(editingKeyword.map { $0.path.joined(separator: " > ") + (keywordEdit == .synonym ? "" : " and everything nested under it move together; photos follow.") } ?? "") }
        .sheet(isPresented: $showingSettings, onDismiss: {
            guard let scope = settingsScope, catalog.scopeIsCurrent(scope) else { return }
            Task {
                guard catalog.scopeIsCurrent(scope) else { return }
                await catalog.finishSettingsPause()
                if catalog.scopeIsCurrent(scope) { await catalog.resumePreviews() }
            }
        }) { LensWorksPreviewSettingsView(catalog: catalog, window: workspace.window) }
        .sheet(isPresented: Binding(get: { movingGroup != nil }, set: { if !$0 { movingGroup = nil } })) { if let group = movingGroup { LensWorksGroupParentPicker(catalog: catalog, group: group) } }
        .sheet(item: $largePhoto) { asset in LensWorksLargePreview(asset: asset, catalog: catalog) }
        .sheet(isPresented: $showingRelink) { LensWorksRelinkSheet(catalog: catalog, window: workspace.window, focus: relinkFocus) }
    }

    private func locate(_ focus: LensWorksRelinkFocus) { relinkFocus = focus; showingRelink = true }
    /// Storage write hold and the one-step Undo of the latest applied relink.
    @ViewBuilder private var relinkBanner: some View {
        let review = catalog.relink
        if review.writeHold || (review.isRunning && review.operation?.action != .Original) {
            HStack {
                Text("Storage operation in progress: catalog writes and new original rendering are held. Cached browsing remains available.").font(.caption)
                Spacer()
                Button("Review Progress") { locate(.general) }
                Button("Cancel Storage Operation") { Task { try? await review.cancel() } }
            }.padding(.horizontal, 8).padding(.bottom, 6).accessibilityElement(children: .contain).accessibilityIdentifier("LensWorks.storageHold")
        } else if let applied = review.lastApplied {
            HStack {
                Text("Relinked \(applied.matched.value + applied.user_confirmed.value) original(s). Photo identities, copies, metadata and working versions are unchanged; no files moved.").font(.caption)
                Spacer()
                Button("Undo Relink") { Task { await action { try await review.undo(applied) } } }.disabled(review.isRunning)
                    .accessibilityIdentifier("LensWorks.undoRelink")
            }.padding(.horizontal, 8).padding(.bottom, 6).accessibilityElement(children: .contain).accessibilityIdentifier("LensWorks.relinkApplied")
        }
    }

    private func loadedEditorIdentity() -> String? {
        guard let asset = catalog.selectedAsset,
              let version = workspace.current.controller.workingVersion,
              version.catalogPath == catalog.catalogPath,
              version.photoID == asset.photoID,
              version.sourceVariantID == (asset.key?.variant_id ?? "master"),
              let document = workspace.current.session.document else { return nil }
        let width = Int(document.size.width.rounded())
        let height = Int(document.size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return asset.filename + "|" + version.sourceVariantID + "|" + String(width) + "x" + String(height)
    }

    private func action(_ body: () async throws -> Void) async {
        let scope = catalog.captureScope()
        do { try catalog.checkScope(scope); try await body() }
        catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
    }
    private func open(_ asset: LensWorksCatalogAsset) async {
        let scope = catalog.captureScope()
        await catalog.select(asset)
        guard catalog.scopeIsCurrent(scope), catalog.selectedAsset?.id == asset.id else { return }
        if let version = catalog.selectedVersions.first { await catalog.openVersion(version, workspace: workspace) }
        else { await catalog.createWorkingVersion(workspace: workspace) }
    }
    /// The selected original's observed availability, re-observed whenever the selection changes or
    /// a cached observation is forgotten (refresh, relink, volume mount/unmount/rename). Until an
    /// observation succeeds it reads as unknown and gated actions stay disabled; failures retry.
    private func originalAvailability(_ asset: LensWorksCatalogAsset) -> some View {
        let status = catalog.originalStatus(asset)
        let failure = catalog.originalObservationErrors[asset.photoID]
        let text = status.map { LensWorksOriginalAvailability.headline($0) } ?? (failure == nil ? "Checking original…" : "Original check failed")
        return HStack {
            Label(text, systemImage: status.map { LensWorksOriginalAvailability.isAvailable($0) ? "checkmark.circle" : "externaldrive.badge.xmark" } ?? (failure == nil ? "clock" : "exclamationmark.triangle"))
                .font(.caption).help(status?.detail ?? catalog.originalUnavailableReason(asset) ?? "")
                .accessibilityIdentifier("LensWorks.originalAvailability").accessibilityValue(text)
            if let status, !LensWorksOriginalAvailability.isAvailable(status) {
                Button("Locate Original…") { locate(.original) }.font(.caption).accessibilityIdentifier("LensWorks.locateOriginal")
            }
        }.task(id: String(catalog.catalogEpoch) + "/" + asset.photoID + "/" + String(status == nil)) {
            var delay = 150
            while !Task.isCancelled, catalog.originalStatus(asset) == nil {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                await catalog.observeSelectedOriginal()
                delay = min(delay * 3, 5_000)
            }
        }
    }
    private func importSummary(_ progress: LWApplicationDtoImportStatus) -> String {
        let results = "Added \(progress.imported.value) · unchanged \(progress.unchanged.value) · failed \(progress.failed.value) · skipped \(progress.skipped.value)"
        let metadata = "Metadata updated \(progress.metadata_updated.value) · warnings \(progress.metadata_warnings.value)"
        let waiting = "Waiting \(progress.awaiting_resources.value) · previews \(progress.pending_previews)"
        return [results, metadata, waiting].joined(separator: "\n")
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LensWorks").font(.title2.weight(.semibold))
            if catalog.closingRequested {
                Text("Catalog retirement is pending.").font(.caption).foregroundStyle(.secondary)
                Button("Retry Close Catalog") { Task { do { try await catalog.close() } catch { catalog.error = error.localizedDescription } } }.disabled(catalog.closeInFlight)
            }
            HStack {
                Button("Open…") { Task { await catalog.openCatalog(create: false, window: workspace.window) } }
                Button("New…") { Task { await catalog.openCatalog(create: true, window: workspace.window) } }
            }.disabled(catalog.isBusy || catalog.isImporting || catalog.closingRequested)
            if let path = catalog.catalogPath {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "photo.stack").font(.headline).help(path)
                Button("All Photos") { Task { await action { try await catalog.browse() } } }
                HStack {
                    Button("Add Photos…") { Task { await catalog.importFolder(window: workspace.window) } }.disabled(catalog.isImporting)
                    Button("Previews…", systemImage: "gearshape") { settingsScope = catalog.captureScope(); showingSettings = true }
                }
                Button("Locate Originals…", systemImage: "externaldrive.badge.questionmark") { locate(.general) }
                    .accessibilityIdentifier("LensWorks.locateOriginals")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Source Folders").font(.headline)
                            Spacer()
                            Button("Root") {
                                let scope = catalog.captureScope(), navigation = catalog.folderNavigationGeneration &+ 1
                                Task { await action {
                                    try catalog.checkScope(scope); try await catalog.loadFolders(); try catalog.checkScope(scope)
                                    guard catalog.folderNavigationGeneration == navigation else { throw CancellationError() }
                                    try await catalog.browse()
                                } }
                            }
                        }
                        if let parent = catalog.folderParent {
                            HStack {
                                Button("Up", systemImage: "chevron.up") { Task { await catalog.upFolder() } }
                                Text(parent.name).lineLimit(1).help((try? parent.locator.localFileURL().path) ?? parent.name)
                            }
                        }
                        ForEach(catalog.folders, id: \.id) { folder in
                            Button { Task { await catalog.enterFolder(folder) } } label: {
                                Label(folder.name, systemImage: "folder").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                                .contextMenu { LensWorksCommandButton(.locateFolder, argument: "\(folder.id)") { locate(.folder(folder)) } }
                        }
                        if catalog.folderNext != nil { Button("More Folders") { Task { await catalog.nextFolders() } } }
                        Toggle("Include Subfolders", isOn: Binding(get: { catalog.recursive }, set: { value in
                            Task { await action { try await catalog.browse(folder: catalog.activeFolder, collection: catalog.browseOptions.collection, recursive: value, text: catalog.searchText) } }
                        })).font(.caption)
                        Divider()
                        HStack {
                            Text("Virtual Folders").font(.headline)
                            Spacer()
                            Button { editingGroup = nil; groupName = ""; groupPrompt = true } label: { Image(systemName: "plus") }.help("New Virtual Folder")
                        }
                        ForEach(catalog.groups, id: \.id) { group in
                            Button { Task { await action { try await catalog.browse(collection: group.id) } } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(group.name, systemImage: "folder.badge.gearshape").lineLimit(1)
                                    if let parent = catalog.placements[group.id]?.parent {
                                        Text(catalog.groups.first { $0.id == parent }?.name ?? parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                                .contextMenu {
                                    LensWorksCommandButton(.addToVirtualFolder, argument: "\(group.id)") { Task { await action { try await catalog.setSelectedMembership(group) } } }
                                    LensWorksCommandButton(.removeFromVirtualFolder, argument: "\(group.id)") { Task { await action { try await catalog.setSelectedMembership(group, remove: true) } } }
                                    LensWorksCommandButton(.renameVirtualFolder, argument: "\(group.id)") { editingGroup = group; groupName = group.name; groupPrompt = true }
                                    LensWorksCommandButton(.moveVirtualFolder, argument: "\(group.id)") { movingGroup = group }
                                    LensWorksCommandButton(.deleteVirtualFolder, argument: "\(group.id)", role: .destructive) { Task { await action { try await catalog.deleteGroup(group) } } }
                                }
                        }
                        if catalog.groupNext != nil { Button("More Virtual Folders") { Task { await catalog.nextGroups() } } }
                        Button("First Virtual Folders") { Task { await action { try await catalog.loadGroups() } } }
                        Divider()
                        HStack {
                            Text("Keywords").font(.headline)
                            Spacer()
                            Picker("Keyword kind", selection: Binding(get: { catalog.keywordKind }, set: { kind in Task { await action { try await catalog.setKeywordKind(kind) } } })) {
                                Text("Nested").tag(LWOrganizationKeywordKind.Hierarchical)
                                Text("Flat").tag(LWOrganizationKeywordKind.Flat)
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                                .accessibilityIdentifier("LensWorks.keywordKind")
                            Button { keywordName = ""; keywordPrompt = true } label: { Image(systemName: "plus") }.help("New Keyword")
                                .accessibilityIdentifier("LensWorks.newKeyword")
                        }
                        if let parent = catalog.keywordParent {
                            HStack {
                                Button("Up", systemImage: "chevron.up") { Task { await action { try await catalog.upKeyword() } } }
                                Text(parent.path.joined(separator: " > ")).lineLimit(1)
                            }
                        }
                        ForEach(catalog.keywords, id: \.id.value) { keyword in
                            Button { Task { await action { try await catalog.setFilters(keyword: .some(keyword)) } } } label: {
                                Label(keyword.name, systemImage: catalog.browseOptions.keyword?.value == keyword.id.value ? "tag.fill" : "tag")
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                                .accessibilityIdentifier("LensWorks.keyword." + keyword.path.joined(separator: "/"))
                                .contextMenu {
                                    let keywordID = keyword.path.joined(separator: "/")
                                    if keyword.kind == .Hierarchical {
                                        LensWorksCommandButton(.showNestedKeywords, argument: keywordID) { Task { await action { try await catalog.enterKeyword(keyword) } } }
                                    }
                                    LensWorksCommandButton(.addKeyword, argument: keywordID) { Task { await action { try await catalog.organize(.addKeyword(keyword.path, kind: keyword.kind)) } } }
                                    LensWorksCommandButton(.removeKeyword, argument: keywordID) { Task { await action { try await catalog.organize(.removeKeyword(keyword.path, kind: keyword.kind)) } } }
                                    Divider()
                                    LensWorksCommandButton(.renameKeyword, argument: keywordID) { editingKeyword = keyword; keywordName = keyword.name; keywordEdit = .rename }
                                    if keyword.kind == .Hierarchical {
                                        LensWorksCommandButton(.moveKeyword, argument: keywordID) { editingKeyword = keyword; keywordName = keyword.path.dropLast().joined(separator: "/"); keywordEdit = .move }
                                    }
                                    LensWorksCommandButton(.addSynonym, argument: keywordID) { editingKeyword = keyword; keywordName = ""; keywordEdit = .synonym }
                                    LensWorksCommandButton(.deleteKeyword, argument: keywordID, role: .destructive) { Task { await action { try await catalog.deleteKeyword(keyword) } } }
                                }
                        }
                        if catalog.keywordNext != nil { Button("More Keywords") { Task { await action { try await catalog.nextKeywords() } } } }
                        if let asset = catalog.selectedAsset {
                            Divider()
                            Text(asset.filename).font(.headline).lineLimit(2)
                            LensWorksCatalogRecipeControls(catalog: catalog)
                            originalAvailability(asset)
                            Button("Large Preview") { largePhoto = asset }
                            let offline = catalog.selectedOriginalUnavailableReason
                            Button("Create Working Version") { Task { await catalog.createWorkingVersion(workspace: workspace) } }
                                .disabled(catalog.isBusy || !workspace.canSwitch || offline != nil)
                                .help(offline ?? "Create an editable layered version of this photo")
                                .accessibilityIdentifier("LensWorks.createWorkingVersion")
                            if let offline { Text("Create Working Version needs the full-resolution original. " + offline).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("LensWorks.createWorkingVersionReason") }
                            ForEach(catalog.selectedVersions) { version in
                                Button { Task { await catalog.openVersion(version, workspace: workspace) } } label: { Label(version.name, systemImage: "square.stack.3d.up").lineLimit(1) }
                                    .buttonStyle(.plain).disabled(catalog.isBusy || !workspace.canSwitch)
                            }
                            if let next = catalog.versionNext { Button("More Working Versions") { Task { await catalog.refreshVersions(after: next) } } }
                            if catalog.versionDiscoveryPending { Button("Continue Finding Versions") { Task { await catalog.refreshVersions() } } }
                            Button("Reconcile Working Versions") { Task { await catalog.reconcileWorkingVersions() } }
                        }
                    }
                }
                if catalog.isOrganizing { Button("Stop Organizing After Current Photo") { catalog.organizationCancelRequested = true } }
                if catalog.importProgress == nil, catalog.hasImportCheckpoint {
                    Button("Resume / Rescan Source") { Task { await action { try await catalog.startImport(resume: true) } } }
                }
                if let progress = catalog.importProgress {
                    Divider()
                    Text("Import · " + progress.phase.rawValue).font(.headline)
                    Text(importSummary(progress)).font(.caption).foregroundStyle(.secondary)
                    if let message = progress.error { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let source = progress.error_source { Text((try? source.localFileURL().path) ?? "Native source path").font(.caption).textSelection(.enabled) }
                    if catalog.isImporting {
                        ProgressView().controlSize(.small)
                        Button("Cancel Import") { Task { await action { try await catalog.cancelImport() } } }
                    } else {
                        Button("Resume / Rescan Source") { Task { await action { try await catalog.startImport(resume: true) } } }
                    }
                }
            } else {
                Text("Catalogs keep track of photos in their existing filesystem folders.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            Button("Working Version Folder…") { Task { await catalog.chooseOutput(window: workspace.window) } }.disabled(catalog.isBusy)
            if let output = catalog.outputDirectory { Text(output).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(output) }
            if catalog.isBusy { ProgressView().controlSize(.small) }
            Text(catalog.status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }.padding(12).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)).accessibilityIdentifier("LensWorks.catalogNavigation")
    }
    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search filenames", text: Binding(get: { catalog.searchText }, set: { catalog.searchText = $0 }))
                    .onSubmit { Task { await action { try await catalog.browse(folder: catalog.activeFolder, collection: catalog.browseOptions.collection, recursive: catalog.recursive, text: catalog.searchText) } } }
                Text("\(catalog.selectionCount) selected").font(.caption).foregroundStyle(.secondary)
                Menu("Sort") {
                    LensWorksCommandButton(.sortBy, argument: "sequence", title: "Sequence") { Task { await catalog.setBrowseOrder(sort: .Sequence, direction: catalog.browseOptions.direction) } }
                    LensWorksCommandButton(.sortBy, argument: "capture", title: "Capture Time") { Task { await catalog.setBrowseOrder(sort: .Capture, direction: catalog.browseOptions.direction) } }
                    LensWorksCommandButton(.sortBy, argument: "filename", title: "Filename") { Task { await catalog.setBrowseOrder(sort: .Filename, direction: catalog.browseOptions.direction) } }
                    LensWorksCommandButton(.sortBy, argument: "rating", title: "Rating") { Task { await catalog.setBrowseOrder(sort: .Rating, direction: catalog.browseOptions.direction) } }
                    Divider()
                    LensWorksCommandButton(.sortDirection, argument: "ascending", title: "Ascending") { Task { await catalog.setBrowseOrder(sort: catalog.browseOptions.sort, direction: .Ascending) } }
                    LensWorksCommandButton(.sortDirection, argument: "descending", title: "Descending") { Task { await catalog.setBrowseOrder(sort: catalog.browseOptions.sort, direction: .Descending) } }
                }
                Button("Select Page") { Task { await catalog.selectCurrentPage() } }
                Button("Clear") { Task { await catalog.clearSelection() } }
            }.padding(10)
            organizeBar.padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200))], spacing: 12) {
                    ForEach(catalog.assets) { asset in
                        LensWorksGridCell(asset: asset, catalog: catalog) { await open(asset) }
                    }
                }.padding(12)
            }
            // On the scroll view only, so toolbar controls keep their own identifiers.
            .accessibilityIdentifier("LensWorks.catalogGrid")
        }.focusable()
            // Lightroom-style culling keys: 0–5 rate, P/X/U flag, 6–9 label; the arrows move the selection.
            .registeredCommandKeys([.catalog]) { command, press in
                if command.id == .moveCatalogSelection {
                    let range = command.argument?.hasPrefix("extend") == true
                    let forward = command.argument == "next" || command.argument == "extendNext"
                    Task { await catalog.moveSelection(forward ? 1 : -1, range: range) }
                    return .handled
                }
                guard press.phase == .down, press.modifiers.isEmpty || press.modifiers == .shift, !catalog.isBusy,
                      let argument = command.argument else { return .ignored }
                switch command.id {
                case .ratePhotos: organize(.rating(UInt8(argument) ?? 0))
                case .labelPhotos: organize(.label(argument))
                case .flagPhotos: organize(.flag(Self.flags[argument] ?? .Unflagged))
                default: return .ignored
                }
                return .handled
            }
    }
    private static let flags: [String: LWOrganizationFlag] = ["pick": .Pick, "reject": .Reject, "unflagged": .Unflagged]
    private func organize(_ change: LensWorksOrganizationChange) { Task { await action { try await catalog.organize(change) } } }
    private var organizeBar: some View {
        HStack {
            Menu("Rate") {
                ForEach(0...5, id: \.self) { value in
                    LensWorksCommandButton(.ratePhotos, argument: String(value), title: value == 0 ? "Unrated" : String(repeating: "★", count: value)) { organize(.rating(UInt8(value))) }
                }
            }.fixedSize().accessibilityIdentifier("LensWorks.rateMenu")
            Menu("Flag") {
                LensWorksCommandButton(.flagPhotos, argument: "pick", title: "Pick") { organize(.flag(.Pick)) }
                LensWorksCommandButton(.flagPhotos, argument: "reject", title: "Reject") { organize(.flag(.Reject)) }
                LensWorksCommandButton(.flagPhotos, argument: "unflagged", title: "Unflagged") { organize(.flag(.Unflagged)) }
            }.fixedSize().accessibilityIdentifier("LensWorks.flagMenu")
            Menu("Label") {
                ForEach(Self.labels, id: \.self) { label in LensWorksCommandButton(.labelPhotos, argument: label, title: label) { organize(.label(label)) } }
                LensWorksCommandButton(.labelPhotos, argument: "None", title: "None") { organize(.label("")) }
            }.fixedSize().accessibilityIdentifier("LensWorks.labelMenu")
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await action { try await catalog.undoOrganization() } } }
                .disabled(catalog.organizationUndo.isEmpty || catalog.isBusy)
                .help(catalog.organizationUndo.last.map { "Undo " + $0.title } ?? "Nothing to undo")
                .accessibilityIdentifier("LensWorks.undoOrganization")
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await action { try await catalog.redoOrganization() } } }
                .disabled(catalog.organizationRedo.isEmpty || catalog.isBusy)
                .help(catalog.organizationRedo.last.map { "Redo " + $0.title } ?? "Nothing to redo")
                .accessibilityIdentifier("LensWorks.redoOrganization")
            Divider().frame(height: 16)
            Menu("Filter") {
                Menu("Rating") {
                    LensWorksCommandButton(.filterRating, argument: "any", title: "Any") { Task { await action { try await catalog.setFilters(rating: .some(nil)) } } }
                    ForEach(0...5, id: \.self) { value in
                        LensWorksCommandButton(.filterRating, argument: String(value), title: value == 0 ? "Unrated (0)" : String(repeating: "★", count: value)) { Task { await action { try await catalog.setFilters(rating: .some(UInt8(value))) } } }
                    }
                }
                Menu("Flag") {
                    LensWorksCommandButton(.filterFlag, argument: "any", title: "Any") { Task { await action { try await catalog.setFilters(flag: .some(nil)) } } }
                    LensWorksCommandButton(.filterFlag, argument: "pick", title: "Pick") { Task { await action { try await catalog.setFilters(flag: .some(.Pick)) } } }
                    LensWorksCommandButton(.filterFlag, argument: "reject", title: "Reject") { Task { await action { try await catalog.setFilters(flag: .some(.Reject)) } } }
                    LensWorksCommandButton(.filterFlag, argument: "unflagged", title: "Unflagged") { Task { await action { try await catalog.setFilters(flag: .some(.Unflagged)) } } }
                }
                Menu("Label") {
                    LensWorksCommandButton(.filterLabel, argument: "any", title: "Any") { Task { await action { try await catalog.setFilters(label: .some(nil)) } } }
                    ForEach(Self.labels, id: \.self) { label in
                        LensWorksCommandButton(.filterLabel, argument: label, title: label) { Task { await action { try await catalog.setFilters(label: .some(label)) } } }
                    }
                }
                LensWorksCommandButton(.filterAnyKeyword) { Task { await action { try await catalog.setFilters(keyword: .some(nil)) } } }
                Divider()
                LensWorksCommandButton(.clearFilters) { Task { await action { try await catalog.clearFilters() } } }
            }.fixedSize().accessibilityIdentifier("LensWorks.filterMenu")
            Text(catalog.filterSummary.isEmpty ? "No metadata filters" : catalog.filterSummary.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("LensWorks.filterSummary")
            Spacer()
        }.disabled(catalog.closingRequested)
    }
    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(catalog.assets) { asset in
                    Button { Task { await open(asset) } } label: {
                        VStack(spacing: 3) {
                            LensWorksThumbnail(asset: asset, catalog: catalog).frame(width: 96, height: 58)
                            Text(asset.filename).font(.caption2).lineLimit(1).frame(width: 100)
                        }.padding(4).background(catalog.selectedPhotoID == asset.id ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(catalog.isBusy || !workspace.canSwitch)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.frame(height: 94).accessibilityLabel("Catalog filmstrip").accessibilityIdentifier("LensWorks.filmstrip")
    }
}

private struct LensWorksGridCell: View {
    let asset: LensWorksCatalogAsset
    let catalog: LensWorksCatalog
    let open: @MainActor () async -> Void
    private var background: Color {
        let selected = catalog.selection.contains(asset.id) || catalog.selectedPhotoID == asset.id
        return selected ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor)
    }
    private func openEditor() { Task { await open() } }
    private func selectPhoto() {
        let flags = NSEvent.modifierFlags
        let extending = flags.contains(.command), range = flags.contains(.shift)
        Task { await catalog.select(asset, extending: extending, range: range) }
    }
    var body: some View {
        VStack(spacing: 5) {
            LensWorksThumbnail(asset: asset, catalog: catalog).frame(height: 112)
            Text(asset.filename).font(.caption).lineLimit(1)
            if let key = asset.key { Text(key.variant_id == "master" ? "Master" : "Copy " + String(key.variant_id.prefix(8))).font(.caption2).foregroundStyle(.secondary) }
            if asset.origin != "native" || asset.translationState != "native" { Text(asset.origin + " · " + asset.translationState).font(.caption2).foregroundStyle(.secondary) }
            if !asset.organizationSummary.isEmpty { Text(asset.organizationSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if let status = catalog.originalStatus(asset), !LensWorksOriginalAvailability.isAvailable(status) {
                Label(LensWorksOriginalAvailability.headline(status), systemImage: "externaldrive.badge.xmark").font(.caption2).foregroundStyle(.orange).help(status.detail)
            }
        }.padding(6).frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .onTapGesture(count: 2, perform: openEditor)
            .onTapGesture(perform: selectPhoto)
            .contextMenu { LensWorksCommandButton(.openInEditor, argument: asset.filename, action: openEditor) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(asset.filename)
            .accessibilityValue(asset.organizationAccessibility)
            .accessibilityIdentifier("LensWorks.catalogAsset." + asset.filename)
    }
}

private struct LensWorksThumbnail: View {
    let asset: LensWorksCatalogAsset
    let catalog: LensWorksCatalog
    @State private var preview: LensWorksPreview?
    @State private var message: String?
    var body: some View {
        Group {
            if let preview { Image(decorative: preview.image, scale: 1).resizable().scaledToFit() }
            else if let message { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary).help(message) }
            else { ProgressView().controlSize(.small) }
        }.task(id: asset.id + "/" + (asset.key?.variant_id ?? "") + "/" + String(catalog.previewGeneration)) {
            preview = nil; message = nil
            let generation = catalog.previewGeneration, epoch = catalog.catalogEpoch
            do {
                let next = try await catalog.thumbnail(asset)
                try Task.checkCancellation()
                guard generation == catalog.previewGeneration, epoch == catalog.catalogEpoch else { return }
                preview = next
            } catch { if !(error is CancellationError), generation == catalog.previewGeneration, epoch == catalog.catalogEpoch { message = error.localizedDescription } }
        }
    }
}

private struct LensWorksGroupParentPicker: View {
    let catalog: LensWorksCatalog
    let group: LWApplicationOrganizationCollection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move " + group.name).font(.headline)
            Text("Choose a parent from the paged virtual-folder list.").foregroundStyle(.secondary)
            Button("Root") { Task { await move(nil) } }
            List(catalog.groups.filter { $0.id != group.id }, id: \.id) { parent in
                Button(parent.name) { Task { await move(parent.id) } }
            }
            HStack {
                Button("First") { Task { await firstPage() } }
                Button("Next") { Task { await catalog.nextGroups() } }.disabled(catalog.groupNext == nil)
                Spacer(); Button("Cancel") { dismiss() }
            }
        }.padding().frame(width: 420, height: 420)
    }
    private func firstPage() async {
        let scope = catalog.captureScope()
        do { try await catalog.loadGroups() }
        catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
    }
    private func move(_ parent: String?) async {
        let scope = catalog.captureScope()
        do { try await catalog.placeGroup(group, parent: parent); if catalog.scopeIsCurrent(scope) { dismiss() } }
        catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
    }
}

private struct LensWorksLargePreview: View {
    let asset: LensWorksCatalogAsset
    let catalog: LensWorksCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var preview: LensWorksPreview?
    @State private var message: String?
    var body: some View {
        VStack {
            Text(asset.filename).font(.headline)
            if let preview { Image(decorative: preview.image, scale: 1).resizable().scaledToFit() }
            else if let message { Text(message) } else { ProgressView() }
            Button("Done") { dismiss() }
        }.padding().frame(minWidth: 500, minHeight: 400)
            .task(id: asset.id + String(catalog.previewGeneration)) {
                preview = nil; message = nil
                let generation = catalog.previewGeneration, epoch = catalog.catalogEpoch
                do {
                    let next = try await catalog.thumbnail(asset, tier: .Large)
                    try Task.checkCancellation()
                    guard generation == catalog.previewGeneration, epoch == catalog.catalogEpoch else { return }
                    preview = next
                } catch { if !(error is CancellationError), generation == catalog.previewGeneration, epoch == catalog.catalogEpoch { message = error.localizedDescription } }
            }
    }
}

private struct LensWorksCatalogRecipeControls: View {
    let catalog: LensWorksCatalog
    @State private var name = ""
    @State private var exposure = "0"
    @State private var naming = false
    @State private var namingSource: LWApplicationDtoVariant?
    private func act(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant) {
        let admission: LensWorksCatalogCommandAdmission
        do { admission = try catalog.admitCommand(action, expected: expected) }
        catch {
            if !(error is CancellationError), let current = catalog.currentCatalogVariant,
               current.key.asset_id == expected.key.asset_id, current.key.variant_id == expected.key.variant_id,
               current.revision == expected.revision { catalog.error = error.localizedDescription }
            return
        }
        Task {
            do { try await catalog.dispatchCommand(admission) }
            catch { if !(error is CancellationError), catalog.catalogControlIsCurrent(admission.native) { catalog.error = error.localizedDescription } }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Catalog Recipe").font(.headline)
            if let variant = catalog.currentCatalogVariant {
                Text(variant.label + " · revision " + String(variant.revision.value)).font(.caption)
                Button("Create Named Catalog Copy…") { name = ""; namingSource = variant; naming = true }
                Button("First Catalog Copies") { act(.firstVariants, expected: variant) }
                ForEach(catalog.catalogVariants, id: \.key.variant_id) { copy in
                    Button(copy.label + (copy.key.variant_id == "master" ? " (Master)" : "")) { act(.selectVariant(copy), expected: variant) }
                }
                if let next = catalog.catalogVariantsNext { Button("More Catalog Copies") { act(.moreVariants(next), expected: variant) } }
                HStack {
                    TextField("Exposure EV", text: $exposure).textFieldStyle(.roundedBorder)
                    let action = LensWorksCatalogControlAction.recipe(.exposure(Float(exposure) ?? .nan))
                    let reason = catalog.catalogCommandAvailability(action, expected: variant)
                    Button("Apply Exposure" + (reason.map { " — " + $0 } ?? "")) { act(action, expected: variant) }
                        .disabled(reason != nil).help(reason ?? "Apply Catalog Exposure")
                        .accessibilityIdentifier(LensWorksCommandID.exposure.rawValue)
                }
                HStack {
                    let undoReason = catalog.catalogCommandAvailability(.recipe(.undo), expected: variant)
                    let redoReason = catalog.catalogCommandAvailability(.recipe(.redo), expected: variant)
                    Button("Undo Catalog Recipe") { act(.recipe(.undo), expected: variant) }.disabled(undoReason != nil).help(undoReason ?? (catalog.recipeHistoryOrigin(redo: false) ?? .user).historyName("Undo Catalog Recipe"))
                    Button("Redo Catalog Recipe") { act(.recipe(.redo), expected: variant) }.disabled(redoReason != nil).help(redoReason ?? (catalog.recipeHistoryOrigin(redo: true) ?? .user).historyName("Redo Catalog Recipe"))
                }
                Text("Catalog Rating · " + (catalog.selectedAsset?.rating.map { String($0) } ?? "Unrated")).font(.caption)
                Menu("Catalog Rating") {
                    ForEach(0...5, id: \.self) { value in
                        LensWorksCommandButton(.rating, argument: String(value), title: value == 0 ? "Unrated" : String(value)) { act(.rating(UInt8(value)), expected: variant) }
                    }
                }
            } else { Text("Loading current catalog recipe…").font(.caption) }
        }.disabled(catalog.isBusy || catalog.closingRequested)
            .task(id: String(catalog.catalogEpoch) + "/" + (catalog.selectedPhotoID ?? "") + "/" + String(catalog.pageAuthority.publication)) {
                let scope = catalog.captureScope(), image = catalog.selectedPhotoID, page = catalog.pageAuthority
                do {
                    try await catalog.loadCatalogVariants()
                    if let variant = catalog.currentCatalogVariant, case .V1(let recipe) = variant.recipe { exposure = String(recipe.exposure_ev.value) }
                } catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope), catalog.selectedPhotoID == image, catalog.pageAuthority == page { catalog.error = error.localizedDescription } }
            }
            .alert("Create Named Catalog Copy", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { namingSource = nil }
                Button("Create") { if let expected = namingSource { let label = name; act(.recipe(.copy(label)), expected: expected) }; namingSource = nil }
            } message: { Text("An independent catalog recipe sharing the untouched source. Layered document versions remain separate.") }
            .accessibilityIdentifier("LensWorks.catalogRecipeControls")
    }
}
