import AppKit
import Testing
@testable import Compositor

/// S17: a catalog photo has several independent named versions. They are created, duplicated, renamed, switched
/// between and deleted from the catalog and from the editor; nothing done to one changes another.
@MainActor
struct IndependentVersionTests {
    typealias H = HistoryFixture

    private func setUp(_ name: String = "Versions") throws -> (root: URL, index: LensWorksCatalogIndex) {
        let root = try H.folder(name)
        return (root, LensWorksCatalogIndex(url: root.appendingPathComponent("Index.sqlite3")))
    }
    private func url(_ controller: ProjectController) throws -> URL { try #require(controller.session.projectURL) }
    private func listed(_ index: LensWorksCatalogIndex, _ version: LensWorksWorkingVersion) async throws -> [String] {
        let catalog = URL(fileURLWithPath: version.catalogPath).resolvingSymlinksInPath().standardizedFileURL.path
        return try await index.versions(catalog: catalog, photo: version.photoID, variant: version.sourceVariantID).versions.map(\.name).sorted()
    }

    /// A duplicate is a whole, separate version: its own identity, the same layers, checkpoints and undo history.
    /// Making it, editing it and saving it leave the original's package byte for byte as it was, and the reverse.
    @Test func duplicatingAVersionNeverChangesItsSiblings() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await H.version(named: "Edit", in: root, index: index)
        let retouch = try #require(first.session.activeLayerID)
        try H.paint(first.session, retouch, H.image(32, 24, seed: 7))
        first.session.createCheckpoint(named: "Graded")
        #expect(await first.save(), "\(first.notices)")
        let original = try #require(first.workingVersion), moment = try H.moment(first.session)
        let files = try H.files(try url(first))

        // From the catalog: the saved package is copied under a new identity.
        let copy = try await LensWorksVersionStore.shared.duplicate(original, named: "  Black & White ")
        _ = try await index.register(URL(fileURLWithPath: copy.projectPath))
        #expect(try H.files(try url(first)) == files, "duplicating only reads the original")
        #expect(copy.id != original.id && copy.name == "Black & White" && copy.photoID == original.photoID && copy.originalPath == original.originalPath)
        let folder = try url(first).deletingLastPathComponent()
        #expect(copy.projectPath != original.projectPath && URL(fileURLWithPath: copy.projectPath).deletingLastPathComponent().path == folder.path)
        let copied = try H.files(URL(fileURLWithPath: copy.projectPath))
        let differing = Set(files.keys).union(copied.keys).filter { files[$0] != copied[$0] }.sorted()
        #expect(differing == ["/History/index.json", "/LensWorks.json", "/manifest.json"], "only the identity differs: \(differing)")
        #expect(try H.staged(in: (try url(first)).deletingLastPathComponent()).isEmpty)
        let second = try await H.open(URL(fileURLWithPath: copy.projectPath), index: index)
        #expect(second.workingVersion?.id == copy.id && second.workingVersion?.name == "Black & White")
        #expect(second.session.document?.id == first.session.document?.id)
        #expect(try H.describe(second.session.document) == moment.document)
        #expect(second.session.history.undoCount == first.session.history.undoCount && second.session.history.checkpoints.map(\.name) == ["Graded"])
        #expect(second.session.siblingVersions.map(\.name) == ["Edit"] && second.session.versionName == "Black & White")

        // Editing and saving the copy does not reach the original…
        try H.paint(second.session, retouch, H.image(32, 24, seed: 8), name: "Copy Stroke")
        second.session.createCheckpoint(named: "Only in the copy")
        #expect(await second.save(), "\(second.notices)")
        #expect(try H.files(try url(first)) == files, "saving the copy left the original untouched")
        // …and editing and saving the original does not reach the copy.
        let copyFiles = try H.files(try url(second))
        try H.paint(first.session, retouch, H.image(32, 24, seed: 9), name: "Original Stroke")
        #expect(await first.save(), "\(first.notices)")
        #expect(try H.files(try url(second)) == copyFiles, "saving the original left the copy untouched")
        let reopenedCopy = try await H.open(try url(second), index: index)
        #expect(reopenedCopy.session.history.undoName == "Copy Stroke" && reopenedCopy.session.history.checkpoints.map(\.name) == ["Graded", "Only in the copy"])
        let reopenedOriginal = try await H.open(try url(first), index: index)
        #expect(reopenedOriginal.session.history.undoName == "Original Stroke" && reopenedOriginal.session.history.checkpoints.map(\.name) == ["Graded"])
        // Each still undoes through the history they share, down to the empty canvas.
        for controller in [reopenedCopy, reopenedOriginal] {
            await controller.session.undoNow(); await controller.session.undoNow()
            #expect(try H.describe(controller.session.document)[1...].first?.contains("Photo") == true)
            while controller.session.canUndo { await controller.session.undoNow(); #expect(controller.session.commandRefusal == nil) }
            #expect(controller.session.document == nil)
        }
        #expect(try await listed(index, original) == ["Black & White", "Edit"])
    }

    /// File › Duplicate Version in the editor: the document as it is now, unsaved edits and all, becomes a new
    /// version. The version being edited is not saved, not switched away from and not changed on disk.
    @Test func duplicatingFromTheEditorTakesTheLiveDocumentAndLeavesTheOpenVersionAsItWas() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await H.version(named: "Edit", in: root, index: index)
        let retouch = try #require(first.session.activeLayerID)
        let files = try H.files(try url(first))
        try H.paint(first.session, retouch, H.image(32, 24, seed: 11), name: "Unsaved Stroke")
        let live = try H.moment(first.session)
        var asked: [LWNameQuestion] = []
        first.answerName = { asked.append($0); return nil }
        #expect(await first.duplicateVersion() == nil, "cancelling the name makes nothing")
        first.answerName = { asked.append($0); return "Bold" }
        let copy = try #require(await first.duplicateVersion(), "\(first.notices)")
        #expect(asked.count == 2 && asked[1].title == "Duplicate Version" && asked[1].initial == "Edit copy")
        #expect(try H.files(try url(first)) == files, "the open version's package was only read")
        #expect(first.session.isModified && first.workingVersion?.name == "Edit" && first.session.projectURL?.path != copy.projectPath, "the tab stays on the version it had, still unsaved")
        #expect(first.session.siblingVersions.map(\.name) == ["Bold"])
        let second = try await H.open(URL(fileURLWithPath: copy.projectPath), index: index)
        #expect(second.workingVersion?.id == copy.id && copy.id != first.workingVersion?.id)
        #expect(try H.describe(second.session.document) == live.document, "the copy has the unsaved stroke")
        #expect(second.session.history.undoName == "Unsaved Stroke" && second.session.history.undoCount == first.session.history.undoCount)
        // A name that cannot be stored is refused with the reason; a standalone document has no versions.
        first.answerName = { _ in "   " }
        #expect(await first.duplicateVersion() == nil && first.notices.last?.contains("A version needs a name") == true)
        let standalone = H.controller(index: index)
        try H.add(standalone.session, "Layer", H.image(16, 16, seed: 1))
        #expect(standalone.versionUnavailableReason?.contains("Only a catalog photo’s working version has named versions") == true)
        #expect(await standalone.duplicateVersion() == nil && standalone.session.commandRefusal == standalone.versionUnavailableReason)
        #expect(!(await standalone.renameVersion()))
    }

    /// Rename changes the name alone; Switch opens the other version in its own tab; Delete asks first, refuses a
    /// version that is open, and moves the package away without touching its sibling.
    @Test func versionsAreRenamedSwitchedAndDeletedOnlyAfterConfirmation() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var asked: [LWLossQuestion] = []
        var agree = false
        let workspace = ProjectWorkspace()
        workspace.configureController = { controller in
            H.configure(controller, index: index)
            controller.answerLoss = { asked.append($0); return agree }
            controller.removeVersionPackage = { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent)) }
        }
        let first = try await H.version(named: "Edit", in: root, index: index, controller: workspace.current.controller)
        let original = try #require(first.workingVersion)
        let other = try await LensWorksVersionStore.shared.duplicate(original, named: "Alternate")
        _ = try await index.register(URL(fileURLWithPath: other.projectPath))
        await first.refreshSiblingVersions()
        #expect(first.session.siblingVersions.map(\.id) == [other.id])

        // Rename: the name only, written at once; the open tab is not reloaded and is not made modified.
        let manifest = try Data(contentsOf: (try url(first)).appendingPathComponent("manifest.json"))
        first.answerName = { question in #expect(question.initial == "Edit"); return "Hero" }
        #expect(await first.renameVersion(), "\(first.notices)")
        #expect(first.workingVersion?.name == "Hero" && first.workingVersion?.id == original.id && !first.session.isModified && first.session.versionName == "Hero")
        #expect(try LensWorksWorkingVersion.read(from: try url(first))?.name == "Hero")
        #expect(try Data(contentsOf: (try url(first)).appendingPathComponent("manifest.json")) == manifest)
        #expect(try await listed(index, original) == ["Alternate", "Hero"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(first.externalChanges.reloadCount == 0, "our own rename is not taken for someone else's change")
        #expect(await first.save())
        #expect(try LensWorksWorkingVersion.read(from: try url(first))?.name == "Hero", "a later save keeps the new name")

        // Switch: the other version opens in its own tab; switching back shows the tab that is already open.
        #expect(await first.switchVersion(other.id))
        #expect(workspace.tabs.count == 2 && workspace.current.controller.workingVersion?.id == other.id)
        let second = workspace.current
        #expect(second.session.siblingVersions.map(\.name) == ["Hero"])
        #expect(await second.controller.switchVersion(original.id) && workspace.tabs.count == 2 && workspace.current.controller === first)

        // Delete: refused while the version is open in a tab, before anything is asked.
        agree = true
        #expect(!(await first.deleteVersion(other.id)))
        #expect(asked.isEmpty && first.notices.last?.contains("“Alternate” is open") == true && FileManager.default.fileExists(atPath: other.projectPath))
        await workspace.close(second.id)
        #expect(workspace.tabs.count == 1)
        // "No" keeps it.
        agree = false
        #expect(!(await first.deleteVersion(other.id)))
        #expect(asked.count == 1 && asked[0].title == "Delete the version “Alternate”?" && asked[0].message.contains("moved to the Trash") && asked[0].button == "Delete Version")
        #expect(FileManager.default.fileExists(atPath: other.projectPath) && first.session.siblingVersions.count == 1)
        // "Yes" moves the package away; the sibling and the original photo are untouched.
        let files = try H.files(try url(first))
        agree = true
        #expect(await first.deleteVersion(other.id), "\(first.notices)")
        #expect(asked.count == 2 && !FileManager.default.fileExists(atPath: other.projectPath))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent(URL(fileURLWithPath: other.projectPath).lastPathComponent).path), "the package went where deleted packages go, whole")
        #expect(try H.files(try url(first)) == files && first.session.siblingVersions.isEmpty)
        #expect(try await listed(index, original) == ["Hero"])
        #expect(FileManager.default.fileExists(atPath: original.originalPath))
    }

    /// The same operations from the catalog's version list, with a version open in the editor at the time.
    @Test func theCatalogDuplicatesRenamesAndDeletesVersions() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LWS17-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = LensWorksCatalog(index: index, defaults: defaults)
        let workspace = ProjectWorkspace()
        workspace.configureController = { H.configure($0, index: index) }
        let first = try await H.version(named: "Edit", in: root, index: index, controller: workspace.current.controller)
        let original = try #require(first.workingVersion)
        let files = try H.files(try url(first))
        let copy = try #require(await catalog.duplicateVersion(original, named: "Print"), "\(catalog.error ?? "")")
        #expect(try H.files(try url(first)) == files && copy.id != original.id)
        #expect(try await listed(index, original) == ["Edit", "Print"])
        #expect(await catalog.duplicateVersion(original, named: "") == nil && catalog.error?.contains("A version needs a name") == true)
        catalog.error = nil
        // Renaming the version that is open: its tab takes the name and is not reloaded.
        #expect(await catalog.renameVersion(original, to: "Master", workspace: workspace), "\(catalog.error ?? "")")
        #expect(first.workingVersion?.name == "Master" && first.workingVersion?.id == original.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(first.externalChanges.reloadCount == 0 && !first.session.isModified)
        #expect(try await listed(index, original) == ["Master", "Print"])
        // Deleting the open version is refused; deleting the other asks, and "no" keeps it.
        let removed = PersistentHistoryStorageTests.Counter()
        let remove: @Sendable (URL) throws -> Void = { removed.count += 1; try FileManager.default.moveItem(at: $0, to: root.appendingPathComponent("Removed-" + $0.lastPathComponent)) }
        #expect(!(await catalog.deleteVersion(try #require(first.workingVersion), workspace: workspace, answer: LWLossAnswer { _ in true }, remove: remove)))
        #expect(catalog.error?.contains("is open") == true && removed.count == 0)
        catalog.error = nil
        #expect(!(await catalog.deleteVersion(copy, workspace: workspace, answer: LWLossAnswer { _ in false }, remove: remove)))
        #expect(removed.count == 0 && catalog.error == nil && FileManager.default.fileExists(atPath: copy.projectPath))
        #expect(await catalog.deleteVersion(copy, workspace: workspace, answer: LWLossAnswer { _ in true }, remove: remove), "\(catalog.error ?? "")")
        #expect(removed.count == 1 && !FileManager.default.fileExists(atPath: copy.projectPath))
        #expect(try await listed(index, original) == ["Master"])
        // A version that moved since it was listed is not acted on.
        #expect(!(await catalog.renameVersion(copy, to: "Gone", workspace: workspace)) && catalog.error?.contains("no longer at") == true)
    }

    /// Versions live in project tabs: each tab is one version with its own session and history. Closing the window
    /// (or quitting) with everything saved releases them without asking, and the saved history is there next time.
    @Test func versionTabsCloseAndQuitWithoutLosingSavedHistory() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace()
        var managingWhileOpening: [Bool] = []
        workspace.configureController = { controller in H.configure(controller, index: index); managingWhileOpening.append(workspace.isManaging) }
        let untitled = workspace.current
        #expect(untitled.defaultName == "Untitled" && untitled.title == "Untitled" && untitled.controller.session === untitled.session && untitled.controller.workspace === workspace)
        let first = try await H.version(named: "Edit", in: root, index: index, controller: untitled.controller)
        first.session.createCheckpoint(named: "Kept")
        #expect(await first.save())
        let firstURL = try url(first)
        #expect(untitled.title == firstURL.deletingPathExtension().lastPathComponent, "a saved version's tab is named for its file")
        let other = try await LensWorksVersionStore.shared.duplicate(try #require(first.workingVersion), named: "Second")
        _ = try await index.register(URL(fileURLWithPath: other.projectPath))
        await first.refreshSiblingVersions()
        #expect(await first.switchVersion(other.id) && workspace.tabs.count == 2)
        #expect(managingWhileOpening == [false, true] && !workspace.isManaging, "the workspace is busy only while it opens the version")
        let second = workspace.current
        #expect(second.id != untitled.id && second.session !== untitled.session && second.session.history.checkpoints.map(\.name) == ["Kept"])
        // An invisible window, never ordered in: closing it is all it is for.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        workspace.window = window
        await workspace.closeWindow(window)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil && untitled.session.document == nil && second.session.document == nil)
        #expect(!window.isVisible && !workspace.isManaging)
        // Quit on a workspace with nothing unsaved asks nothing and lets go of the project.
        let quitting = ProjectWorkspace()
        quitting.configureController = { H.configure($0, index: index) }
        #expect(await quitting.open(firstURL) && quitting.current.session.history.checkpoints.map(\.name) == ["Kept"])
        #expect(await quitting.confirmQuit() && quitting.current.session.document == nil)
        // Nothing was lost by closing: both versions open again with their history and checkpoint.
        for project in [firstURL, URL(fileURLWithPath: other.projectPath)] {
            let reopened = try await H.open(project, index: index)
            #expect(reopened.session.history.checkpoints.map(\.name) == ["Kept"] && reopened.session.history.undoCount == 2)
        }
    }

    /// Every version, checkpoint and history-storage action is a registered command with a menu, and an unavailable
    /// one is refused through the dispatcher with its reason.
    @Test func versionAndCheckpointActionsAreRegisteredCommands() throws {
        let ids: [LensWorksCommandID] = [.duplicateVersion, .renameVersion, .switchVersion, .deleteVersion, .createVersion, .openVersion, .deleteCatalogVersion,
                                         .newCheckpoint, .restoreCheckpoint, .renameCheckpoint, .deleteCheckpoint, .historyStorage]
        for id in ids {
            let descriptor = LensWorksCommandRegistry.descriptor(id)
            #expect(descriptor.id == id && !descriptor.menus.isEmpty && !descriptor.label.isEmpty)
        }
        #expect(LensWorksCommandAudit.registryProblems().isEmpty, "\(LensWorksCommandAudit.registryProblems())")
        #expect(LensWorksCommandRegistry.descriptor(.restoreCheckpoint).undoable && LensWorksCommandRegistry.descriptor(.restoreCheckpoint).historyOwner == .document)
        #expect(LensWorksCommandRegistry.descriptor(.duplicateVersion).menus == ["File", "Catalog Version"])
        #expect(LensWorksCommandRegistry.descriptor(.deleteCheckpoint).accepts(title: "Any name the person chose"))
        // Unavailable: refused by the dispatcher, with the reason the menu item shows.
        let session = EditorSession()
        let reason = try #require(session.checkpointUnavailableReason)
        var ran = false
        #expect(!LensWorksCommandDispatcher.perform(.init(.newCheckpoint), reason: reason) { ran = true })
        #expect(!ran && LensWorksCommandDispatcher.lastRefusal?.reason == "Open a document first.")
        try H.add(session, "Layer", H.image(8, 8, seed: 1))
        #expect(session.checkpointUnavailableReason == nil)
        // The audit knows the names the menus list right now: a checkpoint's item is its command, any other is not.
        // It is handed the session whose menus it audits; the hosting app's own is never touched.
        #expect(session.createCheckpoint(named: "Audited") != nil)
        #expect(LensWorksCommandAudit.currentTitles("Edit/Restore Checkpoint", session: session) == ["Audited"]
                && LensWorksCommandAudit.currentTitles("File/Delete Version", session: session) == [])
        let menu = NSMenu(title: "Restore Checkpoint")
        menu.addItem(NSMenuItem.separator())
        let item = menu.addItem(withTitle: "Audited", action: nil, keyEquivalent: ""), rogue = menu.addItem(withTitle: "Not a checkpoint", action: nil, keyEquivalent: "")
        #expect(LensWorksCommandAudit.command(for: item, path: "Edit/Restore Checkpoint", session: session)?.id == .restoreCheckpoint)
        #expect(LensWorksCommandAudit.command(for: rogue, path: "Edit/Restore Checkpoint", session: session) == nil)
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Edit/Restore Checkpoint", session: session).map(\.title) == ["Not a checkpoint"])
        #expect(LensWorksCommandDispatcher.perform(.init(.newCheckpoint), reason: session.checkpointUnavailableReason) { ran = true } && ran)
    }

    /// A loss confirmation names what the person agreed to lose: one given for anything else deletes nothing. A
    /// test's stand-in answer is heeded only under XCTest, and a version opened while the question was up is not
    /// deleted after all.
    @Test func aConfirmationDeletesOnlyWhatItWasGivenFor() async throws {
        let session = EditorSession()
        try H.add(session, "Layer", H.image(8, 8, seed: 1))
        let first = try #require(session.createCheckpoint(named: "First")), second = try #require(session.createCheckpoint(named: "Second"))
        let question = LWLossQuestion(title: "Delete?", message: "", button: "Delete")
        let forFirst = try #require(await LWPrompts.confirmLoss(question, subject: first.id, window: nil, answer: LWLossAnswer { _ in true }))
        #expect(forFirst.subject == first.id)
        #expect(!session.deleteCheckpoint(second.id, confirmation: forFirst), "a confirmation for one checkpoint deletes no other")
        #expect(session.history.checkpoints.map(\.name) == ["First", "Second"])
        #expect(session.deleteCheckpoint(first.id, confirmation: forFirst) && session.history.checkpoints.map(\.name) == ["Second"])
        #expect(await LWPrompts.confirmLoss(question, subject: second.id, window: nil, answer: LWLossAnswer { _ in false }) == nil)
        // Outside XCTest a stand-in answer is ignored: only the person's alert can answer.
        #expect(LWPrompts.seam(LWLossAnswer { _ in true }, testing: false) == nil && LWPrompts.seam(LWLossAnswer { _ in true }, testing: true) != nil)
        #expect(LWPrompts.seam(Optional({ (_: LWNameQuestion) async -> String? in "x" }), testing: false) == nil)
        // A version's deletion is held to the version confirmed too.
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace()
        workspace.configureController = { H.configure($0, index: index) }
        let opened = try await H.version(named: "Edit", in: root, index: index, controller: workspace.current.controller)
        let other = try await LensWorksVersionStore.shared.duplicate(try #require(opened.workingVersion), named: "Other")
        _ = try await index.register(URL(fileURLWithPath: other.projectPath))
        await opened.refreshSiblingVersions()
        do { try await LensWorksVersionStore.shared.delete(other, confirmation: forFirst) { _ in Issue.record("removed unconfirmed") }; Issue.record("deleted unconfirmed") }
        catch { #expect(error.localizedDescription.contains("was not confirmed")) }
        // The person takes a while to answer, and the version is opened in a tab meanwhile: it is not deleted.
        opened.answerLoss = { _ in _ = await workspace.open(URL(fileURLWithPath: other.projectPath)); return true }
        let removed = PersistentHistoryStorageTests.Counter()
        opened.removeVersionPackage = { _ in removed.count += 1 }
        #expect(!(await opened.deleteVersion(other.id)))
        #expect(removed.count == 0 && FileManager.default.fileExists(atPath: other.projectPath) && opened.notices.last?.contains("“Other” is open") == true, "\(opened.notices)")
    }

    /// A version's file name holds at most 255 UTF-8 bytes, so a long name is cut to a byte budget between
    /// characters; a leading dot, which would hide the package, is replaced.
    @Test func aVersionsFileNameFitsInBytesAndIsNeverHidden() throws {
        let folder = URL(fileURLWithPath: "/tmp/Versions"), id = UUID()
        let long = String(repeating: "🌄", count: 200)
        let made = LensWorksVersionStore.packageURL(named: long, id: id, in: folder).lastPathComponent
        #expect(made.utf8.count <= 255 && made.hasSuffix("-\(id.uuidString.prefix(8)).comp"), "\(made.utf8.count) bytes")
        let kept = made.dropLast("-\(id.uuidString.prefix(8)).comp".count)
        #expect(kept.utf8.count <= LensWorksVersionStore.packageNameBytes && kept.allSatisfy { $0 == "🌄" } && kept.count == LensWorksVersionStore.packageNameBytes / 4)
        let accented = String(repeating: "é", count: 100)
        #expect(LensWorksVersionStore.packageURL(named: accented, id: id, in: folder).lastPathComponent.hasPrefix(String(repeating: "é", count: 60) + "-"))
        let hidden = LensWorksVersionStore.packageURL(named: ".Secret/Version:1", id: id, in: folder).lastPathComponent
        #expect(hidden == "-Secret-Version-1-\(id.uuidString.prefix(8)).comp" && !hidden.hasPrefix("."))
        #expect(LensWorksVersionStore.packageURL(named: "..", id: id, in: folder).lastPathComponent == "-.-\(id.uuidString.prefix(8)).comp")
    }

    /// Duplicating a version from the catalog while its tab is still writing a save waits for that save: the copy
    /// is the version as just saved, never one caught between two saves.
    @Test func aCatalogDuplicateWaitsForTheOpenTabsSave() async throws {
        let (root, index) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LensWorksCatalog(index: index, defaults: LensWorksVolatileDefaults())
        let workspace = ProjectWorkspace()
        workspace.configureController = { H.configure($0, index: index) }
        let first = try await H.version(named: "Edit", in: root, index: index, controller: workspace.current.controller)
        let retouch = try #require(first.session.activeLayerID)
        try H.paint(first.session, retouch, H.image(32, 24, seed: 21), name: "Saving Stroke")
        let saved = try H.moment(first.session)
        let saving = Task { await first.save() }
        await Task.yield()
        let version = try #require(first.workingVersion)
        let copy = try #require(await catalog.duplicateVersion(version, named: "Copy", workspace: workspace), "\(catalog.error ?? "")")
        #expect(await saving.value)
        let opened = try await H.open(URL(fileURLWithPath: copy.projectPath), index: index)
        #expect(try H.describe(opened.session.document) == saved.document && opened.session.history.undoName == "Saving Stroke", "the copy has what the save was writing")
    }
}
