import AppKit

/// Proof that the person agreed to lose one particular thing that cannot be brought back with Undo: a checkpoint,
/// a version, a newer build's saved history. It names what was confirmed, so a confirmation given for one thing
/// deletes nothing else. Only two answers make one: the person's own alert (`LWPrompts.confirmLoss`, which under
/// XCTest a test may answer in their place), and the person's Allow in LensWorks's confirmation sheet for an agent's
/// request (`agentRequest`). No command, menu or agent can make one for itself.
struct LWLossConfirmation: Sendable {
    /// What the person agreed to lose: the checkpoint's, the version's or the document's identifier.
    let subject: UUID
    fileprivate init(subject: UUID) { self.subject = subject }
    /// An agent asked for `subject` to go and the person allowed exactly that request (index `index` of what the
    /// confirmation sheet listed). Nil when they did not.
    static func agentRequest(_ approval: LensWorksAgentTools.Approval, index: Int, subject: UUID) -> LWLossConfirmation? {
        approval.indexes.contains(index) ? LWLossConfirmation(subject: subject) : nil
    }
}
/// Answers a loss question in place of the person. It is heeded only under XCTest: in the app the only answer is
/// the alert's.
struct LWLossAnswer {
    let answer: (LWLossQuestion) async -> Bool
    init(_ answer: @escaping (LWLossQuestion) async -> Bool) { self.answer = answer }
}
struct LWLossQuestion: Equatable {
    let title: String
    let message: String
    let button: String
}
struct LWNameQuestion: Equatable {
    let title: String
    let message: String
    let initial: String
    let button: String
}

@MainActor
enum LWPrompts {
    /// A test's stand-in for the person's answer, heeded only in a process under XCTest.
    static func seam<T>(_ answer: T?, testing: Bool) -> T? { testing ? answer : nil }
    /// Asks before `subject` is lost for good. `answer` stands in for the person under XCTest, and only there.
    static func confirmLoss(_ question: LWLossQuestion, subject: UUID, window: NSWindow?, answer: LWLossAnswer?, testing: Bool = LensWorksUserState.isTesting) async -> LWLossConfirmation? {
        if let answer = seam(answer, testing: testing) { return await answer.answer(question) ? LWLossConfirmation(subject: subject) : nil }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: question.button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertFirstButtonReturn ? LWLossConfirmation(subject: subject) : nil
    }
    static func askName(_ question: LWNameQuestion, window: NSWindow?, answer: ((LWNameQuestion) async -> String?)?, testing: Bool = LensWorksUserState.isTesting) async -> String? {
        if let answer = seam(answer, testing: testing) { return await answer(question) }
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        let field = NSTextField(string: question.initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        field.setAccessibilityIdentifier("LensWorks.nameField")
        alert.accessoryView = field
        alert.addButton(withTitle: question.button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

extension ProjectController {
    /// The test's answer to a loss question; nothing outside XCTest (see `LWPrompts.confirmLoss`).
    var lossAnswer: LWLossAnswer? { answerLoss.map(LWLossAnswer.init) }
    func confirmLoss(_ question: LWLossQuestion, subject: UUID) async -> LWLossConfirmation? {
        await LWPrompts.confirmLoss(question, subject: subject, window: window, answer: lossAnswer)
    }
    func askName(_ question: LWNameQuestion) async -> String? {
        await LWPrompts.askName(question, window: window, answer: answerName)
    }
    func showNotice(_ title: String, _ message: String) async {
        if collectsNotices { notices.append(title + ": " + message); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    // MARK: Checkpoints

    /// Edit › New Checkpoint…: asks for a name (an agent passes one) and keeps the document as it is now under it.
    @discardableResult
    func newCheckpoint(named given: String? = nil, origin: LensWorksCommandOrigin = .user) async -> Bool {
        if let reason = session.checkpointUnavailableReason { session.commandRefusal = reason; return false }
        let number = session.history.checkpoints.count + 1
        let asked: String?
        if let given { asked = given }
        else {
            asked = await askName(.init(title: "New Checkpoint", message: "A checkpoint keeps the document exactly as it is now. It is saved with the document and is never pruned.",
                initial: "Checkpoint \(number)", button: "Create"))
        }
        guard let answer = asked else { return false }
        guard session.createCheckpoint(named: answer, origin: origin) != nil else {
            session.commandRefusal = session.checkpointUnavailableReason ?? "A checkpoint needs a name of at most 1,024 bytes."; return false
        }
        return true
    }
    @discardableResult
    func renameCheckpoint(_ id: UUID, to given: String? = nil) async -> Bool {
        if let reason = session.checkpointUnavailableReason { session.commandRefusal = reason; return false }
        guard let checkpoint = session.history.checkpoints.first(where: { $0.id == id }) else { return false }
        let asked: String?
        if let given { asked = given } else { asked = await askName(.init(title: "Rename Checkpoint", message: "", initial: checkpoint.name, button: "Rename")) }
        guard let answer = asked else { return false }
        guard EditorSession.checkpointName(answer) != nil else { session.commandRefusal = "A checkpoint needs a name of at most 1,024 bytes."; return false }
        if let reason = session.checkpointUnavailableReason { session.commandRefusal = reason; return false }
        return session.renameCheckpoint(id, to: answer)
    }
    /// Edit › Delete Checkpoint: asks first, because a deleted checkpoint cannot be brought back with Undo.
    @discardableResult
    func deleteCheckpoint(_ id: UUID) async -> Bool {
        if let reason = session.checkpointUnavailableReason { session.commandRefusal = reason; return false }
        guard let checkpoint = session.history.checkpoints.first(where: { $0.id == id }),
              let confirmation = await confirmLoss(.init(title: "Delete the checkpoint “\(checkpoint.name)”?",
                message: "The state it keeps is removed from this document the next time it is saved, unless an undo step still passes through it. This cannot be undone.",
                button: "Delete Checkpoint"), subject: id) else { return false }
        // The person may have taken a while to answer: the session is asked again whether it can.
        if let reason = session.checkpointUnavailableReason { session.commandRefusal = reason; return false }
        return session.deleteCheckpoint(id, confirmation: confirmation)
    }
    /// Raises the question a save left behind: checkpoints and the current state are over the storage limit. No
    /// checkpoint was removed, and none is unless the person deletes one themselves; the undo steps were.
    func presentHistoryStorageWarning() async {
        guard let warning = session.historyStorageWarning else { return }
        await showNotice("Checkpoints use more than the history storage limit", warning.message)
    }

    // MARK: Versions

    /// Why a version command on the File menu is unavailable now, or nil (and nil for every other command): the one
    /// answer the menu item shows and an agent is refused with.
    func versionReason(_ id: LensWorksCommandID) -> String? {
        switch id {
        case .duplicateVersion, .renameVersion: versionUnavailableReason
        case .switchVersion, .deleteVersion: canStart ? nil : "Finish the current project operation first."
        default: nil
        }
    }
    /// Why the version commands are unavailable; nil when the open document is a catalog photo's working version.
    var versionUnavailableReason: String? {
        if session.document == nil { return "Open a document first." }
        if workingVersion == nil { return "Only a catalog photo’s working version has named versions. Use Save As for this document." }
        return canStart ? nil : "Finish the current edit or project operation first."
    }
    /// The photo's other working versions, for File › Switch to Version and Delete Version.
    func refreshSiblingVersions() async {
        guard let version = workingVersion, sharesWorkingVersions || versionIndex !== LensWorksCatalogIndex.shared else { session.siblingVersions = []; return }
        let catalog = URL(fileURLWithPath: version.catalogPath).resolvingSymlinksInPath().standardizedFileURL.path
        var found: [LensWorksWorkingVersion] = [], after: String?
        repeat {
            guard let page = try? await versionIndex.versions(catalog: catalog, photo: version.photoID, variant: version.sourceVariantID, after: after) else { break }
            found += page.versions; after = page.next
        } while after != nil && found.count < 500
        session.siblingVersions = found.filter { $0.id != version.id }
        session.versionName = version.name
    }
    /// File › Duplicate Version…: saves the document as it is now — unsaved edits, checkpoints and undo history
    /// included — as a new named version beside this one. This version's file is only read, and this tab stays on it.
    @discardableResult
    func duplicateVersion(named given: String? = nil) async -> LensWorksWorkingVersion? {
        if let reason = versionUnavailableReason { session.commandRefusal = reason; return nil }
        guard let version = workingVersion, let source = session.projectURL else { return nil }
        let asked: String?
        if let given { asked = given }
        else {
            asked = await askName(.init(title: "Duplicate Version", message: "The copy is independent: editing one version never changes another.",
                initial: version.name + " copy", button: "Duplicate"))
        }
        guard let answer = asked else { return nil }
        await finishWriting()
        guard canStart else { session.commandRefusal = "Finish the current edit or project operation first."; return nil }
        session.cancelCrop(); session.commitTransform()
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        do {
            let name = try LensWorksVersionStore.versionName(answer)
            let id = UUID(), destination = LensWorksVersionStore.packageURL(named: name, id: id, in: source.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw LensWorksCatalogError.message("A project named \(destination.lastPathComponent) already exists.") }
            let copy = LensWorksWorkingVersion(id: id, photoID: version.photoID, catalogPath: version.catalogPath, originalPath: version.originalPath,
                projectPath: destination.path, name: name, originalNativePath: version.originalNativePath, originalVariantKey: version.originalVariantKey)
            try await LensWorksVersionStore.shared.validate(copy, destination: destination)
            guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
            let history = try session.historyCapture(limitBytes: historySettings().storageLimitBytes)
            let quickLook = try await ImageExporter.shared.quickLookImages(snapshot)
            try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook, workingVersion: copy, history: history)
            try await registerVersion(destination)
            await refreshSiblingVersions()
            return copy
        } catch { await showError("Couldn’t duplicate the version", error: error); return nil }
    }
    private func registerVersion(_ project: URL) async throws {
        guard sharesWorkingVersions || versionIndex !== LensWorksCatalogIndex.shared else { return }
        guard try await versionIndex.register(project) else { throw LensWorksCatalogError.message("The package no longer contains its LensWorks source record.") }
    }
    /// File › Rename Version…: the name only. The file, the identity and the document are untouched.
    @discardableResult
    func renameVersion(to given: String? = nil) async -> Bool {
        if let reason = versionUnavailableReason { session.commandRefusal = reason; return false }
        guard let version = workingVersion, let url = session.projectURL else { return false }
        let asked: String?
        if let given { asked = given } else { asked = await askName(.init(title: "Rename Version", message: "", initial: version.name, button: "Rename")) }
        guard let answer = asked else { return false }
        await finishWriting()
        // Our own write changes the package; the watch must not take it for someone else's.
        externalChanges.saving = true
        defer { externalChanges.saving = false }
        do {
            var renamed = try await LensWorksVersionStore.shared.rename(version, to: answer)
            // A relink made this session is not on disk yet; it stays with the open version.
            renamed = renamed.relinked(originalPath: version.originalPath, native: version.originalNativePath)
            let relinked = relinkedOriginal
            workingVersion = renamed; relinkedOriginal = relinked
            try await registerVersion(url)
            await rememberProjectDigest(for: url)
            await refreshSiblingVersions()
            return true
        } catch { await showError("Couldn’t rename the version", error: error); return false }
    }
    /// Renames another version of this photo (not the one open here): the name only. A tab that has it open takes
    /// the new name at once.
    @discardableResult
    func renameSibling(_ id: UUID, to name: String) async -> Bool {
        guard let sibling = session.siblingVersions.first(where: { $0.id == id }) else { return false }
        do {
            let renamed = try await LensWorksVersionActions.rename(sibling, to: name, workspace: workspace) { try await self.registerVersion($0) }
            _ = renamed
            await refreshSiblingVersions()
            return true
        } catch { await showError("Couldn’t rename the version", error: error); return false }
    }
    /// Copies another version of this photo (not the one open here) from its saved file. A tab that has it open
    /// finishes writing first; changes it has not saved are not copied.
    @discardableResult
    func duplicateSibling(_ id: UUID, named name: String) async -> LensWorksWorkingVersion? {
        guard let sibling = session.siblingVersions.first(where: { $0.id == id }) else { return nil }
        do {
            await LensWorksVersionActions.tab(for: sibling, in: workspace)?.controller.finishSaving()
            let copy = try await LensWorksVersionStore.shared.duplicate(sibling, named: name)
            try await registerVersion(URL(fileURLWithPath: copy.projectPath))
            await refreshSiblingVersions()
            return copy
        } catch { await showError("Couldn’t duplicate the version", error: error); return nil }
    }
    /// The catalog renamed this open version on disk: take the name, and do not mistake the write for someone else's.
    func noteVersionRenamed(_ record: LensWorksWorkingVersion) async {
        guard let version = workingVersion, version.id == record.id else { return }
        let relinked = relinkedOriginal
        workingVersion = record.relinked(originalPath: version.originalPath, native: version.originalNativePath)
        relinkedOriginal = relinked
        if let url = session.projectURL { await rememberProjectDigest(for: url) }
        await refreshSiblingVersions()
    }
    /// File › Switch to Version: opens the photo's other version in its own tab (or shows the tab it is already in).
    @discardableResult
    func switchVersion(_ id: UUID) async -> Bool {
        guard let sibling = session.siblingVersions.first(where: { $0.id == id }) else { return false }
        return await open(URL(fileURLWithPath: sibling.projectPath))
    }
    /// File › Delete Version: asks first, then moves the other version's package to the Trash. A version open in a
    /// tab is refused; this version (the one being edited) is never the target.
    /// With `confirmation` (the person's Allow for an agent's request) nothing is asked again.
    @discardableResult
    func deleteVersion(_ id: UUID, confirmation: LWLossConfirmation? = nil) async -> Bool {
        guard let sibling = session.siblingVersions.first(where: { $0.id == id }) else { return false }
        let deleted = if let confirmation {
            await LensWorksVersionActions.delete(sibling, confirmation: confirmation, index: versionIndex, workspace: workspace, remove: removeVersionPackage)
        } else {
            await LensWorksVersionActions.delete(sibling, index: versionIndex, workspace: workspace, window: window, answer: lossAnswer, remove: removeVersionPackage)
        }
        if case .failure(let error) = deleted { await showError("Couldn’t delete the version", error: error) }
        await refreshSiblingVersions()
        if case .success(true) = deleted { return true }
        return false
    }
}

/// The version operations the catalog and the editor share.
@MainActor
enum LensWorksVersionActions {
    /// The tab a version is open in, if any.
    static func tab(for version: LensWorksWorkingVersion, in workspace: ProjectWorkspace?) -> ProjectTab? {
        workspace?.tabs.first { $0.controller.workingVersion?.id == version.id }
    }
    /// Renames a saved version; `register` records the new name in the version index. A tab that has the version
    /// open finishes writing first, takes the new name at once and does not take the write for someone else's.
    static func rename(_ version: LensWorksWorkingVersion, to name: String, workspace: ProjectWorkspace?,
                       register: (URL) async throws -> Void) async throws -> LensWorksWorkingVersion {
        let open = tab(for: version, in: workspace)
        await open?.controller.finishSaving()
        open?.controller.externalChanges.saving = true
        defer { open?.controller.externalChanges.saving = false }
        let renamed = try await LensWorksVersionStore.shared.rename(version, to: name)
        try await register(URL(fileURLWithPath: renamed.projectPath))
        await open?.controller.noteVersionRenamed(renamed)
        return renamed
    }
    /// Asks, then deletes. `.success(false)` is the person saying no.
    static func delete(_ version: LensWorksWorkingVersion, index: LensWorksCatalogIndex, workspace: ProjectWorkspace?, window: NSWindow?,
                       answer: LWLossAnswer?, remove: @escaping @Sendable (URL) throws -> Void) async -> Result<Bool, Error> {
        let open = LensWorksCatalogError.message("“\(version.name)” is open. Close its tab before deleting it.")
        guard tab(for: version, in: workspace) == nil else { return .failure(open) }
        guard let confirmation = await LWPrompts.confirmLoss(.init(title: "Delete the version “\(version.name)”?",
            message: "Its layers, checkpoints and undo history go with it. The original photo and the photo’s other versions are not changed. The version’s file is moved to the Trash.",
            button: "Delete Version"), subject: version.id, window: window, answer: answer) else { return .success(false) }
        return await delete(version, confirmation: confirmation, index: index, workspace: workspace, remove: remove)
    }
    /// Deletes what the person already confirmed. A version open in a tab is refused: the question can stay up for
    /// as long as the person likes, and the version may have been opened meanwhile.
    static func delete(_ version: LensWorksWorkingVersion, confirmation: LWLossConfirmation, index: LensWorksCatalogIndex, workspace: ProjectWorkspace?,
                       remove: @escaping @Sendable (URL) throws -> Void) async -> Result<Bool, Error> {
        guard tab(for: version, in: workspace) == nil else { return .failure(LensWorksCatalogError.message("“\(version.name)” is open. Close its tab before deleting it.")) }
        do {
            try await LensWorksVersionStore.shared.delete(version, confirmation: confirmation, remove: remove)
            try await index.remove(URL(fileURLWithPath: version.projectPath))
            return .success(true)
        } catch { return .failure(error) }
    }
}
