import SwiftUI

struct LayerAppearanceControls: View {
    @Bindable var session: EditorSession
    let layerID: UUID?
    @State private var percentage = "100"
    @State private var stepper = ArrowStepper()
    @State private var cancellingPercentage = false
    @State private var interactionToken: UUID?
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
                        .onExitCommand { cancellingPercentage = true; cancelInteraction(); focused = false; sync() }
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
            .onExitCommand { cancelInteraction(); sync() }
    }
    private func beginInteraction() {
        guard interactionToken == nil, session.activeLayerID == layerID else { return }
        session.beginOpacityEdit(); interactionToken = session.commandInteraction?.token
    }
    private func finishInteraction() {
        guard let token = interactionToken else { return }
        defer { interactionToken = nil }
        guard session.commandInteraction?.token == token else { return }
        session.finishOpacityEdit()
    }
    private func cancelInteraction() {
        guard let token = interactionToken else { return }
        defer { interactionToken = nil }
        guard session.commandInteraction?.token == token else { return }
        session.cancelOpacityEdit()
    }
    private func setOpacity(_ value: Double) {
        if interactionToken == nil { beginInteraction() }
        guard let token = interactionToken, session.commandInteraction?.token == token,
              session.activeLayerID == layerID else { return }
        session.setLayerOpacity(value)
    }
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
