#!/usr/bin/env python3
"""Static half of the S39 command audit: fail on any menu item or keyboard shortcut that bypasses the registry.

The runtime half (CompositorTests/CommandAuditTests) walks the live main menu and the AppKit context and pull-down
menus. This scan covers what a running app cannot show without user interaction — SwiftUI context and pull-down
menus, view key bindings and key handlers — by requiring every one of them to go through the registry's binding
helpers in native/Compositor/Commands/LensWorksCommandBindings.swift, the only file exempt from these rules:

* key binding APIs (`.keyboardShortcut(`, `.onKeyPress(`, `.onExitCommand`, `.onMoveCommand`, `.onCommand(`,
  `.onDeleteCommand`) only in the binding helpers (views use `registeredCommandShortcut`, `registeredCommandKeys`,
  `registeredExitCommand`);
* AppKit menu items (`NSMenuItem(`, `addItem(withTitle:action:…)`, `insertItem(withTitle:action:…)`) only in the
  binding helpers (`LensWorksCommandRegistry.menuItem`), except an inert submenu holder or placeholder with
  `action: nil` and no key equivalent;
* inside context menus (`.contextMenu { }`, `.contextMenu(menuItems:)`, `.contextMenu(forSelectionType:)`), `Menu`,
  `CommandMenu` and `CommandGroup` blocks, items are `LensWorksCommandButton` / `LensWorksCommandToggle` /
  `LensWorksLayerCommandButton`, never a bare `Button`, `Toggle`, `Picker` or `Link` (`SwiftUI.`-qualified or not)
  — including one inside a view property, view function or View type the block refers to;
* nothing reads a raw key (`keyCode`, `charactersIgnoringModifiers`, `specialKey`, or an event's `characters`) —
  key handlers, key-event monitors and any helper they call resolve presses with
  `LensWorksCommandDispatcher.resolveKey`; and `cancelOperation(_:)` / `doCommand(by:)` overrides and `doCommandBy`
  delegates resolve the key through the dispatcher before answering. A line that must read a physical key for
  another purpose carries `// command-audit: allow <reason>`, and every allowance is printed.

usage: command_registry_audit.py [source-root]   (default native/Compositor)
"""
from __future__ import annotations

import pathlib
import re
import sys

# The registry's binding helpers: the only source allowed to call the key binding and menu item APIs directly.
BINDING_FILES = {'Commands/LensWorksCommandBindings.swift'}
ALLOW = re.compile(r'//\s*command-audit:\s*allow\s+(\S.*)$')
SWIFTUI = r'(?:(?<=SwiftUI\.)|(?<![\w.]))'
MENU_BLOCK = re.compile(r'\.contextMenu\s*(?:\{|\()|' + SWIFTUI + r'(?:CommandMenu|CommandGroup|Menu)\s*(?:\(|\{)')
MENU_ITEM = re.compile(SWIFTUI + r'(Button|Toggle|Picker|Link)\s*(?:\(|\{)')
KEY_APIS = {
    r'\.keyboardShortcut\s*\(': 'keyboard shortcut bypasses the command registry (use registeredCommandShortcut)',
    r'\.onKeyPress\s*\(': 'key press handler bypasses the command registry (use registeredCommandKeys)',
    r'\.onExitCommand\b': 'exit command handler bypasses the command registry (use registeredExitCommand)',
    r'\.onMoveCommand\b': 'move command handler bypasses the command registry (use registeredCommandKeys)',
    r'\.onCommand\s*\(': 'command handler bypasses the command registry (use a LensWorksCommandButton)',
    r'\.onDeleteCommand\b': 'delete command handler bypasses the command registry (use registeredCommandKeys)',
}
MENU_APIS = re.compile(r'\bNSMenuItem\s*\(|\b(?:addItem|insertItem)\s*\(\s*withTitle:')
SELECTOR_HANDLER = re.compile(r'override\s+func\s+(cancelOperation|doCommand)\s*\(|func\s+control\s*\([^)]*\bdoCommandBy\b')
RAW_KEY = re.compile(r'\.(keyCode|charactersIgnoringModifiers|specialKey)\b|(?i:event)[?!]?\.(characters)\b')
ANY_CHARACTERS = re.compile(r'\.(characters)\b')
TITLE = re.compile(r'"((?:[^"\\]|\\.)*)"')
VIEW_PROPERTY = re.compile(r'\bvar\s+(\w+)\s*:\s*some\s+View\s*\{')
VIEW_FUNCTION = re.compile(r'\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\([^{]*?\)\s*->\s*some\s+View\s*\{')
VIEW_TYPE = re.compile(r'\bstruct\s+(\w+)\s*(?:<[^>]*>)?\s*:\s*[^{]*\bView\b[^{]*\{')
IDENTIFIER = re.compile(r'\b(\w+)\b')
# Items that are registered commands, and the name every view defines, which a menu reference never means.
NOT_FOLLOWED = {'LensWorksCommandButton', 'LensWorksCommandToggle', 'LensWorksLayerCommandButton', 'body'}

Tree = dict[str, list[tuple[str, int, int]]]


def strip_comments(line: str) -> str:
    """The code part of a line: drop // comments outside string literals."""
    out, quoted, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != '\\'):
            quoted = not quoted
        if not quoted and line.startswith('//', i):
            break
        out.append(c)
        i += 1
    return ''.join(out)


def matching(code: str, open_index: int) -> int:
    """Index just past the bracket group opening at code[open_index] ('{' or '(')."""
    opener = code[open_index]
    closer = '}' if opener == '{' else ')'
    depth, i, quoted = 0, open_index, False
    while i < len(code):
        c = code[i]
        if c == '"' and code[i - 1] != '\\':
            quoted = not quoted
        elif not quoted and c == opener:
            depth += 1
        elif not quoted and c == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(code)


def menu_span(code: str, match: re.Match) -> tuple[int, int]:
    """Where a menu block's items live: its parenthesized arguments (menuItems:/content: closures) and its first
    trailing closure."""
    start = match.end() - 1
    if code[start] == '{':
        return start, matching(code, start)
    end = matching(code, start)
    j = end
    while j < len(code) and code[j] in ' \t':
        j += 1
    return (start, matching(code, j)) if j < len(code) and code[j] == '{' else (start, end)


def prepared(text: str) -> tuple[list[str], str]:
    lines = text.split('\n')
    return lines, '\n'.join(strip_comments(line) for line in lines)


def line_of(code: str, index: int) -> int:
    return code.count('\n', 0, index) + 1


def collect(codes: dict[str, str]) -> Tree:
    """Every view property, view function and View type: name -> [(relative path, body start, body end)]."""
    tree: Tree = {}
    for relative, code in codes.items():
        for pattern in (VIEW_PROPERTY, VIEW_FUNCTION, VIEW_TYPE):
            for match in pattern.finditer(code):
                brace = match.end() - 1
                tree.setdefault(match.group(1), []).append((relative, brace, matching(code, brace)))
    return tree


def scan_text(relative: str, text: str, codes: dict[str, str] | None = None, tree: Tree | None = None) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    allowances: list[str] = []
    lines, code = prepared(text)
    codes = codes if codes is not None else {relative: code}
    tree = tree if tree is not None else collect(codes)

    def allowed(number: int) -> re.Match | None:
        return ALLOW.search(lines[number - 1]) or (ALLOW.search(lines[number - 2]) if number > 1 else None)

    def report(index: int, problem: str) -> None:
        number = line_of(code, index)
        violations.append(f'{relative}:{number}: {problem}: {lines[number - 1].strip()}')

    if relative not in BINDING_FILES:
        for pattern, problem in KEY_APIS.items():
            for match in re.finditer(pattern, code):
                report(match.start(), problem)
        for match in MENU_APIS.finditer(code):
            statement = code[match.start():matching(code, code.index('(', match.start()))]
            if match.group(0).startswith(('addItem', 'insertItem')) and 'action:' not in statement:
                continue  # NSPopUpButton.addItem(withTitle:) adds a value choice, not a command.
            if 'action: nil' in statement and 'keyEquivalent: ""' in statement:
                continue
            title = TITLE.search(statement)
            report(match.start(), f'menu item {title.group(0) if title else ""} is not built from the command registry (use LensWorksCommandRegistry.menuItem)')
        for match in SELECTOR_HANDLER.finditer(code):
            brace = code.find('{', match.end())
            if brace >= 0 and 'LensWorksCommandDispatcher.resolve' in code[brace:matching(code, brace)]:
                continue
            report(match.start(), f'{match.group(1) or "doCommandBy"} handler answers a key command without resolving it through the command registry')
        raw_keys = list(RAW_KEY.finditer(code))
        if 'NSEvent' in code:  # A file handling events may read characters through any name.
            raw_keys += [m for m in ANY_CHARACTERS.finditer(code) if not any(r.start() <= m.start() < r.end() for r in raw_keys)]
        for raw in sorted(raw_keys, key=lambda m: m.start()):
            number = line_of(code, raw.start())
            if (allowance := allowed(number)):
                allowances.append(f'{relative}:{number}: {allowance.group(1)}')
                continue
            name = next(group for group in raw.groups() if group)
            report(raw.start(), f'key handler reads raw key .{name} instead of resolving a registered command')

    def targets(name: str, path: str, index: int) -> list[tuple[str, int, int]]:
        """The definitions a reference at codes[path][index] may mean: its own file's when it has one, else every
        file's; never the definition the reference sits in."""
        found = tree.get(name, [])
        local = [d for d in found if d[0] == path]
        return [d for d in (local or found) if not (d[0] == path and d[1] <= index < d[2])]

    def reached(name: str, path: str, index: int, visited: set[str]) -> list[str]:
        """Bare menu items inside the view property, function or type a menu block refers to, followed onward."""
        found: list[str] = []
        visited.add(name)
        for def_path, start, end in targets(name, path, index):
            body = codes[def_path]
            for item in MENU_ITEM.finditer(body, start, end):
                title = TITLE.search(body, item.end(), min(end, body.find('\n', item.end()) + 1 or end))
                found.append(f'{title.group(0) if title else item.group(1)} (in {name})')
            for reference in IDENTIFIER.finditer(body, start, end):
                inner = reference.group(1)
                if inner not in visited and inner not in NOT_FOLLOWED and inner in tree:
                    found += reached(inner, def_path, reference.start(), visited)
        return found

    seen: set[int] = set()
    for match in MENU_BLOCK.finditer(code):
        start, end = menu_span(code, match)
        for item in MENU_ITEM.finditer(code, start, end):
            if item.start() in seen:
                continue
            seen.add(item.start())
            title = TITLE.search(code, item.end(), min(end, code.find('\n', item.end()) + 1 or end))
            report(item.start(), f'menu item {title.group(0) if title else item.group(1)} is not a registered command (use LensWorksCommandButton)')
        for reference in IDENTIFIER.finditer(code, start, end):
            name = reference.group(1)
            if name in NOT_FOLLOWED or name not in tree or reference.start() in seen:
                continue
            seen.add(reference.start())
            for title in reached(name, relative, reference.start(), set()):
                report(reference.start(), f'menu item {title} is not a registered command (use LensWorksCommandButton)')
    return violations, sorted(set(allowances))


def scan(root: pathlib.Path) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    allowances: list[str] = []
    texts = {path.relative_to(root).as_posix(): path.read_text(encoding='utf-8') for path in sorted(root.rglob('*.swift'))}
    codes = {relative: prepared(text)[1] for relative, text in texts.items()}
    tree = collect(codes)
    for relative, text in texts.items():
        found, allowed = scan_text(relative, text, codes, tree)
        violations += found
        allowances += allowed
    return violations, allowances


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1] if len(argv) > 1 else 'native/Compositor')
    if not root.is_dir():
        print(f'no source root at {root}', file=sys.stderr)
        return 2
    violations, allowances = scan(root)
    for allowance in allowances:
        print(f'allowed raw key read: {allowance}')
    for violation in violations:
        print(f'::error::{violation}')
    print(f'command registry audit: {len(violations)} bypass(es), {len(allowances)} documented raw key read(s)')
    return 1 if violations else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
