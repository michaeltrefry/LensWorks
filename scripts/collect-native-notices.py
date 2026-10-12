#!/usr/bin/env python3
"""Adapt the pinned PhotoCatalog collector to LensWorks' Rust/Swift payload."""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
from native_notice_reuse import reuse_native_notices, reuse_crate_notices

if sys.version_info < (3, 11):
    raise SystemExit('Notice collection requires Python 3.11 or later')
import hashlib
import tomllib
import re
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--fetch', action='store_true', help='Retrieve checksum/commit-pinned official notices and corresponding sources')
parser.add_argument('--reuse-native-notices', type=pathlib.Path, help='Reuse only matching aom/VMAF/LibRaw obligations from a prior complete native inventory')
parser.add_argument('--reuse-inventory-sha256', help='Explicit SHA256 of the prior inventory.json')
parser.add_argument('--reuse-manifest-sha256', help='Explicit SHA256 of the prior manifest.json')
parser.add_argument('--reuse-crate-notices', action='store_true', help='Also verify and reuse exact prior zune-core@0.4.12 / zune-jpeg@0.4.21 upstream notices against current cached crate archives')
args = parser.parse_args()
if args.reuse_native_notices:
    if args.fetch or not args.reuse_inventory_sha256 or not args.reuse_manifest_sha256:
        parser.error('Offline reuse requires both prior JSON pins and cannot be combined with --fetch')
elif args.reuse_inventory_sha256 or args.reuse_manifest_sha256 or args.reuse_crate_notices:
    parser.error('Reuse pins require --reuse-native-notices')
output = args.output.absolute()
if output.exists():
    raise SystemExit('Notice output must be a new directory')
# The retained collector uses desktop paths; supply the actual native Rust locks
# and an explicitly empty frontend lock because LensWorks has no npm payload.
stage = output.parent / (output.name + '-inputs')
if stage.exists():
    raise SystemExit('Notice input staging must be new')
(stage / 'desktop/src-tauri').mkdir(parents=True)
# Every Rust payload the app ships: the catalog adapter and engine, and the MCP bridge (Contents/Helpers/LensWorksMCP).
manifests = ('adapters/catalog/Cargo.toml', 'engines/catalog/Cargo.toml', 'adapters/mcp/Cargo.toml')
locks = [root / 'adapters/catalog/Cargo.lock', root / 'engines/catalog/Cargo.lock', root / 'adapters/mcp/Cargo.lock']
lock_bytes = {lock: lock.read_bytes() for lock in locks}
lock_hashes = {str(lock.relative_to(root)): hashlib.sha256(data).hexdigest() for lock, data in lock_bytes.items()}
manifest_bytes = {root / name: (root / name).read_bytes() for name in manifests}
packages = {}
graphs = []
payload_identities = set()
for manifest in manifests:
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
# the desktop lock, so inventory the union of every independently built payload.
union = 'version = 4\n' + ''.join('\n[[package]]\n' + ''.join(key + ' = ' + json.dumps(value) + '\n' for key, value in record.items()) for _, record in sorted(packages.items()))
(stage / 'desktop/src-tauri/Cargo.lock').write_text(union)
for destination, source in [('Cargo.lock', locks[1]), ('rust-toolchain.toml', root / 'rust-toolchain.toml')]:
    shutil.copy2(source, stage / destination)
(stage / 'desktop/package-lock.json').write_text(json.dumps({'packages': {}}))
(stage / 'vendor').mkdir()
for name in ('xmp_toolkit', 'libsqlite3-sys'):
    (stage / 'vendor' / name).symlink_to(root / 'engines/catalog/vendor' / name, target_is_directory=True)
sysroot = subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip()
command = [sys.executable, str(root / 'engines/catalog/scripts/collect_desktop_notices.py'), '--checkout', str(stage), '--sdk', str(root / '.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1'), '--output', str(output), '--rust-sysroot', sysroot]
if args.fetch:
    command.append('--fetch')
result = subprocess.run(command)
report_path = output / 'inventory.json'
if not report_path.exists():
    raise SystemExit(result.returncode or 'Collector did not produce a report')
report = json.loads(report_path.read_text())
if args.reuse_native_notices:
    if result.returncode not in (0, 1):
        raise SystemExit('Collector failed outside its missing-notice outcome; reuse cannot cover that failure')
    manifest = reuse_native_notices(output, report, args.reuse_native_notices,
                                   args.reuse_inventory_sha256, args.reuse_manifest_sha256)
    if args.reuse_crate_notices:
        manifest = reuse_crate_notices(output, report, manifest, args.reuse_native_notices,
                                      args.reuse_inventory_sha256, args.reuse_manifest_sha256)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
if any(path.read_bytes() != data for path, data in {**lock_bytes, **manifest_bytes}.items()):
    raise SystemExit('Payload dependency input changed during notice collection')
report['native_input_locks'] = lock_hashes
report['native_input_manifests'] = {str(path.relative_to(root)): hashlib.sha256(data).hexdigest() for path, data in manifest_bytes.items()}
report['native_dependency_graphs'] = graphs
report['excluded_lock_packages'] = {'basis': 'Not reachable through default-feature normal/build dependencies for the actual Apple-silicon payloads; development/test and other-target packages are not redistributed.', 'packages': excluded}
expected = {(record['name'] + '@' + record['version'], record.get('source'), record.get('checksum')) for record in packages.values()}
actual = {(record['identity'], record.get('source'), record.get('checksum')) for record in report['rust']}
if actual != expected:
    raise SystemExit('Collected Rust notices do not match the locked payloads')
# This absent component is intentional and directly evidenced by the empty lock;
# all other missing notices remain errors rather than a redistribution claim.
report['missing'] = [entry for entry in report['missing'] if entry.get('component') != 'frontend-dependencies']
report['native_adaptation'] = 'Union of actual default-feature Apple-silicon normal/build dependency graphs from every locked payload (catalog adapter, catalog engine, MCP bridge); excluded lock entries recorded explicitly; no npm runtime/frontend component is linked.'
report['status'] = 'NOTICE_INVENTORY_COMPLETE' if not report['missing'] else 'NOTICE_INVENTORY_INCOMPLETE'
report_path.write_text(json.dumps(report, indent=2) + '\n')
if report['missing']:
    raise SystemExit('Missing native notice records: ' + json.dumps(report['missing']))
print('Native source notice inventory complete; final public redistribution review remains sc-24690.')
