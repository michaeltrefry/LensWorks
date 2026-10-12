import AppKit
import SwiftUI

/// A registered command with the parameter value one menu item or key binding supplies.
nonisolated struct LensWorksCommandInvocation: Equatable, Sendable, CustomStringConvertible {
    let id: LensWorksCommandID
    let argument: String?
    init(_ id: LensWorksCommandID, _ argument: String? = nil) { self.id = id; self.argument = argument }
    /// Stable identity for a rendered item: the command id, then `#argument` for a parameterized binding.
    var identifier: String { id.rawValue + (argument.map { "#" + $0 } ?? "") }
    var description: String { identifier }
    init?(identifier: String) {
        let parts = identifier.split(separator: "#", maxSplits: 1).map(String.init)
        guard let first = parts.first, let id = LensWorksCommandID(rawValue: first) else { return nil }
        self.init(id, parts.count > 1 ? parts[1] : nil)
    }
}

extension ShortcutChord {
    /// A key press in registry terms (stable bits: Command, Option, Control, Shift). The registry's binding helpers
    /// are the one place a physical key is read; every handler resolves the resulting chord through the dispatcher.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        let modifiers = (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
        let key: String
        switch event.keyCode {
        case 51, 117: key = "\u{7f}"
        case 36, 76: key = "\r"
        case 53: key = "\u{1b}"
        case 48: key = "\t"
        case 49: key = " "
        case 123: key = "\u{f702}"
        case 124: key = "\u{f703}"
        case 125: key = "\u{f701}"
        case 126: key = "\u{f700}"
        default:
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            key = ["{": "[", "}": "]", "+": "=", "_": "-" ][typed] ?? typed
        }
        self.init(key, modifiers)
    }
}

extension LensWorksCommandDispatcher {
    /// The Cancel Field Editing command for the key press that raised an exit command or `cancelOperation(_:)`, or
    /// nil when that press is not one of its registered keys. With no key event (an accessibility action), Escape.
    static func resolveFieldCancel() -> LensWorksCommandInvocation? {
        let chord = NSApp.currentEvent.flatMap { $0.type == .keyDown ? ShortcutChord($0) : nil } ?? ShortcutChord("\u{1b}")
        guard let invocation = resolveKey(chord, in: [.field], effective: false), invocation.id == .cancelField else { return nil }
        return invocation
    }
}

extension LensWorksCommandRegistry {
    /// The command a key press means in these scopes. `effective` compares with the user's chords; false compares with
    /// the defaults, for handlers that already translated the press back to its default (ShortcutSettings.canvasEvent).
    /// Exact chords win; then bindings that accept extra modifiers (most specific first); then bindings that ignore
    /// modifiers; and a letter pressed with Shift falls back to the same letter without it, as tool keys always have.
    @MainActor static func resolve(_ chord: ShortcutChord, in scopes: Set<LensWorksShortcutScope>, effective: Bool) -> LensWorksCommandInvocation? {
        let definitions = ShortcutDefinition.all.filter { scopes.contains($0.scope) }
        func value(_ definition: ShortcutDefinition) -> ShortcutChord { effective ? ShortcutSettings.shared.chord(definition) : definition.original }
        func invocation(_ definition: ShortcutDefinition) -> LensWorksCommandInvocation { .init(definition.commandID, definition.argument) }
        if let exact = definitions.first(where: { value($0) == chord }) { return invocation(exact) }
        let wider = definitions.filter {
            let bound = value($0)
            return $0.binding.modifierMatch == .atLeast && bound.key == chord.key && bound.modifiers & ~chord.modifiers == 0
        }.max { value($0).modifiers.nonzeroBitCount < value($1).modifiers.nonzeroBitCount }
        if let wider { return invocation(wider) }
        if let any = definitions.first(where: { $0.binding.modifierMatch == .any && value($0).key == chord.key }) { return invocation(any) }
        if chord.modifiers & 8 != 0, chord.key.count == 1, chord.key.first?.isLetter == true {
            return resolve(ShortcutChord(chord.key, chord.modifiers & ~8), in: scopes, effective: effective)
        }
        return nil
    }
    /// An AppKit menu item for a registered command: its identifier names the command, and a menu binding supplies its
    /// key equivalent, so the command audit can map every item back to the registry. Context menus pass
    /// `showsKeyEquivalent: false`: their items keep the command identity but show no shortcut, as context menus do.
    @MainActor static func menuItem(_ id: LensWorksCommandID, argument: String? = nil, title: String? = nil, target: AnyObject?, action: Selector?,
                                    showsKeyEquivalent: Bool = true) -> NSMenuItem {
        let invocation = LensWorksCommandInvocation(id, argument)
        let item = NSMenuItem(title: title ?? descriptor(id).label, action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(invocation.identifier)
        item.target = target
        if showsKeyEquivalent, let definition = ShortcutDefinition.all.first(where: { $0.isMenu && $0.commandID == id && $0.argument == argument }) {
            let chord = ShortcutSettings.shared.chord(definition)
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.cocoaModifiers
        }
        return item
    }
}

extension View {
    /// Binds a registered command's effective key. With `role`, the default chord keeps that standard role (the
    /// default button's appearance, and ⌘. for cancel); a user's custom chord replaces it.
    @ViewBuilder func registeredCommandShortcut(_ id: LensWorksCommandID, argument: String? = nil, role: KeyboardShortcut? = nil) -> some View {
        if let definition = ShortcutDefinition.all.first(where: { $0.commandID == id && $0.argument == argument }), let key = ShortcutSettings.shared.chord(definition).key.first {
            let chord = ShortcutSettings.shared.chord(definition)
            if let role, chord == definition.original { self.keyboardShortcut(role) }
            else { self.keyboardShortcut(KeyEquivalent(key), modifiers: chord.eventModifiers) }
        } else { self }
    }
    /// Escape (or ⌘.) in a focused field, resolved to the registered Cancel Field Editing command before `action` runs.
    func registeredExitCommand(perform action: @escaping () -> Void) -> some View {
        onExitCommand {
            guard let invocation = LensWorksCommandDispatcher.resolveFieldCancel() else { return }
            LensWorksCommandDispatcher.perform(invocation, action)
        }
    }
    /// Key presses on a focused SwiftUI view, resolved through the registry before `handler` acts on them.
    func registeredCommandKeys(_ scopes: Set<LensWorksShortcutScope>, handler: @escaping (LensWorksCommandInvocation, KeyPress) -> KeyPress.Result) -> some View {
        onKeyPress(phases: [.down, .repeat]) { press in
            let bits = (press.modifiers.contains(.command) ? 1 : 0) | (press.modifiers.contains(.option) ? 2 : 0)
                | (press.modifiers.contains(.control) ? 4 : 0) | (press.modifiers.contains(.shift) ? 8 : 0)
            let typed = String(press.key.character).lowercased()
            guard let invocation = LensWorksCommandDispatcher.resolveKey(ShortcutChord(typed, bits), in: scopes, effective: true) else { return .ignored }
            return handler(invocation, press)
        }
    }
}

/// A menu, context-menu or pull-down item for a registered command. The title defaults to the registered label, a
/// menu binding supplies the shortcut, and a non-nil reason disables the item, shows the reason as its tooltip and
/// refuses dispatch.
struct LensWorksCommandButton: View {
    let invocation: LensWorksCommandInvocation
    var title: String?
    var reason: String?
    var role: ButtonRole?
    let action: () -> Void
    init(_ id: LensWorksCommandID, argument: String? = nil, title: String? = nil, reason: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        invocation = .init(id, argument); self.title = title; self.reason = reason; self.role = role; self.action = action
    }
    var body: some View {
        let descriptor = LensWorksCommandRegistry.descriptor(invocation.id)
        let button = Button(role: role) { LensWorksCommandDispatcher.perform(invocation, reason: reason, action) } label: { Text(title ?? descriptor.label) }
            .disabled(reason != nil)
            .help(reason ?? "")
        if descriptor.bindings.contains(where: { $0.scope == .menu && $0.argument == invocation.argument }) {
            button.registeredCommandShortcut(invocation.id, argument: invocation.argument)
        } else { button }
    }
}

/// A checkable menu item for a registered command.
struct LensWorksCommandToggle: View {
    let invocation: LensWorksCommandInvocation
    var title: String?
    var reason: String?
    let isOn: Binding<Bool>
    init(_ id: LensWorksCommandID, argument: String? = nil, title: String? = nil, reason: String? = nil, isOn: Binding<Bool>) {
        invocation = .init(id, argument); self.title = title; self.reason = reason; self.isOn = isOn
    }
    var body: some View {
        let descriptor = LensWorksCommandRegistry.descriptor(invocation.id)
        let toggle = Toggle(title ?? descriptor.label, isOn: Binding(get: { isOn.wrappedValue }, set: { value in
            LensWorksCommandDispatcher.perform(invocation, reason: reason) { isOn.wrappedValue = value }
        }))
            .disabled(reason != nil)
            .help(reason ?? "")
        if descriptor.bindings.contains(where: { $0.scope == .menu && $0.argument == invocation.argument }) {
            toggle.registeredCommandShortcut(invocation.id, argument: invocation.argument)
        } else { toggle }
    }
}

extension EditorSession {
    /// Why a document command is unavailable: no document, a running project operation, or the command's own reason.
    func commandReason(_ disabled: Bool, _ reason: String) -> String? {
        guard disabled else { return nil }
        if document == nil { return "Open a document first." }
        if isProjectBusy || isImporting { return "Finish the current project operation first." }
        return reason
    }
}
