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
                         'key handler matches raw key .keyCode'):
            self.assertIn(expected, text)
        self.assertNotIn('Holder', text)
        self.assertNotIn('openInEditor', text)
        self.assertEqual(len(violations), 6, text)
        self.assertEqual(allowances, ['UI/Rogue.swift:29: fixture reason'])

    def test_registered_items_pass_and_the_registry_itself_may_bind_keys(self):
        self.assertEqual(audit.scan_text('UI/Clean.swift', CLEAN), ([], []))
        registry = 'extension View { func k() -> some View { keyboardShortcut("k").onKeyPress(.space) { _ in .handled } } }'
        self.assertEqual(audit.scan_text('Commands/LensWorksCommandBindings.swift', '.' + registry), ([], []))
        self.assertTrue(audit.scan_text('UI/Bindings.swift', '.' + registry)[0])

    def test_every_menu_item_and_shortcut_in_the_app_passes(self):
        violations, allowances = audit.scan(ROOT)
        self.assertEqual(violations, [])
        self.assertTrue(all('EditorCanvas.swift' in allowance for allowance in allowances), allowances)

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
