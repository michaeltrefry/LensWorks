#!/usr/bin/env python3
"""Static half of the S39 command audit: fail on any menu item or keyboard shortcut that bypasses the registry.

The runtime half (CompositorTests/CommandAuditTests) walks the live main menu and the AppKit context menus. This
scan covers what a running app cannot show without user interaction — SwiftUI context and pull-down menus, view
key bindings and key handlers — by requiring every one of them to go through native/Compositor/Commands:

* `.keyboardShortcut(` and `.onKeyPress(` only inside the registry (views use `registeredCommandShortcut` /
  `registeredCommandKeys`);
* `NSMenuItem(` only inside the registry (`LensWorksCommandRegistry.menuItem`), except an inert submenu holder or
  placeholder with `action: nil` and no key equivalent;
* inside `.contextMenu`, `Menu`, `CommandMenu` and `CommandGroup` blocks, items are `LensWorksCommandButton` /
  `LensWorksCommandToggle` / `LensWorksLayerCommandButton`, never a bare `Button` or `Toggle`;
* key handlers (`keyDown`/`keyUp`/`performKeyEquivalent` overrides and key-event monitors) never match raw keys
  (`keyCode`, `characters`, `specialKey`); they resolve presses with `LensWorksCommandDispatcher.resolveKey`. A line
  that must read a physical key for another purpose carries `// command-audit: allow <reason>`, and every allowance
  is printed.

usage: command_registry_audit.py [source-root]   (default native/Compositor)
"""
from __future__ import annotations

import pathlib
import re
import sys

REGISTRY_DIR = 'Commands'
ALLOW = re.compile(r'//\s*command-audit:\s*allow\s+(\S.*)$')
MENU_BLOCK = re.compile(r'\.contextMenu\s*\{|\bCommandMenu\s*\(|\bCommandGroup\s*\(|(?<![\w.])Menu\s*(\(|\{)')
MENU_ITEM = re.compile(r'(?<![\w.])(Button|Toggle)\s*(\(|\{)')
KEY_HANDLER = re.compile(r'override\s+func\s+(keyDown|keyUp|performKeyEquivalent)\s*\(with|add(Local|Global)MonitorForEvents\s*\(\s*matching:\s*([^)]*?)\)\s*\{')
RAW_KEY = re.compile(r'\.(keyCode|charactersIgnoringModifiers|characters|specialKey)\b')
TITLE = re.compile(r'"((?:[^"\\]|\\.)*)"')


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


def block_end(code: str, open_index: int) -> int:
    """Index just past the brace block opening at code[open_index] == '{'."""
    depth, i, quoted = 0, open_index, False
    while i < len(code):
        c = code[i]
        if c == '"' and code[i - 1] != '\\':
            quoted = not quoted
        elif not quoted and c == '{':
            depth += 1
        elif not quoted and c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(code)


def first_brace(code: str, start: int) -> int:
    """The `{` opening the trailing closure after a call starting at `start`, skipping its parenthesized arguments."""
    depth, i, quoted = 0, start, False
    while i < len(code):
        c = code[i]
        if c == '"' and code[i - 1] != '\\':
            quoted = not quoted
        elif not quoted and c == '(':
            depth += 1
        elif not quoted and c == ')':
            depth -= 1
        elif not quoted and c == '{' and depth == 0:
            return i
        elif not quoted and c == '\n' and depth == 0 and code[start:i].strip().endswith(')'):
            return -1
        i += 1
    return -1


def scan_text(relative: str, text: str) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    allowances: list[str] = []
    lines = text.split('\n')
    code = '\n'.join(strip_comments(line) for line in lines)
    line_of = lambda index: code.count('\n', 0, index) + 1
    in_registry = relative.split('/')[0] == REGISTRY_DIR

    def report(index: int, problem: str) -> None:
        number = line_of(index)
        violations.append(f'{relative}:{number}: {problem}: {lines[number - 1].strip()}')

    if not in_registry:
        for match in re.finditer(r'\.keyboardShortcut\s*\(', code):
            report(match.start(), 'keyboard shortcut bypasses the command registry (use registeredCommandShortcut)')
        for match in re.finditer(r'\.onKeyPress\s*\(', code):
            report(match.start(), 'key press handler bypasses the command registry (use registeredCommandKeys)')
        for match in re.finditer(r'\bNSMenuItem\s*\(', code):
            statement = code[match.start():code.find(')', match.end()) + 1]
            if 'action: nil' in statement and 'keyEquivalent: ""' in statement:
                continue
            title = TITLE.search(statement)
            report(match.start(), f'menu item {title.group(0) if title else ""} is not built from the command registry (use LensWorksCommandRegistry.menuItem)')
    seen: set[int] = set()
    for match in MENU_BLOCK.finditer(code):
        brace = code.index('{', match.start()) if code[match.end() - 1] == '{' else first_brace(code, match.end() - 1)
        if brace < 0:
            continue
        end = block_end(code, brace)
        for item in MENU_ITEM.finditer(code, brace, end):
            if item.start() in seen:
                continue
            seen.add(item.start())
            title = TITLE.search(code, item.end(), min(end, code.find('\n', item.end()) + 1 or end))
            name = title.group(0) if title else item.group(1)
            report(item.start(), f'menu item {name} is not a registered command (use LensWorksCommandButton)')
    for match in KEY_HANDLER.finditer(code):
        if match.group(3) is not None and 'keyDown' not in match.group(3) and 'keyUp' not in match.group(3):
            continue
        brace = code.index('{', match.start())
        end = block_end(code, brace)
        for raw in RAW_KEY.finditer(code, brace, end):
            number = line_of(raw.start())
            allowed = ALLOW.search(lines[number - 1]) or (number > 1 and ALLOW.search(lines[number - 2]))
            if allowed:
                allowances.append(f'{relative}:{number}: {allowed.group(1)}')
                continue
            report(raw.start(), f'key handler matches raw key .{raw.group(1)} instead of resolving a registered command')
    return violations, sorted(set(allowances))


def scan(root: pathlib.Path) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    allowances: list[str] = []
    for path in sorted(root.rglob('*.swift')):
        found, allowed = scan_text(path.relative_to(root).as_posix(), path.read_text(encoding='utf-8'))
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
