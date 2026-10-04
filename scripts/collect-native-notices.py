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
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--fetch', action='store_true', help='Retrieve checksum/commit-pinned official notices and corresponding sources')
args = parser.parse_args()
output = args.output.absolute()
if output.exists():
    raise SystemExit('Notice output must be a new directory')
# The retained collector uses desktop paths; supply the actual native Rust lock
# and an explicitly empty frontend lock because LensWorks has no npm payload.
stage = output.parent / (output.name + '-inputs')
if stage.exists():
    raise SystemExit('Notice input staging must be new')
(stage / 'desktop/src-tauri').mkdir(parents=True)
for destination, source in [('Cargo.lock', root / 'adapters/catalog/Cargo.lock'), ('desktop/src-tauri/Cargo.lock', root / 'adapters/catalog/Cargo.lock'), ('rust-toolchain.toml', root / 'rust-toolchain.toml')]:
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
# This absent component is intentional and directly evidenced by the empty lock;
# all other missing notices remain errors rather than a redistribution claim.
report['missing'] = [entry for entry in report['missing'] if entry.get('component') != 'frontend-dependencies']
report['native_adaptation'] = 'Actual LensWorks Rust lock; no npm runtime/frontend component is linked.'
report['status'] = 'NOTICE_INVENTORY_COMPLETE' if not report['missing'] else 'NOTICE_INVENTORY_INCOMPLETE'
report_path.write_text(json.dumps(report, indent=2) + '\n')
if report['missing']:
    raise SystemExit('Missing native notice records: ' + json.dumps(report['missing']))
print('Native source notice inventory complete; final public redistribution review remains sc-24690.')
