import AppKit

/// Checks rendered menus against the command registry. Every app menu item must map to a registered command — by
/// its identifier (AppKit items built with `LensWorksCommandRegistry.menuItem`) or by its menu path and title
/// (SwiftUI command items) — and every key equivalent must be that command's registered effective chord. A
/// violation names the offending item so CI says exactly what bypassed the registry.
@MainActor enum LensWorksCommandAudit {
    struct Violation: Equatable, CustomStringConvertible {
        let path: String
        let title: String
        let problem: String
        var description: String { "\(path) › \(title): \(problem)" }
    }

    /// Standard commands macOS itself supplies (About, Services, Quit, text services, window management, full
    /// screen, Help). They are AppKit responder actions, not LensWorks actions, so they carry no registry entry.
    static let systemActions: Set<String> = [
        "orderFrontStandardAboutPanel:", "showSettingsWindow:", "terminate:", "hide:", "hideOtherApplications:",
        "unhideAllApplications:", "performClose:", "performMiniaturize:", "performZoom:", "arrangeInFront:",
        "makeKeyAndOrderFront:", "toggleFullScreen:", "toggleToolbarShown:", "runToolbarCustomizationPalette:",
        "toggleSidebar:", "toggleTabBar:", "toggleTabOverview:", "selectNextTab:", "selectPreviousTab:",
        "moveTabToNewWindow:", "mergeAllWindows:", "showHelp:", "orderFrontCharacterPalette:", "startDictation:",
        "_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:", "_handleInsertFromCreditCardsCommand:",
        "performFindPanelAction:", "centerSelectionInVisibleArea:", "showGuessPanel:", "checkSpelling:",
        "toggleContinuousSpellChecking:", "toggleGrammarChecking:", "toggleAutomaticSpellingCorrection:",
        "orderFrontSubstitutionsPanel:", "toggleSmartInsertDelete:", "toggleAutomaticQuoteSubstitution:",
        "toggleAutomaticDashSubstitution:", "toggleAutomaticLinkDetection:", "toggleAutomaticDataDetection:",
        "toggleAutomaticTextReplacement:", "uppercaseWord:", "lowercaseWord:", "capitalizeWord:", "startSpeaking:",
        "stopSpeaking:", "toggleAutomaticTextCompletion:", "showWritingTools:"
    ]
    /// Window-menu tiling items (Fill, Center, Move & Resize, Full Screen Tile) use private AppKit selectors.
    static func isSystem(_ item: NSMenuItem, path: String) -> Bool {
        guard let action = item.action.map(NSStringFromSelector) else { return false }
        if systemActions.contains(action) { return true }
        return path.hasPrefix("Window") && action.hasPrefix("_")
    }

    /// The main menu: the application menu's path is "App", every other top-level menu its title.
    static func audit(mainMenu: NSMenu) -> [Violation] {
        var violations: [Violation] = []
        var claimed: [ShortcutChord: Int] = [:]
        for (index, top) in mainMenu.items.enumerated() {
            guard let submenu = top.submenu else { continue }
            if submenu === NSApp.servicesMenu { continue }
            violations += audit(menu: submenu, path: index == 0 ? "App" : top.title, claimed: &claimed)
        }
        // Each registered menu shortcut appears on exactly one rendered item.
        for definition in ShortcutDefinition.all where definition.isMenu {
            let chord = ShortcutSettings.shared.chord(definition)
            let count = claimed[chord] ?? 0
            if count != 1 {
                violations.append(.init(path: "Registry", title: definition.title,
                    problem: "registered shortcut \(chord.label) is bound by \(count) main-menu items instead of one"))
            }
        }
        return violations
    }
    /// A context or pull-down menu built in AppKit, under `path`.
    static func audit(menu: NSMenu, path: String) -> [Violation] {
        var claimed: [ShortcutChord: Int] = [:]
        return audit(menu: menu, path: path, claimed: &claimed)
    }

    private static func audit(menu: NSMenu, path: String, claimed: inout [ShortcutChord: Int]) -> [Violation] {
        var violations: [Violation] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                if submenu === NSApp.servicesMenu { continue }
                violations += audit(menu: submenu, path: path + "/" + item.title, claimed: &claimed)
                continue
            }
            let chord = Self.chord(item)
            if let chord { claimed[chord, default: 0] += 1 }
            if isSystem(item, path: path) { continue }
            guard let command = command(for: item, path: path) else {
                violations.append(.init(path: path, title: item.title, problem: "menu item is not a registered command"
                    + (chord.map { " (and its shortcut \($0.label) bypasses the registry)" } ?? "")))
                continue
            }
            if let chord, !registeredChords(command).contains(chord) {
                violations.append(.init(path: path, title: item.title,
                    problem: "shortcut \(chord.label) is not the registered shortcut for \(command.identifier)"))
            }
        }
        return violations
    }

    /// The registered command a rendered item is: its identifier, else the one command whose menu path and titles
    /// accept it (preferring the one whose shortcut it carries, for same-titled items like View › Snap).
    static func command(for item: NSMenuItem, path: String) -> LensWorksCommandInvocation? {
        if let raw = item.identifier?.rawValue, let invocation = LensWorksCommandInvocation(identifier: raw),
           LensWorksCommandRegistry.descriptor(invocation.id).menus.contains(path) {
            return invocation
        }
        let candidates = LensWorksCommandRegistry.descriptors.filter { $0.menus.contains(path) && $0.titleMatch != .any && $0.accepts(title: item.title) }
            + LensWorksCommandRegistry.descriptors.filter { $0.menus.contains(path) && $0.titleMatch == .any }
        let chord = Self.chord(item)
        let match = candidates.first { descriptor in registeredChords(.init(descriptor.id)).contains { $0 == chord } }
            ?? candidates.first { descriptor in chord == nil && !descriptor.bindings.contains { $0.scope == .menu } }
            ?? candidates.first
        return match.map { .init($0.id) }
    }
    private static func registeredChords(_ invocation: LensWorksCommandInvocation) -> [ShortcutChord] {
        ShortcutDefinition.all.filter { $0.isMenu && $0.commandID == invocation.id }.map { ShortcutSettings.shared.chord($0) }
    }
    /// An item's key equivalent in registry terms, or nil when it has none.
    static func chord(_ item: NSMenuItem) -> ShortcutChord? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        var modifiers = (mask.contains(.command) ? 1 : 0) | (mask.contains(.option) ? 2 : 0) | (mask.contains(.control) ? 4 : 0) | (mask.contains(.shift) ? 8 : 0)
        if key != key.lowercased() { key = key.lowercased(); modifiers |= 8 }
        if key == "\u{8}" { key = "\u{7f}" }
        return ShortcutChord(key, modifiers)
    }

    /// Internal consistency: unique ids, every binding resolvable to exactly its command, and no two commands
    /// claiming the same rendered item.
    static func registryProblems() -> [String] {
        var problems: [String] = []
        let descriptors = LensWorksCommandRegistry.descriptors
        if Set(descriptors.map(\.id)) != Set(LensWorksCommandID.allCases) || Set(descriptors.map(\.id)).count != descriptors.count {
            problems.append("every command id must have exactly one descriptor")
        }
        let definitionIDs = ShortcutDefinition.all.map(\.id)
        if Set(definitionIDs).count != definitionIDs.count { problems.append("binding identities must be unique") }
        for definition in ShortcutDefinition.all {
            let resolved = LensWorksCommandRegistry.resolve(definition.original, in: [definition.scope], effective: false)
            if resolved != .init(definition.commandID, definition.argument) {
                problems.append("\(definition.title) resolves to \(resolved?.identifier ?? "nothing") instead of \(definition.id)")
            }
        }
        for descriptor in descriptors where descriptor.titleMatch == .exact {
            for title in descriptor.titles {
                let chords = descriptor.bindings.filter { $0.scope == .menu }.map(\.chord)
                let rivals = descriptors.filter { other in
                    other.id != descriptor.id && other.titleMatch == .exact && other.titles.contains(title)
                        && !Set(other.menus).isDisjoint(with: descriptor.menus)
                        && other.bindings.filter { $0.scope == .menu }.map(\.chord) == chords
                }
                if !rivals.isEmpty { problems.append("\(title) in \(descriptor.menu) is claimed by \(descriptor.id.rawValue) and \(rivals.map(\.id.rawValue))") }
            }
        }
        if let problem = ShortcutSettings.problem(in: [:]) { problems.append(problem) }
        return problems
    }
}
