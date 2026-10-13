import AppKit
import Testing
@testable import Compositor

/// S39: every menu item and keyboard shortcut is a registered command, and the audit names any that is not.
@Suite(.serialized)
@MainActor
struct CommandAuditTests {
    private func mainMenu() async throws -> NSMenu {
        for _ in 0..<50 {
            if let menu = NSApp.mainMenu, menu.items.contains(where: { $0.title == "Layer" }) { return menu }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try #require(NSApp.mainMenu)
    }
    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = self.item(title, in: submenu) { return found }
        }
        return nil
    }

    @Test func registryIsInternallyConsistent() {
        #expect(LensWorksCommandAudit.registryProblems() == [])
    }

    @Test func everyMainMenuItemAndShortcutMapsToARegisteredCommand() async throws {
        let violations = LensWorksCommandAudit.audit(mainMenu: try await mainMenu())
        #expect(violations.isEmpty, "Registry bypasses: \(violations.map(\.description).joined(separator: "; "))")
    }

    /// AC1: a menu item and a shortcut added outside the registry fail the audit, which names each.
    @Test func auditFailsNamingAnInjectedBypassingMenuItemAndShortcut() async throws {
        let menu = try await mainMenu()
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        let rogue = NSMenuItem(title: "Rogue Export…", action: Selector(("rogueExport:")), keyEquivalent: "k")
        // A registered title carrying a shortcut the registry never gave it.
        let rebound = NSMenuItem(title: "Keyboard Shortcuts…", action: Selector(("rogueShortcuts:")), keyEquivalent: "j")
        rebound.keyEquivalentModifierMask = [.command, .option]
        file.addItem(rogue); edit.addItem(rebound)
        defer { file.removeItem(rogue); edit.removeItem(rebound) }
        let violations = LensWorksCommandAudit.audit(mainMenu: menu)
        let rogueViolation = try #require(violations.first { $0.title == "Rogue Export…" })
        #expect(rogueViolation.path == "File" && rogueViolation.problem.contains("not a registered command") && rogueViolation.problem.contains("⌘K"))
        #expect(rogueViolation.description == "File › Rogue Export…: menu item is not a registered command (and its shortcut ⌘K bypasses the registry)")
        let shortcutViolation = try #require(violations.first { $0.title == "Keyboard Shortcuts…" })
        #expect(shortcutViolation.problem == "shortcut ⌥⌘J is not the registered shortcut for edit.keyboardShortcuts")
        #expect(violations.count == 2, "\(violations)")
    }

    @Test func layersPanelContextMenuItemsAreRegisteredCommandsAndDispatchThroughTheRegistry() throws {
        let session = EditorSession(); session.createDocument(width: 8, height: 8); session.addBlankLayer(); session.history.reset()
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = NSTableView(); table.addTableColumn(NSTableColumn(identifier: .init("layer")))
        table.dataSource = coordinator; table.delegate = coordinator
        coordinator.update(table)
        let menu = try #require(coordinator.contextMenu(for: 0))
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Layers Panel") == [])
        func leaves(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { $0.submenu.map(leaves) ?? ($0.isSeparatorItem ? [] : [$0]) } }
        #expect(leaves(menu).allSatisfy { $0.identifier.flatMap { LensWorksCommandInvocation(identifier: $0.rawValue) } != nil })
        // Context menus show no key equivalents, as before the registry: Duplicate Layer is not ⌘J's Layer via Copy.
        #expect(leaves(menu).allSatisfy { $0.keyEquivalent.isEmpty }, "\(leaves(menu).filter { !$0.keyEquivalent.isEmpty }.map(\.title))")
        let hide = try #require(leaves(menu).first { $0.identifier?.rawValue == LensWorksCommandID.visibility.rawValue })
        _ = (hide.target as? NSObject)?.perform(hide.action, with: hide)
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .visibility)
        #expect(session.activeLayer?.isVisible == false && session.history.undoCount == 1)
        // An unregistered item in that menu is named.
        menu.addItem(NSMenuItem(title: "Rogue Layer Action", action: Selector(("rogueLayer:")), keyEquivalent: ""))
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Layers Panel").map(\.title) == ["Rogue Layer Action"])
    }

    @Test func keyPressesResolveThroughRegisteredBindingsInEveryScope() {
        func resolve(_ key: String, _ modifiers: Int, _ scopes: Set<LensWorksShortcutScope>) -> String? {
            LensWorksCommandRegistry.resolve(ShortcutChord(key, modifiers), in: scopes, effective: false)?.identifier
        }
        #expect(resolve("b", 0, [.canvas]) == "tool.brush")
        #expect(resolve("b", 8, [.canvas]) == "tool.brush") // Shift-letter falls back to the tool key.
        #expect(resolve("u", 8, [.canvas]) == "tool.shape.cycleKind") // ...unless Shift has its own binding.
        #expect(resolve("[", 8, [.canvas]) == "brush.hardness#decrease")
        #expect(resolve("\u{f702}", 9, [.canvas]) == "canvas.movePixels#left.10")
        #expect(resolve("\u{1b}", 1, [.canvas]) == "canvas.cancel") // Esc cancels with any modifiers.
        #expect(resolve("\t", 8, [.canvas]) == nil)
        #expect(resolve("7", 0, [.canvas]) == "layer.opacityDigit#7")
        #expect(resolve("x", 0, [.catalog]) == "catalog.organize.flag#reject")
        #expect(resolve("p", 8, [.catalog]) == "catalog.organize.flag#pick")
        #expect(resolve("4", 0, [.catalog]) == "catalog.organize.rate#4")
        #expect(resolve("8", 0, [.catalog]) == "catalog.organize.label#Green")
        #expect(resolve("\u{f703}", 9, [.catalog]) == "catalog.selection.move#extendNext")
        #expect(resolve("\u{f702}", 3, [.text]) == "text.tracking#decrease.1")
        #expect(resolve("\r", 9, [.text]) == "text.finish")
        #expect(resolve("\u{f700}", 9, [.field]) == "field.step#up.10")
        #expect(resolve("p", 2, [.canvas]) == "levels.togglePreview")
        // ⌥P toggles the Levels preview with extra modifiers too, as it always has (⌘⌥P, ⌃⌥P, ⇧⌥P); P alone does not.
        #expect(resolve("p", 3, [.canvas]) == "levels.togglePreview")
        #expect(resolve("p", 6, [.canvas]) == "levels.togglePreview")
        #expect(resolve("p", 10, [.canvas]) == "levels.togglePreview")
        #expect(resolve("p", 0, [.canvas]) == nil)
        #expect(resolve("\u{1b}", 0, [.field]) == "field.cancel")
        #expect(resolve(".", 1, [.field]) == "field.cancel#commandPeriod")
        #expect(resolve("q", 0, [.canvas]) == nil)
    }

    @Test func canvasKeyDownDispatchesTheResolvedRegisteredCommand() throws {
        let session = EditorSession(); session.createDocument(width: 40, height: 20); session.addBlankLayer()
        let canvas = CanvasView(session: session)
        func press(_ key: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) throws {
            canvas.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)))
        }
        session.selectTool(.move)
        try press("e")
        #expect(session.tool == .brush && session.brushMode == .erase && LensWorksCommandDispatcher.lastInvocation == .init(.eraserTool))
        try press("V", .shift)
        #expect(session.tool == .move && LensWorksCommandDispatcher.lastInvocation == .init(.moveTool))
    }

    @Test func layersPanelShiftTabCyclesTheToolModeLikeTab() throws {
        let session = EditorSession(); session.createDocument(width: 8, height: 8)
        let table = LayerTableView(); table.session = session
        func press(_ flags: NSEvent.ModifierFlags) throws {
            table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
        }
        session.selectTool(.brush); session.brushMode = .paint
        try press([])
        #expect(session.brushMode == .erase && LensWorksCommandDispatcher.lastInvocation == .init(.cycleToolMode))
        try press(.shift)
        #expect(session.brushMode == .paint && LensWorksCommandDispatcher.lastInvocation == .init(.cycleToolMode))
    }

    @Test func fieldExitCommandsResolveToTheRegisteredCancelFieldCommand() {
        #expect(LensWorksCommandDispatcher.resolveFieldCancel()?.id == .cancelField)
        #expect(LensWorksCommandDispatcher.lastInvocation?.id == .cancelField)
    }

    /// S40 added the Settings window: its standard app-menu item is macOS's, and nothing else passes as it.
    @Test func onlyTheStandardSettingsItemIsTreatedAsTheSystemSettingsCommand() async throws {
        let menu = try await mainMenu()
        let app = try #require(menu.items.first?.submenu)
        let settings = try #require(app.items.first { $0.title == "Settings…" })
        #expect(LensWorksCommandAudit.chord(settings) == ShortcutChord(",", 1) && LensWorksCommandAudit.isSystem(settings, path: "App"))
        let rebound = NSMenuItem(title: "Settings…", action: Selector(("rogueSettings:")), keyEquivalent: "k")
        let misplaced = NSMenuItem(title: "Settings…", action: Selector(("rogueSettings:")), keyEquivalent: ",")
        let renamed = NSMenuItem(title: "Rogue Settings", action: Selector(("rogueSettings:")), keyEquivalent: ",")
        #expect(!LensWorksCommandAudit.isSystem(rebound, path: "App") && !LensWorksCommandAudit.isSystem(misplaced, path: "Edit") && !LensWorksCommandAudit.isSystem(renamed, path: "App"))
    }

    @Test func hiddenItemsThatKeepTheirKeyEquivalentAndUnidentifiedItemsInFileMenusAreAudited() async throws {
        let menu = try await mainMenu()
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        let hidden = NSMenuItem(title: "Rogue Hidden", action: Selector(("rogueHidden:")), keyEquivalent: "k")
        hidden.keyEquivalentModifierMask = [.command, .option, .control]
        hidden.isHidden = true; hidden.allowsKeyEquivalentWhenHidden = true
        let inert = NSMenuItem(title: "Hidden Placeholder", action: Selector(("rogueInert:")), keyEquivalent: "")
        inert.isHidden = true
        edit.addItem(hidden); edit.addItem(inert)
        defer { edit.removeItem(hidden); edit.removeItem(inert) }
        let recent = try #require(item("Open Recent", in: menu)?.submenu)
        let rogueRecent = NSMenuItem(title: "Rogue Recent Project", action: Selector(("rogueRecent:")), keyEquivalent: "")
        recent.insertItem(rogueRecent, at: 0)
        defer { recent.removeItem(rogueRecent) }
        let violations = LensWorksCommandAudit.audit(mainMenu: menu)
        #expect(violations.map(\.title).sorted() == ["Rogue Hidden", "Rogue Recent Project"], "\(violations)")
        #expect(violations.first { $0.title == "Rogue Recent Project" }?.path == "File/Open Recent")
        #expect(violations.first { $0.title == "Rogue Hidden" }?.problem.contains("⌃⌥⌘K") == true)
    }

    @Test func projectTabOverflowPullDownItemsAreRegisteredCommands() throws {
        let anchor = OverflowMenuAnchor.AnchorView()
        var chosen: Int?
        let menu = anchor.makeMenu([("One", { chosen = 0 }), ("Two", { chosen = 1 })])
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Project Tabs") == [])
        anchor.choose(menu.items[1])
        #expect(chosen == 1 && LensWorksCommandDispatcher.lastInvocation == .init(.selectProjectTab, "1"))
        // A tab-named item without the command's identifier is a bypass even though the menu accepts any title.
        menu.addItem(NSMenuItem(title: "Rogue Tab", action: Selector(("rogueTab:")), keyEquivalent: ""))
        #expect(LensWorksCommandAudit.audit(menu: menu, path: "Project Tabs").map(\.title) == ["Rogue Tab"])
    }

    @Test func aSavedShortcutThatNowClashesIsDroppedAloneAndNamed() {
        // A menu command saved on plain P before the catalog culling keys took P: only that one is dropped.
        let saved = ["file.save": ShortcutChord("p"), "tool.brush": ShortcutChord("y"), "file.newCanvas": ShortcutChord("n", 3)]
        #expect(ShortcutSettings.problem(in: saved) != nil)
        let loaded = ShortcutSettings.applicable(saved)
        #expect(loaded.overrides == ["tool.brush": ShortcutChord("y"), "file.newCanvas": ShortcutChord("n", 3)])
        #expect(loaded.dropped == ["Save (P)"])
        // A swap survives whichever entry comes first.
        let swapped = ShortcutSettings.applicable(["tool.brush": ShortcutChord("v"), "tool.move": ShortcutChord("y")])
        #expect(swapped.overrides.count == 2 && swapped.dropped.isEmpty)
    }

    @Test func dispatcherRefusesAnUnavailableCommandWithItsReason() {
        var ran = false
        #expect(!LensWorksCommandDispatcher.perform(.init(.save), reason: "Open a document first.") { ran = true })
        #expect(!ran && LensWorksCommandDispatcher.lastRefusal?.reason == "Open a document first.")
        #expect(LensWorksCommandDispatcher.perform(.init(.save)) { ran = true } && ran)
    }

    @Test func savedCustomShortcutsMoveFromTheirLegacyKeysAndScopesOnlyConflictWhereTheyOverlap() {
        let migrated = ShortcutSettings.migrated(["Menus:Save": ShortcutChord("s", 3), "Canvas & Layers:Brush tool": ShortcutChord("y"), "layer.visibility": ShortcutChord("h", 11)])
        #expect(migrated == ["file.save": ShortcutChord("s", 3), "tool.brush": ShortcutChord("y"), "layer.visibility": ShortcutChord("h", 11)])
        // Catalog culling keys share letters with canvas tools without conflict, but never with a menu shortcut.
        #expect(ShortcutSettings.problem(in: [:]) == nil)
        #expect(ShortcutSettings.problem(in: ["catalog.organize.flag#pick": ShortcutChord("b")]) == nil)
        #expect(ShortcutSettings.problem(in: ["catalog.organize.flag#pick": ShortcutChord("s", 1)]) != nil)
        #expect(ShortcutSettings.problem(in: ["tool.brush": ShortcutChord("v")]) != nil)
    }
}
