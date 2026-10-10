import SwiftUI

nonisolated enum LensWorksCommandID: String, Codable, CaseIterable, Sendable {
    case visibility = "layer.visibility"
    case opacity = "layer.opacity"
    case rename = "layer.rename"
    case beginRename = "layer.rename.begin"
    case firstVariants = "catalog.variants.first"
    case moreVariants = "catalog.variants.more"
    case selectVariant = "catalog.variant.select"
    case copy = "catalog.recipe.copy"
    case exposure = "catalog.recipe.exposure"
    case undoRecipe = "catalog.recipe.undo"
    case redoRecipe = "catalog.recipe.redo"
    case rating = "catalog.rating"
}
nonisolated enum LensWorksCommandHistoryOwner: String, Codable, Sendable {
    case document, nativeRecipe, nativeMetadata, none
}
nonisolated enum LensWorksCommandParameterType: String, Codable, Sendable {
    case uuid, uuidArray, optionalBoolean, unitInterval, layerName, cursor, variant, catalogCopyName, exposure, rating
}
nonisolated struct LensWorksCommandParameter: Codable, Sendable {
    let name: String
    let type: LensWorksCommandParameterType
    let description: String
}
nonisolated struct LensWorksCommandShortcut: Codable, Sendable {
    let key: String
    let modifiers: Int
    init(_ key: String, _ modifiers: Int) { self.key = key; self.modifiers = modifiers }
}
nonisolated struct LensWorksCommandDescriptor: Codable, Identifiable, Sendable {
    let id: LensWorksCommandID
    let label: String
    let menu: String
    let shortcut: LensWorksCommandShortcut?
    let parameters: [LensWorksCommandParameter]
    let undoable: Bool
    let historyOwner: LensWorksCommandHistoryOwner
}
nonisolated enum LensWorksCommandRegistry {
    static let descriptors: [LensWorksCommandDescriptor] = [
        .init(id: .visibility, label: "Hide/Show Layer", menu: "Layer", shortcut: LensWorksCommandShortcut("h", 9), parameters: [.init(name: "layers", type: .uuidArray, description: "Exact layer identities in the admitted document; visibility toggles or an explicit Bool."), .init(name: "visible", type: .optionalBoolean, description: "Nil toggles each admitted layer; Bool sets explicit visibility.")], undoable: true, historyOwner: .document),
        .init(id: .opacity, label: "Layer Opacity", menu: "Layer/Appearance", shortcut: nil, parameters: [.init(name: "layers", type: .uuidArray, description: "Exact layer UUIDs in the admitted document."), .init(name: "opacity", type: .unitInterval, description: "Finite value from 0 through 1 applied to the admitted layer identities.")], undoable: true, historyOwner: .document),
        .init(id: .rename, label: "Rename Layer", menu: "Layer", shortcut: nil, parameters: [.init(name: "layer", type: .uuid, description: "Exact admitted layer UUID."), .init(name: "name", type: .layerName, description: "Nonempty trimmed name, at most 16,384 UTF-8 bytes, for one exact layer UUID.")], undoable: true, historyOwner: .document),
        .init(id: .beginRename, label: "Rename Layer…", menu: "Layer", shortcut: nil, parameters: [.init(name: "layer", type: .uuid, description: "The exact layer to name in this admitted document.")], undoable: false, historyOwner: .none),
        .init(id: .firstVariants, label: "First Catalog Copies", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch.") ], undoable: false, historyOwner: .none),
        .init(id: .moreVariants, label: "More Catalog Copies", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch."), .init(name: "cursor", type: .cursor, description: "Exact continuing cursor from the admitted page.")], undoable: false, historyOwner: .none),
        .init(id: .selectVariant, label: "Select Catalog Version", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch."), .init(name: "variant", type: .variant, description: "Full native VariantKey and revision from this admitted photo's variant page.")], undoable: false, historyOwner: .none),
        .init(id: .copy, label: "Create Named Catalog Copy", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch."), .init(name: "label", type: .catalogCopyName, description: "Nonempty catalog version name, at most 1,024 UTF-8 bytes.")], undoable: false, historyOwner: .nativeRecipe),
        .init(id: .exposure, label: "Apply Catalog Exposure", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch."), .init(name: "exposureEV", type: .exposure, description: "Finite native recipe exposure; full VariantKey, revision and recipe digest CAS are captured synchronously.")], undoable: true, historyOwner: .nativeRecipe),
        .init(id: .undoRecipe, label: "Undo Catalog Recipe", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch.") ], undoable: false, historyOwner: .nativeRecipe),
        .init(id: .redoRecipe, label: "Redo Catalog Recipe", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch.") ], undoable: false, historyOwner: .nativeRecipe),
        .init(id: .rating, label: "Catalog Rating", menu: "Catalog/Recipe", shortcut: nil, parameters: [.init(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch."), .init(name: "rating", type: .rating, description: "0 (unrated) through 5; native metadata revision CAS owns publication.")], undoable: false, historyOwner: .nativeMetadata)
    ]
    static func menuLabel(_ label: String, reason: String?) -> String { label + (reason.map { " — " + $0 } ?? "") }
    static func descriptor(_ id: LensWorksCommandID) -> LensWorksCommandDescriptor {
        descriptors.first { $0.id == id }!
    }
}
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
    func admitCommand(_ command: LensWorksLayerCommand) throws -> LensWorksLayerAdmission {
        if let reason = commandAvailability(command) { throw LensWorksCommandRefusal(reason: reason) }
        guard let document else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        if case .rename(let id, _) = command, renamingLayerID == id {
            guard let starting = commandRenameAdmission else { throw LensWorksCommandRefusal(reason: "This name editor no longer owns a command admission.") }
            return .init(command: command, document: starting.document, selection: starting.selection, selected: starting.selected, revision: starting.revision, epoch: starting.epoch, interactionToken: starting.interactionToken)
        }
        return .init(command: command, document: document, selection: activeLayerID, selected: selectedLayerIDs, revision: history.currentRevision, epoch: commandContextEpoch, interactionToken: commandInteraction?.token)
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
        let name: String
        switch admission.command {
        case .visibility(let ids, let explicit): name = explicit == false || (explicit == nil && document?.layers.first(where: { $0.id == ids[0] })?.isVisible == true) ? "Hide Layer" : "Show Layer"
        default: name = LensWorksCommandRegistry.descriptor(admission.command.id).label
        }
        let ownsEdit = commandInteraction == nil && admission.command.id != .beginRename
        if ownsEdit { beginEdit(name) }
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
        guard let token = history.beginInteraction(command.id == .visibility ? (command == .visibility(command.targets, false) ? "Hide Layer" : "Show Layer") : LensWorksCommandRegistry.descriptor(command.id).label, document: document, selection: activeLayerID) else { throw LensWorksCommandRefusal(reason: "Finish the current history transaction first.") }
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
    func admitCommand(_ action: LensWorksCatalogControlAction, expected: LWApplicationDtoVariant) throws -> LensWorksCatalogCommandAdmission {
        .init(id: commandID(action), native: try captureCatalogControl(action, expected: expected))
    }
    func dispatchCommand(_ admission: LensWorksCatalogCommandAdmission) async throws {
        try await LensWorksCommandDispatcher.dispatch(admission, in: self)
    }
}

struct LensWorksLayerCommandButton: View {
    let session: EditorSession
    let command: LensWorksLayerCommand
    var label: String? = nil
    var body: some View {
        let descriptor = LensWorksCommandRegistry.descriptor(command.id)
        let reason = session.commandAvailability(command)
        Button { session.runCommand(command) } label: {
            Text(LensWorksCommandRegistry.menuLabel(label ?? descriptor.label, reason: reason))
        }.disabled(reason != nil).help(reason ?? descriptor.label)
            .accessibilityIdentifier(descriptor.id.rawValue)
    }
}

extension View {
    @ViewBuilder func registeredCommandShortcut(_ id: LensWorksCommandID) -> some View {
        if let definition = ShortcutDefinition.all.first(where: { $0.commandID == id }) {
            let chord = ShortcutSettings.shared.chord(definition)
            self.keyboardShortcut(KeyEquivalent(chord.key.first!), modifiers: chord.eventModifiers)
        } else { self }
    }
}

/// One UI-thread dispatch namespace; native catalog history remains native, and document edits commit the atomic project/history snapshot.
@MainActor enum LensWorksCommandDispatcher {
    @discardableResult static func dispatch(_ admission: LensWorksLayerAdmission, in session: EditorSession) throws -> Bool {
        try session.applyAdmittedCommand(admission)
    }
    static func dispatch(_ admission: LensWorksCatalogCommandAdmission, in catalog: LensWorksCatalog) async throws {
        try await catalog.performCatalogControl(admission.native)
    }
}
