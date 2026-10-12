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
        .visibility, .opacity, .rename,
        .firstVariants, .moreVariants, .selectVariant, .copy, .exposure, .undoRecipe, .redoRecipe, .rating,
        .deleteVirtualFolder
    ]
    /// Permanent deletes: the person confirms each one in the app before it runs.
    static let confirmedCommands: Set<LensWorksCommandID> = [.deleteVirtualFolder]
    static let previewDefault = 1024, previewMinimum = 64, previewMaximum = 2048

    static let toolNames: Set<String> = ["list_commands", "get_state", "invoke_command", "render_preview"]
    static var definitions: [[String: Any]] {
        let empty: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        return [
            ["name": "list_commands", "title": "List LensWorks commands",
             "description": "Every registered LensWorks command: id, title, menu, whether an agent can run it now (with the reason when not), whether it asks the person to confirm, and the JSON schema of its arguments for invoke_command.",
             "inputSchema": empty, "annotations": ["readOnlyHint": true]],
            ["name": "get_state", "title": "Describe the open document and catalog",
             "description": "The open document (size, layers with id, name, visibility and opacity, the selected layer) and the open catalog (selected photo, its current catalog version and copies, and the virtual folders on the current page).",
             "inputSchema": empty, "annotations": ["readOnlyHint": true]],
            ["name": "invoke_command", "title": "Run a LensWorks command",
             "description": "Runs one registered command as the agent. Document edits enter LensWorks history labeled “(Agent)”, so Undo in the app reverts them. Permanent deletes wait for the person to confirm in LensWorks and return a refusal when they decline.",
             "inputSchema": ["type": "object", "required": ["command"], "additionalProperties": false, "properties": [
                "command": ["type": "string", "enum": agentCommands.map(\.rawValue), "description": "A command id from list_commands."],
                "arguments": ["type": "object", "description": "Arguments matching that command's inputSchema from list_commands."]]]],
            ["name": "render_preview", "title": "Render a preview of the open document",
             "description": "A PNG of the open document composited as it stands, scaled to fit maxDimension pixels (never enlarged).",
             "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
                "maxDimension": ["type": "integer", "minimum": previewMinimum, "maximum": previewMaximum, "default": previewDefault]]],
             "annotations": ["readOnlyHint": true]]
        ]
    }

    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "list_commands": return Self.structured(["commands": listCommands()])
            case "get_state": return Self.structured(state())
            case "invoke_command": return Self.structured(try await invoke(arguments))
            default: return try await preview(arguments)
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    // MARK: Listing

    func listCommands() -> [[String: Any]] {
        LensWorksCommandRegistry.descriptors.map { descriptor in
            let reason = agentAvailability(descriptor.id)
            var row: [String: Any] = [
                "id": descriptor.id.rawValue, "title": descriptor.label, "menu": descriptor.menu,
                "undoable": descriptor.undoable, "history": descriptor.historyOwner.rawValue,
                "agentInvocable": Self.agentCommands.contains(descriptor.id),
                "requiresConfirmation": Self.confirmedCommands.contains(descriptor.id),
                "available": reason == nil,
                "parameters": descriptor.parameters.map { ["name": $0.name, "type": $0.type.rawValue, "description": $0.description] },
                "inputSchema": Self.inputSchema(descriptor.id)
            ]
            if let reason { row["reason"] = reason }
            return row
        }
    }

    /// Why an agent cannot run `id` now (with its default arguments), or nil when it can.
    func agentAvailability(_ id: LensWorksCommandID) -> String? {
        guard Self.agentCommands.contains(id) else {
            return id.rawValue.hasPrefix("automation.") ? "Automation settings and confirmations are never available to agents."
                : "Agents cannot run this command yet: it runs only from its menu, shortcut or panel."
        }
        switch id {
        case .visibility, .opacity, .rename:
            guard let session = session(), session.document != nil else { return "Open a document first." }
            guard let layer = session.activeLayer else { return session.layerMenuAvailability(nil) }
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

    static func inputSchema(_ id: LensWorksCommandID) -> [String: Any] {
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let expected: [String: Any] = ["type": "object", "description": "Optional guard: the catalog version (variantId and revision from get_state) this command was decided against; refused when it changed.",
                                       "properties": ["variantId": ["type": "string"], "revision": ["type": "integer"]]]
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

    func invoke(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let raw = arguments["command"] as? String, let id = LensWorksCommandID(rawValue: raw) else {
            throw LensWorksCommandRefusal(reason: "Name a command id from list_commands.")
        }
        guard Self.agentCommands.contains(id) else { throw LensWorksCommandRefusal(reason: agentAvailability(id) ?? "Agents cannot run this command.") }
        let values = arguments["arguments"] as? [String: Any] ?? [:]
        switch id {
        case .visibility, .opacity, .rename: return try invokeLayer(id, values)
        case .deleteVirtualFolder: return try await invokeFolderDelete(values)
        default: return try await invokeCatalog(id, values)
        }
    }

    private func layerIDs(_ values: [String: Any], key: String, session: EditorSession) throws -> [UUID] {
        guard let given = values[key] else {
            guard let active = session.activeLayerID else { throw LensWorksCommandRefusal(reason: "Select a layer first, or pass layer ids from get_state.") }
            return [active]
        }
        let strings = (given as? [String]) ?? (given as? String).map { [$0] }
        guard let strings, !strings.isEmpty else { throw LensWorksCommandRefusal(reason: "\(key) must list layer ids from get_state.") }
        return try strings.map { guard let id = UUID(uuidString: $0) else { throw LensWorksCommandRefusal(reason: "\($0) is not a layer id.") }; return id }
    }

    private func invokeLayer(_ id: LensWorksCommandID, _ values: [String: Any]) throws -> [String: Any] {
        guard let session = session(), session.document != nil else { throw LensWorksCommandRefusal(reason: "Open a document first.") }
        let command: LensWorksLayerCommand
        switch id {
        case .visibility:
            let visible: Bool?
            switch values["visible"] {
            case nil, is NSNull: visible = nil
            case let value as Bool: visible = value
            default: throw LensWorksCommandRefusal(reason: "visible must be true, false or null.")
            }
            command = .visibility(try layerIDs(values, key: "layers", session: session), visible)
        case .opacity:
            guard let value = (values["opacity"] as? NSNumber)?.doubleValue else { throw LensWorksCommandRefusal(reason: "opacity must be a number from 0 through 1.") }
            command = .opacity(try layerIDs(values, key: "layers", session: session), value)
        default:
            guard let name = values["name"] as? String else { throw LensWorksCommandRefusal(reason: "name must be a string.") }
            command = .rename(try layerIDs(values, key: "layer", session: session).first!, name)
        }
        let changed = try session.dispatchCommand(session.admitCommand(command, origin: .agent))
        return ["command": id.rawValue, "changed": changed, "history": changed ? session.history.undoName : NSNull(),
                "message": changed ? "\(session.history.undoName) is in LensWorks history; Undo in the app reverts it." : "Nothing changed."]
    }

    private func invokeCatalog(_ id: LensWorksCommandID, _ values: [String: Any]) async throws -> [String: Any] {
        guard let catalog = catalog(), catalog.catalogPath != nil else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        guard let current = catalog.currentCatalogVariant else { throw LensWorksCommandRefusal(reason: "Select a catalog photo first.") }
        if let expected = values["expected"] as? [String: Any] {
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
        try await catalog.dispatchCommand(catalog.admitCommand(action, expected: current, origin: .agent))
        return ["command": id.rawValue, "changed": true, "message": LensWorksCommandRegistry.descriptor(id).label + " ran (Agent)."]
    }

    private func invokeFolderDelete(_ values: [String: Any]) async throws -> [String: Any] {
        guard let catalog = catalog() else { throw LensWorksCommandRefusal(reason: "Open a catalog first.") }
        guard let folder = values["folder"] as? String else { throw LensWorksCommandRefusal(reason: "folder must be a virtual folder id from get_state.") }
        let admission = try catalog.admitFolderDelete(folder, origin: .agent)
        guard let automation else { throw LensWorksCommandRefusal(reason: "LensWorks automation is off.") }
        let allowed = await automation.confirm(.init(commandID: .deleteVirtualFolder,
            title: "Allow an AI agent to delete the virtual folder “\(admission.folder.name)”?",
            message: "An agent connected over automation asked to permanently delete this virtual folder. This cannot be undone.",
            actionTitle: "Delete Folder"))
        guard allowed else { throw LensWorksCommandRefusal(reason: "The person declined in LensWorks: the virtual folder “\(admission.folder.name)” was not deleted.") }
        // The catalog may have changed while the sheet was open: re-admit against the folder the person approved.
        let current = try catalog.admitFolderDelete(folder, origin: .agent)
        guard current.folder.revision == admission.folder.revision else { throw LensWorksCommandRefusal(reason: "The virtual folder changed while waiting for confirmation; nothing was deleted.") }
        try await LensWorksCommandDispatcher.dispatch(current, in: catalog)
        return ["command": LensWorksCommandID.deleteVirtualFolder.rawValue, "changed": true, "message": "Deleted the virtual folder “\(admission.folder.name)” after the person allowed it."]
    }

    // MARK: Preview

    func preview(_ arguments: [String: Any]) async throws -> [String: Any] {
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

    static func structured(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": false]
    }
    nonisolated static func encodeResult(id: Any?, _ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id ?? NSNull(), "result": result])) ?? encodeError(id: id, code: -32603, "The result could not be encoded.")
    }
    nonisolated static func encodeError(id: Any?, code: Int, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? Data("{}".utf8)
    }
}
