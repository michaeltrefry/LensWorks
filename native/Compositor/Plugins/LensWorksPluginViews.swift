import AppKit
import SwiftUI

extension LensWorksPluginStore {
    /// Settings › Plugins › Install Plugin…: the person picks a package folder. Installing code is their decision,
    /// so this is the only way a plugin arrives; no agent command reaches it.
    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a plugin package: a folder holding \(LensWorksPluginManifest.fileName) and \(LensWorksPluginManifest.moduleName). A plugin runs in a sandbox and sees only the pixels of the layer it is run on."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start { try await self.install(from: url).message }
    }
    /// Runs a store change for the settings pane, keeping what happened (or why it did not) for the person.
    func perform(_ change: @MainActor () async throws -> String) async {
        do { lastMessage = try await change(); lastError = nil }
        catch { lastError = error.localizedDescription; lastMessage = nil }
    }
    /// A button's action: the change runs without holding the window, and its result arrives in the pane.
    @discardableResult func start(_ change: @escaping @MainActor () async throws -> String) -> Task<Void, Never> {
        Task { await perform(change) }
    }
}

/// Settings › Plugins: the installed plugins with version and hash, and Install, Reload and Remove.
struct LensWorksPluginSettingsView: View {
    let store: LensWorksPluginStore
    var body: some View {
        Form {
            Section {
                Text("A filter plugin is a WebAssembly module that changes the pixels of the layer it is run on. It runs in a sandbox: it cannot read files, use the network or the clock, or see any other layer or document, and it is stopped if it runs too long or asks for too much memory. Installed plugins appear in Filter › Plugins.")
                    .font(.caption).foregroundStyle(.secondary)
                LensWorksCommandButton(.pluginInstall) { store.chooseAndInstall() }
                    .accessibilityIdentifier(LensWorksCommandID.pluginInstall.rawValue)
                if let message = store.lastMessage { Text(verbatim: message).font(.caption).textSelection(.enabled).accessibilityIdentifier("LensWorks.plugins.message") }
                if let error = store.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("LensWorks.plugins.error") }
            }
            Section("Installed") {
                if store.plugins.isEmpty && store.damaged.isEmpty { Text("No plugins are installed.").font(.caption) }
                ForEach(store.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            // The plugin's own name is only ever shown beside its id.
                            Text(verbatim: plugin.manifest.name).fontWeight(.medium)
                            Text(verbatim: plugin.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            LensWorksCommandButton(.pluginReload, argument: plugin.id) { store.start { try await store.reload(plugin.id).message } }
                            LensWorksCommandButton(.pluginRemove, argument: plugin.id, role: .destructive) {
                                store.start { try await store.remove(plugin.id); return "Removed \(plugin.manifest.name) (\(plugin.id))." }
                            }
                        }
                        Text(verbatim: "Version \(plugin.manifest.version) · interface \(plugin.manifest.interface) · \(plugin.manifest.parameters.count) parameter\(plugin.manifest.parameters.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: "SHA-256 " + plugin.moduleHash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "From " + plugin.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityIdentifier("LensWorks.plugins.row")
                }
                ForEach(store.damaged) { plugin in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: plugin.id).font(.system(.caption, design: .monospaced))
                            Text(verbatim: plugin.problem).font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        LensWorksCommandButton(.pluginRemove, argument: plugin.id, role: .destructive) { store.start { try await store.remove(plugin.id); return "Removed \(plugin.id)." } }
                    }
                }
            }
            Section("Limits") {
                let limits = LensWorksPluginSandbox.limits
                Text("Module at most \(limits.module_bytes / 1_048_576) MB · memory at most \(limits.memory_bytes / 1_048_576) MB · one table of at most \(limits.table_elements) elements · stack \(limits.stack_bytes / 1024) KB and \(limits.recursion_depth) calls deep · tiles of at most \(limits.tile_pixels) pixels · \(limits.fuel_filter_base) + \(limits.fuel_per_pixel) per pixel units of execution fuel per tile, and \(limits.fuel_run / 272_144_000) full tiles’ worth for a whole run (\(limits.fuel_run_agent / 272_144_000) when an agent starts it) · color values within ±\(limits.color_magnitude).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The parameters a plugin declares, as controls: a slider for a number, a stepper for a whole number, a switch
/// and a pop-up. Every label comes from the checked manifest; the title is LensWorks's own.
struct LensWorksPluginParameterSheet: View {
    let session: EditorSession
    @Bindable var edit: LensWorksPluginParameterEdit
    var body: some View {
        let manifest = edit.plugin.manifest
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugin Filter").font(.headline)
            HStack {
                Text(verbatim: manifest.name)
                Text(verbatim: manifest.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            ForEach(Array(manifest.parameters.enumerated()), id: \.offset) { index, parameter in
                let value = Binding(get: { edit.values[index] }, set: { edit.values[index] = $0 })
                switch parameter.kind {
                case .number:
                    HStack {
                        Text(verbatim: parameter.label).frame(width: 130, alignment: .leading)
                        Slider(value: value, in: parameter.minimum!...parameter.maximum!)
                        Text(verbatim: String(format: "%.3g", edit.values[index])).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                case .integer:
                    Stepper(value: value, in: parameter.minimum!...parameter.maximum!, step: 1) {
                        Text(verbatim: "\(parameter.label): \(LensWorksPluginManifest.plain(edit.values[index]))")
                    }
                case .boolean:
                    Toggle(isOn: Binding(get: { edit.values[index] == 1 }, set: { edit.values[index] = $0 ? 1 : 0 })) { Text(verbatim: parameter.label) }
                case .choice:
                    Picker(selection: Binding(get: { Int(edit.values[index]) }, set: { edit.values[index] = Double($0) })) {
                        ForEach(Array(parameter.choices.enumerated()), id: \.offset) { position, choice in Text(verbatim: choice).tag(position) }
                    } label: { Text(verbatim: parameter.label) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { session.cancelPluginParameters() }.registeredCommandShortcut(.cancel, role: .cancelAction)
                Button("Run") { session.commitPluginParameters() }.registeredCommandShortcut(.apply, role: .defaultAction)
            }
        }
        .padding(20).frame(width: 440)
    }
}

/// Shown while a plugin filter has been running for a moment: what is running, how far, and Cancel.
struct LensWorksPluginProgressPanel: View {
    let session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Running Plugin Filter").font(.headline)
            if let run = session.pluginRun {
                HStack {
                    Text(verbatim: run.plugin.manifest.name)
                    Text(verbatim: run.plugin.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, run.progress)))
            }
            HStack {
                Spacer()
                LensWorksCommandButton(.pluginCancel) { session.cancelPlugin() }
                    .registeredCommandShortcut(.cancel, role: .cancelAction)
                    .accessibilityIdentifier(LensWorksCommandID.pluginCancel.rawValue)
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// The plugin steps retained on a live RAW layer: each with the plugin, the hash of the code that made it and its
/// parameter values, whether it can be applied again as it stands, and Re-run and Remove.
struct LensWorksPluginStepsSheet: View {
    let session: EditorSession
    @Bindable var edit: LensWorksPluginStepsEdit
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retained Plugin Steps").font(.headline)
            Text("A plugin run on a RAW layer is kept with the layer and applied again whenever the RAW is developed, with the same plugin code and values. A step whose plugin is missing or has changed stops the layer from being developed until you re-run it with the plugin installed now, or remove it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(edit.steps) { state in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // The plugin's own name is only ever shown beside its id.
                        Text(verbatim: state.step.name).fontWeight(.medium)
                        Text(verbatim: state.step.plugin).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        LensWorksCommandButton(.pluginStepRerun, argument: state.id.uuidString,
                                               reason: state.installed ? nil : "The plugin is not installed.") { session.performPluginStep { try await session.rerunPluginStep(state.id) } }
                        LensWorksCommandButton(.pluginStepRemove, argument: state.id.uuidString, role: .destructive) { session.performPluginStep { try await session.removePluginStep(state.id) } }
                    }
                    Text(verbatim: "SHA-256 " + state.step.moduleHash).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    if !state.step.parameters.isEmpty {
                        Text(verbatim: "Values " + state.step.parameters.map(LensWorksPluginManifest.plain).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let problem = state.problem { Text(verbatim: problem.reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    else { Text("Applied again as recorded when the RAW is developed.").font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("LensWorks.plugins.step")
            }
            if let error = edit.error { Text(verbatim: error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("LensWorks.plugins.stepError") }
            HStack {
                Spacer()
                Button("Done") { session.closePluginSteps() }.registeredCommandShortcut(.cancel, role: .cancelAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}

/// What a plugin puts in front of the person in the editor window: its parameter sheet, the progress panel of a
/// run that is taking a while, and the alert that says why a run was not applied. Titles are LensWorks's own.
struct LensWorksPluginPresentation: ViewModifier {
    @Bindable var session: EditorSession
    func body(content: Content) -> some View {
        content
            .alert("The plugin filter wasn’t applied", isPresented: Binding(get: { session.pluginError != nil }, set: { if !$0 { session.pluginError = nil } })) {
                Button("OK") { session.pluginError = nil }
            } message: { Text(verbatim: session.pluginError ?? "") }
            .sheet(item: $session.pluginParameters) { edit in LensWorksPluginParameterSheet(session: session, edit: edit) }
            .sheet(item: $session.pluginSteps) { edit in LensWorksPluginStepsSheet(session: session, edit: edit) }
            .sheet(isPresented: Binding(get: { session.pluginRun?.showsPanel == true }, set: { _ in })) { LensWorksPluginProgressPanel(session: session) }
    }
}
