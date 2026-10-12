import AppKit
import CoreGraphics
import Foundation

/// A registered command an agent asked for, with its arguments checked against the registry and its paths admitted
/// to a granted folder. `LensWorksCommandDispatcher.dispatch` runs it: the same dispatcher the menus use.
struct LensWorksAgentAdmission {
    let id: LensWorksCommandID
    let arguments: LensWorksAgentArguments
    let origin = LensWorksCommandOrigin.agent
    var descriptor: LensWorksCommandDescriptor { LensWorksCommandRegistry.descriptor(id) }
}

/// What an agent's command runs against: the project tab on screen, its controller, the tab strip and the catalog.
struct LensWorksAgentContext {
    let session: EditorSession?
    let projects: ProjectController?
    let workspace: ProjectWorkspace?
    let catalog: LensWorksCatalog?
    let folders: LensWorksGrantedFolders
}

extension EditorSession {
    /// Runs `body` as one agent history entry. The entry takes the name of the first edit made inside it (as the
    /// menu's edit is named), labeled “(Agent)”; `name` is used when the body makes none. When the body throws, the
    /// document and selection go back to where they started and history gains nothing.
    func agentTransaction<T>(_ name: String, adoptingNestedName: Bool, requiresDocument: Bool = true, _ body: () async throws -> T) async throws -> T {
        if requiresDocument || document != nil, let reason = agentModalReason { throw LensWorksCommandRefusal(reason: reason) }
        let selected = selectedLayerIDs, revision = history.currentRevision, maskTarget = isMaskSelected
        let admitted = try document?.admittingMetadataMutation()
        guard let token = history.beginInteraction(LensWorksCommandOrigin.agent.historyName(name), document: document, selection: activeLayerID,
                                                   afterMetadataStorage: admitted?.metadataStorage, origin: .agent,
                                                   adoptingNestedName: adoptingNestedName) else {
            throw LensWorksCommandRefusal(reason: "Finish the current history transaction first.")
        }
        document = admitted
        do {
            let value = try await body()
            guard history.endInteraction(token, document: document, selection: activeLayerID) else {
                throw LensWorksCommandRefusal(reason: "The command no longer owns this document transaction.")
            }
            if history.currentRevision != revision { commandContextEpoch &+= 1 }
            return value
        } catch {
            if let snapshot = history.cancelInteraction(token) {
                document = snapshot.document; activeLayerID = snapshot.activeLayerID; selectedLayerIDs = selected
                isMaskSelected = maskTarget && activeLayer?.mask != nil
                commandContextEpoch &+= 1
            }
            throw error
        }
    }
}

extension LensWorksCommandDispatcher {
    /// Runs one admitted agent command on the open document. The caller owns the history transaction.
    static func dispatch(_ admission: LensWorksAgentAdmission, in session: EditorSession, context: LensWorksAgentContext) async throws {
        noteAgent(admission)
        try await LensWorksAgentDocumentCommands(session: session, context: context).run(admission)
    }
    /// Runs one admitted agent command on the open catalog.
    static func dispatch(_ admission: LensWorksAgentAdmission, in catalog: LensWorksCatalog, context: LensWorksAgentContext) async throws {
        noteAgent(admission)
        try await LensWorksAgentCatalogCommands(catalog: catalog, context: context).run(admission)
    }
    /// Runs one admitted agent command on project files, tabs or the catalog itself. Returns what to tell the agent.
    static func dispatchStandalone(_ admission: LensWorksAgentAdmission, context: LensWorksAgentContext) async throws -> String {
        noteAgent(admission)
        return try await LensWorksAgentProjectCommands(context: context).run(admission)
    }
}

/// The document commands: each selects the layers the agent named, answers with the menu's own reason when the
/// command is unavailable, then calls the session function the menu item calls.
struct LensWorksAgentDocumentCommands {
    let session: EditorSession
    let context: LensWorksAgentContext
    private var canStart: Bool { context.projects?.canStart ?? session.canStartProjectOperation }

    private func refuse(_ reason: String) -> LensWorksCommandRefusal { .init(reason: reason) }
    /// Why `id` cannot run on the document as it stands, or nil: the menu item's own reason where the menu shows
    /// one, and for commands whose item only declines when chosen (or that live in a panel), what it checks then.
    /// `argument` is a filter or adjustment kind, or a nudge's target.
    func reason(_ id: LensWorksCommandID, _ argument: String? = nil) -> String? {
        func unless(_ available: Bool, _ reason: String) -> String? { session.commandReason(!available, reason) }
        let editing = "Finish the current tool, dialog or layer edit first."
        switch id {
        case .selectLayers: return unless(session.canEditLayers, editing)
        case .cut: return unless(session.selection != nil && session.canCopyPixels, "Make a selection on an editable pixel layer first.")
        case .copyPixels: return unless(session.canCopyPixels || session.canCopyLayer, "Select a layer or an area of pixels first.")
        case .paste: return unless(session.canPaste, "There is nothing to paste, or a tool, dialog or layer edit is open.")
        case .selectAll: return unless(session.canEditSelection, editing)
        case .newAdjustment: return session.menuReason(.newBlankLayer, canStart: canStart)
        case .transform: return unless(session.canTransform, "Select a layer that can be transformed first.")
        case .duplicateLayer: return unless(session.canEditLayers && session.activeLayer != nil, "Select a layer first.")
        case .groupLayers: return session.menuReason(id, canStart: canStart) ?? unless(!session.selectedLayerIDs.isEmpty, "Select a layer first.")
        case .addMask: return unless(session.canEditMask && session.activeLayer?.mask == nil, "Select one layer without a mask first.")
        case .toggleMask, .deleteMask: return unless(session.canEditMask && session.activeLayer?.mask != nil, "Select one layer with a mask first.")
        case .linkMask: return unless(session.canEditLayers && session.activeLayer?.mask != nil, "Select a layer with a mask first.")
        case .addEffect: return unless(session.canEditEffects, "Select a pixel layer first.")
        case .blendMode: return unless(session.canEditAppearance, "Select one layer that is not a folder first.")
        case .swapColors, .resetColors: return unless(session.canEditPalette, "Finish the current project operation first.")
        case .nudge:
            if argument == "selection" { return unless(session.selection?.isEmpty == false && session.canEditSelection && session.lassoDraft == nil, "Make a selection first.") }
            return unless(session.canTransform, "Select a layer that can be transformed first.")
        case .movePixels: return unless(session.selection?.isEmpty == false && session.canEditPixels, "Make a selection on an editable pixel layer first.")
        case .canvasDelete:
            if session.selectedEffect != nil { return unless(session.canEditLayers, editing) }
            return session.menuReason(session.selection != nil ? .clearSelectionPixels : .deleteLayer, canStart: canStart)
        default: return session.menuReason(id, argument: argument, canStart: canStart)
        }
    }
    private func check(_ id: LensWorksCommandID, _ argument: String? = nil) throws {
        if let reason = reason(id, argument) { throw refuse(reason) }
    }
    private func layer(_ id: UUID) throws -> ImageLayer {
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else { throw refuse("The requested layer is no longer in this document.") }
        return layer
    }
    private func activeID() throws -> UUID {
        guard let id = session.activeLayerID else { throw refuse(session.commandReason(true, "Select a layer first, or pass a layer id from get_state.") ?? "") }
        return id
    }

    /// Selects what the agent named (`layer`, `layers`, `target`), as clicking those rows and thumbnails would.
    private func aim(_ arguments: LensWorksAgentArguments) throws {
        var chosen: [UUID]?
        if let one = try arguments.uuid("layer"), arguments.id != .rename { chosen = [one] }
        if let many = try arguments.uuids("layers"), arguments.id != .selectLayers { chosen = many }
        if let chosen {
            guard !chosen.isEmpty, Set(chosen).count == chosen.count else { throw refuse("Name each layer once, and at least one.") }
            for id in chosen { _ = try layer(id) }
            if Set(chosen) != session.selectedLayerIDs || session.activeLayerID.map(chosen.contains) != true {
                session.selectLayers(Set(chosen), primary: chosen[0])
                guard session.selectedLayerIDs == Set(chosen) else { throw refuse("Finish the current tool, dialog or layer edit first.") }
            }
            // A named layer means the layer itself, never a mask or effect the person had targeted on it.
            session.isMaskSelected = false; session.effectSelection = nil
        }
        if let target = try arguments.string("target"), ["pixels", "mask"].contains(target), arguments.id != .nudge {
            let id = try activeID()
            if target == "mask" { guard try layer(id).mask != nil else { throw refuse("That layer has no mask.") } }
            session.isMaskSelected = target == "mask"
        }
    }

    /// Runs `body`, turning an error the session would have shown the person into the agent's refusal.
    private func reporting(_ body: () async throws -> Void) async throws {
        let prior = session.brushError
        session.brushError = nil
        defer { if session.brushError == nil { session.brushError = prior } }
        try await body()
        if let failure = session.brushError { session.brushError = prior; throw refuse(failure) }
    }

    private static func step(_ argument: String?) throws -> (dx: CGFloat, dy: CGFloat) {
        guard let step = CanvasView.step(argument) else { throw LensWorksCommandRefusal(reason: "step must be a direction and a distance, such as left.10.") }
        return step
    }

    func run(_ admission: LensWorksAgentAdmission) async throws {
        let arguments = admission.arguments, id = admission.id
        try aim(arguments)
        try await reporting { try await perform(id, arguments) }
    }

    private func perform(_ id: LensWorksCommandID, _ arguments: LensWorksAgentArguments) async throws {
        switch id {
        case .selectLayers:
            let ids = try arguments.required("layers", try arguments.uuids("layers"))
            guard Set(ids).count == ids.count else { throw refuse("Name each layer once.") }
            for id in ids { _ = try layer(id) }
            let primary = try arguments.uuid("primary") ?? ids.first
            if let primary, !ids.contains(primary) { throw refuse("primary must be one of layers.") }
            session.selectLayers(Set(ids), primary: primary)
            guard session.selectedLayerIDs == Set(ids) else { throw refuse("Finish the current tool, dialog or layer edit first.") }
        case .importImages:
            try check(.importImages)
            let urls = arguments.paths["paths"] ?? []
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw refuse("“\(url.lastPathComponent.prefix(128))” is not a file in a granted folder.")
                }
            }
            // A Photoshop file's conversion notes are accepted for the agent rather than put to the person in a sheet.
            let asked = session.confirmConversions
            if asked == nil { session.confirmConversions = { _ in true } }
            defer { if asked == nil { session.confirmConversions = nil } }
            await session.importImages(urls)
            if let failure = session.importError { session.importError = nil; throw refuse(failure) }
        case .cut:
            try check(id)
            await session.cutSelection()
        case .copyPixels:
            try check(id)
            session.copySelection()
        case .copyMerged: try check(id); session.copyMergedSelection()
        case .paste:
            if context.workspace?.pasteCopiedLayer() == true { return }
            try check(id)
            session.paste()
        case .fillForeground, .fillBackground:
            if let color = try arguments.color("color") {
                guard session.canEditPalette, !session.isMaskSelected else { throw refuse("A color cannot be set while a mask is targeted or a stroke is in progress.") }
                session.setPaletteColor(color, background: id == .fillBackground)
            }
            try check(id)
            await session.fillSelection(with: id == .fillBackground ? .background : .foreground)
        case .clearSelectionPixels: try check(id); await session.clearSelectedPixels()
        case .contentAwareFill: try check(id); try await filter(.contentAwareFill, nil)
        case .clearGuides: try check(id); session.clearGuides()
        case .selectAll: try check(id); session.selectAll()
        case .deselect: try check(id); session.deselect()
        case .inverseSelection: try check(id); session.invertSelection()
        case .selectLayerPixels: try check(id); session.loadLayerSelection(layerID: try activeID())
        case .selectMaskBlack: try check(id); session.loadMaskSelection(layerID: try activeID())
        case .selectSubject: try check(id); await session.selectSubject()
        case .colorRange: try await colorRange(arguments)
        case .expandSelection, .contractSelection, .featherSelection:
            try check(id)
            let amount = try arguments.required("amount", try arguments.integer("amount"))
            if id == .expandSelection { session.expandSelection(by: amount) }
            else if id == .contractSelection { session.contractSelection(by: amount) }
            else { session.featherSelection(by: amount) }
        case .curves: try check(id); try await filter(.curves, try arguments.object("settings"))
        case .imageAdjustment, .filter:
            let name = try arguments.required("kind", try arguments.string("kind"))
            guard let kind = FilterKind(rawValue: name) else { throw refuse("kind is not a filter.") }
            try check(id, name)
            try await filter(kind, try arguments.object("settings"))
        case .levels:
            try check(id)
            session.beginLevels()
            guard let edit = session.levels else { throw refuse("Levels could not open on that layer.") }
            do { session.updateLevels(try LensWorksAgentSettings.merged(edit.settings, try arguments.object("settings")), preview: false) }
            catch { session.cancelLevels(); throw error }
            await session.commitLevels()
            if session.levels != nil { session.cancelLevels(); throw refuse("Levels could not be applied.") }
        case .hueSaturation:
            try check(id)
            session.beginHueSaturation()
            guard let edit = session.hueSaturation else { throw refuse("Hue/Saturation could not open on that layer.") }
            do { session.updateHueSaturation(try LensWorksAgentSettings.hueMerged(edit.settings, try arguments.object("settings")), preview: false) }
            catch { session.cancelHueSaturation(); throw error }
            await session.commitHueSaturation()
            if session.hueSaturation != nil { session.cancelHueSaturation(); throw refuse("Hue/Saturation could not be applied.") }
        case .invert: try check(id); await session.invertPixels()
        case .canvasSize, .imageSize, .trim: try await resize(id, arguments)
        case .flipCanvasHorizontal, .flipCanvasVertical: try check(id); session.flipCanvas(horizontally: id == .flipCanvasHorizontal)
        case .newAdjustment:
            try check(id)
            let name = try arguments.required("kind", try arguments.string("kind"))
            guard let kind = AdjustmentKind(rawValue: name) else { throw refuse("kind is not an adjustment.") }
            let before = Set(session.document?.layers.map(\.id) ?? [])
            session.addAdjustment(kind)
            // The agent's settings stand in for the editor the menu opens on the new layer.
            session.adjustmentEditingID = nil
            guard let made = session.document?.layers.first(where: { !before.contains($0.id) }), let adjustment = made.adjustment else {
                throw refuse("The adjustment layer could not be added.")
            }
            try adjust(made.id, adjustment, try arguments.object("settings"))
        case .editAdjustment:
            try check(id)
            let target = try layer(try activeID())
            guard let adjustment = target.adjustment else { throw refuse("Select an adjustment layer first.") }
            try adjust(target.id, adjustment, try arguments.object("settings"))
        case .transform: try transform(arguments)
        case .layerViaCopy: try check(id); session.layerViaCopy()
        case .duplicateLayer:
            try check(id)
            session.duplicateActiveLayer()
        case .clippingMask: try check(id); session.toggleClippingMask(try activeID())
        case .groupLayers:
            try check(id)
            guard !session.selectedLayerIDs.isEmpty else { throw refuse("Select a layer first.") }
            session.groupSelectedLayers()
        case .ungroupLayers: try check(id); session.ungroupLayers()
        case .moveOutOfFolder: try check(id); session.moveActiveLayerOutOfGroup()
        case .newBlankLayer: try check(id); session.addBlankLayer()
        case .moveLayerUp, .moveLayerDown: try check(id); session.moveActiveLayer(by: id == .moveLayerUp ? 1 : -1)
        case .mergeLayers: try check(id); session.mergeLayers()
        case .flipLayerHorizontal, .flipLayerVertical: try check(id); session.flipLayers(horizontally: id == .flipLayerHorizontal)
        case .deleteLayer:
            try check(id)
            if session.selectedEffect != nil { session.removeSelectedEffect() }
            else if session.isMaskSelected, session.activeLayer?.mask != nil, session.selectedLayerIDs.count <= 1 { session.deleteLayerMask() }
            else { try await deleteLayers(arguments) }
        case .canvasDelete:
            if session.selectedEffect != nil { try check(id); session.removeSelectedEffect() }
            else if session.selection != nil { try check(.clearSelectionPixels); await session.clearSelectedPixels() }
            else {
                try check(.deleteLayer)
                if session.isMaskSelected, session.activeLayer?.mask != nil, session.selectedLayerIDs.count <= 1 { session.deleteLayerMask() }
                else { try await deleteLayers(arguments) }
            }
        case .addMask:
            try check(id)
            session.addLayerMask(revealing: try arguments.string("fill") != "black")
        case .toggleMask, .deleteMask:
            try check(id)
            if id == .toggleMask { session.toggleLayerMask() } else { session.deleteLayerMask() }
        case .linkMask:
            try check(id)
            session.toggleMaskLink(try activeID())
        case .addEffect: try addEffect(arguments)
        case .blendMode:
            let mode = try arguments.string("mode"), direction = try arguments.string("direction")
            guard (mode == nil) != (direction == nil) else { throw refuse("Pass exactly one of mode and direction.") }
            try check(id)
            if let mode { session.setLayerBlendMode(LayerBlendMode(rawValue: mode) ?? .normal) }
            else { session.cycleBlendMode(forward: direction == "next") }
        case .swapColors, .resetColors:
            guard session.canEditPalette else { throw refuse("Finish the current project operation first.") }
            if id == .swapColors { session.swapPaletteColors() } else { session.resetPaletteColors() }
        case .nudge:
            let step = try Self.step(try arguments.string("step"))
            if try arguments.string("target") == "selection" {
                try check(id, "selection")
                session.nudgeSelection(dx: step.dx, dy: step.dy)
            } else {
                try check(id)
                // The nudge is the Move tool's; the person's own tool is put back.
                let tool = session.tool
                session.nudgeLayer(dx: step.dx, dy: step.dy)
                session.tool = tool
            }
        case .movePixels:
            let step = try Self.step(try arguments.string("step"))
            try check(id)
            await session.nudgePixels(dx: step.dx, dy: step.dy)
        default: throw refuse("\(id.rawValue) is not a document command.")
        }
    }

    /// Runs a filter with the agent's settings in place of its dialog: opened, set and committed in one step.
    private func filter(_ kind: FilterKind, _ overrides: [String: Any]?) async throws {
        session.beginFilter(kind)
        guard let edit = session.filterEdit else { throw refuse("\(kind.rawValue) could not open on that layer.") }
        do {
            let settings = try LensWorksAgentSettings.filterMerged(kind, edit.settings, overrides)
            session.updateFilter(settings, preview: kind.isAutomatic)
        } catch { session.cancelFilter(); throw error }
        await session.commitFilter()
        if session.filterEdit != nil {
            let failure = edit.previewError
            session.cancelFilter()
            throw refuse(failure ?? "\(kind.rawValue) could not be applied.")
        }
    }

    private func adjust(_ id: UUID, _ current: LayerAdjustment, _ overrides: [String: Any]?) throws {
        guard let overrides, !overrides.isEmpty else { return }
        let value = try LensWorksAgentSettings.adjustmentMerged(current, overrides)
        guard value.isValid else { throw refuse("settings holds a value outside what that adjustment accepts.") }
        session.updateAdjustment(id, value: value)
    }

    private func colorRange(_ arguments: LensWorksAgentArguments) async throws {
        try check(.colorRange)
        let x = try arguments.required("x", try arguments.double("x")), y = try arguments.required("y", try arguments.double("y"))
        session.beginColorRange()
        guard let edit = session.colorRange else { throw refuse("Color Range could not open on this document.") }
        if let fuzziness = try arguments.double("fuzziness") { edit.fuzziness = fuzziness }
        edit.invert = try arguments.bool("invert") ?? false
        session.sampleColorRange(at: CGPoint(x: x, y: y), shift: false, option: false)
        guard edit.hasColors else { session.cancelColorRange(); throw refuse("x and y must name a pixel inside the document.") }
        let generation = edit.generation, deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while edit.settledGeneration < generation {
            guard session.colorRange === edit, ContinuousClock.now < deadline else { session.cancelColorRange(); throw refuse("Color Range did not finish.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure = edit.error { session.cancelColorRange(); throw refuse(failure) }
        session.commitColorRange()
    }

    private func resize(_ id: LensWorksCommandID, _ arguments: LensWorksAgentArguments) async throws {
        try check(id)
        guard let document = session.document else { throw refuse("Open a document first.") }
        session.cancelCrop(); session.commitTransform()
        if id == .trim {
            var options = TrimOptions()
            if let based = try arguments.string("basedOn") { options.basedOn = TrimBasedOn(rawValue: based) ?? options.basedOn }
            options.top = try arguments.bool("top") ?? true; options.bottom = try arguments.bool("bottom") ?? true
            options.left = try arguments.bool("left") ?? true; options.right = try arguments.bool("right") ?? true
            options.tolerance = UInt8(clamping: try arguments.integer("tolerance") ?? 0)
            guard options.trimsAny else { throw refuse("Trim at least one edge.") }
            _ = try await session.trim(options: options)
            return
        }
        let width = try arguments.required("width", try arguments.integer("width")), height = try arguments.required("height", try arguments.integer("height"))
        guard let snapshot = session.projectSnapshot() else { throw refuse("Open a document first.") }
        let admission = try session.captureDocumentEditAdmission()
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        if id == .canvasSize {
            let anchors = LensWorksCommandRegistry.descriptor(.canvasSize).parameters.first { $0.name == "anchor" }?.choices ?? []
            var options = CanvasSizeOptions(width: width, height: height)
            if let anchor = try arguments.string("anchor"), let index = anchors.firstIndex(of: anchor) { options.anchor = index }
            if let fill = try arguments.color("fill") { options.fill = CanvasExtensionColor(red: fill.red, green: fill.green, blue: fill.blue) }
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized, actionName: "Canvas Size", admission: admission)
        } else {
            var options = ImageSizeOptions(width: width, height: height, resolution: try arguments.double("resolution") ?? document.resolution)
            if let sampling = try arguments.string("sampling") { options.sampling = LayerSampling(rawValue: sampling) ?? options.sampling }
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized, actionName: "Image Size", admission: admission)
        }
    }

    private func transform(_ arguments: LensWorksAgentArguments) throws {
        try check(.transform)
        let names = ["x", "y", "width", "height", "rotation"]
        guard names.contains(where: arguments.has) else { throw refuse("Pass at least one of: " + names.joined(separator: ", ") + ".") }
        let tool = session.tool
        defer { session.tool = tool }
        session.beginTransform(persistent: false)
        guard var value = session.transformEdit?.draft else { throw refuse("Select a layer that can be transformed first.") }
        if let x = try arguments.double("x") { value.origin.x = x }
        if let y = try arguments.double("y") { value.origin.y = y }
        if let width = try arguments.double("width") { value.size.width = width }
        if let height = try arguments.double("height") { value.size.height = height }
        if let rotation = try arguments.double("rotation") { value.rotation = rotation }
        guard value.isValid else { session.cancelTransform(); throw refuse("That transform is outside what a layer accepts.") }
        session.previewTransform(value)
        session.commitTransform()
    }

    /// Deletes the selected layers. Where a deleted layer supplies a live mask to one that stays, the agent says
    /// what becomes of it (the menu asks the person in an alert).
    private func deleteLayers(_ arguments: LensWorksAgentArguments) async throws {
        guard let document = session.document else { return }
        let ids = document.layers.map(\.id).filter(session.selectedLayerIDs.contains)
        guard !ids.isEmpty else { throw refuse("Select a layer first.") }
        let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1).union([$1])) }
        let dependents = document.layers.filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }.map(\.id)
        var baked: [UUID: ImportedImage] = [:]
        if !dependents.isEmpty {
            guard let choice = try arguments.string("liveMasks") else {
                throw refuse("A layer being deleted supplies a live mask to a layer that stays: pass liveMasks as removeLinks or bake.")
            }
            if choice == "bake" {
                guard let snapshot = session.projectSnapshot() else { throw refuse("Open a document first.") }
                session.isProjectBusy = true
                defer { session.isProjectBusy = false }
                baked = try await Task.detached(priority: .userInitiated) {
                    var result: [UUID: ImportedImage] = [:]
                    for target in dependents { result[target] = try LiveMaskBaker.bake(snapshot, target: target) }
                    return result
                }.value
            }
        }
        session.finishDeletingLayers(ids, baked: baked)
    }

    private func addEffect(_ arguments: LensWorksAgentArguments) throws {
        try check(.addEffect)
        let name = try arguments.required("kind", try arguments.string("kind"))
        guard let kind = LayerEffectKind(rawValue: name) else { throw refuse("kind is not a layer effect.") }
        let id = try activeID()
        session.addEffect(kind)
        // The agent's settings stand in for the effects panel the menu opens.
        session.finishEffectsEditing(commit: true)
        guard let overrides = try arguments.object("settings"), !overrides.isEmpty else { return }
        let key = LensWorksAgentSettings.key(kind)
        let allowed = (LensWorksAgentSettings.json(session.activeEffects)[key] as? [String: Any])?.keys.map { $0 } ?? []
        if let stray = overrides.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw refuse("Unknown setting “\(stray.prefix(64))” for \(kind.rawValue). Its settings are: " + allowed.sorted().joined(separator: ", ") + ".")
        }
        let effects = try LensWorksAgentSettings.merged(session.activeEffects, [key: overrides])
        guard effects.isValid else { throw refuse("settings holds a value outside what that effect accepts.") }
        session.setEffects(effects, on: id, name: "Add " + kind.rawValue)
    }
}

/// The catalog commands: each finds the folder, keyword or photo the agent named on the current page, then calls
/// the catalog function its menu item calls.
struct LensWorksAgentCatalogCommands {
    let catalog: LensWorksCatalog
    let context: LensWorksAgentContext
    private func refuse(_ reason: String) -> LensWorksCommandRefusal { .init(reason: reason) }

    static func keywordID(_ keyword: LWApplicationOrganizationKeyword) -> String { keyword.path.joined(separator: "/") }
    func folder(_ arguments: LensWorksAgentArguments, _ name: String = "folder") throws -> LWApplicationOrganizationCollection {
        let id = try arguments.required(name, try arguments.string(name))
        guard let group = catalog.groups.first(where: { $0.id == id }) else { throw refuse("The virtual folder is not on the current folder page.") }
        return group
    }
    func keyword(_ arguments: LensWorksAgentArguments) throws -> LWApplicationOrganizationKeyword {
        let id = try arguments.required("keyword", try arguments.string("keyword"))
        guard let keyword = catalog.keywords.first(where: { Self.keywordID($0) == id }) else { throw refuse("The keyword is not on the current keyword page.") }
        return keyword
    }
    func photos(_ ids: [String]) throws -> [LensWorksCatalogAsset] {
        try ids.map { id in
            guard let asset = catalog.assets.first(where: { $0.id == id }) else { throw refuse("Photo \(id.prefix(64)) is not on the current catalog page.") }
            return asset
        }
    }
    private static let flags: [String: LWOrganizationFlag] = ["pick": .Pick, "reject": .Reject, "unflagged": .Unflagged]
    private static let sorts: [String: LWOrganizationSearchSort] = ["sequence": .Sequence, "capture": .Capture, "filename": .Filename, "rating": .Rating]

    /// Why `admission` cannot run on the catalog as it stands, or nil. Checked for every member before a batch runs.
    func availability(_ admission: LensWorksAgentAdmission) -> String? {
        guard catalog.catalogPath != nil else { return "Open a catalog first." }
        guard !catalog.isBusy else { return "Finish the current catalog operation first." }
        do {
            try catalog.admitCatalogWork()
            let arguments = admission.arguments
            switch admission.id {
            case .addToVirtualFolder, .removeFromVirtualFolder, .renameVirtualFolder: _ = try folder(arguments)
            case .moveVirtualFolder:
                let moved = try folder(arguments)
                if arguments.has("parent") { guard try folder(arguments, "parent").id != moved.id else { throw refuse("A virtual folder cannot move into itself.") } }
            case .showNestedKeywords: guard try keyword(arguments).kind == .Hierarchical else { throw refuse("A flat keyword has no nested keywords.") }
            case .moveKeyword: guard try keyword(arguments).kind == .Hierarchical else { throw refuse("A flat keyword cannot move under another.") }
            case .addKeyword, .removeKeyword, .renameKeyword, .addSynonym, .deleteKeyword: _ = try keyword(arguments)
            case .selectPhotos: _ = try photos(try arguments.strings("photos") ?? [])
            case .moveCatalogSelection: guard !catalog.assets.isEmpty else { throw refuse("There are no photos on the current catalog page.") }
            default: break
            }
            switch admission.id {
            case .addToVirtualFolder, .removeFromVirtualFolder, .addKeyword, .removeKeyword, .ratePhotos, .flagPhotos, .labelPhotos:
                guard catalog.selectionCount > 0 || catalog.selectedAsset != nil else { throw refuse("Select photos to organize.") }
            default: break
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func run(_ admission: LensWorksAgentAdmission) async throws {
        if let reason = availability(admission) { throw refuse(reason) }
        let arguments = admission.arguments, scope = catalog.captureScope()
        let prior = catalog.error
        catalog.error = nil
        defer { if catalog.error == nil { catalog.error = prior } }
        func choice(_ name: String) throws -> String { try arguments.required(name, try arguments.string(name)) }
        switch admission.id {
        case .addToVirtualFolder: try await catalog.setSelectedMembership(try folder(arguments))
        case .removeFromVirtualFolder: try await catalog.setSelectedMembership(try folder(arguments), remove: true)
        case .renameVirtualFolder: try await catalog.renameGroup(try folder(arguments), name: try choice("name"))
        case .moveVirtualFolder: try await catalog.placeGroup(try folder(arguments), parent: arguments.has("parent") ? try folder(arguments, "parent").id : nil)
        case .showNestedKeywords: try await catalog.enterKeyword(try keyword(arguments))
        case .addKeyword: let keyword = try keyword(arguments); try await catalog.organize(.addKeyword(keyword.path, kind: keyword.kind))
        case .removeKeyword: let keyword = try keyword(arguments); try await catalog.organize(.removeKeyword(keyword.path, kind: keyword.kind))
        case .renameKeyword: try await catalog.renameKeyword(try keyword(arguments), to: try choice("name"))
        case .moveKeyword: try await catalog.moveKeyword(try keyword(arguments), under: LensWorksCatalog.keywordPath(try choice("parent")))
        case .addSynonym: try await catalog.addKeywordSynonym(try keyword(arguments), try choice("synonym"))
        case .deleteKeyword: try await catalog.deleteKeyword(try keyword(arguments))
        case .sortBy: await catalog.setBrowseOrder(sort: Self.sorts[try choice("sort")] ?? .Sequence, direction: catalog.browseOptions.direction)
        case .sortDirection: await catalog.setBrowseOrder(sort: catalog.browseOptions.sort, direction: try choice("direction") == "descending" ? .Descending : .Ascending)
        case .ratePhotos: try await catalog.organize(.rating(UInt8(try choice("rating")) ?? 0))
        case .flagPhotos: try await catalog.organize(.flag(Self.flags[try choice("flag")] ?? .Unflagged))
        case .labelPhotos: let label = try choice("label"); try await catalog.organize(.label(label == "None" ? "" : label))
        case .moveCatalogSelection:
            let step = try choice("step")
            await catalog.moveSelection(step == "next" || step == "extendNext" ? 1 : -1, range: step.hasPrefix("extend"))
        case .selectPhotos:
            let chosen = try photos(try arguments.strings("photos") ?? [])
            let extend = try arguments.bool("extend") ?? false
            if chosen.isEmpty { if !extend { await catalog.clearSelection() } }
            for (index, asset) in chosen.enumerated() {
                let adding = extend || index > 0
                if adding, catalog.selection.contains(asset.id) { continue }
                await catalog.select(asset, extending: adding)
            }
        case .filterRating: let value = try choice("rating"); try await catalog.setFilters(rating: .some(value == "any" ? nil : UInt8(value)))
        case .filterFlag: let value = try choice("flag"); try await catalog.setFilters(flag: .some(value == "any" ? nil : Self.flags[value]))
        case .filterLabel: let value = try choice("label"); try await catalog.setFilters(label: .some(value == "any" ? nil : value))
        case .filterAnyKeyword: try await catalog.setFilters(keyword: .some(nil))
        case .clearFilters: try await catalog.clearFilters()
        default: throw refuse("\(admission.id.rawValue) is not a catalog command.")
        }
        guard catalog.scopeIsCurrent(scope) else { throw refuse("The catalog changed while the command ran.") }
        if let failure = catalog.error { catalog.error = prior; throw refuse(failure) }
    }
}

/// Project files, tabs and the catalog itself. Every path was admitted to a granted folder before this runs.
struct LensWorksAgentProjectCommands {
    let context: LensWorksAgentContext
    private func refuse(_ reason: String) -> LensWorksCommandRefusal { .init(reason: reason) }

    /// Why `id` cannot run now, or nil: the menu item's own reason, then what an agent's version also needs.
    func availability(_ id: LensWorksCommandID) -> String? {
        let session = context.session
        func menu() -> String? { session.flatMap { $0.menuReason(id, canStart: context.projects?.canStart ?? $0.canStartProjectOperation) } }
        switch id {
        case .openCatalog, .newCatalog:
            guard let catalog = context.catalog else { return "The catalog is not available." }
            return catalog.isBusy || catalog.isImporting || catalog.closingRequested ? "Finish the current catalog operation first." : nil
        case .addPhotos:
            guard let catalog = context.catalog, catalog.catalogPath != nil else { return "Open a catalog first." }
            return catalog.isBusy || catalog.isImporting ? "Finish the current catalog operation first." : nil
        case .openInEditor:
            guard let catalog = context.catalog, catalog.catalogPath != nil else { return "Open a catalog first." }
            guard let workspace = context.workspace else { return "There is no project window to open the photo in." }
            return catalog.isBusy || !workspace.canSwitch ? "Finish the current catalog or project operation first." : nil
        case .selectProjectTab:
            guard let workspace = context.workspace else { return "There is no project window." }
            return workspace.canSwitch ? nil : "Finish the current project operation first."
        case .newCanvas, .openProject, .openRecent:
            guard session != nil else { return "There is no project window." }
            if let reason = session?.menuReason(.openProject, canStart: context.projects?.canStart ?? true) { return reason }
            // Without tabs the new project replaces the open one, which only the person may discard.
            if context.workspace == nil, session?.isModified == true, session?.document != nil { return "Save the open project first: opening another would discard its unsaved changes." }
            return nil
        case .closeProject:
            guard let session, context.workspace != nil else { return "There is no project tab to close." }
            if let reason = menu() { return reason }
            return session.isModified && session.document != nil ? "Save the project first: closing it would discard its unsaved changes." : nil
        case .save:
            guard session?.document != nil else { return "Open a document first." }
            if let reason = menu() { return reason }
            return session?.projectURL == nil ? "This project has no file yet: use file.saveAs with a path." : nil
        case .saveAs, .exportPNG, .exportJPEG:
            guard session?.document != nil, context.projects != nil else { return "Open a document first." }
            return menu()
        default: return nil
        }
    }

    /// The file `admission` writes, when there is one.
    func destination(_ admission: LensWorksAgentAdmission) throws -> URL? {
        switch admission.id {
        case .save:
            guard let url = context.session?.projectURL else { return nil }
            // The project's own file is a path too: saving over it needs its folder granted.
            return try context.folders.admit(url.path)
        case .saveAs, .exportPNG, .exportJPEG:
            let url = try admission.arguments.url("path")
            let allowed: [String] = admission.id == .saveAs ? ["comp"] : admission.id == .exportPNG ? ["png"] : ["jpg", "jpeg"]
            guard allowed.contains(url.pathExtension.lowercased()) else { throw refuse("path must end in ." + allowed.joined(separator: " or .") + ".") }
            var isDirectory: ObjCBool = false
            if admission.id != .saveAs, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw refuse("path names a folder, not a file.")
            }
            return url
        default: return nil
        }
    }

    func run(_ admission: LensWorksAgentAdmission) async throws -> String {
        let id = admission.id, arguments = admission.arguments
        if let reason = availability(id) { throw refuse(reason) }
        var failure: String?
        let sink = ProjectController.agentErrorSink
        ProjectController.agentErrorSink = { failure = failure ?? $0 }
        defer { ProjectController.agentErrorSink = sink }
        func finished(_ succeeded: Bool, _ fallback: String) throws {
            if let failure { throw refuse(failure) }
            if !succeeded { throw refuse(fallback) }
        }
        switch id {
        case .newCanvas:
            let width = try arguments.required("width", try arguments.integer("width")), height = try arguments.required("height", try arguments.integer("height"))
            guard let session = context.session else { throw refuse("There is no project window.") }
            if let workspace = context.workspace {
                let tab = workspace.addTab()
                tab.session.createDocument(width: width, height: height, emptyLayer: true)
                guard tab.session.document != nil else { throw refuse("The canvas could not be created.") }
            } else {
                session.createNewProject(width: width, height: height)
                guard session.document?.width == width, session.document?.height == height else { throw refuse("The canvas could not be created.") }
            }
            return "A \(width)×\(height) canvas is open."
        case .openProject, .openRecent:
            let url = try arguments.url(id == .openRecent ? "project" : "path")
            guard url.pathExtension.lowercased() == "comp" else { throw refuse("A LensWorks project path ends in .comp.") }
            if id == .openRecent {
                guard RecentProjects.shared.urls.contains(where: { (try? LensWorksGrantedFolders.realPath($0.path)) == url.path }) else {
                    throw refuse("That project is not in Open Recent.")
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw refuse("There is no project at that path.") }
            let opened = try await context.folders.withAccess(to: url) {
                if let workspace = context.workspace { return await workspace.open(url) }
                return await context.projects?.open(url) ?? false
            }
            try finished(opened, "The project could not be opened.")
            return "The project is open."
        case .save, .saveAs:
            guard let projects = context.projects, let url = try destination(admission) else { throw refuse("Open a document first.") }
            let saved = try await context.folders.withAccess(to: url) { await projects.save(asNew: id == .saveAs, to: url) }
            try finished(saved, "The project could not be saved.")
            return "The project is saved."
        case .exportPNG, .exportJPEG:
            guard let projects = context.projects, let url = try destination(admission) else { throw refuse("Open a document first.") }
            try await context.folders.withAccess(to: url) {
                if id == .exportPNG { try await projects.exportPNG(to: url) } else {
                    var options = JPEGOptions()
                    if let quality = try arguments.double("quality") { options.quality = quality }
                    if let matte = try arguments.color("matte") { options.red = matte.red; options.green = matte.green; options.blue = matte.blue }
                    try await projects.exportJPEG(to: url, options: options)
                }
            }
            try finished(true, "")
            return "The file is written."
        case .closeProject:
            guard let workspace = context.workspace, let session = context.session,
                  let tab = workspace.tabs.first(where: { $0.session === session }) else { throw refuse("There is no project tab to close.") }
            let id = tab.id
            await workspace.close(id)
            if let failure = tab.session.commandRefusal, workspace.tabs.contains(where: { $0.id == id }), tab.session.document != nil { throw refuse(failure) }
            try finished(true, "")
            return "The project tab is closed."
        case .selectProjectTab:
            guard let workspace = context.workspace else { throw refuse("There is no project window.") }
            guard let tab = UUID(uuidString: try arguments.required("tab", try arguments.string("tab"))), workspace.tabs.contains(where: { $0.id == tab }) else {
                throw refuse("tab must be a project tab id from get_state.")
            }
            workspace.select(tab)
            guard workspace.selectedID == tab else { throw refuse("Finish the current project operation first.") }
            return "That project tab is on screen."
        case .openCatalog, .newCatalog:
            guard let catalog = context.catalog else { throw refuse("The catalog is not available.") }
            let url = try arguments.url("path")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if id == .openCatalog { guard exists, isDirectory.boolValue else { throw refuse("There is no catalog folder at that path.") } }
            else if exists {
                guard isDirectory.boolValue, (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
                    throw refuse("A new catalog needs an empty or new folder: something is already at that path.")
                }
            }
            let prior = catalog.error
            catalog.error = nil
            try await context.folders.withAccess(to: url) { await catalog.connect(url.path, create: id == .newCatalog) }
            if let failure = catalog.error { catalog.error = prior; throw refuse(failure) }
            catalog.error = prior
            guard let opened = catalog.catalogPath, (try? LensWorksGrantedFolders.realPath(opened)) == url.path else { throw refuse("The catalog could not be opened.") }
            return "The catalog is open."
        case .addPhotos:
            guard let catalog = context.catalog else { throw refuse("Open a catalog first.") }
            let url = try arguments.url("folder")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw refuse("There is no folder at that path.") }
            try await context.folders.withAccess(to: url) { try await catalog.startImport(url.path) }
            return "The folder is being added to the catalog; get_state shows the catalog when it is no longer busy."
        case .openInEditor:
            guard let catalog = context.catalog, let workspace = context.workspace else { throw refuse("There is no project window to open the photo in.") }
            let photo = try arguments.required("photo", try arguments.string("photo"))
            guard let asset = catalog.assets.first(where: { $0.id == photo }) else { throw refuse("That photo is not on the current catalog page.") }
            let scope = catalog.captureScope(), prior = catalog.error, tabs = workspace.tabs.map(\.id), shown = workspace.selectedID
            catalog.error = nil
            await catalog.select(asset)
            if catalog.scopeIsCurrent(scope), catalog.selectedAsset?.id == asset.id, catalog.error == nil {
                if let version = catalog.selectedVersions.first { await catalog.openVersion(version, workspace: workspace) }
                else { await catalog.createWorkingVersion(workspace: workspace) }
            }
            if let failure = catalog.error { catalog.error = prior; throw refuse(failure) }
            catalog.error = prior
            guard workspace.tabs.map(\.id) != tabs || workspace.selectedID != shown || workspace.current.controller.workingVersion?.photoID == asset.photoID else {
                throw refuse("The photo could not be opened in the editor.")
            }
            return "The photo is open in the editor."
        default: throw refuse("\(id.rawValue) cannot be run by an agent this way.")
        }
    }
}
