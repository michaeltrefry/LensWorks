import SwiftUI

struct LayerAppearanceControls: View {
    @Bindable var session: EditorSession
    let layerID: UUID?
    @State private var percentage = "100"
    @State private var stepper = ArrowStepper()
    @State private var cancellingPercentage = false
    @State private var interaction = LayerOpacityInteraction()
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Blend").font(.caption)
                BlendModePicker(session: session)
            }.disabled(!session.canEditAppearance)
            HStack(spacing: 6) {
                Text("Opacity").font(.caption)
                    .scrubbable(sensitivity: 1,
                                value: Binding<Double>(get: { (session.activeLayer?.opacity ?? 1) * 100 }, set: step),
                                range: 0...100,
                                onStart: beginInteraction,
                                onEnd: finishInteraction)
                Slider(value: Binding(get: { session.activeLayer?.opacity ?? 1 },
                                      set: { setOpacity($0) }), in: 0...1,
                       onEditingChanged: { if $0 { beginInteraction() } else { finishInteraction() } })
                HStack(spacing: 2) {
                    TextField("Opacity percent", text: $percentage)
                        .textFieldStyle(.roundedBorder).frame(width: 44).focused($focused)
                        .onSubmit { releaseFocus() }
                        .registeredExitCommand { cancellingPercentage = true; cancelInteraction(); focused = false; sync() }
                        .onChange(of: focused) { _, isFocused in
                            if isFocused { beginInteraction() }
                            else if cancellingPercentage { cancellingPercentage = false; sync() }
                            else { applyPercentage(); finishInteraction() }
                        }
                        .arrowSteps(editing: focused, stepper: stepper,
                                    value: { ((session.activeLayer?.opacity ?? 1) * 100).rounded() },
                                    change: { step($0) })
                    Text("%").font(.caption)
                }
            }
        }.padding(12).disabled(!session.canEditOpacity)
            .onAppear { sync() }
            .onChange(of: session.activeLayer?.opacity) { _, _ in if !focused { sync() } }
            .onDisappear { finishInteraction() }
            .registeredExitCommand { cancelInteraction(); sync() }
    }
    private func beginInteraction() { interaction.begin(session: session, layerID: layerID) }
    private func finishInteraction() { interaction.finish(session: session) }
    private func cancelInteraction() { interaction.cancel(session: session) }
    private func setOpacity(_ value: Double) { interaction.set(value, session: session, layerID: layerID) }
    /// Up and Down nudge the opacity by one percent, or ten with Shift.
    private func step(_ percent: Double) {
        guard session.activeLayerID == layerID else { return }
        setOpacity(min(100, max(0, percent)) / 100)
        sync()
    }
    /// Losing focus applies the value; the canvas takes the focus back so a tool's key works straight away.
    private func releaseFocus() {
        focused = false
        session.canvasFocusRequest += 1
    }
    private func sync() { percentage = String(Int(((session.activeLayer?.opacity ?? 1) * 100).rounded())) }
    private func applyPercentage() {
        guard session.activeLayerID == layerID else { return }
        if let value = Double(percentage), value.isFinite { setOpacity(value / 100) }
        sync()
    }
}

/// Owns the opacity control's registry interaction. A drag, scrub or focused
/// field opens one interaction that coalesces its changes into a single undo
/// step; a change with no interaction open (a keyboard or accessibility
/// increment) is committed on its own as one complete command.
struct LayerOpacityInteraction {
    private(set) var token: UUID?
    mutating func begin(session: EditorSession, layerID: UUID?) {
        guard token == nil, session.activeLayerID == layerID else { return }
        session.beginOpacityEdit(); token = session.commandInteraction?.token
    }
    mutating func finish(session: EditorSession) {
        guard let token else { return }
        defer { self.token = nil }
        guard session.commandInteraction?.token == token else { return }
        session.finishOpacityEdit()
    }
    mutating func cancel(session: EditorSession) {
        guard let token else { return }
        defer { self.token = nil }
        guard session.commandInteraction?.token == token else { return }
        session.cancelOpacityEdit()
    }
    mutating func set(_ value: Double, session: EditorSession, layerID: UUID?) {
        guard session.activeLayerID == layerID else { return }
        let standalone = token == nil
        if standalone { begin(session: session, layerID: layerID) }
        guard let token, session.commandInteraction?.token == token else { return }
        session.setLayerOpacity(value)
        if standalone { finish(session: session) }
    }
}
