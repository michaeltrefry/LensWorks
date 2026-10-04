#!/usr/bin/env python3
"""Reject source/SwiftPM pin drift before building the native application."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'DEPENDENCIES.json').read_text())
for name in ('Compositor', 'PhotoCatalog'):
    item = manifest[name]
    source = root / item['source']
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != item['revision']:
        raise SystemExit(f'{name}: unexpected revision {revision}')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
        raise SystemExit(f'{name}: frozen source has local changes')
resolved = json.loads((root / 'native/Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
sparkle = next(pin for pin in resolved['pins'] if pin['identity'] == 'sparkle')
if sparkle['state']['revision'] != manifest['Sparkle']['revision']:
    raise SystemExit('Sparkle revision drift')
for name, expected in manifest.get('native_libraries', {}).items():
    actual = subprocess.check_output(['pkg-config', '--modversion', name], text=True).strip()
    if actual != expected:
        raise SystemExit(f'{name}: expected native library {expected}, found {actual}')
for name, expected in manifest.get('native_formulae', {}).items():
    actual = pathlib.Path('/opt/homebrew/opt', name).resolve().name
    if actual != expected:
        raise SystemExit(f'{name}: expected installed formula {expected}, found {actual}')
print('Frozen source and native library revisions verified; Sparkle is a baseline reference only.')
