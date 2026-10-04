#!/usr/bin/env python3
"""Adapt the pinned PhotoCatalog collector to LensWorks' Rust/Swift payload."""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys

if sys.version_info < (3, 11):
    raise SystemExit('Notice collection requires Python 3.11 or later')
import hashlib
import tomllib
import re
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--fetch', action='store_true', help='Retrieve checksum/commit-pinned official notices and corresponding sources')
args = parser.parse_args()
output = args.output.absolute()
if output.exists():
    raise SystemExit('Notice output must be a new directory')
# The retained collector uses desktop paths; supply the actual native Rust locks
# and an explicitly empty frontend lock because LensWorks has no npm payload.
stage = output.parent / (output.name + '-inputs')
if stage.exists():
    raise SystemExit('Notice input staging must be new')
(stage / 'desktop/src-tauri').mkdir(parents=True)
locks = [root / 'adapters/catalog/Cargo.lock', root / 'vendor/PhotoCatalog/Cargo.lock']
lock_bytes = {lock: lock.read_bytes() for lock in locks}
lock_hashes = {str(lock.relative_to(root)): hashlib.sha256(data).hexdigest() for lock, data in lock_bytes.items()}
manifest_bytes = {root / name: (root / name).read_bytes() for name in ('adapters/catalog/Cargo.toml', 'vendor/PhotoCatalog/Cargo.toml')}
packages = {}
graphs = []
payload_identities = set()
for manifest in ('adapters/catalog/Cargo.toml', 'vendor/PhotoCatalog/Cargo.toml'):
    command = ['cargo', 'tree', '--manifest-path', str(root / manifest), '--locked', '--offline', '--edges', 'normal,build', '--target', 'aarch64-apple-darwin', '--prefix', 'none', '--format', '{p}']
    tree = subprocess.check_output(command, text=True)
    for line in tree.splitlines():
        match = re.match(r'^(\S+) v(\S+)(?: |$)', line)
        if not match:
            raise SystemExit('Unrecognized Cargo dependency identity: ' + line)
        payload_identities.add(match.groups())
    graphs.append({'manifest': manifest, 'command': command, 'sha256': hashlib.sha256(tree.encode()).hexdigest(), 'dependency_tree': tree})
for lock in locks:
    for package in tomllib.loads(lock_bytes[lock].decode())['package']:
        identity = (package['name'], package['version'], package.get('source', ''))
        record = {key: package[key] for key in ('name', 'version', 'source', 'checksum') if key in package}
        if identity in packages and packages[identity] != record:
            raise SystemExit('Conflicting locked source/checksum: ' + str(identity))
        packages[identity] = record
excluded = [record for identity, record in sorted(packages.items()) if identity[:2] not in payload_identities]
packages = {identity: record for identity, record in packages.items() if identity[:2] in payload_identities}
if {identity[:2] for identity in packages} != payload_identities:
    raise SystemExit('Cargo payload dependency graph does not match locked identities')
# This is a notice input, never a build lock. The retained collector reads only
# the desktop lock, so inventory the union of both independently built payloads.
union = 'version = 4\n' + ''.join('\n[[package]]\n' + ''.join(key + ' = ' + json.dumps(value) + '\n' for key, value in record.items()) for _, record in sorted(packages.items()))
(stage / 'desktop/src-tauri/Cargo.lock').write_text(union)
for destination, source in [('Cargo.lock', locks[1]), ('rust-toolchain.toml', root / 'rust-toolchain.toml')]:
    shutil.copy2(source, stage / destination)
(stage / 'desktop/package-lock.json').write_text(json.dumps({'packages': {}}))
(stage / 'vendor').mkdir()
for name in ('xmp_toolkit', 'libsqlite3-sys'):
    (stage / 'vendor' / name).symlink_to(root / 'vendor/PhotoCatalog/vendor' / name, target_is_directory=True)
sysroot = subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip()
command = [sys.executable, str(root / 'vendor/PhotoCatalog/scripts/collect_desktop_notices.py'), '--checkout', str(stage), '--sdk', str(root / '.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1'), '--output', str(output), '--rust-sysroot', sysroot]
if args.fetch:
    command.append('--fetch')
result = subprocess.run(command)
report_path = output / 'inventory.json'
if not report_path.exists():
    raise SystemExit(result.returncode or 'Collector did not produce a report')
report = json.loads(report_path.read_text())
if any(path.read_bytes() != data for path, data in {**lock_bytes, **manifest_bytes}.items()):
    raise SystemExit('Payload dependency input changed during notice collection')
report['native_input_locks'] = lock_hashes
report['native_input_manifests'] = {str(path.relative_to(root)): hashlib.sha256(data).hexdigest() for path, data in manifest_bytes.items()}
report['native_dependency_graphs'] = graphs
report['excluded_lock_packages'] = {'basis': 'Not reachable through default-feature normal/build dependencies for the actual Apple-silicon payloads; development/test and other-target packages are not redistributed.', 'packages': excluded}
expected = {(record['name'] + '@' + record['version'], record.get('source'), record.get('checksum')) for record in packages.values()}
actual = {(record['identity'], record.get('source'), record.get('checksum')) for record in report['rust']}
if actual != expected:
    raise SystemExit('Collected Rust notices do not match both locked payloads')
# This absent component is intentional and directly evidenced by the empty lock;
# all other missing notices remain errors rather than a redistribution claim.
report['missing'] = [entry for entry in report['missing'] if entry.get('component') != 'frontend-dependencies']
report['native_adaptation'] = 'Union of actual default-feature Apple-silicon normal/build dependency graphs from both locked payloads; excluded lock entries recorded explicitly; no npm runtime/frontend component is linked.'
report['status'] = 'NOTICE_INVENTORY_COMPLETE' if not report['missing'] else 'NOTICE_INVENTORY_INCOMPLETE'
report_path.write_text(json.dumps(report, indent=2) + '\n')
if report['missing']:
    raise SystemExit('Missing native notice records: ' + json.dumps(report['missing']))
print('Native source notice inventory complete; final public redistribution review remains sc-24690.')
