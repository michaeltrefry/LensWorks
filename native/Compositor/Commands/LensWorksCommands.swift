import SwiftUI
nonisolated enum LensWorksLayerCommand: Codable, Equatable, Sendable {
    case visibility([UUID], Bool?)
    case opacity([UUID], Double)
    case rename(UUID, String)
    case beginRename(UUID)
    var id: LensWorksCommandID {
        switch self { case .visibility: .visibility; case .opacity: .opacity; case .rename: .rename; case .beginRename: .beginRename }
    }
    var targets: [UUID] {
        switch self { case .visibility(let ids, _), .opacity(let ids, _): ids; case .rename(let id, _), .beginRename(let id): [id] }
    }
}
/// Who asked for a command: the person at the Mac (menus, shortcuts, panels) or an AI agent over automation (MCP).
/// An agent's document edits carry "(Agent)" in their history entry so Undo names them.
nonisolated enum LensWorksCommandOrigin: String, Codable, Sendable {
    case user, agent
    /// The history entry name for a command named `name` that this origin dispatched.
    func historyName(_ name: String) -> String { self == .agent ? name + " (Agent)" : name }
}
nonisolated struct LensWorksCommandRefusal: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}
struct LensWorksLayerAdmission {
    let command: LensWorksLayerCommand
    let document: CanvasDocument
    let selection: UUID?
    let selected: Set<UUID>
    let revision: UUID
    let epoch: UInt64
    let interactionToken: UUID?
    var origin: LensWorksCommandOrigin = .user
}
struct LensWorksCommandInteraction {
    let token: UUID
    let commandID: LensWorksCommandID
    let starting: LensWorksLayerAdmission
    var expected: CanvasDocument
}

extension EditorSession {
    func commandAvailability(_ command: LensWorksLayerCommand) -> String? {
        guard let document else { return "Open a document first." }
        guard !isProjectBusy, !isImporting else { return "Finish the current project operation first." }
        guard !command.targets.isEmpty, Set(command.targets).count == command.targets.count,
              command.targets.allSatisfy({ id in document.layers.contains { $0.id == id } }) else { return "The requested layer is no longer in this document." }
        switch command {
        case .rename(let id, let name):
            guard renamingLayerID == nil || renamingLayerID == id else { return "Finish renaming the other layer first." }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 16_384 else { return "Supply a nonempty layer name of at most 16,384 UTF-8 bytes." }
            // The existing name editor deliberately remains available while its own rename field owns focus.
            if renamingLayerID == id { return commandInteraction == nil && canEditLayersWithoutRename ? nil : "Finish the current tool, dialog or layer interaction first." }
        case .opacity(_, let value):
            guard value.isFinite, (0...1).contains(value) else { return "Opacity must be a finite value from 0 through 1." }
        default: break
        }
        guard canEditLayersForCommand else { return "Finish the current tool, dialog or layer edit first." }
        if let interaction = commandInteraction {
            guard interaction.commandID == command.id, Set(command.targets).isSubset(of: Set(interaction.starting.command.targets)) else { return "Finish the current layer interaction first." }
        }
        return nil
    }
    /// The command a Layer menu item targets: the selected layer, or nil when none is selected.
    func layerMenuCommand(_ id: LensWorksCommandID) -> LensWorksLayerCommand? {
        guard let layer = activeLayerID else { return nil }
        switch id {
        case .beginRename: return .beginRename(layer)
        case .visibility: return .visibility([layer], nil)
        default: return nil
        }
    }
    /// The Layer menu's disabled reason. With no selected layer there is no command to
    /// target, so the menu says so rather than reporting a stale or missing layer.
    func layerMenuAvailability(_ command: LensWorksLayerCommand?) -> String? {
        if let command { return commandAvailability(command) }
        guard document != nil else { return "Open a document first." }
        guard !isProjectBusy, !isImporting else { return "Finish the current project operation first." }
        return "Select a layer first."
    }
    func admitCommand(_ command: LensWorksLayerCommand, origin: LensWorksCommandOrigin = .user) throws -> LensWorksLayerAdmission {
        if let reason = commandAvailability(command) { throw LensWorksCommandRefusal(reason: reason) }
        // An agent never joins a person's open layer interaction or name editor: its edit gets its own labeled entry.
        if origin == .agent, commandInteraction != nil || renamingLayerID != nil || command.id == .beginRename {
            throw LensWorksCommandRefusal(reason: "Finish the current layer interaction first.")
        }
        guard let document else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        if case .rename(let id, _) = command, renamingLayerID == id {
            guard let starting = commandRenameAdmission else { throw LensWorksCommandRefusal(reason: "This name editor no longer owns a command admission.") }
            return .init(command: command, document: starting.document, selection: starting.selection, selected: starting.selected, revision: starting.revision, epoch: starting.epoch, interactionToken: starting.interactionToken, origin: origin)
        }
        return .init(command: command, document: document, selection: activeLayerID, selected: selectedLayerIDs, revision: history.currentRevision, epoch: commandContextEpoch, interactionToken: commandInteraction?.token, origin: origin)
    }
    func commandIsCurrent(_ admission: LensWorksLayerAdmission) -> Bool {
        document == admission.document && activeLayerID == admission.selection && selectedLayerIDs == admission.selected && history.currentRevision == admission.revision && commandContextEpoch == admission.epoch && commandInteraction?.token == admission.interactionToken
    }
    /// All callers admit synchronously before deferred work; dispatch rechecks the exact immutable snapshot.
    @discardableResult func dispatchCommand(_ admission: LensWorksLayerAdmission) throws -> Bool {
        try LensWorksCommandDispatcher.dispatch(admission, in: self)
    }
    fileprivate func applyAdmittedCommand(_ admission: LensWorksLayerAdmission) throws -> Bool {
        guard commandIsCurrent(admission) else { throw LensWorksCommandRefusal(reason: "The document or selection changed after command admission.") }
        if let reason = commandAvailability(admission.command) { throw LensWorksCommandRefusal(reason: reason) }
        if let interaction = commandInteraction {
            guard interaction.expected == document, interaction.starting.document.id == document?.id,
                  interaction.starting.selection == activeLayerID, interaction.starting.selected == selectedLayerIDs else { throw LensWorksCommandRefusal(reason: "The layer interaction's document or selection changed.") }
        }
        let label: String
        switch admission.command {
        case .visibility(let ids, let explicit): label = explicit == false || (explicit == nil && document?.layers.first(where: { $0.id == ids[0] })?.isVisible == true) ? "Hide Layer" : "Show Layer"
        default: label = LensWorksCommandRegistry.descriptor(admission.command.id).label
        }
        let name = admission.origin.historyName(label)
        let ownsEdit = commandInteraction == nil && admission.command.id != .beginRename
        var stringBytes=0
        if case .rename(_,let value)=admission.command { stringBytes=try LWSourceMetadataStorage.product(value.utf8.count,2) }
        if ownsEdit { guard beginEdit(name,additionalMetadataBytes:stringBytes) else { throw ProjectError.tooLarge } }
        switch admission.command {
        case .visibility(let ids, let value):
            for index in document!.layers.indices where ids.contains(document!.layers[index].id) {
                document!.layers[index].isVisible = value ?? !document!.layers[index].isVisible
            }
        case .opacity(let ids, let value):
            for index in document!.layers.indices where ids.contains(document!.layers[index].id) { document!.layers[index].opacity = value }
        case .rename(let id, let name):
            let index = document!.layers.firstIndex { $0.id == id }!
            document!.layers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .beginRename(let id): commandRenameAdmission = admission; renamingLayerID = id
        }
        if commandInteraction != nil { commandInteraction!.expected = document! }
        if ownsEdit { endEdit() }
        commandRefusal = nil
        return document != admission.document
    }
    @discardableResult func runCommand(_ command: LensWorksLayerCommand) -> Bool {
        do { return try dispatchCommand(admitCommand(command)) }
        catch { commandRefusal = error.localizedDescription; return false }
    }
    @discardableResult func beginCommandInteraction(_ command: LensWorksLayerCommand) throws -> UUID {
        guard commandInteraction == nil, command.id == .opacity || command.id == .visibility else { throw LensWorksCommandRefusal(reason: "This command cannot begin another layer interaction.") }
        let admission = try admitCommand(command)
        let admittedDocument=try document?.admittingMetadataMutation()
        guard let token = history.beginInteraction(command.id == .visibility ? (command == .visibility(command.targets, false) ? "Hide Layer" : "Show Layer") : LensWorksCommandRegistry.descriptor(command.id).label, document:document,selection:activeLayerID,afterMetadataStorage:admittedDocument?.metadataStorage) else { throw LensWorksCommandRefusal(reason:"Finish the current history transaction first.") }
        document=admittedDocument
        commandInteraction = .init(token: token, commandID: command.id, starting: admission, expected: admission.document)
        return token
    }
    func endCommandInteraction(_ token: UUID) throws {
        guard let interaction = commandInteraction, interaction.token == token,
              interaction.expected == document, interaction.starting.document.id == document?.id,
              interaction.starting.selection == activeLayerID, interaction.starting.selected == selectedLayerIDs, interaction.starting.epoch == commandContextEpoch,
              history.endInteraction(token, document: document, selection: activeLayerID) else { throw LensWorksCommandRefusal(reason: "The layer interaction no longer owns this document transaction.") }
        commandInteraction = nil; commandContextEpoch &+= 1
    }
    /// Retire the exact current transaction while its starting selection/epoch still owns it.
    /// A late UI end/cancel carrying the retired token remains refused.
    func finishCommandInteractionBeforeSelectionChange() {
        guard let interaction = commandInteraction else { return }
        do { try endCommandInteraction(interaction.token); opacityEditLayerID = nil }
        catch { commandRefusal = error.localizedDescription }
    }
    func cancelCommandInteraction(_ token: UUID) throws {
        guard let interaction = commandInteraction, interaction.token == token,
              interaction.expected == document, interaction.starting.document.id == document?.id,
              interaction.starting.selection == activeLayerID, interaction.starting.selected == selectedLayerIDs,
              interaction.starting.revision == history.currentRevision, interaction.starting.epoch == commandContextEpoch,
              let snapshot = history.cancelInteraction(token) else { throw LensWorksCommandRefusal(reason: "The layer interaction no longer owns this document transaction.") }
        commandInteraction = nil; opacityEditLayerID = nil
        document = snapshot.document; activeLayerID = snapshot.activeLayerID
        selectedLayerIDs = interaction.starting.selected; commandContextEpoch &+= 1
    }
}

nonisolated struct LensWorksCatalogCommandAdmission: Sendable {
    let id: LensWorksCommandID
    let native: LensWorksCatalogControlAdmission
    var origin: LensWorksCommandOrigin = .user
}
/// A permanent catalog organization delete (a virtual folder), admitted against the folder row the caller saw.
nonisolated struct LensWorksCatalogDeleteAdmission: Sendable {
    let id: LensWorksCommandID
    let folder: LWApplicationOrganizationCollection
    let origin: LensWorksCommandOrigin
}
extension LensWorksCatalog {
    func commandID(_ action: LensWorksCatalogControlAction) -> LensWorksCommandID {
        switch action {
        case .firstVariants: .firstVariants
        case .moreVariants: .moreVariants
        case .selectVariant: .selectVariant
        case .recipe(.copy): .copy
        case .recipe(.exposure): .exposure
        case .recipe(.undo): .undoRecipe
        case .recipe(.redo): .redoRecipe
        case .rating: .rating
        }
    }
    func catalogCommandAvailability(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant) -> String? {
        do { _ = try captureCatalogControl(action, expected: expected); return nil }
        catch is CancellationError { return "The catalog, photo, version or revision is no longer current." }
        catch { return error.localizedDescription }
    }
    func admitCommand(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant, origin: LensWorksCommandOrigin = .user) throws -> LensWorksCatalogCommandAdmission {
        .init(id: commandID(action), native: try captureCatalogControl(action, expected: expected), origin: origin)
    }
    /// Why the virtual folder `id` cannot be deleted now, or nil when it can.
    func folderDeleteAvailability(_ id: String) -> String? {
        guard catalogPath != nil else { return "Open a catalog first." }
        guard !isBusy else { return "Finish the current catalog operation first." }
        do { try admitCatalogWork() } catch { return error.localizedDescription }
        guard groups.contains(where: { $0.id == id }) else { return "The virtual folder is not on the current folder page." }
        return nil
    }
    func admitFolderDelete(_ id: String, origin: LensWorksCommandOrigin) throws -> LensWorksCatalogDeleteAdmission {
        if let reason = folderDeleteAvailability(id) { throw LensWorksCommandRefusal(reason: reason) }
        return .init(id: .deleteVirtualFolder, folder: groups.first { $0.id == id }!, origin: origin)
    }
    func dispatchCommand(_ admission: LensWorksCatalogCommandAdmission) async throws {
        try await LensWorksCommandDispatcher.dispatch(admission, in: self)
    }
}

struct LensWorksLayerCommandButton: View {
    let session: EditorSession
    let id: LensWorksCommandID
    var label: String? = nil
    var body: some View {
        let descriptor = LensWorksCommandRegistry.descriptor(id)
        let command = session.layerMenuCommand(id)
        let reason = session.layerMenuAvailability(command)
        Button { if let command { session.runCommand(command) } } label: {
            Text(LensWorksCommandRegistry.menuLabel(label ?? descriptor.label, reason: reason))
        }.disabled(reason != nil).help(reason ?? descriptor.label)
            .accessibilityIdentifier(descriptor.id.rawValue)
    }
}

/// One UI-thread dispatch namespace; native catalog history remains native, and document edits commit the atomic project/history snapshot.
@MainActor enum LensWorksCommandDispatcher {
    @discardableResult static func dispatch(_ admission: LensWorksLayerAdmission, in session: EditorSession) throws -> Bool {
        lastInvocation = .init(admission.command.id); lastOrigin = admission.origin
        return try session.applyAdmittedCommand(admission)
    }
    static func dispatch(_ admission: LensWorksCatalogCommandAdmission, in catalog: LensWorksCatalog) async throws {
        lastInvocation = .init(admission.id); lastOrigin = admission.origin
        try await catalog.performCatalogControl(admission.native)
    }
    static func dispatch(_ admission: LensWorksCatalogDeleteAdmission, in catalog: LensWorksCatalog) async throws {
        lastInvocation = .init(admission.id, admission.folder.id); lastOrigin = admission.origin
        try await catalog.deleteGroup(admission.folder)
    }
    /// Who dispatched `lastInvocation` through a typed admission.
    private(set) static var lastOrigin: LensWorksCommandOrigin = .user
    /// The last command a menu item, button or key press dispatched, for diagnostics and the command audit tests.
    private(set) static var lastInvocation: LensWorksCommandInvocation?
    /// The last dispatch refused because its command was unavailable, with the reason the item showed.
    private(set) static var lastRefusal: (invocation: LensWorksCommandInvocation, reason: String)?
    /// Every menu item, context-menu item and pull-down item runs its command through here.
    @discardableResult static func perform(_ invocation: LensWorksCommandInvocation, reason: String? = nil, _ handler: () -> Void) -> Bool {
        lastInvocation = invocation; lastOrigin = .user
        if let reason { lastRefusal = (invocation, reason); return false }
        handler()
        return true
    }
    /// Every key handler resolves a press through the registry's bindings here before acting on it.
    static func resolveKey(_ chord: ShortcutChord, in scopes: Set<LensWorksShortcutScope>, effective: Bool) -> LensWorksCommandInvocation? {
        guard let invocation = LensWorksCommandRegistry.resolve(chord, in: scopes, effective: effective) else { return nil }
        lastInvocation = invocation
        return invocation
    }
}
