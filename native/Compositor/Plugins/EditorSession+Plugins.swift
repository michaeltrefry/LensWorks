import CoreGraphics
import Foundation
import Observation

/// A plugin filter that is running: what the progress panel shows, and what its Cancel stops.
@Observable final class LensWorksPluginRun {
    let plugin: LensWorksPluginStore.Installed
    var progress = 0.0
    /// Set once the run has lasted long enough to be worth a panel, so a quick filter never flashes one.
    var showsPanel = false
    @ObservationIgnored let cancellation = LWFloatCancellation()
    @ObservationIgnored var cancelled = false
    /// The most fuel the whole run may spend: every run's bound, or the tighter one of a run an agent started.
    let runFuel: UInt64
    init(plugin: LensWorksPluginStore.Installed, runFuel: UInt64) { self.plugin = plugin; self.runFuel = runFuel }
}

/// The values the person is choosing in a plugin's parameter sheet, one per declared parameter.
@Observable final class LensWorksPluginParameterEdit: Identifiable {
    let plugin: LensWorksPluginStore.Installed
    var values: [Double]
    init(plugin: LensWorksPluginStore.Installed) { self.plugin = plugin; values = plugin.manifest.defaults }
}

extension EditorSession {
    /// Why a plugin filter cannot run on the document as it stands, or nil when it can: the reason its Filter ›
    /// Plugins item shows and the reason an agent is refused with. `plugin` is the installed plugin's id; without
    /// one, only the document is judged.
    func pluginReason(_ plugin: String?) -> String? {
        commandReason(!canAdjustColors, "Select an editable pixel layer first.")
            ?? LensWorksCommandRegistry.unavailable(hueSaturation != nil, "Finish Hue/Saturation first.")
            // A pending transform or gradient would be applied on the way in; a plugin that then fails must leave
            // the document and its history exactly as they were, so the person finishes those first.
            ?? LensWorksCommandRegistry.unavailable(transformEdit != nil || gradientEdit != nil, "Apply or cancel the current transform or gradient first.")
            ?? plugin.flatMap { id in
                if plugins.plugin(id) != nil { return nil }
                return plugins.damaged.first { $0.id == id }.map { "The plugin \(id) cannot run. " + $0.problem } ?? "The plugin \(String(id.prefix(LensWorksPluginManifest.idLimit))) is not installed."
            }
    }

    /// Filter › Plugins: a plugin with parameters opens its sheet; one without runs at once.
    func beginPlugin(_ id: String) {
        guard pluginReason(id) == nil, pluginParameters == nil, pluginSteps == nil, let plugin = plugins.plugin(id) else { return }
        if plugin.manifest.parameters.isEmpty { Task { await runPluginReporting(id, values: []) } }
        else { pluginParameters = LensWorksPluginParameterEdit(plugin: plugin) }
    }
    /// The parameter sheet's OK.
    func commitPluginParameters() {
        guard let edit = pluginParameters else { return }
        pluginParameters = nil
        Task { await runPluginReporting(edit.plugin.id, values: edit.values) }
    }
    func cancelPluginParameters() { pluginParameters = nil }

    /// Runs a plugin for the person: a failure is shown to them, and a run they cancelled is not.
    func runPluginReporting(_ id: String, values: [Double]) async {
        do { try await runPlugin(id, values: values) }
        catch is CancellationError {}
        catch { pluginError = error.localizedDescription }
    }

    /// Stops the running plugin filter. The document is left as it was and history gains nothing.
    func cancelPlugin() {
        guard let run = pluginRun else { return }
        run.cancelled = true
        run.cancellation.cancel()
    }

    /// Runs the installed plugin `id` over the active layer's pixels (inside the selection when there is one) as
    /// one history entry. The plugin runs in the sandbox, off the main actor. Whatever goes wrong — it is not
    /// installed, its files changed, it asks for something the interface does not provide, it loops, recurses,
    /// exhausts memory, spends the whole run's budget, traps, writes outside its memory, returns something
    /// unusable, or is cancelled — throws with the document unchanged and no history entry.
    ///
    /// On a live RAW layer the run is retained on the layer's source (`LWSourceRetainedPlugin`), as a built-in
    /// filter is: the layer keeps its source, and developing the RAW again applies the plugin again.
    func runPlugin(_ id: String, values: [Double], origin: LensWorksCommandOrigin = .user, tileSide: Int = LWFloatPlane.tileSide, runFuel: UInt64? = nil) async throws {
        if let reason = pluginReason(id) { throw LensWorksCommandRefusal(reason: reason) }
        guard pluginRun == nil else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        guard let document, let layer = activeLayer, let asset = layer.asset, let listed = plugins.plugin(id),
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else {
            throw LensWorksCommandRefusal(reason: "Select an editable pixel layer first.")
        }
        func failed(_ plugin: LensWorksPluginManifest, _ error: Error) -> LensWorksPluginFailure {
            LensWorksPluginFailure("The plugin \(plugin.name) (\(plugin.id)) failed, and the document was not changed. " + error.localizedDescription)
        }
        let manifest = listed.manifest
        let parameters = values.isEmpty ? manifest.defaults : values
        guard manifest.admits(parameters) else {
            throw LensWorksCommandRefusal(reason: "The values given are not the plugin’s declared parameters, each inside its range.")
        }
        finishOpacityEdit()
        // Every run has a whole-run budget; an agent's is tighter.
        let fuel = runFuel ?? LensWorksPluginSandbox.runFuel(for: origin)
        let run = LensWorksPluginRun(plugin: listed, runFuel: fuel)
        pluginRun = run; isProjectBusy = true
        defer { pluginRun = nil; isProjectBusy = false }
        // Read from LensWorks's own copy and checked against the installed hash, off the main actor; the sandbox
        // validates it again.
        let loaded = try await plugins.load(id)
        guard loaded.plugin == listed else { throw LensWorksCommandRefusal(reason: "The plugin \(id) changed while it was being started. Run it again.") }
        let reveal = Task { [weak run] in
            try? await Task.sleep(for: .milliseconds(400))
            run?.showsPanel = true
        }
        defer { reveal.cancel() }
        let progress: @Sendable (Double) -> Void = { [weak run] value in Task { @MainActor in run?.progress = value } }
        let cancellation = run.cancellation
        let made: ImportedImage
        var retained: LWLiveSourceNode?
        do {
            let clip = try selection?.clip(canvas: document.size)
            if let source = layer.liveSource {
                guard let before = asset.linearPlane else { throw LensWorksPluginFailure("The layer’s developed pixels are not in memory.") }
                let map = try source.currentSpatialMap, transform = layer.transform, name = asset.name
                let prepared = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) { () -> (ImportedImage, LWLiveSourceNode) in
                        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
                        let registration = cancellation.register { workspace.cancellation.cancel() }
                        defer { withExtendedLifetime(registration) {} }
                        let result = try LWSourcePluginPreparation.prepare(source, before: before, map: map, plugin: loaded.plugin, module: loaded.module,
                            parameters: parameters, selection: clip, transform: transform, workspace: workspace, runFuel: fuel, progress: progress)
                        try cancellation.check(); try result.node.validateBackingAssets()
                        return (try ImportedImage(plane: result.plane, name: name), result.node)
                    }.value
                } onCancel: { cancellation.cancel() }
                made = prepared.0; retained = prepared.1
            } else {
                var job = LensWorksPluginRunner.Job(wasm: loaded.module, parameters: parameters, asset: asset, selection: clip,
                    pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height),
                    name: asset.name, cancellation: cancellation, tileSide: tileSide, runFuel: fuel)
                job.progress = progress
                made = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) { [job] in try LensWorksPluginRunner.run(job) }.value
                } onCancel: { cancellation.cancel() }
            }
        } catch {
            if run.cancelled || error is CancellationError || Task.isCancelled {
                // The person's Cancel reaches an agent's request as a refusal, and the person as nothing more.
                if origin == .agent { throw LensWorksCommandRefusal(reason: "The plugin \(manifest.name) (\(manifest.id)) was cancelled in LensWorks, and the document was not changed.") }
                throw CancellationError()
            }
            throw failed(manifest, error)
        }
        // Only write over the layer the result was computed from.
        guard !sourceClosePending, let layers = self.document?.layers, layers.indices.contains(index), case let current = layers[index], current.id == layer.id, current.asset?.image === asset.image,
              current.transform == layer.transform, current.mask == layer.mask, current.liveSource == layer.liveSource else {
            throw failed(manifest, LensWorksPluginFailure("The layer changed while the plugin ran."))
        }
        guard beginEdit(manifest.historyName) else {
            let reason = brushError; brushError = nil
            throw failed(manifest, LensWorksPluginFailure(reason ?? "The edit could not be recorded."))
        }
        if let retained {
            // A live RAW layer stays live: the same layer, its pixels replaced, the run retained on its source.
            var changed = current; changed.asset = made; changed.liveSource = retained
            self.document?.layers[index] = changed
        } else {
            // As a built-in filter leaves it: the same layer, its pixels replaced, keeping its name, placement,
            // opacity, blend mode, mask and effects. Live text or a shape becomes pixels.
            self.document?.layers[index] = ImageLayer(id: current.id, asset: made, name: current.name, isVisible: current.isVisible,
                transform: current.transform, parentID: current.parentID, isGroup: false, opacity: current.opacity, blendMode: current.blendMode,
                mask: current.mask, maskSourceID: current.maskSourceID, effects: current.effects)
        }
        endEdit()
        brushRevision += 1
    }
}

// MARK: Plugin steps retained on a live RAW layer

/// One retained plugin step of the layer the sheet is open for, and what stands in the way of applying it again.
struct LensWorksPluginStepState: Identifiable, Equatable {
    let step: LWSourceRetainedPlugin
    let problem: LWSourceRetainedPluginProblem?
    /// Whether the plugin is installed at all, so the step can be re-run with what is installed.
    let installed: Bool
    var id: UUID { step.id }
}

/// Filter › Plugins › Retained Plugin Steps…: the plugin steps retained on one live RAW layer.
@Observable final class LensWorksPluginStepsEdit: Identifiable {
    let layerID: UUID
    var steps: [LensWorksPluginStepState] = []
    /// Why the last re-run or removal did not happen.
    var error: String?
    init(layerID: UUID) { self.layerID = layerID }
}

extension EditorSession {
    /// The retained plugin steps on the active layer's live source, in the order they are applied.
    var retainedPluginSteps: [LWSourceRetainedPlugin] {
        guard let node = activeLayer?.liveSource else { return [] }
        return node.operations.compactMap { operation in
            if case .plugin(let id) = operation { return node.plugins.first { $0.id == id } }
            return nil
        }
    }
    /// Why the retained plugin steps of the selected layer cannot be listed or changed now, or nil when they can.
    var pluginStepsReason: String? {
        commandReason(!canAdjustColors || pluginRun != nil, "Select an editable pixel layer first.")
            ?? LensWorksCommandRegistry.unavailable(hueSaturation != nil || transformEdit != nil || gradientEdit != nil, "Finish the current edit first.")
            ?? LensWorksCommandRegistry.unavailable(retainedPluginSteps.isEmpty, "The selected layer has no retained plugin steps.")
    }
    /// Each retained step of the active layer held against what is installed now. The installed modules are read
    /// and hashed off the main actor.
    func pluginStepStates() async -> [LensWorksPluginStepState] {
        let steps = retainedPluginSteps, directory = plugins.directory
        return await Task.detached(priority: .userInitiated) {
            LensWorksRetainedPlugins.$directory.withValue(directory) {
                steps.map { step in
                    let problem = LensWorksRetainedPlugins.problem(step)
                    return LensWorksPluginStepState(step: step, problem: problem, installed: problem?.kind != .notInstalled)
                }
            }
        }.value
    }
    /// Filter › Plugins › Retained Plugin Steps…
    func beginPluginSteps() {
        guard pluginStepsReason == nil, pluginSteps == nil, let layer = activeLayer else { return }
        let edit = LensWorksPluginStepsEdit(layerID: layer.id)
        pluginSteps = edit
        Task { edit.steps = await pluginStepStates() }
    }
    func closePluginSteps() { pluginSteps = nil }

    /// The sheet's Remove Step: the step is dropped from the layer's source and the source developed again
    /// without it, as one history entry.
    func removePluginStep(_ id: UUID) async throws {
        if let reason = pluginStepsReason { throw LensWorksCommandRefusal(reason: reason) }
        guard let layer = activeLayer, let node = layer.liveSource, let step = node.plugins.first(where: { $0.id == id }) else {
            throw LensWorksCommandRefusal(reason: "That plugin step is not on the selected layer.")
        }
        try await redevelop(layer, to: try node.removingPlugin(id), name: "Remove Plugin Step: " + step.name)
    }
    /// The sheet's Re-run with Installed Plugin: the step is bound to the plugin as it is installed now — its
    /// module's hash and interface — with the parameter values it recorded, and the source is developed again.
    func rerunPluginStep(_ id: UUID) async throws {
        if let reason = pluginStepsReason { throw LensWorksCommandRefusal(reason: reason) }
        guard let layer = activeLayer, let node = layer.liveSource, let step = node.plugins.first(where: { $0.id == id }) else {
            throw LensWorksCommandRefusal(reason: "That plugin step is not on the selected layer.")
        }
        guard plugins.plugin(step.plugin) != nil else {
            throw LensWorksCommandRefusal(reason: plugins.damaged.first { $0.id == step.plugin }.map { "The plugin \(step.plugin) cannot run. " + $0.problem }
                ?? "The plugin \(step.plugin) is not installed. Install it, or remove the step.")
        }
        let installed = try await plugins.load(step.plugin).plugin
        guard installed.manifest.admits(step.parameters) else {
            throw LensWorksCommandRefusal(reason: "The plugin \(installed.manifest.name) (\(installed.id)) installed now does not take the parameter values this step recorded. Remove the step and run the plugin again.")
        }
        try await redevelop(layer, to: try node.replacingPlugin(step.rebound(to: installed, parameters: step.parameters)), name: "Re-run Plugin Step: " + installed.manifest.name)
    }
    /// Develops `layer`'s source again as `changed` and replaces the layer's pixels and source in one history
    /// entry. A development that fails or is cancelled leaves the layer as it was and throws the reason.
    private func redevelop(_ layer: ImageLayer, to changed: LWLiveSourceNode, name: String) async throws {
        guard !isProjectBusy, let node = layer.liveSource else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        let epoch = commandContextEpoch
        isProjectBusy = true
        defer { isProjectBusy = false; brushRevision += 1 }
        let made = try await LensWorksRetainedPlugins.$directory.withValue(plugins.directory) { try await LWSourceDeveloper.shared.evaluatePlane(changed) }
        guard !sourceClosePending, commandContextEpoch == epoch, let index = document?.layers.firstIndex(where: { $0.id == layer.id }), let current = document?.layers[index],
              current.liveSource == node, current.asset?.image === layer.asset?.image, current.transform == layer.transform, current.mask == layer.mask else {
            throw LensWorksCommandRefusal(reason: "The layer changed while its RAW was developed, so it was left as it is.")
        }
        var updated = current
        updated.asset = try ImportedImage(plane: made.surface, name: current.asset?.name ?? current.name); updated.liveSource = changed
        guard beginEdit(name) else {
            let reason = brushError; brushError = nil
            throw LensWorksCommandRefusal(reason: reason ?? "The edit could not be recorded.")
        }
        document?.layers[index] = updated
        endEdit()
    }
    /// A sheet button's action: the step is re-run or removed, the list is read again, and a failure stays in the sheet.
    @discardableResult func performPluginStep(_ change: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        Task {
            let edit = pluginSteps
            do { try await change(); edit?.error = nil }
            catch { edit?.error = error.localizedDescription }
            guard let edit, pluginSteps === edit else { return }
            edit.steps = activeLayerID == edit.layerID ? await pluginStepStates() : []
            if edit.steps.isEmpty && edit.error == nil { pluginSteps = nil }
        }
    }
}
