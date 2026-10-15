import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    var workingVersion: LensWorksWorkingVersion? { didSet { if workingVersion?.id != relinkedOriginal?.version { relinkedOriginal = nil } } }
    /// The original location a catalog relink assigned to the open working version this session.
    /// It is recorded by the next save and survives reloads of a package written elsewhere.
    var relinkedOriginal: (version: UUID, path: String, native: LWCatalogNativePath?)?
    private var saveGeneration = 0
    /// Whether opening and saving add the project to File › Open Recent (macOS keeps that list for the person; tests
    /// turn this off so a fixture never lands in it).
    var recordsRecentProjects = true
    /// Whether saving a catalog working version records it in the app's shared version index and as the last one
    /// opened (tests turn this off so a fixture never lands in the person's own).
    var sharesWorkingVersions = true
    /// The history storage limits a save works to. Tests supply their own.
    var historySettings: () -> LWHistorySettings = { LWHistorySettingsCenter.shared.settings }
    /// Stands in for the process dying part-way through a history write (tests only).
    var historyFault: (@Sendable (LWHistoryArchive.Stage) throws -> Void)?
    /// Test seams: they answer a question that would otherwise go to the person in an alert, so no window appears.
    /// They are read only under XCTest (`LensWorksUserState.isTesting`): in the app nothing answers a loss question
    /// but the person's alert, so nothing in the product can make an `LWLossConfirmation` for itself.
    var answerLoss: ((LWLossQuestion) async -> Bool)?
    var answerName: ((LWNameQuestion) async -> String?)?
    /// With this set, errors and notices are recorded in `notices` instead of raising an alert (tests set it).
    var collectsNotices = false
    private var warnedHistoryStorage: HistoryStorageWarning?
    /// The storage limit the person has been told removes undo steps from this document at a save.
    private var notifiedPruneLimit: Int64?
    var notices: [String] = []
    /// Where version commands look up and record a photo's working versions.
    var versionIndex = LensWorksCatalogIndex.shared
    /// How a deleted version's package leaves its folder: to the Trash, so the person can still take it back.
    var removeVersionPackage: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    private(set) var sourceCloseRequested = false
    private var standaloneCloseConfirmed = false
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false, to suppliedDestination: URL? = nil) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        let prepared = await prepareSave(asNew: asNew, suppliedDestination: suppliedDestination)
        // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
        // while the package is written in the background, as in Photoshop.
        session.isProjectBusy = false
        guard let prepared else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision, workingVersion: prepared.workingVersion, history: prepared.history)
    }

    /// Points the open working version at its original's current (relinked) location. Identity,
    /// photo, copy and project are unchanged; Save As and export guards use the new location.
    func relinkOriginal(path: String, native: LWCatalogNativePath?) {
        guard let version = workingVersion, version.originalPath != path || version.originalNativePath != native else { return }
        workingVersion = version.relinked(originalPath: path, native: native)
        relinkedOriginal = (version.id, path, native)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    private var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }
    /// Waits for a save under way to finish: one still capturing the document, then its write.
    func finishSaving() async {
        await session.waitForProjectAccess()
        await finishWriting()
    }
    /// Whether a save is still writing the package.
    var isWriting: Bool { writing != nil }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await ImageExporter.shared.exportPNG(snapshot, to: url, workingVersion: workingVersion)
        }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    /// Export PNG straight to `url`, for a caller that already chose the destination (an agent's granted path).
    func exportPNG(to url: URL) async throws {
        guard session.document != nil, begin() else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
        try await ImageExporter.shared.exportPNG(snapshot, to: url, workingVersion: workingVersion)
    }
    /// Export JPEG straight to `url` with `options`, without the export sheet.
    func exportJPEG(to url: URL, options: JPEGOptions) async throws {
        guard session.document != nil, begin() else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
        let raster = try await ImageExporter.shared.render(snapshot)
        let data = try await ImageExporter.shared.jpegFile(raster, options: options)
        try data.check()
        try await ImageExporter.shared.write(data.file, to: url, workingVersion: workingVersion)
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Canvas Size"
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, session: session) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized,actionName:"Canvas Size",admission:admission)
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Image Size"
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized,actionName:"Image Size",admission:admission)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Trim"
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            try session.applyDocumentSize(resized,actionName:"Trim",admission:admission)
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    /// View > Grid Settings…: changes only how the grid is drawn and snapped to, so nothing is saved or undone. The
    /// grid shows while the sheet is open, changing as it's edited, and goes back to how it was on Cancel.
    func gridSettings() async {
        guard let window, window.attachedSheet == nil else { return }
        let original = (grid: session.layoutGrid, appearance: session.gridAppearance, shown: session.showsGrid)
        session.showsGrid = true
        let settings: (LayoutGrid, GridAppearance)? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Grid"
            sheet.contentViewController = NSHostingController(rootView: GridSettingsSheet(
                session: session, grid: original.grid, appearance: original.appearance,
                preview: { [session] grid, appearance in
                    session.layoutGrid = grid
                    session.gridAppearance = appearance
                }) { settings in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    sheet.contentViewController = nil
                    continuation.resume(returning: settings)
                })
            window.beginSheet(sheet)
        }
        session.showsGrid = original.shown
        session.layoutGrid = settings?.0 ?? original.grid
        session.gridAppearance = settings?.1 ?? original.appearance
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: JPEGFileResult? = await withCheckedContinuation { continuation in
                let sheet = NSWindow()
                sheet.styleMask = [.titled, .fullSizeContentView]
                sheet.title = "Export JPEG"
                sheet.contentViewController = NSHostingController(rootView: JPEGExportSheet(raster: raster, session: session) { data in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    // Release the hosted view and its closure after dismissal.
                    sheet.contentViewController = nil
                    continuation.resume(returning: data)
                })
                window.beginSheet(sheet)
            }
            guard let data else { return }
            try data.check()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.check()
            try await ImageExporter.shared.write(data.file,to:url,workingVersion:workingVersion)
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return true }
        guard let prepared = await prepareSave(asNew: asNew) else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision, workingVersion: prepared.workingVersion, history: prepared.history)
    }

    /// The document as it is now, and where it goes: asks with the Save panel when it has no file yet (or Save As).
    private func prepareSave(asNew: Bool, suppliedDestination: URL? = nil) async -> (snapshot: ProjectSnapshot, destination: URL, revision: DocumentHistory.SaveToken, workingVersion: LensWorksWorkingVersion?, history: LWHistoryArchive.Capture)? {
        let settings = historySettings()
        session.history.entryLimit = settings.stepLimit
        // The document as it is now is the state a save captures, under a name of its own when it was changed
        // outside history since a checkpoint or step recorded the state at the cursor.
        session.history.reconcileCursor(with: session.document)
        let revision = session.history.saveToken
        guard let snapshot = session.projectSnapshot() else { return nil }
        // History is captured with the document, in the same instant, so both describe one state.
        var history: LWHistoryArchive.Capture
        do { history = try session.historyCapture(limitBytes: settings.storageLimitBytes) }
        catch { await showError("Couldn’t save the project", error: error); return nil }
        history.fault = historyFault
        var destination = suppliedDestination ?? (asNew ? nil : session.projectURL)
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.comp"
            panel.title = asNew ? "Save Project As" : "Save Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return nil }
            destination = url
        }
        guard let destination else { return nil }
        // The package holds undo history and checkpoints a newer build wrote. This build cannot read them, and a
        // save over the package would leave them out: that is only done once the person has said so.
        if let schema = session.newerHistorySchema, let open = session.projectURL,
           destination.resolvingSymlinksInPath().standardizedFileURL.path == open.resolvingSymlinksInPath().standardizedFileURL.path {
            guard await confirmLoss(.init(title: "Save without this document’s saved history?",
                message: "A newer version of LensWorks saved undo history and checkpoints in “\(open.lastPathComponent)” (history format \(schema)). This version cannot read them, and saving here removes them from the document for good. Use Save As to keep this file as it is.",
                button: "Save and Remove History"), subject: session.document?.id ?? UUID()) != nil else { return nil }
        }
        do {
            let version = try await LensWorksVersionStore.shared.versionForDestination(workingVersion, destination: destination)
            return (snapshot, destination, revision, version, history)
        } catch { await showError("Destination protected", error: error); return nil }
    }

    /// Writes a captured document in the background. Only that captured version counts as saved.
    private func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: DocumentHistory.SaveToken, workingVersion savedVersion: LensWorksWorkingVersion?, history: LWHistoryArchive.Capture) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Our own save changes the package too; the watch ignores events until the saved bytes are remembered.
            externalChanges.saving = true
            defer { externalChanges.saving = false }
            do {
                let quickLook = try await ImageExporter.shared.quickLookImages(snapshot)
                let commit = try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook, workingVersion: savedVersion, history: history)
                if var version = savedVersion {
                    version.projectPath = destination.path
                    workingVersion = version
                    if sharesWorkingVersions { LensWorksUserState.defaults.set(destination.path, forKey: "LensWorks.lastWorkingVersion") }
                }
                // Register before publishing the URL: the catalog lists working versions again when the project URL
                // changes, and a listing that reached the index before this registration would miss the saved version.
                var registrationError: Error?
                if savedVersion != nil, sharesWorkingVersions {
                    do { guard try await LensWorksCatalogIndex.shared.register(destination) else { throw LensWorksCatalogError.message("The saved package no longer contains its LensWorks source record.") } }
                    catch { registrationError = error }
                }
                session.projectURL = destination
                session.history.markSaved(revision)
                if let commit { session.applyHistorySave(commit, snapshot: snapshot) }
                await refreshSiblingVersions()
                // Asked once per change in what is protected, not on every save.
                if let warning = session.historyStorageWarning {
                    if warning.checkpoints != warnedHistoryStorage?.checkpoints || warning.limitBytes != warnedHistoryStorage?.limitBytes {
                        warnedHistoryStorage = warning
                        notifiedPruneLimit = warning.limitBytes
                        await presentHistoryStorageWarning()
                    }
                } else {
                    warnedHistoryStorage = nil
                    // Undo steps left this session's Undo with the save: the person is told how many and why, once
                    // for a limit (the History Storage panel keeps showing what the last save removed).
                    if let notice = session.historyPruneNotice, notice.limitBytes != notifiedPruneLimit {
                        notifiedPruneLimit = notice.limitBytes
                        await showNotice("Saving removed undo steps to stay within the history storage limit", notice.message)
                    }
                }
                saveGeneration += 1
                if recordsRecentProjects { RecentProjects.shared.note(destination) }
                await rememberProjectDigest(for: destination)
                watchProject(at: destination)
                if let registrationError { await showError("The project was saved; its catalog registration needs reconciliation", error: registrationError) }
                if let commit, !commit.lost.isEmpty {
                    await showNotice("Some saved history could not be kept", "Its saved state was no longer in the project: " + commit.lost.joined(separator: ", ") + ".")
                }
                return true
            } catch {
                await showError("Couldn’t save the project", error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Open Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        // A recent project deleted in Finder: name the project, not the manifest inside it the load would miss.
        guard FileManager.default.fileExists(atPath: source.path) else {
            RecentProjects.shared.refresh()
            await showError("Couldn’t open the project", error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]))
            return false
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            try agentRequest?.admit(snapshot)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
                try agentRequest?.admit(snapshot)
            }
            // Before the package's history is taken up: it is adopted within the step limit, newest steps first.
            session.history.entryLimit = historySettings().stepLimit
            session.installProject(snapshot, from: source)
            workingVersion = snapshot.workingVersion
            await refreshSiblingVersions()
            if recordsRecentProjects { RecentProjects.shared.note(source) }
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard await closeStandaloneSourceProject() else { return }
        do { try session.resumeAfterCheckedSourceClose(); sourceCloseRequested = false; standaloneCloseConfirmed = false }
        catch { session.commandRefusal = error.localizedDescription }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard await closeStandaloneSourceProject() else { return }
        window.close()
    }
    private func closeStandaloneSourceProject() async -> Bool {
        if !standaloneCloseConfirmed {
            guard begin() else { return false }
            let proceed = await confirmReplacement()
            session.isProjectBusy = false
            guard proceed else { return false }
            standaloneCloseConfirmed = true
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(30000))
        do {
            try await releaseConfirmedSourceProject(deadline: deadline)
            try session.finishConfirmedSourceRetirement(protectedOwners: [], deadline: deadline)
            try await LWSourceDeveloper.shared.drainRetainedSessions(deadline: deadline)
            return true
        } catch { session.commandRefusal = "Source Close failed; retry Close: " + error.localizedDescription; return false }
    }

    /// Only a confirmed Close may discard retained failed autosave snapshots.
    /// No new writes/watch callbacks may retain a project while source owners drain.
    func releaseConfirmedSourceProject(deadline: ContinuousClock.Instant) async throws {
        await finishWriting()
        guard writing == nil else { throw ProjectError.invalid }
        try session.beginConfirmedSourceClose()
        sourceCloseRequested = true
        stopWatchingProject()
        while externalChanges.checkTask != nil || externalChanges.checking {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LWSourceCleanupFailure(operation:nil,cleanup:"Project reload is still draining; retry Close.") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await session.releaseConfirmedSourceProject(deadline: deadline)
        workingVersion = nil
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    /// Set on the one controller an agent's file command is driving, for as long as it runs: an error there goes back
    /// to the agent instead of into an alert. Every other project's errors still reach the person.
    var agentRequest: ProjectAgentRequest?
    func showError(_ title: String, error: Error) async {
        if let agentRequest { agentRequest.failure = agentRequest.failure ?? title + ": " + error.localizedDescription; return }
        if collectsNotices { notices.append(title + ": " + error.localizedDescription); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}

/// What an agent's file command supplies in place of the person on the controller it drives: where a failure goes
/// instead of an alert, and a check on a project that was read before it is installed.
@MainActor final class ProjectAgentRequest {
    var failure: String?
    var admit: (ProjectSnapshot) throws -> Void = { _ in }
}
