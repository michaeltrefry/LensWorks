"""S39 static command audit: it names every menu item or shortcut that bypasses the registry, and the tree is clean."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ci'))
import command_registry_audit as audit

ROOT = Path(__file__).resolve().parents[2] / 'native' / 'Compositor'

BYPASSES = '''
import SwiftUI
struct RogueView: View {
    var body: some View {
        VStack {
            Button("Rogue Export") { export() }.keyboardShortcut("k", modifiers: .command)
            Text("photo").contextMenu {
                Button("Rogue Context Action") { act() }
                LensWorksCommandButton(.openInEditor) { open() }
            }
            Menu("More") {
                Toggle("Rogue Toggle", isOn: $flag)
            }
            Text("grid").onKeyPress(.space) { _ in .handled }
        }
    }
}
final class RogueMenuOwner: NSObject {
    func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Rogue Item", action: #selector(go), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Holder", action: nil, keyEquivalent: ""))
        return menu
    }
}
final class RogueView2: NSView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 40 { kill() }
        let physical = event.keyCode // command-audit: allow fixture reason
    }
}
'''

# Every way the first audit missed a bypass: each must fail naming the item or handler.
EVASIONS = {
    'context menu menuItems: closure': ('Text("a").contextMenu(menuItems: { Button("Rogue MenuItems") { act() } })', '"Rogue MenuItems"'),
    'context menu for selection type': ('List {}.contextMenu(forSelectionType: Int.self) { ids in Button("Rogue Selection") { act() } } primaryAction: { _ in }', '"Rogue Selection"'),
    'view property referenced from a menu': ('var rogueItems: some View { Button("Rogue Property") { act() } }\nvar body: some View { Text("a").contextMenu { rogueItems } }', '"Rogue Property" (in rogueItems)'),
    'view function referenced from a menu': ('func rogueRow(_ x: Int) -> some View { Toggle("Rogue Function", isOn: $f) }\nvar body: some View { Menu("M") { rogueRow(1) } }', '"Rogue Function" (in rogueRow)'),
    'view type referenced from a menu': ('struct RogueContent: View { var body: some View { Link("Rogue Type", destination: url) } }\nstruct V: View { var body: some View { Text("a").contextMenu { RogueContent() } } }', '"Rogue Type" (in RogueContent)'),
    'picker inside a menu': ('Menu("Size") { Picker("Rogue Picker", selection: $s) { Text("a") } }', '"Rogue Picker"'),
    'link inside a menu': ('Menu("Help") { Link("Rogue Link", destination: url) }', '"Rogue Link"'),
    'qualified SwiftUI button': ('Text("a").contextMenu { SwiftUI.Button("Rogue Qualified") { act() } }', '"Rogue Qualified"'),
    'NSMenu addItem withTitle': ('menu.addItem(withTitle: "Rogue AddItem", action: #selector(go), keyEquivalent: "r")', 'menu item "Rogue AddItem" is not built from the command registry'),
    'NSMenu insertItem withTitle': ('menu.insertItem(withTitle: "Rogue Insert", action: #selector(go), keyEquivalent: "", at: 0)', 'menu item "Rogue Insert" is not built from the command registry'),
    'exit command': ('TextField("a", text: $t).onExitCommand { cancel() }', 'exit command handler bypasses the command registry'),
    'move command': ('List {}.onMoveCommand { direction in move(direction) }', 'move command handler bypasses the command registry'),
    'command selector': ('Text("a").onCommand(#selector(copy(_:))) { copy() }', 'command handler bypasses the command registry'),
    'delete command': ('List {}.onDeleteCommand { delete() }', 'delete command handler bypasses the command registry'),
    'cancelOperation override': ('override func cancelOperation(_ sender: Any?) { close() }', 'cancelOperation handler answers a key command without resolving it'),
    'doCommand override': ('override func doCommand(by selector: Selector) { if selector == #selector(cancel) { close() } }', 'doCommand handler answers a key command without resolving it'),
    'doCommandBy delegate': ('func control(_ c: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool { close(); return true }', 'doCommandBy handler answers a key command without resolving it'),
    'keyDown delegating to a helper': ('override func keyDown(with event: NSEvent) { handle(event) }\nfunc handle(_ e: NSEvent) { if e.keyCode == 40 { kill() } }', 'key handler reads raw key .keyCode'),
    'helper reading characters': ('override func keyDown(with event: NSEvent) { handle(event) }\nfunc handle(_ e: NSEvent) { if e.characters == "k" { kill() } }', 'key handler reads raw key .characters'),
    'monitor with handler label': ('monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in event.charactersIgnoringModifiers == "k" ? nil : event })', 'key handler reads raw key .charactersIgnoringModifiers'),
    'current event characters': ('if NSApp.currentEvent?.characters == "k" { kill() }', 'key handler reads raw key .characters'),
    'special key in a monitor': ('NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in e.specialKey == .tab ? nil : e }', 'key handler reads raw key .specialKey'),
}

CLEAN = '''
struct CleanView: View {
    var body: some View {
        Text("photo").contextMenu { LensWorksCommandButton(.openInEditor) { open() } }
        Button("Not a menu item") { act() }
        Button("Apply") { apply() }.registeredCommandShortcut(.apply)
    }
}
'''


class CommandRegistryAuditTests(unittest.TestCase):
    def test_injected_bypassing_menu_items_and_shortcuts_fail_naming_each(self):
        violations, allowances = audit.scan_text('UI/Rogue.swift', BYPASSES)
        text = '\n'.join(violations)
        for expected in ('UI/Rogue.swift:6: keyboard shortcut bypasses the command registry',
                         'Button("Rogue Export")',
                         'menu item "Rogue Context Action" is not a registered command',
                         'menu item "Rogue Toggle" is not a registered command',
                         'key press handler bypasses the command registry',
                         'menu item "Rogue Item" is not built from the command registry',
                         'key handler reads raw key .keyCode'):
            self.assertIn(expected, text)
        self.assertNotIn('Holder', text)
        self.assertNotIn('openInEditor', text)
        self.assertEqual(len(violations), 6, text)
        self.assertEqual(allowances, ['UI/Rogue.swift:29: fixture reason'])

    def test_every_evasion_the_first_audit_missed_fails_naming_the_item(self):
        for case, (source, expected) in EVASIONS.items():
            with self.subTest(case):
                violations, _ = audit.scan_text('UI/Rogue.swift', 'import AppKit\n' + source + '\n')
                self.assertTrue(any(expected in violation for violation in violations), f'{case}: {violations}')

    def test_menu_content_reached_through_another_file_is_followed(self):
        codes = {'UI/Menu.swift': 'struct V: View { var body: some View { Text("a").contextMenu { SharedRogueItems() } } }',
                 'UI/Items.swift': 'struct SharedRogueItems: View { var body: some View { Button("Rogue Shared") { act() } } }'}
        tree = audit.collect(codes)
        violations, _ = audit.scan_text('UI/Menu.swift', codes['UI/Menu.swift'], codes, tree)
        self.assertEqual(len(violations), 1, violations)
        self.assertIn('menu item "Rogue Shared" (in SharedRogueItems) is not a registered command', violations[0])
        # A view that only holds registered items, or one used outside any menu, passes.
        codes['UI/Items.swift'] = 'struct SharedRogueItems: View { var body: some View { LensWorksCommandButton(.save) { save() } } }'
        self.assertEqual(audit.scan_text('UI/Menu.swift', codes['UI/Menu.swift'], codes, audit.collect(codes)), ([], []))

    def test_registered_items_pass_and_only_the_binding_helpers_may_bind_keys(self):
        self.assertEqual(audit.scan_text('UI/Clean.swift', CLEAN), ([], []))
        registry = ('extension View { func k() -> some View { self.keyboardShortcut("k").onKeyPress(.space) { _ in .handled }.onExitCommand { } } }\n'
                    'func chord(_ event: NSEvent) -> Int { Int(event.keyCode) }\n'
                    'let item = NSMenuItem(title: "T", action: #selector(go), keyEquivalent: "")')
        self.assertEqual(audit.scan_text('Commands/LensWorksCommandBindings.swift', '.' + registry), ([], []))
        self.assertTrue(audit.scan_text('UI/Bindings.swift', '.' + registry)[0])
        # The rest of Commands/ gets no blanket exemption.
        violations = audit.scan_text('Commands/LensWorksCommands.swift', '.' + registry)[0]
        self.assertEqual(len(violations), 5, violations)

    def test_selector_handlers_that_resolve_through_the_registry_and_value_pickers_pass(self):
        clean = ('func control(_ c: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {\n'
                 '    guard let invocation = LensWorksCommandDispatcher.resolveFieldCancel() else { return false }\n    return true\n}\n'
                 'popUp.addItem(withTitle: fontName)\nlet dither = settings.dither.characters\n'
                 'Picker("Units", selection: $unit) { Text("px") }')
        self.assertEqual(audit.scan_text('UI/Clean.swift', clean), ([], []))

    def test_every_menu_item_and_shortcut_in_the_app_passes(self):
        violations, allowances = audit.scan(ROOT)
        self.assertEqual(violations, [])
        self.assertEqual([allowance.split(':')[0] for allowance in allowances], ['Rendering/EditorCanvas.swift'] * 2, allowances)

    def test_command_line_fails_on_a_bypass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'UI').mkdir()
            (root / 'UI' / 'Rogue.swift').write_text(BYPASSES)
            self.assertEqual(audit.main(['audit', str(root)]), 1)
            (root / 'UI' / 'Rogue.swift').write_text(CLEAN)
            self.assertEqual(audit.main(['audit', str(root)]), 0)


if __name__ == '__main__':
    unittest.main()
