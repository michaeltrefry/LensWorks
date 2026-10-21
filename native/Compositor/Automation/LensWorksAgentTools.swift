import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The MCP tools an agent sees. Commands come from the registry and run through LensWorksCommandDispatcher with an
/// agent origin, so they share admission, availability reasons and history with the menus that run them. What an
/// agent can run, and with which arguments, is the registry's answer (`LensWorksCommandDescriptor.agent` and
/// `.parameters`): nothing here lists commands.
final class LensWorksAgentTools {
    let session: () -> EditorSession?
    let catalog: () -> LensWorksCatalog?
    /// The controller and tab strip of the project on screen (the app supplies them; a bare session has neither).
    var projects: () -> ProjectController? = { nil }
    var workspace: () -> ProjectWorkspace? = { nil }
    let folders: LensWorksGrantedFolders
    weak var automation: LensWorksAutomation?
    init(session: @escaping () -> EditorSession?, catalog: @escaping () -> LensWorksCatalog?, folders: LensWorksGrantedFolders) {
        self.session = session; self.catalog = catalog; self.folders = folders
    }
    var context: LensWorksAgentContext { .init(session: session(), projects: projects(), workspace: workspace(), catalog: catalog(), folders: folders) }

    /// Every command an agent can run: the registry's answer.
    static var agentCommands: [LensWorksCommandID] { LensWorksCommandRegistry.agentCommands }
    /// The S38 typed layer commands, admitted against exact layer identities.
    static let layerCommands: Set<LensWorksCommandID> = [.visibility, .opacity, .rename]
    /// The S38 typed catalog controls, admitted against the catalog version they were decided on.
    static let controlCommands: Set<LensWorksCommandID> = [.firstVariants, .moreVariants, .selectVariant, .copy, .exposure, .undoRecipe, .redoRecipe, .rating]
    static func kind(_ id: LensWorksCommandID) -> LensWorksAgentCommandKind? { id.agentAccess.kind }
    /// Whether the registry puts the person's confirmation in front of this command (always, or when it replaces a file).
    static func requiresConfirmation(_ id: LensWorksCommandID) -> Bool { LensWorksCommandRegistry.descriptor(id).requiresAgentConfirmation }
    static func batchable(_ id: LensWorksCommandID) -> Bool { kind(id) == .document || kind(id) == .catalog }
    static let previewDefault = 1024, previewMinimum = 64, previewMaximum = 2048
    /// The most commands one batch may carry.
    static let batchLimit = 64
    /// The longest per-command message in a reply.
    static let messageLimit = 512
    /// The largest text reply (list_commands, get_state, command results). The request limit is the server's.
    static let replyLimit = 1 << 20
    /// The most rows of one kind get_state lists; `…Truncated` says when there were more.
    static let stateRowLimit = 256
    static let stateTextLimit = 256

    static let toolNames: Set<String> = ["list_commands", "get_state", "invoke_command", "batch", "render_preview"]
    static var definitions: [[String: Any]] {
        let empty: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        let member: [String: Any] = ["type": "object", "required": ["command"], "additionalProperties": false, "properties": [
            "command": ["type": "string", "enum": agentCommands.filter(batchable).map(\.rawValue), "description": "A command id from list_commands."],
            "arguments": ["type": "object", "description": "Arguments matching that command's inputSchema from list_commands."]]]
        return [
            ["name": "list_commands", "title": "List LensWorks commands",
             "description": "Every registered LensWorks command: id, title, menu, whether an agent can run it (agentInvocable) and, when it cannot, the reason specific to that command; whether it can run now (with the menu's own reason when not), whether it can be part of a batch, whether it asks the person to confirm, and the JSON schema of its arguments for invoke_command and batch. Pass prefix (for example “layer.” or “catalog.”) to list part of the registry.",
             "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                "prefix": ["type": "string", "maxLength": 64, "description": "Only commands whose id starts with this."]]],
             "annotations": ["readOnlyHint": true]],
            ["name": "get_state", "title": "Describe the open document and catalog",
             "description": "The open document (size, selection, layers with id, name, visibility, opacity, blend mode, mask and effects, the selected layers, and who made the edits Undo and Redo would step over), the project tabs and recent projects, the folders granted to automation, and the open catalog (the photos, catalog folders, virtual folders and keywords on the current page, filters and sort, the selected photo, its catalog version (with who made the recipe changes its Undo and Redo would step over) and copies). Long lists are cut at \(stateRowLimit) rows and say so.",
             "inputSchema": empty, "annotations": ["readOnlyHint": true]],
            ["name": "invoke_command", "title": "Run a LensWorks command",
             "description": "Runs one registered command as the agent. Document edits enter LensWorks history labeled “(Agent)”, so Undo in the app reverts them. edit.undo and edit.redo step only over the agent's own edits, as do the catalog's recipe Undo and Redo. A file path is accepted only inside a folder the person granted to automation, and so is every file a command reaches without naming it (a catalog photo’s original and working version, a project’s RAW originals). Permanent changes (deletes, saving over the project file, replacing an existing file, relinking a moved folder, opening another catalog over organize changes Undo could still revert) wait for the person to confirm in LensWorks and return a refusal when they decline. Unknown argument names are refused.",
             "inputSchema": ["type": "object", "required": ["command"], "additionalProperties": false, "properties": [
                "command": ["type": "string", "enum": agentCommands.map(\.rawValue), "description": "A command id from list_commands."],
                "arguments": ["type": "object", "description": "Arguments matching that command's inputSchema from list_commands."]]]],
            ["name": "batch", "title": "Run several LensWorks commands as one step",
             "description": "Runs up to \(batchLimit) commands in order. Every command's arguments are checked before any runs; one that cannot run refuses the whole batch. A batch is either all document commands (one “(Agent)” history entry that one Undo reverts; any failure rolls the whole batch back) or all catalog commands (checked against the catalog as it stands, run in order and stopped at the first failure; the catalog cannot roll back, so the two kinds never mix). Permanent deletes are confirmed by the person once, for the whole batch, before anything runs, and ride with no unconfirmed command that changes keywords or virtual folders, so what the person approved is what is deleted. History steps and project-file commands (list_commands says batchable: false) are not allowed in a batch. The reply lists a result per command.",
             "inputSchema": ["type": "object", "required": ["commands"], "additionalProperties": false, "properties": [
                "commands": ["type": "array", "minItems": 1, "maxItems": batchLimit, "items": member]]]],
            ["name": "render_preview", "title": "Render a preview of the open document",
             "description": "A PNG of the open document composited as it stands, scaled to fit maxDimension pixels (never enlarged).",
             "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                "maxDimension": ["type": "integer", "minimum": previewMinimum, "maximum": previewMaximum, "default": previewDefault]]],
             "annotations": ["readOnlyHint": true]]
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: LensWorksAutomationCaller = .inProcess) async -> [String: Any] {
        do {
            switch name {
            case "list_commands":
                try Self.rejectUnknown(arguments, allowed: ["prefix"], in: name)
                let prefix = arguments["prefix"] as? String
                if arguments["prefix"] != nil, prefix == nil || prefix!.utf8.count > 64 { throw LensWorksCommandRefusal(reason: "prefix must be a string of at most 64 bytes.") }
                return try Self.bounded(["commands": listCommands(prefix: prefix)], hint: " Pass a prefix such as “layer.” to list part of the registry.")
            case "get_state":
                try Self.rejectUnknown(arguments, allowed: [], in: name)
                return try Self.bounded(state())
            case "invoke_command": return try Self.bounded(try await invoke(arguments, caller: caller))
            case "batch":
                let outcome = try await batch(arguments, caller: caller)
                return try Self.bounded(outcome.value, isError: !outcome.completed)
            default: return try await preview(arguments)
            }
        } catch {
            return ["content": [["type": "text", "text": String(error.localizedDescription.prefix(4096))]], "isError": true]
        }
    }

    /// Refuses argument names the tool or command does not declare: a misspelled name must never silently change
    /// what a command does.
    static func rejectUnknown(_ values: [String: Any], allowed: [String], in what: String) throws {
        guard let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) else { return }
        throw LensWorksCommandRefusal(reason: "Unknown argument “\(unknown.prefix(64))” for \(what). " + (allowed.isEmpty ? "It takes no arguments." : "Its arguments are: " + allowed.sorted().joined(separator: ", ") + "."))
    }

    // MARK: Listing

    func listCommands(prefix: String? = nil) -> [[String: Any]] {
        LensWorksCommandRegistry.descriptors.filter { prefix == nil || $0.id.rawValue.hasPrefix(prefix!) }.map { descriptor in
            let reason = agentAvailability(descriptor.id)
            var row: [String: Any] = [
                "id": descriptor.id.rawValue, "title": descriptor.label, "menu": descriptor.menu,
                "undoable": descriptor.undoable, "history": descriptor.historyOwner.rawValue,
                "agentInvocable": descriptor.agent.isRunnable,
                "batchable": Self.batchable(descriptor.id),
                "requiresConfirmation": descriptor.requiresAgentConfirmation,
                "confirmation": descriptor.agentConfirmation.rawValue,
                "available": reason == nil,
                "parameters": descriptor.parameters.map { ["name": $0.name, "type": $0.type.rawValue, "description": $0.description, "required": $0.required] },
                "inputSchema": Self.inputSchema(descriptor.id)
            ]
            if let kind = descriptor.agent.kind { row["kind"] = kind.rawValue }
            if let reason { row["reason"] = reason } else if let note = agentNote(descriptor.id) { row["note"] = note }
            return row
        }
    }

    /// The layer a listed layer command is checked against: the selected one, else any layer, since an agent may
    /// name layers by id without a selection.
    private func listedLayer(_ session: EditorSession) -> ImageLayer? { session.activeLayer ?? session.document?.layers.last }

    /// Why an agent cannot run `id` now (with its default arguments, or with ids it may pass), or nil when it can.
    /// A command agents never run answers with the reason specific to it.
    func agentAvailability(_ id: LensWorksCommandID) -> String? {
        let descriptor = LensWorksCommandRegistry.descriptor(id)
        guard let kind = descriptor.agent.kind else { return descriptor.agent.exclusion?.rawValue }
        if descriptor.parameters.contains(where: { $0.type.namesPath && $0.required }), folders.grants.isEmpty {
            return "No folders are granted to automation, so no file can be named. " + LensWorksGrantedFolders.rule
        }
        switch id {
        case .undo, .redo:
            guard let session = session() else { return "Open a document first." }
            return session.agentHistoryAvailability(redo: id == .redo)
        case .visibility, .opacity, .rename:
            guard let session = session(), session.document != nil else { return "Open a document first." }
            guard let layer = listedLayer(session) else { return "This document has no layers." }
            if session.commandInteraction != nil || session.renamingLayerID != nil { return "Finish the current layer interaction first." }
            let command: LensWorksLayerCommand = id == .visibility ? .visibility([layer.id], nil) : id == .opacity ? .opacity([layer.id], layer.opacity) : .rename(layer.id, layer.name)
            return session.commandAvailability(command)
        case .deleteVirtualFolder:
            guard let catalog = catalog(), catalog.catalogPath != nil else { return "Open a catalog first." }
            guard let first = catalog.groups.first else { return catalog.isBusy ? "Finish the current catalog operation first." : "There are no virtual folders on the current page." }
            return catalog.folderDeleteAvailability(first.id)
        case _ where Self.controlCommands.contains(id):
            guard let catalog = catalog(), catalog.catalogPath != nil else { return "Open a catalog first." }
            guard let current = catalog.currentCatalogVariant else { return "Select a catalog photo first." }
            if id == .moreVariants && catalog.catalogVariantsNext == nil { return "There are no more catalog copies." }
            return catalog.catalogCommandAvailability(defaultAction(id, catalog: catalog, current: current), expected: current, origin: .agent)
        default: break
        }
        switch kind {
        case .document:
            guard let session = session() else { return "Open a document first." }
            if session.document == nil, id != .importImages { return "Open a document first." }
            if session.document != nil, let reason = session.agentModalReason { return reason }
            return LensWorksAgentDocumentCommands(session: session, context: context).reason(id)
        case .catalog:
            guard let catalog = catalog(), catalog.catalogPath != nil else { return "Open a catalog first." }
            if catalog.isBusy { return "Finish the current catalog operation first." }
            do { try catalog.admitCatalogWork() } catch { return error.localizedDescription }
            return nil
        case .standalone:
            return LensWorksAgentProjectCommands(context: context).availability(id)
        }
    }

    /// What an agent must pass for an available command to run as listed.
    func agentNote(_ id: LensWorksCommandID) -> String? {
        switch id {
        case .visibility, .opacity, .rename:
            return session()?.activeLayerID == nil ? "No layer is selected: pass layer ids from get_state." : nil
        case .deleteVirtualFolder: return "Pass a virtual folder id from get_state."
        default:
            let parameters = LensWorksCommandRegistry.descriptor(id).parameters
            if parameters.contains(where: { $0.type == .reference || $0.type == .referenceArray }) { return "Pass ids from get_state." }
            if parameters.contains(where: { $0.name == "layer" || $0.name == "layers" }) { return "Acts on the selected layers, or on layer ids from get_state." }
            return nil
        }
    }

    private func defaultAction(_ id: LensWorksCommandID, catalog: LensWorksCatalog, current: LWApplicationDtoVariant) -> LensWorksCatalogControlAction {
        switch id {
        case .moreVariants: .moreVariants(catalog.catalogVariantsNext ?? LWCatalogI64(0))
        case .selectVariant: .selectVariant(current)
        case .copy: .recipe(.copy("Agent Copy"))
        case .exposure:
            if case .V1(let recipe) = current.recipe { .recipe(.exposure(recipe.exposure_ev.value)) } else { .recipe(.exposure(0)) }
        case .undoRecipe: .recipe(.undo)
        case .redoRecipe: .recipe(.redo)
        case .rating: .rating(UInt8(clamping: catalog.selectedAsset?.rating ?? 0))
        default: .firstVariants
        }
    }

    static let expectedProperties = ["variantId", "revision"]
    /// The JSON schema of a command's arguments, generated from its registered parameters.
    static func inputSchema(_ id: LensWorksCommandID) -> [String: Any] { LensWorksAgentSchema.inputSchema(id) }

    // MARK: State

    private static func clip(_ text: String) -> String { String(text.prefix(stateTextLimit)) }
    /// At most `stateRowLimit` rows, and whether there were more.
    private static func rows<S: Sequence>(_ items: S, _ row: (S.Element) -> [String: Any]) -> (rows: [[String: Any]], truncated: Bool) {
        var result: [[String: Any]] = [], truncated = false
        for item in items { if result.count == stateRowLimit { truncated = true; break }; result.append(row(item)) }
        return (result, truncated)
    }

    func state() -> [String: Any] {
        var result: [String: Any] = ["document": NSNull(), "catalog": NSNull()]
        result["grantedFolders"] = folders.grants.prefix(Self.stateRowLimit).map(\.path)
        if let workspace = workspace() {
            let tabs = Self.rows(workspace.tabs) { ["id": $0.id.uuidString, "title": Self.clip($0.title), "selected": $0.id == workspace.selectedID, "modified": $0.session.isModified] }
            result["projectTabs"] = tabs.rows
            if tabs.truncated { result["projectTabsTruncated"] = true }
        }
        if projects() != nil { result["recentProjects"] = RecentProjects.shared.urls.prefix(20).map(\.path) }
        if let session = session(), let document = session.document {
            let layers = Self.rows(document.layers.reversed()) { layer in
                var row: [String: Any] = ["id": layer.id.uuidString, "name": Self.clip(layer.name), "visible": layer.isVisible, "opacity": layer.opacity,
                                          "isGroup": layer.isGroup, "parent": layer.parentID?.uuidString ?? NSNull(), "blendMode": layer.blendMode.rawValue,
                                          "hasPixels": layer.asset != nil, "hasMask": layer.mask != nil,
                                          "x": layer.transform.origin.x, "y": layer.transform.origin.y, "width": layer.transform.size.width,
                                          "height": layer.transform.size.height, "rotation": layer.transform.rotation]
                if let mask = layer.mask { row["maskEnabled"] = mask.isEnabled; row["maskLinked"] = mask.isLinked }
                if let adjustment = layer.adjustment { row["adjustment"] = adjustment.kind.rawValue }
                if let effects = layer.effects { row["effects"] = effects.kinds.map(\.rawValue) }
                if let source = layer.maskSourceID { row["clippedTo"] = source.uuidString }
                return row
            }
            var described: [String: Any] = [
                "id": document.id.uuidString, "width": document.width, "height": document.height, "resolution": document.resolution,
                "name": Self.clip(session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"),
                "path": session.projectURL?.path ?? NSNull(), "modified": session.isModified,
                "selectedLayer": session.activeLayerID?.uuidString ?? NSNull(),
                "selectedLayers": session.selectedLayerIDs.map(\.uuidString).sorted().prefix(Self.stateRowLimit).map { $0 },
                "maskTargeted": session.isMaskSelected,
                "canUndo": session.canUndo, "undoName": Self.clip(session.history.undoName),
                "canRedo": session.canRedo, "redoName": Self.clip(session.history.redoName),
                "undoOrigin": session.history.undoOrigin?.rawValue ?? NSNull(), "redoOrigin": session.history.redoOrigin?.rawValue ?? NSNull(),
                "guides": document.guides.count,
                "layers": layers.rows
            ]
            if layers.truncated { described["layersTruncated"] = true }
            if let selection = session.selection {
                let box = selection.isEmpty ? CGRect.zero : selection.path.boundingBoxOfPath
                described["selection"] = ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height, "feather": selection.feather] as [String: Any]
            } else { described["selection"] = NSNull() }
            if let controller = projects(), controller.session === session, let history = controller.lensWorksDocument {
                // Keep the selected version actionable even when the bounded
                // state omits older rows; checkpoint rows share one total budget.
                var shown: [LensWorksPhotoVersion] = []
                if let selected = history.versions.first(where: { $0.id == controller.selectedLensWorksVersionID }) { shown.append(selected) }
                for version in history.versions where version.id != controller.selectedLensWorksVersionID {
                    guard shown.count < Self.stateRowLimit else { break }
                    shown.append(version)
                }
                var remainingCheckpoints = Self.stateRowLimit
                let versions = Self.rows(shown) { version in
                    let checkpoints = Self.rows(version.checkpoints.prefix(remainingCheckpoints)) { ["id": $0.id.uuidString, "name": Self.clip($0.name)] }
                    remainingCheckpoints -= checkpoints.rows.count
                    var row: [String: Any] = ["id": version.id.uuidString, "name": Self.clip(version.name),
                        "selected": controller.selectedLensWorksVersionID == version.id, "checkpoints": checkpoints.rows]
                    if checkpoints.rows.count < version.checkpoints.count { row["checkpointsTruncated"] = true }
                    return row
                }
                described["versions"] = versions.rows
                if shown.count < history.versions.count { described["versionsTruncated"] = true }
            }
            result["document"] = described
        }
        if let catalog = catalog(), let path = catalog.catalogPath {
            func version(_ variant: LWApplicationDtoVariant) -> [String: Any] {
                ["variantId": variant.key.variant_id, "label": Self.clip(variant.label), "revision": variant.revision.value]
            }
            // As for the document: whose recipe change Undo and Redo would step over (null when none, or not recorded).
            func current(_ variant: LWApplicationDtoVariant) -> [String: Any] {
                version(variant).merging(["canUndo": variant.can_undo, "canRedo": variant.can_redo,
                                          "undoOrigin": catalog.recipeHistoryOrigin(redo: false)?.rawValue ?? NSNull(),
                                          "redoOrigin": catalog.recipeHistoryOrigin(redo: true)?.rawValue ?? NSNull()]) { $1 }
            }
            let photos = Self.rows(catalog.assets) { asset in
                ["id": asset.id, "filename": Self.clip(asset.filename), "rating": asset.rating.map { Int($0) } ?? NSNull(), "flag": asset.flag,
                 "label": Self.clip(asset.label), "selected": catalog.selection.contains(asset.id)] as [String: Any]
            }
            let folders = Self.rows(catalog.groups) { ["id": $0.id, "name": Self.clip($0.name)] }
            let sources = Self.rows(catalog.folders) { ["id": String($0.id.value), "name": Self.clip($0.name), "path": Self.clip(LensWorksRelinkPaths.label($0.locator))] }
            let keywords = Self.rows(catalog.keywords) { ["id": Self.clip(LensWorksAgentCatalogCommands.keywordID($0)), "name": Self.clip($0.name), "kind": $0.kind.rawValue] }
            var described: [String: Any] = [
                "path": path, "busy": catalog.isBusy, "importing": catalog.isImporting,
                "selectedPhoto": catalog.selectedPhotoID ?? NSNull(), "selectionCount": catalog.selectionCount,
                "rating": catalog.selectedAsset?.rating.map { Int($0) } ?? NSNull(),
                "currentVersion": catalog.currentCatalogVariant.map(current) ?? NSNull(),
                "copies": catalog.catalogVariants.prefix(Self.stateRowLimit).map(version),
                "copiesCursor": catalog.catalogVariantsNext?.value ?? NSNull(),
                "photos": photos.rows, "hasMorePhotos": catalog.hasMore,
                "folders": sources.rows, "virtualFolders": folders.rows, "keywords": keywords.rows,
                "keywordParent": catalog.keywordParent.map { Self.clip(LensWorksAgentCatalogCommands.keywordID($0)) } ?? NSNull(),
                "filters": catalog.filterSummary.prefix(16).map(Self.clip),
                "sort": catalog.browseOptions.sort.rawValue, "sortDirection": catalog.browseOptions.direction.rawValue
            ]
            if photos.truncated { described["photosTruncated"] = true }
            if folders.truncated { described["virtualFoldersTruncated"] = true }
            if sources.truncated { described["foldersTruncated"] = true }
            if keywords.truncated { described["keywordsTruncated"] = true }
            result["catalog"] = described
        }
        return result
    }

    // MARK: Invocation

    /// One command an agent asked for, with its arguments checked against the registry.
    struct Call {
        let admission: LensWorksAgentAdmission
        var id: LensWorksCommandID { admission.id }
        var arguments: LensWorksAgentArguments { admission.arguments }
        var kind: LensWorksAgentCommandKind { LensWorksAgentTools.kind(id) ?? .standalone }
        var isDocument: Bool { kind == .document }
    }

    /// Checks one `{command, arguments}` request: a registered command an agent may run, only arguments its
    /// parameters declare, each of the declared shape, and every path inside a granted folder.
    func parse(_ request: [String: Any]) throws -> Call {
        try Self.rejectUnknown(request, allowed: ["command", "arguments"], in: "a command")
        guard let raw = request["command"] as? String, let id = LensWorksCommandID(rawValue: raw) else {
            throw LensWorksCommandRefusal(reason: "Name a command id from list_commands.")
        }
        let descriptor = LensWorksCommandRegistry.descriptor(id)
        guard descriptor.agent.isRunnable else {
            throw LensWorksCommandRefusal(reason: "Agents cannot run \(id.rawValue). " + (descriptor.agent.exclusion?.rawValue ?? ""))
        }
        let values: [String: Any]
        switch request["arguments"] {
        case nil, is NSNull: values = [:]
        case let given as [String: Any]: values = given
        default: throw LensWorksCommandRefusal(reason: "arguments must be an object.")
        }
        var arguments = try LensWorksAgentArguments.check(values, for: descriptor)
        for parameter in descriptor.parameters where parameter.type.namesPath {
            guard let named = try arguments.strings(parameter.name) else { continue }
            guard !named.isEmpty else { throw LensWorksCommandRefusal(reason: "\(parameter.name) must name at least one path.") }
            arguments.paths[parameter.name] = try named.map(folders.admit)
        }
        return Call(admission: .init(id: id, arguments: arguments))
    }

    func invoke(_ arguments: [String: Any], caller: LensWorksAutomationCaller = .inProcess) async throws -> [String: Any] {
        let call = try parse(arguments)
        let label = LensWorksCommandRegistry.descriptor(call.id).label
        switch call.kind {
        case .document:
            guard let session = session() else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
            if Self.layerCommands.contains(call.id) {
                let command = try layerCommand(call)
                let changed = try session.dispatchCommand(session.admitCommand(command, origin: .agent))
                return ["command": call.id.rawValue, "changed": changed, "history": changed ? session.history.undoName : NSNull(),
                        "message": changed ? "\(session.history.undoName) is in LensWorks history; Undo in the app reverts it." : "Nothing changed."]
            }
            if session.document == nil, call.id != .importImages { throw LensWorksCommandRefusal(reason: "Open a document first.") }
            let revision = session.history.currentRevision
            let context = context
            try await session.agentTransaction(label, adoptingNestedName: true, requiresDocument: call.id != .importImages) {
                try await LensWorksCommandDispatcher.dispatch(call.admission, in: session, context: context)
            }
            let changed = session.history.currentRevision != revision
            let transient = call.id.reversal == .transient
            return ["command": call.id.rawValue, "changed": changed || transient, "history": changed ? session.history.undoName : NSNull(),
                    "message": changed ? "\(session.history.undoName) is in LensWorks history; Undo in the app reverts it."
                        : transient ? "\(label) ran (Agent)." : "Nothing changed."]
        case .standalone where Self.historyCommands.contains(call.id):
            guard let session = session() else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
            let redo = call.id == .redo
            let name = try LensWorksCommandDispatcher.dispatchHistory(redo: redo, origin: .agent, in: session)
            return ["command": call.id.rawValue, "changed": true, "history": name, "message": (redo ? "Redid " : "Undid ") + (name.isEmpty ? "the last edit." : "“\(name)”.")]
        case .standalone:
            let commands = LensWorksAgentProjectCommands(context: context)
            if let reason = commands.availability(call.id) { throw LensWorksCommandRefusal(reason: reason) }
            if let session = session(), session.document != nil, let reason = session.agentModalReason { throw LensWorksCommandRefusal(reason: reason) }
            try commands.validate(call.admission)
            let approved = try await confirm([call], caller: caller)
            try admitReplacement(call, approved: approved.indexes.contains(0))
            var context = context
            context.discardsCatalogHistory = approved.indexes.contains(0)
            let message = try await LensWorksCommandDispatcher.dispatchStandalone(call.admission, context: context)
            return ["command": call.id.rawValue, "changed": true, "message": message + (approved.indexes.isEmpty ? "" : " The person allowed it.")]
        case .catalog:
            try admitCatalog([call])
            let approved = try await confirm([call], caller: caller)
            try await run(call, index: 0, approved: approved)
            return ["command": call.id.rawValue, "changed": true, "message": label + (approved.indexes.isEmpty ? " ran (Agent)." : " ran (Agent) after the person allowed it.")]
        }
    }
    /// The catalog commands that change the keyword dictionary, the virtual folders, or which photos hold them.
    static let catalogStructureCommands: Set<LensWorksCommandID> = [
        .renameKeyword, .moveKeyword, .addSynonym, .deleteKeyword, .addKeyword, .removeKeyword,
        .renameVirtualFolder, .moveVirtualFolder, .deleteVirtualFolder, .addToVirtualFolder, .removeFromVirtualFolder]
    /// History steps: never part of a batch.
    static let historyCommands: Set<LensWorksCommandID> = [.undo, .redo]

    private func layerIDs(_ arguments: LensWorksAgentArguments, key: String, session: EditorSession) throws -> [UUID] {
        guard let given = try arguments.uuids(key) else {
            guard let active = session.activeLayerID else { throw LensWorksCommandRefusal(reason: "Select a layer first, or pass layer ids from get_state.") }
            return [active]
        }
        guard !given.isEmpty else { throw LensWorksCommandRefusal(reason: "\(key) must list layer ids from get_state.") }
        return given
    }

    /// The typed S38 layer command for `call`, against the selection as it stands.
    private func layerCommand(_ call: Call) throws -> LensWorksLayerCommand {
        guard let session = session(), session.document != nil else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        let arguments = call.arguments
        switch call.id {
        case .visibility: return .visibility(try layerIDs(arguments, key: "layers", session: session), try arguments.bool("visible"))
        case .opacity: return .opacity(try layerIDs(arguments, key: "layers", session: session), try arguments.required("opacity", try arguments.double("opacity")))
        default: return .rename(try layerIDs(arguments, key: "layer", session: session).first!, try arguments.required("name", try arguments.string("name")))
        }
    }

    /// The typed catalog action for `id` against the catalog version as it stands.
    private func catalogAction(_ id: LensWorksCommandID, _ arguments: LensWorksAgentArguments, checkingExpected: Bool) throws -> (catalog: LensWorksCatalog, action: LensWorksCatalogControlAction, current: LWApplicationDtoVariant) {
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        guard let current = catalog.currentCatalogVariant else { throw LensWorksCommandRefusal(reason: "Select a catalog photo first.") }
        if checkingExpected, let expected = try arguments.object("expected") {
            let variant = expected["variantId"] as? String, revision = (expected["revision"] as? NSNumber)?.int64Value
            guard variant == nil || variant == current.key.variant_id, revision == nil || revision == current.revision.value else {
                throw LensWorksCommandRefusal(reason: "The catalog version changed since get_state; read it again.")
            }
        }
        let action: LensWorksCatalogControlAction
        switch id {
        case .firstVariants: action = .firstVariants
        case .moreVariants:
            let cursor = try arguments.integer("cursor").map { LWCatalogI64(Int64($0)) } ?? catalog.catalogVariantsNext
            guard let cursor else { throw LensWorksCommandRefusal(reason: "There are no more catalog copies.") }
            action = .moreVariants(cursor)
        case .selectVariant:
            guard let wanted = try arguments.string("variant"), let copy = catalog.catalogVariants.first(where: { $0.key.variant_id == wanted }) else {
                throw LensWorksCommandRefusal(reason: "variant must be a variantId from get_state's catalog copies.")
            }
            action = .selectVariant(copy)
        case .copy: action = .recipe(.copy(try arguments.required("label", try arguments.string("label"))))
        case .exposure: action = .recipe(.exposure(Float(try arguments.required("exposureEV", try arguments.double("exposureEV")))))
        case .undoRecipe: action = .recipe(.undo)
        case .redoRecipe: action = .recipe(.redo)
        default: action = .rating(UInt8(clamping: try arguments.required("rating", try arguments.integer("rating"))))
        }
        return (catalog, action, current)
    }

    /// Admits every catalog call against the catalog as it stands, without running any. Throws naming the call.
    private func admitCatalog(_ calls: [Call]) throws {
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        var deleted = Set<String>()
        let commands = LensWorksAgentCatalogCommands(catalog: catalog, context: context)
        for (index, call) in calls.enumerated() {
            do {
                switch call.id {
                case _ where Self.controlCommands.contains(call.id):
                    let prepared = try catalogAction(call.id, call.arguments, checkingExpected: true)
                    _ = try catalog.admitCommand(prepared.action, expected: prepared.current, origin: .agent)
                case .deleteVirtualFolder:
                    let folder = try call.arguments.required("folder", try call.arguments.string("folder"))
                    guard deleted.insert("folder " + folder).inserted else { throw LensWorksCommandRefusal(reason: "The same virtual folder is deleted twice.") }
                    _ = try catalog.admitFolderDelete(folder, origin: .agent)
                case _ where call.kind == .catalog:
                    if call.id == .deleteKeyword, let keyword = try call.arguments.string("keyword") {
                        guard deleted.insert("keyword " + keyword).inserted else { throw LensWorksCommandRefusal(reason: "The same keyword is deleted twice.") }
                    }
                    if let reason = commands.availability(call.admission) { throw LensWorksCommandRefusal(reason: reason) }
                default: throw LensWorksCommandRefusal(reason: "This is not a catalog command.")
                }
            } catch { throw Self.naming(index, of: calls, error) }
        }
    }

    private static func naming(_ index: Int, of calls: [Call], _ error: Error) -> LensWorksCommandRefusal {
        let reason = error is CancellationError ? "The catalog, photo, version or revision is no longer current." : String(error.localizedDescription.prefix(messageLimit))
        return .init(reason: calls.count == 1 ? reason : "Command \(index + 1) (\(calls[index].id.rawValue)): \(reason)")
    }

    /// What the person approved, by index, each with the check that what they saw is still what would run. The check
    /// runs once when they answer and again immediately before its command is dispatched.
    struct Approval {
        var indexes: Set<Int> = []
        var rechecks: [Int: () throws -> LensWorksCatalogDeleteAdmission?] = [:]
    }
    /// One change waiting on the person: the row the sheet shows, and a check that what they saw is still what runs.
    private struct Pending {
        let index: Int
        let item: LensWorksAgentConfirmation.Item
        let recheck: () throws -> LensWorksCatalogDeleteAdmission?
    }

    /// The confirmation `call` needs before it runs, or nil: the registry's rule decides, never the agent.
    private func pending(_ call: Call, index: Int) throws -> Pending? {
        let descriptor = LensWorksCommandRegistry.descriptor(call.id)
        let label = descriptor.label
        switch descriptor.agentConfirmation {
        case .never: return nil
        case .whenReplacingFile:
            guard let url = try LensWorksAgentProjectCommands(context: context).destination(call.admission), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Pending(index: index, item: .init(action: "Replace with " + label.replacingOccurrences(of: "…", with: ""), name: url.path)) { nil }
        case .whenDiscardingCatalogHistory:
            guard let catalog = catalog(), let path = catalog.catalogPath else { return nil }
            let steps = catalog.organizationUndo.count + catalog.organizationRedo.count
            guard steps > 0 else { return nil }
            return Pending(index: index, item: .init(action: "Discard \(steps) organize change\(steps == 1 ? "" : "s") from Undo to " + label.replacingOccurrences(of: "…", with: ""), name: path)) { [weak self] in
                guard let catalog = self?.catalog(), catalog.catalogPath == path, catalog.organizationUndo.count + catalog.organizationRedo.count == steps else {
                    throw LensWorksCommandRefusal(reason: "The catalog changed while waiting for confirmation: nothing was opened.")
                }
                return nil
            }
        case .always:
            switch call.id {
            case .deleteVirtualFolder:
                guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
                let admission = try catalog.admitFolderDelete(try call.arguments.required("folder", try call.arguments.string("folder")), origin: .agent)
                return Pending(index: index, item: .init(action: label, name: admission.folder.name)) { [weak self] in
                    // The catalog may have changed while the sheet was open: re-admit exactly what the person approved.
                    guard let catalog = self?.catalog(), let current = try? catalog.admitFolderDelete(admission.folder.id, origin: .agent),
                          current.folder.revision == admission.folder.revision, current.folder.name == admission.folder.name else {
                        throw LensWorksCommandRefusal(reason: "A virtual folder changed while waiting for confirmation: nothing was run or deleted.")
                    }
                    return current
                }
            case .deleteKeyword:
                guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
                let commands = LensWorksAgentCatalogCommands(catalog: catalog, context: context)
                let keyword = try commands.keyword(call.arguments)
                return Pending(index: index, item: .init(action: label, name: keyword.path.joined(separator: " > "))) { [weak self] in
                    guard let catalog = self?.catalog(),
                          let current = try? LensWorksAgentCatalogCommands(catalog: catalog, context: commands.context).keyword(call.arguments),
                          current.id.value == keyword.id.value, current.path == keyword.path else {
                        throw LensWorksCommandRefusal(reason: "A keyword changed while waiting for confirmation: nothing was run or deleted.")
                    }
                    return nil
                }
            case .locateFolder:
                guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
                let from = try LensWorksAgentProjectCommands.movedFolder(catalog, call.arguments).label, to = try call.arguments.url("path").path
                return Pending(index: index, item: .init(action: label.replacingOccurrences(of: "…", with: ""), name: String(from.suffix(96)) + " → " + to)) { [weak self] in
                    guard let catalog = self?.catalog(), (try? LensWorksAgentProjectCommands.movedFolder(catalog, call.arguments).label) == from else {
                        throw LensWorksCommandRefusal(reason: "The catalog folder changed while waiting for confirmation: nothing was relinked.")
                    }
                    return nil
                }
            case .save:
                guard let url = try LensWorksAgentProjectCommands(context: context).destination(call.admission) else {
                    throw LensWorksCommandRefusal(reason: "This project has no file yet: use file.saveAs with a path.")
                }
                let revision = session()?.history.currentRevision
                return Pending(index: index, item: .init(action: "Save over", name: url.path)) { [weak self] in
                    guard self?.session()?.projectURL.flatMap({ try? LensWorksGrantedFolders.realPath($0.path) }) == url.path, self?.session()?.history.currentRevision == revision else {
                        throw LensWorksCommandRefusal(reason: "The project changed while waiting for confirmation: nothing was saved.")
                    }
                    return nil
                }
            default:
                // A command the registry marks permanent with no way to show the person what it would change never runs.
                throw LensWorksCommandRefusal(reason: "\(call.id.rawValue) needs the person’s confirmation, which agents cannot ask for.")
            }
        }
    }

    /// Asks the person once for every call the registry puts a confirmation in front of, naming each from the app's
    /// own rows and the resolved file it would replace. Returns what the person approved, re-checked after the
    /// answer; nothing but Allow returns.
    private func confirm(_ calls: [Call], caller: LensWorksAutomationCaller) async throws -> Approval {
        var asked: [Pending] = []
        for (index, call) in calls.enumerated() { if let pending = try pending(call, index: index) { asked.append(pending) } }
        guard !asked.isEmpty else { return Approval() }
        guard let automation else { throw LensWorksCommandRefusal(reason: "LensWorks automation is off.") }
        let answer = await automation.confirm(.init(
            title: asked.count == 1 ? "Allow an AI agent to make a permanent change?" : "Allow an AI agent to make \(asked.count) permanent changes?",
            message: "An agent connected over automation asked for this. It cannot be undone.", items: asked.map(\.item)), owner: caller.connection)
        switch answer {
        case .allowed: break
        case .declined: throw LensWorksCommandRefusal(reason: "The person declined in LensWorks: nothing was run or deleted.")
        case .busy: throw LensWorksCommandRefusal(reason: "LensWorks is already asking the person to confirm another agent request: nothing was run or deleted.")
        case .unanswered: throw LensWorksCommandRefusal(reason: "The person did not answer the confirmation in LensWorks (it timed out, the client disconnected, or automation was turned off or its secret changed): nothing was run or deleted.")
        }
        guard caller.isCurrent() else { throw LensWorksCommandRefusal(reason: "The automation connection or its secret changed while waiting for confirmation: nothing was run or deleted.") }
        var approval = Approval()
        for pending in asked {
            _ = try pending.recheck()
            approval.indexes.insert(pending.index); approval.rechecks[pending.index] = pending.recheck
        }
        return approval
    }

    /// Refuses a file command that would replace a file the person was not asked about (one that appeared after the
    /// check, or a rule that was never satisfied).
    private func admitReplacement(_ call: Call, approved: Bool) throws {
        // The person may have taken a grant back, or a folder on the way may have become a link, while the sheet was
        // open: every path is admitted again from the words the agent sent and must reach the same file.
        for parameter in LensWorksCommandRegistry.descriptor(call.id).parameters where parameter.type.namesPath {
            guard let named = try call.arguments.strings(parameter.name) else { continue }
            guard try named.map(folders.admit) == call.arguments.paths[parameter.name] else {
                throw LensWorksCommandRefusal(reason: "\(parameter.name) no longer reaches the file it did when the request was checked: nothing was read or written.")
            }
        }
        let rule = LensWorksCommandRegistry.descriptor(call.id).agentConfirmation
        guard rule != .never, !approved else { return }
        if rule == .always { throw LensWorksCommandRefusal(reason: "The person has not confirmed \(call.id.rawValue).") }
        // Opening another catalog: the command itself refuses when there is organize history and no approval.
        if rule == .whenDiscardingCatalogHistory { return }
        if let url = try LensWorksAgentProjectCommands(context: context).destination(call.admission), FileManager.default.fileExists(atPath: url.path) {
            throw LensWorksCommandRefusal(reason: "A file appeared at that path, and the person has not confirmed replacing it: nothing was written.")
        }
    }

    /// Runs one admitted catalog call. A call that needs confirmation runs only from what the person approved.
    private func run(_ call: Call, index: Int, approved: Approval) async throws {
        guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        if Self.requiresConfirmation(call.id), !approved.indexes.contains(index) { throw LensWorksCommandRefusal(reason: "The person has not confirmed \(call.id.rawValue).") }
        // Checked again here, with nothing between the check and the dispatch: an earlier member of the batch, or
        // the person, may have changed what the approved name stands for since they answered.
        let rechecked = try approved.rechecks[index]?()
        switch call.id {
        case _ where Self.controlCommands.contains(call.id):
            let prepared = try catalogAction(call.id, call.arguments, checkingExpected: false)
            try await catalog.dispatchCommand(catalog.admitCommand(prepared.action, expected: prepared.current, origin: .agent))
        case .deleteVirtualFolder:
            guard let folder = rechecked else { throw LensWorksCommandRefusal(reason: "The person has not confirmed this delete.") }
            try await LensWorksCommandDispatcher.dispatch(folder, in: catalog)
        case _ where call.kind == .catalog:
            try await LensWorksCommandDispatcher.dispatch(call.admission, in: catalog, context: context)
        default: throw LensWorksCommandRefusal(reason: "This is not a catalog command.")
        }
    }

    // MARK: Batch

    /// Runs several commands as one step. Every member's arguments are checked before any runs. Document members
    /// share one agent history entry and roll back together; catalog members are admitted against the catalog as it
    /// stands, run in order and stop at the first failure. Throws when nothing ran; `completed` is false when a
    /// catalog batch stopped part-way.
    func batch(_ arguments: [String: Any], caller: LensWorksAutomationCaller = .inProcess) async throws -> (value: [String: Any], completed: Bool) {
        let unrun = " Nothing was run."
        try Self.rejectUnknown(arguments, allowed: ["commands"], in: "batch")
        guard let members = arguments["commands"] as? [[String: Any]], !members.isEmpty else {
            throw LensWorksCommandRefusal(reason: "commands must list at least one {command, arguments} object.")
        }
        guard members.count <= Self.batchLimit else {
            throw LensWorksCommandRefusal(reason: "A batch carries at most \(Self.batchLimit) commands; this one has \(members.count)." + unrun)
        }
        var calls: [Call] = []
        for (index, member) in members.enumerated() {
            do {
                let call = try parse(member)
                if Self.historyCommands.contains(call.id) { throw LensWorksCommandRefusal(reason: "edit.undo and edit.redo cannot be part of a batch; run them with invoke_command.") }
                if call.kind == .standalone { throw LensWorksCommandRefusal(reason: "\(call.id.rawValue) cannot be part of a batch (it opens, saves or switches projects or the catalog); run it with invoke_command.") }
                calls.append(call)
            } catch { throw LensWorksCommandRefusal(reason: "Command \(index + 1): " + String(error.localizedDescription.prefix(Self.messageLimit)) + unrun) }
        }
        let documents = calls.filter(\.isDocument).count
        guard documents == 0 || documents == calls.count else {
            throw LensWorksCommandRefusal(reason: "A batch cannot mix document commands with catalog commands: the catalog cannot roll back with the document. Send them as two batches." + unrun)
        }
        // Never under the person's open interaction, whichever kind of batch this is.
        if let session = session(), session.document != nil, let reason = session.agentModalReason { throw LensWorksCommandRefusal(reason: reason + unrun) }
        guard caller.isCurrent() else { throw LensWorksCommandRefusal(reason: "The automation connection or its secret changed." + unrun) }
        return documents > 0 ? (try await documentBatch(calls, caller: caller), true) : try await catalogBatch(calls, caller: caller)
    }

    private func documentBatch(_ calls: [Call], caller: LensWorksAutomationCaller) async throws -> [String: Any] {
        guard let session = session(), session.document != nil else { throw LensWorksCommandRefusal(reason: "Open a document first. Nothing was run.") }
        // A batch of typed layer commands is admitted whole against the document as it stands. Other members depend
        // on the members before them (a new layer, a selection), so each is admitted at its turn; a refusal there
        // rolls the whole batch back, which leaves the document exactly as an up-front refusal would.
        if calls.allSatisfy({ Self.layerCommands.contains($0.id) }) {
            for (index, call) in calls.enumerated() {
                do { _ = try session.admitCommand(try layerCommand(call), origin: .agent) }
                catch { throw LensWorksCommandRefusal(reason: Self.naming(index, of: calls, error).reason + " Nothing was run.") }
            }
        }
        for (index, call) in calls.enumerated() where Self.requiresConfirmation(call.id) {
            throw LensWorksCommandRefusal(reason: Self.naming(index, of: calls, LensWorksCommandRefusal(reason: "It needs the person’s confirmation and runs on its own with invoke_command.")).reason + " Nothing was run.")
        }
        let revision = session.history.currentRevision
        var results: [[String: Any]] = []
        let context = context
        do {
            try await session.agentTransaction(calls.count == 1 ? "1 Document Command" : "\(calls.count) Document Commands", adoptingNestedName: false) {
                for (index, call) in calls.enumerated() {
                    guard caller.isCurrent() else { throw LensWorksCommandRefusal(reason: "The automation connection or its secret changed before command \(index + 1).") }
                    do {
                        let before = session.document
                        if Self.layerCommands.contains(call.id) { try session.dispatchCommand(session.admitCommand(try layerCommand(call), origin: .agent)) }
                        else { try await LensWorksCommandDispatcher.dispatch(call.admission, in: session, context: context) }
                        results.append(["index": index + 1, "command": call.id.rawValue, "status": "ran", "changed": session.document != before])
                    } catch { throw Self.naming(index, of: calls, error) }
                }
            }
        } catch { throw LensWorksCommandRefusal(reason: error.localizedDescription + " The whole batch was rolled back: the document, its history, the selection and the palette colors are as they were (anything a cut or copy put on the clipboard stays there).") }
        let changed = session.history.currentRevision != revision
        return ["kind": "document", "completed": true, "changed": changed, "history": changed ? session.history.undoName : NSNull(), "results": results,
                "message": changed ? "\(session.history.undoName) is one entry in LensWorks history; one Undo in the app reverts the whole batch." : "Nothing changed."]
    }

    private func catalogBatch(_ calls: [Call], caller: LensWorksAutomationCaller) async throws -> (value: [String: Any], completed: Bool) {
        let unrun = " Nothing was run."
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first." + unrun) }
        guard !catalog.isBusy else { throw LensWorksCommandRefusal(reason: "Finish the current catalog operation first." + unrun) }
        // One answer covers a name, not what another member turns that name into: a member that needs the person
        // rides only with others the person is asked about too, never with an unasked change to keywords or virtual
        // folders.
        if let index = calls.firstIndex(where: { Self.requiresConfirmation($0.id) }),
           calls.contains(where: { Self.catalogStructureCommands.contains($0.id) && !Self.requiresConfirmation($0.id) }) {
            throw LensWorksCommandRefusal(reason: Self.naming(index, of: calls, LensWorksCommandRefusal(reason: "It needs the person’s confirmation, so it cannot share a batch with another command that changes keywords or virtual folders; run it with invoke_command.")).reason + unrun)
        }
        do { try admitCatalog(calls) } catch { throw LensWorksCommandRefusal(reason: error.localizedDescription + unrun) }
        let approved = try await confirm(calls, caller: caller)
        var results: [[String: Any]] = [], stopped: String?
        for (index, call) in calls.enumerated() {
            var row: [String: Any] = ["index": index + 1, "command": call.id.rawValue]
            if stopped != nil { row["status"] = "notRun" }
            else if !caller.isCurrent() {
                stopped = "The automation connection or its secret changed before command \(index + 1)."
                row["status"] = "notRun"
            } else {
                do { try await run(call, index: index, approved: approved); row["status"] = "ran" }
                catch {
                    let reason = Self.naming(index, of: calls, error).reason
                    stopped = reason; row["status"] = "failed"; row["message"] = reason
                }
            }
            results.append(row)
        }
        let ran = results.filter { $0["status"] as? String == "ran" }.count
        return (["kind": "catalog", "completed": stopped == nil, "changed": ran > 0, "results": results,
                 "message": stopped.map { "\($0) \(ran) of \(calls.count) catalog commands ran (Agent) and stay in place: the catalog cannot roll a batch back." }
                    ?? "\(ran) catalog commands ran (Agent)."], stopped == nil)
    }

    // MARK: Preview

    func preview(_ arguments: [String: Any]) async throws -> [String: Any] {
        try Self.rejectUnknown(arguments, allowed: ["maxDimension"], in: "render_preview")
        let requested = (arguments["maxDimension"] as? NSNumber)?.intValue ?? Self.previewDefault
        guard (Self.previewMinimum...Self.previewMaximum).contains(requested) else {
            throw LensWorksCommandRefusal(reason: "maxDimension must be from \(Self.previewMinimum) through \(Self.previewMaximum).")
        }
        guard let session = session(), let document = session.document, let snapshot = session.projectSnapshot() else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        let raster = try await ImageExporter.shared.render(snapshot)
        let png = try Self.boundedPNG(raster.image, maxDimension: requested)
        return ["content": [
            ["type": "image", "data": png.data.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": "Preview \(png.width)×\(png.height) of a \(document.width)×\(document.height) document."]
        ], "isError": false]
    }

    nonisolated static func boundedPNG(_ image: CGImage, maxDimension: Int) throws -> (data: Data, width: Int, height: Int) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ExportError.render }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return (data as Data, width, height)
    }

    // MARK: Encoding

    /// A structured reply, refused when it is larger than `replyLimit`: no reply grows without bound.
    static func bounded(_ value: [String: Any], isError: Bool = false, hint: String = "") throws -> [String: Any] {
        let reply = structured(value, isError: isError)
        let size = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String)?.utf8.count ?? 0
        guard size <= replyLimit else { throw LensWorksCommandRefusal(reason: "The reply would be \(size) bytes, over the \(replyLimit)-byte limit." + hint) }
        return reply
    }
    static func structured(_ value: [String: Any], isError: Bool = false) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": isError]
    }
    nonisolated static func encodeResult(id: Any?, _ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id ?? NSNull(), "result": result])) ?? encodeError(id: id, code: -32603, "The result could not be encoded.")
    }
    nonisolated static func encodeError(id: Any?, code: Int, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? Data("{}".utf8)
    }
}
