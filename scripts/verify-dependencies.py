#!/usr/bin/env python3
"""Reject source/SwiftPM pin drift before building the native application."""
import json
import pathlib
import subprocess
import tomllib
import catalog_source

root = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'DEPENDENCIES.json').read_text())
for name in ('Compositor',):
    item = manifest[name]
    source = root / item['source']
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != item['revision']:
        raise SystemExit(f'{name}: unexpected revision {revision}')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
        raise SystemExit(f'{name}: frozen source has local changes')
catalog_source.verify()
# The retained inference runtime: Cargo.toml and Cargo.lock must name exactly the pinned revision.
inference = manifest['inference']
cargo = (root / 'adapters/inference/Cargo.toml').read_text()
lock = (root / 'adapters/inference/Cargo.lock').read_text()
for name, revision in (('inference', inference['revision']), ('mlx-rs', inference['mlx_rs_revision'])):
    if f'rev = "{revision}"' not in cargo:
        raise SystemExit(f'{name}: adapters/inference/Cargo.toml does not pin {revision}')
pinned = [line for line in lock.splitlines() if line.startswith('source = "git+https://github.com/SceneWorks/inference')]
if not pinned or any(not line.endswith(f'#{inference["revision"]}"') for line in pinned):
    raise SystemExit('inference: Cargo.lock resolves a revision other than the pin')
# The plugin sandbox's WebAssembly runtime: exact versions in the manifest, and the same crate archives (by
# checksum) in the adapter's own lock and in the lock of the static library that links it into the app.
wasmi = manifest['wasmi']
plugins = (root / 'adapters/plugins/Cargo.toml').read_text()
if f'wasmi = {{ version = "={wasmi["version"]}"' not in plugins:
    raise SystemExit(f'wasmi: adapters/plugins/Cargo.toml does not pin ={wasmi["version"]}')
assembler = wasmi['sample_plugin_assembler']
if f'{assembler["crate"]} = "={assembler["version"]}"' not in plugins:
    raise SystemExit(f'{assembler["crate"]}: adapters/plugins/Cargo.toml does not pin ={assembler["version"]}')
for lock_path, crates in (('adapters/plugins/Cargo.lock', {**wasmi['crates'], assembler['crate']: assembler}), ('adapters/catalog/Cargo.lock', wasmi['crates'])):
    locked = tomllib.loads((root / lock_path).read_text())['package']
    for name, pin in crates.items():
        found = [package for package in locked if package['name'] == name and package['version'] == pin['version']]
        if len(found) != 1 or found[0].get('checksum') != pin['checksum'] or found[0].get('source') != 'registry+https://github.com/rust-lang/crates.io-index':
            raise SystemExit(f'{name}: {lock_path} does not lock {pin["version"]} with the pinned checksum')
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
print('Compositor pin, inference pin, owned catalog source digest and native library revisions verified; Sparkle is a baseline reference only.')
