import AppKit
import SwiftUI

struct ShortcutChord: Codable, Equatable, Hashable {
    var key: String
    var modifiers: Int
    init(_ key: String, _ modifiers: Int = 0) { self.key = key; self.modifiers = modifiers }
    var eventModifiers: EventModifiers {
        var flags: EventModifiers = []
        if modifiers & 1 != 0 { flags.insert(.command) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.command) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }
    var label: String {
        let special = ["\u{7f}": "Delete", "\r": "Return", "\u{1b}": "Esc", "\t": "Tab", " ": "Space",
                       "\u{f702}": "←", "\u{f703}": "→", "\u{f701}": "↓", "\u{f700}": "↑"]
        return (modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
            + (modifiers & 8 != 0 ? "⇧" : "") + (modifiers & 1 != 0 ? "⌘" : "")
            + (special[key] ?? key.uppercased())
    }
    func event(like event: NSEvent) -> NSEvent? {
        let codes: [String: UInt16] = ["\u{7f}": 51, "\r": 36, "\u{1b}": 53, "\t": 48, " ": 49,
                                       "\u{f702}": 123, "\u{f703}": 124, "\u{f701}": 125, "\u{f700}": 126,
                                       "=": 24, "-": 27]
        let shifted = modifiers & 8 != 0 ? (["[": "{", "]": "}", "=": "+", "-": "_"][key] ?? key) : key
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: cocoaModifiers,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: shifted, charactersIgnoringModifiers: shifted, isARepeat: event.isARepeat,
            keyCode: codes[key] ?? 0xffff)
    }
}

/// One key binding from the command registry: every shortcut the app answers is a registered command's binding.
struct ShortcutDefinition: Identifiable {
    let commandID: LensWorksCommandID
    let binding: LensWorksCommandBinding
    var title: String { binding.title }
    var scope: LensWorksShortcutScope { binding.scope }
    var group: String { scope.rawValue }
    var argument: String? { binding.argument }
    var original: ShortcutChord { ShortcutChord(binding.chord.key, binding.chord.modifiers) }
    var id: String { LensWorksCommandInvocation(commandID, argument).identifier }
    /// The key saved custom shortcuts used before every binding became a registered command.
    var legacyID: String { group + ":" + title }
    var isMenu: Bool { scope == .menu }

    static let all: [ShortcutDefinition] = LensWorksCommandRegistry.descriptors.flatMap { descriptor in
        descriptor.bindings.map { ShortcutDefinition(commandID: descriptor.id, binding: $0) }
    }
}

@MainActor @Observable
final class ShortcutSettings {
    static let shared = ShortcutSettings()
    private(set) var overrides: [String: ShortcutChord] = [:]
    /// Saved custom shortcuts not applied at launch because they now clash with another binding, as "title (chord)".
    private(set) var droppedOverrides: [String] = []
    @ObservationIgnored private let panel = FloatingPanelController(name: "keyboardShortcuts")
    private static let storageKey = "keyboardShortcuts.v1"
    private init() {
        if let data = LensWorksUserState.defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: ShortcutChord].self, from: data) {
            (overrides, droppedOverrides) = Self.applicable(Self.migrated(stored))
            if !droppedOverrides.isEmpty { NSLog("Keyboard shortcuts: custom shortcuts not applied: %@", droppedOverrides.joined(separator: ", ")) }
        }
    }
    /// The saved custom shortcuts that can still apply: each one is kept unless it clashes with the defaults or the
    /// ones already kept (a binding added since it was saved, say), so one clash drops only that shortcut. Returns the
    /// dropped ones as "title (chord)".
    static func applicable(_ saved: [String: ShortcutChord]) -> (overrides: [String: ShortcutChord], dropped: [String]) {
        var kept: [String: ShortcutChord] = [:]
        var pending = ShortcutDefinition.all.filter { saved[$0.id] != nil }
        // Repeat until nothing more fits, so a swap (A takes B's key, B moves on) survives in either order.
        var progressed = true
        while progressed {
            progressed = false
            pending.removeAll { definition in
                var candidate = kept
                candidate[definition.id] = saved[definition.id]
                guard problem(in: candidate) == nil else { return false }
                kept = candidate; progressed = true
                return true
            }
        }
        return (kept, pending.map { "\($0.title) (\(saved[$0.id]!.label))" })
    }
    func chord(_ definition: ShortcutDefinition) -> ShortcutChord { overrides[definition.id] ?? definition.original }
    /// Saved chords keyed by the pre-registry "Group:Title" identities move to their registered command identities.
    static func migrated(_ stored: [String: ShortcutChord]) -> [String: ShortcutChord] {
        var result: [String: ShortcutChord] = [:]
        for definition in ShortcutDefinition.all where definition.binding.configurable {
            if let chord = stored[definition.id] ?? stored[definition.legacyID] { result[definition.id] = chord }
        }
        return result
    }
    func show() {
        panel.show(title: "Keyboard Shortcuts", content: KeyboardShortcutsSheet(settings: self))
    }
    func close() { panel.close() }
    func save(_ values: [String: ShortcutChord]) {
        guard Self.problem(in: values) == nil, let data = try? JSONEncoder().encode(values) else { return }
        overrides = values
        LensWorksUserState.defaults.set(data, forKey: Self.storageKey)
        close()
    }
    static func problem(in values: [String: ShortcutChord]) -> String? {
        var assigned: [ShortcutChord: [(scope: LensWorksShortcutScope, title: String)]] = [:]
        for definition in ShortcutDefinition.all where definition.binding.configurable {
            let chord = values[definition.id] ?? definition.original
            guard chord.key.count == 1, (0...15).contains(chord.modifiers) else { return "Choose a single key with optional modifiers." }
            if definition.group == "Text Editing", chord.modifiers & 7 == 0 {
                return "Text-editing shortcuts need Command, Option, or Control so they do not replace normal typing."
            }
            if [ShortcutChord("q", 1), ShortcutChord(",", 1), ShortcutChord("m", 3)].contains(chord) {
                return "\(chord.label) is reserved by macOS."
            }
            if let other = assigned[chord]?.first(where: { $0.scope.overlaps(definition.scope) }) {
                return "\(chord.label) is assigned to both \(other.title) and \(definition.title)."
            }
            assigned[chord, default: []].append((definition.scope, definition.title))
        }
        return nil
    }

    /// Translate only at the existing canvas/layer responder boundary. Native text
    /// fields and dialog controls retain their normal typing and navigation behavior.
    func canvasEvent(_ event: NSEvent) -> NSEvent? {
        guard !overrides.isEmpty else { return event }
        let input = ShortcutChord(event)
        if let definition = ShortcutDefinition.all.first(where: { $0.scope == .canvas && chord($0) == input }) {
            return definition.original == input ? event : definition.original.event(like: event)
        }
        if ShortcutDefinition.all.contains(where: { ($0.scope == .menu || $0.scope == .canvas) && $0.original == input && chord($0) != input }) { return nil }
        // Letter tool shortcuts traditionally also accept Shift. Follow the base
        // assignment unless Shift has its own explicit command (e.g. cycle shape).
        if input.modifiers == 8 {
            let plain = ShortcutChord(input.key)
            if let definition = ShortcutDefinition.all.first(where: { $0.scope == .canvas && $0.original.modifiers == 0 && chord($0) == plain }) {
                return ShortcutChord(definition.original.key, 8).event(like: event)
            }
            if ShortcutDefinition.all.contains(where: { $0.scope == .canvas && $0.original == plain && chord($0) != plain }) { return nil }
        }
        return event
    }

    func textEvent(_ event: NSEvent) -> NSEvent? {
        guard !overrides.isEmpty else { return event }
        let definitions = ShortcutDefinition.all.filter { $0.scope == .text || ($0.scope == .canvas && $0.original == ShortcutChord("\u{1b}")) }
        let input = ShortcutChord(event)
        if let definition = definitions.first(where: { chord($0) == input }) {
            return definition.original == input ? event : definition.original.event(like: event)
        }
        if definitions.contains(where: { $0.original == input && chord($0) != input }) { return nil }
        return event
    }
}

private struct KeyboardShortcutsSheet: View {
    let settings: ShortcutSettings
    @State private var draft: [String: ShortcutChord]
    @State private var search = ""
    @State private var recording: String?
    init(settings: ShortcutSettings) { self.settings = settings; _draft = State(initialValue: settings.overrides) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click a shortcut, then press its new key combination. Changes apply when you save.")
                .foregroundStyle(.secondary)
            if !settings.droppedOverrides.isEmpty {
                Text("These saved shortcuts clash with newer ones and were reset to their defaults: " + settings.droppedOverrides.joined(separator: ", ") + ".")
                    .foregroundStyle(.orange)
            }
            TextField("Search shortcuts", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(["Menus", "Canvas & Layers", "Text Editing", "Catalog"], id: \.self) { group in
                        Text(group).font(.headline).padding(.top, 8)
                        ForEach(ShortcutDefinition.all.filter { $0.group == group && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { definition in
                            HStack {
                                Text(definition.title)
                                Spacer()
                                ShortcutRecorder(chord: draft[definition.id] ?? definition.original,
                                    recording: recording == definition.id,
                                    start: { recording = definition.id },
                                    finish: { chord in
                                        if let chord { draft[definition.id] = chord }
                                        recording = nil
                                    })
                                    .frame(width: 150, height: 26)
                            }
                        }
                    }
                    Divider().padding(.vertical, 8)
                    Text("Contextual keys & mouse gestures").font(.headline)
                    Text("Text fields keep standard macOS editing keys. Dialogs share the Apply/Cancel assignments above. Numeric fields use Up/Down, with Shift for larger steps. Standard macOS commands include ⌘Q to quit and ⌃⌘F for full screen. The shortcut editor itself always uses Return to save and Esc to cancel when not recording.")
                    Text("Option temporarily selects the eyedropper in painting tools. Shift constrains shapes/movement or adds to a selection; Option subtracts from selections or draws from center. Command-drag moves selected pixels; Command-Option-drag copies them. Option-drag duplicates layers/folders/effects; Option-click at a layer boundary toggles clipping. Command-click a thumbnail loads its selection. Control bypasses snapping. Right-drag adjusts brush size. Modifier-and-mouse gestures are fixed.")
                }.padding(.trailing, 8)
            }.frame(height: 465)
            // Only a conflict takes room here; an empty line left a wide gap above the buttons.
            if let problem = ShortcutSettings.problem(in: draft) {
                Text(problem)
                    .foregroundStyle(.orange).font(.callout).lineLimit(2)
                    .frame(height: 22, alignment: .topLeading)
            }
            Divider()
            HStack {
                Button("Restore Defaults") { recording = nil; draft = [:] }
                Spacer()
                Button("Cancel") { LensWorksCommandDispatcher.perform(.init(.cancelShortcuts)) { settings.close() } }
                    .registeredCommandShortcut(.cancelShortcuts, role: .cancelAction)
                Button("Save") { LensWorksCommandDispatcher.perform(.init(.saveShortcuts)) { settings.save(draft) } }
                    .registeredCommandShortcut(.saveShortcuts, role: .defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(recording != nil || ShortcutSettings.problem(in: draft) != nil)
            }
        }.padding(24).frame(width: 660).fixedSize()
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let chord: ShortcutChord
    let recording: Bool
    let start: () -> Void
    let finish: (ShortcutChord?) -> Void
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.start = start; button.finish = finish; button.recording = recording
        button.title = recording ? "Press keys…" : chord.label
        button.setAccessibilityLabel(recording ? "Press a shortcut" : chord.label)
        if recording, button.window?.firstResponder !== button { button.window?.makeFirstResponder(button) }
    }
    final class RecorderButton: NSButton {
        var start: (() -> Void)?
        var finish: ((ShortcutChord?) -> Void)?
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded; target = self; action = #selector(beginRecording)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func beginRecording() { window?.makeFirstResponder(self); recording = true; start?() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let chord = ShortcutChord(event)
            guard chord.key.count == 1 else { NSSound.beep(); return }
            recording = false
            finish?(chord)
            window?.makeFirstResponder(nil)
        }
    }
}
