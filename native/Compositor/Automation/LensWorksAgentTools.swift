import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The MCP tools an agent sees. Commands come from the registry and run through LensWorksCommandDispatcher with an
/// agent origin, so they share admission, availability reasons and history with the menus that run them.
final class LensWorksAgentTools {
    let session: () -> EditorSession?
    let catalog: () -> LensWorksCatalog?
    weak var automation: LensWorksAutomation?
    init(session: @escaping () -> EditorSession?, catalog: @escaping () -> LensWorksCatalog?) {
        self.session = session; self.catalog = catalog
    }

    /// Commands with a typed admission an agent can supply arguments for. The rest of the registry is listed with the
    /// reason an agent cannot run it.
    static let agentCommands: [LensWorksCommandID] = [
        .visibility, .opacity, .rename, .undo, .redo,
        .firstVariants, .moreVariants, .selectVariant, .copy, .exposure, .undoRecipe, .redoRecipe, .rating,
        .deleteVirtualFolder
    ]
    /// Document edits: they share one history transaction in a batch.
    static let documentCommands: Set<LensWorksCommandID> = [.visibility, .opacity, .rename]
    /// History steps: never part of a batch.
    static let historyCommands: Set<LensWorksCommandID> = [.undo, .redo]
    /// Permanent changes (the registry says which): the person confirms them in the app before they run.
    static func requiresConfirmation(_ id: LensWorksCommandID) -> Bool { LensWorksCommandRegistry.descriptor(id).requiresAgentConfirmation }
    static func batchable(_ id: LensWorksCommandID) -> Bool { agentCommands.contains(id) && !historyCommands.contains(id) }
    static let previewDefault = 1024, previewMinimum = 64, previewMaximum = 2048
    /// The most commands one batch may carry.
    static let batchLimit = 64
    /// The longest per-command message in a reply.
    static let messageLimit = 512

    static let toolNames: Set<String> = ["list_commands", "get_state", "invoke_command", "batch", "render_preview"]
    static var definitions: [[String: Any]] {
        let empty: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        let member: [String: Any] = ["type": "object", "required": ["command"], "additionalProperties": false, "properties": [
            "command": ["type": "string", "enum": agentCommands.filter(batchable).map(\.rawValue), "description": "A command id from list_commands."],
            "arguments": ["type": "object", "description": "Arguments matching that command's inputSchema from list_commands."]]]
        return [
            ["name": "list_commands", "title": "List LensWorks commands",
             "description": "Every registered LensWorks command: id, title, menu, whether an agent can run it now (with the reason when not), whether it can be part of a batch, whether it asks the person to confirm, and the JSON schema of its arguments for invoke_command and batch.",
             "inputSchema": empty, "annotations": ["readOnlyHint": true]],
            ["name": "get_state", "title": "Describe the open document and catalog",
             "description": "The open document (size, layers with id, name, visibility and opacity, the selected layer, and who made the edits Undo and Redo would step over) and the open catalog (selected photo, its current catalog version and copies, and the virtual folders on the current page).",
             "inputSchema": empty, "annotations": ["readOnlyHint": true]],
            ["name": "invoke_command", "title": "Run a LensWorks command",
             "description": "Runs one registered command as the agent. Document edits enter LensWorks history labeled “(Agent)”, so Undo in the app reverts them. edit.undo and edit.redo step only over the agent's own edits. Permanent deletes wait for the person to confirm in LensWorks and return a refusal when they decline. Unknown argument names are refused.",
             "inputSchema": ["type": "object", "required": ["command"], "additionalProperties": false, "properties": [
                "command": ["type": "string", "enum": agentCommands.map(\.rawValue), "description": "A command id from list_commands."],
                "arguments": ["type": "object", "description": "Arguments matching that command's inputSchema from list_commands."]]]],
            ["name": "batch", "title": "Run several LensWorks commands as one step",
             "description": "Runs up to \(batchLimit) commands in order. Every command is checked against the app as it stands before any runs; one that cannot run refuses the whole batch. A batch is either all document commands (one “(Agent)” history entry that one Undo reverts; any failure rolls the whole batch back) or all catalog commands (run in order and stopped at the first failure; the catalog cannot roll back, so the two kinds never mix). Permanent deletes are confirmed by the person once, for the whole batch, before anything runs. edit.undo and edit.redo are not allowed in a batch. The reply lists a result per command.",
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
                try Self.rejectUnknown(arguments, allowed: [], in: name)
                return Self.structured(["commands": listCommands()])
            case "get_state":
                try Self.rejectUnknown(arguments, allowed: [], in: name)
                return Self.structured(state())
            case "invoke_command": return Self.structured(try await invoke(arguments, caller: caller))
            case "batch":
                let outcome = try await batch(arguments, caller: caller)
                return Self.structured(outcome.value, isError: !outcome.completed)
            default: return try await preview(arguments)
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    /// Refuses argument names the tool or command does not declare: a misspelled name must never silently change
    /// what a command does.
    static func rejectUnknown(_ values: [String: Any], allowed: [String], in what: String) throws {
        guard let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) else { return }
        throw LensWorksCommandRefusal(reason: "Unknown argument “\(unknown.prefix(64))” for \(what). " + (allowed.isEmpty ? "It takes no arguments." : "Its arguments are: " + allowed.sorted().joined(separator: ", ") + "."))
    }

    // MARK: Listing

    func listCommands() -> [[String: Any]] {
        LensWorksCommandRegistry.descriptors.map { descriptor in
            let reason = agentAvailability(descriptor.id)
            var row: [String: Any] = [
                "id": descriptor.id.rawValue, "title": descriptor.label, "menu": descriptor.menu,
                "undoable": descriptor.undoable, "history": descriptor.historyOwner.rawValue,
                "agentInvocable": Self.agentCommands.contains(descriptor.id),
                "batchable": Self.batchable(descriptor.id),
                "requiresConfirmation": descriptor.requiresAgentConfirmation,
                "available": reason == nil,
                "parameters": descriptor.parameters.map { ["name": $0.name, "type": $0.type.rawValue, "description": $0.description] },
                "inputSchema": Self.inputSchema(descriptor.id)
            ]
            if let reason { row["reason"] = reason } else if let note = agentNote(descriptor.id) { row["note"] = note }
            return row
        }
    }

    /// The layer a listed layer command is checked against: the selected one, else any layer, since an agent may
    /// name layers by id without a selection.
    private func listedLayer(_ session: EditorSession) -> ImageLayer? { session.activeLayer ?? session.document?.layers.last }

    /// Why an agent cannot run `id` now (with its default arguments, or with ids it may pass), or nil when it can.
    func agentAvailability(_ id: LensWorksCommandID) -> String? {
        guard Self.agentCommands.contains(id) else {
            return id.rawValue.hasPrefix("automation.") ? "Automation settings and confirmations are never available to agents."
                : "Agents cannot run this command: it runs only from its menu, shortcut or panel."
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
        default:
            guard let catalog = catalog(), catalog.catalogPath != nil else { return "Open a catalog first." }
            guard let current = catalog.currentCatalogVariant else { return "Select a catalog photo first." }
            if id == .moreVariants && catalog.catalogVariantsNext == nil { return "There are no more catalog copies." }
            return catalog.catalogCommandAvailability(defaultAction(id, catalog: catalog, current: current), expected: current)
        }
    }

    /// What an agent must pass for an available command to run as listed.
    func agentNote(_ id: LensWorksCommandID) -> String? {
        switch id {
        case .visibility, .opacity, .rename:
            session()?.activeLayerID == nil ? "No layer is selected: pass layer ids from get_state." : nil
        case .deleteVirtualFolder: "Pass a virtual folder id from get_state."
        default: nil
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
    static func inputSchema(_ id: LensWorksCommandID) -> [String: Any] {
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let expected: [String: Any] = ["type": "object", "description": "Optional guard: the catalog version (variantId and revision from get_state) this command was decided against; refused when it changed.",
                                       "properties": ["variantId": ["type": "string"], "revision": ["type": "integer"]], "additionalProperties": false]
        var properties: [String: Any] = [:], required: [String] = []
        switch id {
        case .visibility:
            properties = ["layers": ["type": "array", "items": uuid, "description": "Layer ids from get_state; defaults to the selected layer."],
                          "visible": ["type": ["boolean", "null"], "description": "true shows, false hides; omitted or null toggles each layer."]]
        case .opacity:
            properties = ["layers": ["type": "array", "items": uuid, "description": "Layer ids from get_state; defaults to the selected layer."],
                          "opacity": ["type": "number", "minimum": 0, "maximum": 1]]
            required = ["opacity"]
        case .rename:
            properties = ["layer": uuid.merging(["description": "Defaults to the selected layer."]) { $1 }, "name": ["type": "string", "minLength": 1]]
            required = ["name"]
        case .firstVariants, .undoRecipe, .redoRecipe: properties = ["expected": expected]
        case .moreVariants: properties = ["expected": expected, "cursor": ["type": "integer", "description": "Defaults to the current page's continuation."]]
        case .selectVariant: properties = ["expected": expected, "variant": ["type": "string", "description": "variantId of a catalog copy from get_state."]]; required = ["variant"]
        case .copy: properties = ["expected": expected, "label": ["type": "string", "minLength": 1, "maxLength": 1024]]; required = ["label"]
        case .exposure: properties = ["expected": expected, "exposureEV": ["type": "number"]]; required = ["exposureEV"]
        case .rating: properties = ["expected": expected, "rating": ["type": "integer", "minimum": 0, "maximum": 5]]; required = ["rating"]
        case .deleteVirtualFolder: properties = ["folder": ["type": "string", "description": "Virtual folder id from get_state."]]; required = ["folder"]
        default: return ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    // MARK: State

    func state() -> [String: Any] {
        var result: [String: Any] = ["document": NSNull(), "catalog": NSNull()]
        if let session = session(), let document = session.document {
            result["document"] = [
                "id": document.id.uuidString, "width": document.width, "height": document.height,
                "name": session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                "selectedLayer": session.activeLayerID?.uuidString ?? NSNull(),
                "selectedLayers": session.selectedLayerIDs.map(\.uuidString).sorted(),
                "canUndo": session.canUndo, "undoName": session.history.undoName,
                "canRedo": session.canRedo, "redoName": session.history.redoName,
                "undoOrigin": session.history.undoOrigin?.rawValue ?? NSNull(), "redoOrigin": session.history.redoOrigin?.rawValue ?? NSNull(),
                "layers": document.layers.reversed().map { layer in
                    ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible, "opacity": layer.opacity,
                     "isGroup": layer.isGroup, "parent": layer.parentID?.uuidString ?? NSNull()] as [String: Any]
                }
            ] as [String: Any]
        }
        if let catalog = catalog(), let path = catalog.catalogPath {
            func version(_ variant: LWApplicationDtoVariant) -> [String: Any] {
                ["variantId": variant.key.variant_id, "label": variant.label, "revision": variant.revision.value]
            }
            result["catalog"] = [
                "path": path, "busy": catalog.isBusy,
                "selectedPhoto": catalog.selectedPhotoID ?? NSNull(),
                "rating": catalog.selectedAsset?.rating.map { Int($0) } ?? NSNull(),
                "currentVersion": catalog.currentCatalogVariant.map(version) ?? NSNull(),
                "copies": catalog.catalogVariants.map(version),
                "copiesCursor": catalog.catalogVariantsNext?.value ?? NSNull(),
                "virtualFolders": catalog.groups.map { ["id": $0.id, "name": $0.name] }
            ] as [String: Any]
        }
        return result
    }

    // MARK: Invocation

    /// One command an agent asked for, with its arguments checked.
    enum Call {
        case layer(LensWorksLayerCommand)
        case history(redo: Bool)
        case catalog(LensWorksCommandID, [String: Any])
        case folderDelete(String)
        var id: LensWorksCommandID {
            switch self {
            case .layer(let command): command.id
            case .history(let redo): redo ? .redo : .undo
            case .catalog(let id, _): id
            case .folderDelete: .deleteVirtualFolder
            }
        }
        var isDocument: Bool { if case .layer = self { true } else { false } }
    }

    /// Checks one `{command, arguments}` request: a registered command an agent may run, and only arguments its
    /// schema declares, each of the right shape.
    func parse(_ request: [String: Any]) throws -> Call {
        try Self.rejectUnknown(request, allowed: ["command", "arguments"], in: "a command")
        guard let raw = request["command"] as? String, let id = LensWorksCommandID(rawValue: raw) else {
            throw LensWorksCommandRefusal(reason: "Name a command id from list_commands.")
        }
        guard Self.agentCommands.contains(id) else { throw LensWorksCommandRefusal(reason: agentAvailability(id) ?? "Agents cannot run this command.") }
        let values: [String: Any]
        switch request["arguments"] {
        case nil, is NSNull: values = [:]
        case let given as [String: Any]: values = given
        default: throw LensWorksCommandRefusal(reason: "arguments must be an object.")
        }
        try Self.rejectUnknown(values, allowed: Array(((Self.inputSchema(id)["properties"] as? [String: Any]) ?? [:]).keys), in: id.rawValue)
        if let expected = values["expected"] {
            guard let expected = expected as? [String: Any] else { throw LensWorksCommandRefusal(reason: "expected must be an object.") }
            try Self.rejectUnknown(expected, allowed: Self.expectedProperties, in: "expected")
        }
        switch id {
        case .visibility, .opacity, .rename: return .layer(try layerCommand(id, values))
        case .undo, .redo: return .history(redo: id == .redo)
        case .deleteVirtualFolder:
            guard let folder = values["folder"] as? String else { throw LensWorksCommandRefusal(reason: "folder must be a virtual folder id from get_state.") }
            return .folderDelete(folder)
        default: return .catalog(id, values)
        }
    }

    func invoke(_ arguments: [String: Any], caller: LensWorksAutomationCaller = .inProcess) async throws -> [String: Any] {
        let call = try parse(arguments)
        switch call {
        case .layer(let command):
            guard let session = session() else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
            let changed = try session.dispatchCommand(session.admitCommand(command, origin: .agent))
            return ["command": call.id.rawValue, "changed": changed, "history": changed ? session.history.undoName : NSNull(),
                    "message": changed ? "\(session.history.undoName) is in LensWorks history; Undo in the app reverts it." : "Nothing changed."]
        case .history(let redo):
            guard let session = session() else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
            let name = try LensWorksCommandDispatcher.dispatchHistory(redo: redo, origin: .agent, in: session)
            return ["command": call.id.rawValue, "changed": true, "history": name, "message": (redo ? "Redid " : "Undid ") + (name.isEmpty ? "the last edit." : "“\(name)”.")]
        case .catalog, .folderDelete:
            try admitCatalog([call])
            let approved = try await confirm([call], caller: caller)
            try await run(call, approved: approved[0])
            return ["command": call.id.rawValue, "changed": true, "message": LensWorksCommandRegistry.descriptor(call.id).label + (approved.isEmpty ? " ran (Agent)." : " ran (Agent) after the person allowed it.")]
        }
    }

    private func layerIDs(_ values: [String: Any], key: String, session: EditorSession) throws -> [UUID] {
        guard let given = values[key] else {
            guard let active = session.activeLayerID else { throw LensWorksCommandRefusal(reason: "Select a layer first, or pass layer ids from get_state.") }
            return [active]
        }
        let strings = (given as? [String]) ?? (given as? String).map { [$0] }
        guard let strings, !strings.isEmpty else { throw LensWorksCommandRefusal(reason: "\(key) must list layer ids from get_state.") }
        return try strings.map { guard let id = UUID(uuidString: $0) else { throw LensWorksCommandRefusal(reason: "\($0.prefix(64)) is not a layer id.") }; return id }
    }

    private func layerCommand(_ id: LensWorksCommandID, _ values: [String: Any]) throws -> LensWorksLayerCommand {
        guard let session = session(), session.document != nil else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        switch id {
        case .visibility:
            let visible: Bool?
            switch values["visible"] {
            case nil, is NSNull: visible = nil
            case let value as Bool: visible = value
            default: throw LensWorksCommandRefusal(reason: "visible must be true, false or null.")
            }
            return .visibility(try layerIDs(values, key: "layers", session: session), visible)
        case .opacity:
            guard let value = (values["opacity"] as? NSNumber)?.doubleValue else { throw LensWorksCommandRefusal(reason: "opacity must be a number from 0 through 1.") }
            return .opacity(try layerIDs(values, key: "layers", session: session), value)
        default:
            guard let name = values["name"] as? String else { throw LensWorksCommandRefusal(reason: "name must be a string.") }
            return .rename(try layerIDs(values, key: "layer", session: session).first!, name)
        }
    }

    /// The typed catalog action for `id` against the catalog version as it stands.
    private func catalogAction(_ id: LensWorksCommandID, _ values: [String: Any], checkingExpected: Bool) throws -> (catalog: LensWorksCatalog, action: LensWorksCatalogControlAction, current: LWApplicationDtoVariant) {
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        guard let current = catalog.currentCatalogVariant else { throw LensWorksCommandRefusal(reason: "Select a catalog photo first.") }
        if checkingExpected, let expected = values["expected"] as? [String: Any] {
            let variant = expected["variantId"] as? String, revision = (expected["revision"] as? NSNumber)?.int64Value
            guard variant == nil || variant == current.key.variant_id, revision == nil || revision == current.revision.value else {
                throw LensWorksCommandRefusal(reason: "The catalog version changed since get_state; read it again.")
            }
        }
        let action: LensWorksCatalogControlAction
        switch id {
        case .firstVariants: action = .firstVariants
        case .moreVariants:
            let cursor = (values["cursor"] as? NSNumber).map { LWCatalogI64($0.int64Value) } ?? catalog.catalogVariantsNext
            guard let cursor else { throw LensWorksCommandRefusal(reason: "There are no more catalog copies.") }
            action = .moreVariants(cursor)
        case .selectVariant:
            guard let wanted = values["variant"] as? String, let copy = catalog.catalogVariants.first(where: { $0.key.variant_id == wanted }) else {
                throw LensWorksCommandRefusal(reason: "variant must be a variantId from get_state's catalog copies.")
            }
            action = .selectVariant(copy)
        case .copy:
            guard let label = values["label"] as? String else { throw LensWorksCommandRefusal(reason: "label must be a string.") }
            action = .recipe(.copy(label))
        case .exposure:
            guard let value = (values["exposureEV"] as? NSNumber)?.floatValue else { throw LensWorksCommandRefusal(reason: "exposureEV must be a number.") }
            action = .recipe(.exposure(value))
        case .undoRecipe: action = .recipe(.undo)
        case .redoRecipe: action = .recipe(.redo)
        default:
            guard let value = (values["rating"] as? NSNumber)?.intValue, (0...5).contains(value) else { throw LensWorksCommandRefusal(reason: "rating must be an integer from 0 through 5.") }
            action = .rating(UInt8(value))
        }
        return (catalog, action, current)
    }

    /// Admits every catalog call against the catalog as it stands, without running any. Throws naming the call.
    private func admitCatalog(_ calls: [Call]) throws {
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        var folders = Set<String>()
        for (index, call) in calls.enumerated() {
            do {
                switch call {
                case .catalog(let id, let values):
                    let prepared = try catalogAction(id, values, checkingExpected: true)
                    _ = try catalog.admitCommand(prepared.action, expected: prepared.current, origin: .agent)
                case .folderDelete(let folder):
                    guard folders.insert(folder).inserted else { throw LensWorksCommandRefusal(reason: "The same virtual folder is deleted twice.") }
                    _ = try catalog.admitFolderDelete(folder, origin: .agent)
                default: throw LensWorksCommandRefusal(reason: "This is not a catalog command.")
                }
            } catch { throw Self.naming(index, of: calls, error) }
        }
    }

    private static func naming(_ index: Int, of calls: [Call], _ error: Error) -> LensWorksCommandRefusal {
        let reason = error is CancellationError ? "The catalog, photo, version or revision is no longer current." : String(error.localizedDescription.prefix(messageLimit))
        return .init(reason: calls.count == 1 ? reason : "Command \(index + 1) (\(calls[index].id.rawValue)): \(reason)")
    }

    /// Asks the person once for every call the registry marks as needing confirmation, naming each from the app's own
    /// rows. Returns, by index, the admissions the person approved, re-admitted after the answer; nothing but Allow
    /// returns.
    private func confirm(_ calls: [Call], caller: LensWorksAutomationCaller) async throws -> [Int: LensWorksCatalogDeleteAdmission] {
        var asked: [Int: LensWorksCatalogDeleteAdmission] = [:], items: [LensWorksAgentConfirmation.Item] = []
        for (index, call) in calls.enumerated() where Self.requiresConfirmation(call.id) {
            guard case .folderDelete(let folder) = call, let catalog = catalog() else {
                throw LensWorksCommandRefusal(reason: "\(call.id.rawValue) needs the person’s confirmation, which agents cannot ask for.")
            }
            let admission = try catalog.admitFolderDelete(folder, origin: .agent)
            asked[index] = admission
            items.append(.init(action: LensWorksCommandRegistry.descriptor(call.id).label, name: admission.folder.name))
        }
        guard !asked.isEmpty else { return [:] }
        guard let automation else { throw LensWorksCommandRefusal(reason: "LensWorks automation is off.") }
        let answer = await automation.confirm(.init(
            title: items.count == 1 ? "Allow an AI agent to make a permanent change?" : "Allow an AI agent to make \(items.count) permanent changes?",
            message: "An agent connected over automation asked for this. It cannot be undone.", items: items), owner: caller.connection)
        switch answer {
        case .allowed: break
        case .declined: throw LensWorksCommandRefusal(reason: "The person declined in LensWorks: nothing was run or deleted.")
        case .busy: throw LensWorksCommandRefusal(reason: "LensWorks is already asking the person to confirm another agent request: nothing was run or deleted.")
        case .unanswered: throw LensWorksCommandRefusal(reason: "The person did not answer the confirmation in LensWorks (it timed out, the client disconnected, or automation was turned off or its secret changed): nothing was run or deleted.")
        }
        guard caller.isCurrent() else { throw LensWorksCommandRefusal(reason: "The automation connection or its secret changed while waiting for confirmation: nothing was run or deleted.") }
        // The catalog may have changed while the sheet was open: re-admit exactly what the person approved.
        var approved: [Int: LensWorksCatalogDeleteAdmission] = [:]
        for (index, admission) in asked {
            guard let catalog = catalog(), let current = try? catalog.admitFolderDelete(admission.folder.id, origin: .agent),
                  current.folder.revision == admission.folder.revision, current.folder.name == admission.folder.name else {
                throw LensWorksCommandRefusal(reason: "A virtual folder changed while waiting for confirmation: nothing was run or deleted.")
            }
            approved[index] = current
        }
        return approved
    }

    /// Runs one admitted catalog call. A call that needs confirmation runs only from the admission the person approved.
    private func run(_ call: Call, approved: LensWorksCatalogDeleteAdmission?) async throws {
        guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        switch call {
        case .catalog(let id, let values):
            guard !Self.requiresConfirmation(id) else { throw LensWorksCommandRefusal(reason: "\(id.rawValue) needs the person’s confirmation.") }
            let prepared = try catalogAction(id, values, checkingExpected: false)
            try await catalog.dispatchCommand(catalog.admitCommand(prepared.action, expected: prepared.current, origin: .agent))
        case .folderDelete:
            guard let approved else { throw LensWorksCommandRefusal(reason: "The person has not confirmed this delete.") }
            try await LensWorksCommandDispatcher.dispatch(approved, in: catalog)
        default: throw LensWorksCommandRefusal(reason: "This is not a catalog command.")
        }
    }

    // MARK: Batch

    /// Runs several commands as one step. Every member is checked and admitted before any runs. Document members
    /// share one agent history entry and roll back together; catalog members run in order and stop at the first
    /// failure. Throws when nothing ran; `completed` is false when a catalog batch stopped part-way.
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
                if case .history = call { throw LensWorksCommandRefusal(reason: "edit.undo and edit.redo cannot be part of a batch; run them with invoke_command.") }
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
        return documents > 0 ? (try documentBatch(calls, caller: caller), true) : try await catalogBatch(calls, caller: caller)
    }

    private func documentBatch(_ calls: [Call], caller: LensWorksAutomationCaller) throws -> [String: Any] {
        guard let session = session(), session.document != nil else { throw LensWorksCommandRefusal(reason: "Open a document first. Nothing was run.") }
        let commands = calls.compactMap { call -> LensWorksLayerCommand? in if case .layer(let command) = call { command } else { nil } }
        for (index, command) in commands.enumerated() {
            do { _ = try session.admitCommand(command, origin: .agent) }
            catch { throw LensWorksCommandRefusal(reason: Self.naming(index, of: calls, error).reason + " Nothing was run.") }
        }
        let revision = session.history.currentRevision
        var results: [[String: Any]] = []
        do {
            try session.agentTransaction(commands.count == 1 ? "1 Layer Command" : "\(commands.count) Layer Commands") {
                for (index, command) in commands.enumerated() {
                    guard caller.isCurrent() else { throw LensWorksCommandRefusal(reason: "The automation connection or its secret changed before command \(index + 1).") }
                    do {
                        let changed = try session.dispatchCommand(session.admitCommand(command, origin: .agent))
                        results.append(["index": index + 1, "command": command.id.rawValue, "status": "ran", "changed": changed])
                    } catch { throw Self.naming(index, of: calls, error) }
                }
            }
        } catch { throw LensWorksCommandRefusal(reason: error.localizedDescription + " The whole batch was rolled back: the document and its history are unchanged.") }
        let changed = session.history.currentRevision != revision
        return ["kind": "document", "completed": true, "changed": changed, "history": changed ? session.history.undoName : NSNull(), "results": results,
                "message": changed ? "\(session.history.undoName) is one entry in LensWorks history; one Undo in the app reverts the whole batch." : "Nothing changed."]
    }

    private func catalogBatch(_ calls: [Call], caller: LensWorksAutomationCaller) async throws -> (value: [String: Any], completed: Bool) {
        let unrun = " Nothing was run."
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first." + unrun) }
        guard !catalog.isBusy else { throw LensWorksCommandRefusal(reason: "Finish the current catalog operation first." + unrun) }
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
                do { try await run(call, approved: approved[index]); row["status"] = "ran" }
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
