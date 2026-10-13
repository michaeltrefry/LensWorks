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
    init(plugin: LensWorksPluginStore.Installed) { self.plugin = plugin }
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
        guard pluginReason(id) == nil, pluginParameters == nil, let plugin = plugins.plugin(id) else { return }
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
    /// exhausts memory, traps, writes outside its memory, returns something unusable, or is cancelled — throws
    /// with the document unchanged and no history entry.
    func runPlugin(_ id: String, values: [Double], origin: LensWorksCommandOrigin = .user, tileSide: Int = LWFloatPlane.tileSide) async throws {
        if let reason = pluginReason(id) { throw LensWorksCommandRefusal(reason: reason) }
        guard pluginRun == nil else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        guard let document, let layer = activeLayer, let asset = layer.asset,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else {
            throw LensWorksCommandRefusal(reason: "Select an editable pixel layer first.")
        }
        func failed(_ plugin: LensWorksPluginManifest, _ error: Error) -> LensWorksPluginFailure {
            LensWorksPluginFailure("The plugin \(plugin.name) (\(plugin.id)) failed, and the document was not changed. " + error.localizedDescription)
        }
        // Read from LensWorks's own copy and checked against the installed hash; the sandbox validates it again.
        let loaded = try plugins.load(id)
        let manifest = loaded.plugin.manifest
        let parameters = values.isEmpty ? manifest.defaults : values
        guard manifest.admits(parameters) else {
            throw LensWorksCommandRefusal(reason: "The values given are not the plugin’s declared parameters, each inside its range.")
        }
        finishOpacityEdit()
        let run = LensWorksPluginRun(plugin: loaded.plugin)
        pluginRun = run; isProjectBusy = true
        defer { pluginRun = nil; isProjectBusy = false }
        let reveal = Task { [weak run] in
            try? await Task.sleep(for: .milliseconds(400))
            run?.showsPanel = true
        }
        defer { reveal.cancel() }
        let made: ImportedImage
        do {
            var job = LensWorksPluginRunner.Job(wasm: loaded.module, parameters: parameters, asset: asset, selection: try selection?.clip(canvas: document.size),
                pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height),
                name: asset.name, cancellation: run.cancellation, tileSide: tileSide)
            job.progress = { [weak run] value in Task { @MainActor in run?.progress = value } }
            let cancellation = run.cancellation
            made = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) { [job] in try LensWorksPluginRunner.run(job) }.value
            } onCancel: { cancellation.cancel() }
        } catch {
            if run.cancelled || error is CancellationError || Task.isCancelled {
                // The person's Cancel reaches an agent's request as a refusal, and the person as nothing more.
                if origin == .agent { throw LensWorksCommandRefusal(reason: "The plugin \(manifest.name) (\(manifest.id)) was cancelled in LensWorks, and the document was not changed.") }
                throw CancellationError()
            }
            throw failed(manifest, error)
        }
        // Only write over the layer the result was computed from.
        guard let layers = self.document?.layers, layers.indices.contains(index), case let current = layers[index], current.id == layer.id, current.asset?.image === asset.image,
              current.transform == layer.transform, current.mask == layer.mask else {
            throw failed(manifest, LensWorksPluginFailure("The layer changed while the plugin ran."))
        }
        guard beginEdit(manifest.historyName) else {
            let reason = brushError; brushError = nil
            throw failed(manifest, LensWorksPluginFailure(reason ?? "The edit could not be recorded."))
        }
        // As a built-in filter leaves it: the same layer, its pixels replaced; a live source or live text becomes pixels.
        self.document?.layers[index] = ImageLayer(id: current.id, asset: made, name: current.name, isVisible: current.isVisible,
            transform: current.transform, parentID: current.parentID, isGroup: false, opacity: current.opacity, blendMode: current.blendMode,
            mask: current.mask, maskSourceID: current.maskSourceID, effects: current.effects)
        endEdit()
        brushRevision += 1
    }
}
