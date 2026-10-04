#!/usr/bin/env python3
"""Relocate a local native build for acceptance; ad hoc signed, never notarized."""
import argparse
import importlib.util
import json
import pathlib
import plistlib
import shutil
import hashlib
import os

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=pathlib.Path, required=True)
parser.add_argument('--destination', type=pathlib.Path, required=True)
parser.add_argument('--notices', type=pathlib.Path, required=True, help='Verified collect-native-notices output')
args = parser.parse_args()
source, destination = args.source.resolve(), args.destination.absolute()
notice_root = args.notices.resolve()
notice_report = json.loads((notice_root / 'inventory.json').read_text())
if notice_report.get('missing'):
    raise SystemExit('Missing notice records prevent installation')
for name in ('adapters/catalog/Cargo.lock', 'vendor/PhotoCatalog/Cargo.lock'):
    if notice_report.get('native_input_locks', {}).get(name) != hashlib.sha256((root / name).read_bytes()).hexdigest():
        raise SystemExit('Notice inventory does not match current payload lock: ' + name)
for name in ('adapters/catalog/Cargo.toml', 'vendor/PhotoCatalog/Cargo.toml'):
    if notice_report.get('native_input_manifests', {}).get(name) != hashlib.sha256((root / name).read_bytes()).hexdigest():
        raise SystemExit('Notice inventory does not match current payload manifest: ' + name)
notice_manifest = json.loads((notice_root / 'manifest.json').read_text())
if destination.exists() or destination.resolve().is_relative_to(source) or not source.is_dir() or source.suffix != '.app':
    raise SystemExit('Require an existing source .app and a new destination directory')
test_frameworks = {'XCTest.framework', 'XCTestCore.framework', 'XCTestSupport.framework',
                   'XCUnit.framework', 'XCTAutomationSupport.framework',
                   'XCUIAutomation.framework', 'Testing.framework',
                   'libXCTestBundleInject.dylib', 'libXCTestSwiftSupport.dylib'}
if any(path.name in test_frameworks or path.suffix == '.xctest' for path in source.rglob('*')):
    raise SystemExit('Test-injected application cannot be installed; use scripts/build-native.sh')
spec = importlib.util.spec_from_file_location('photocatalog_packaging', root / 'vendor/PhotoCatalog/scripts/package_desktop.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)
info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
executable = source / 'Contents/MacOS' / info['CFBundleExecutable']
helpers_root = source / 'Contents/Helpers'
helpers = sorted(helpers_root.iterdir()) if helpers_root.exists() else []
if {path.name for path in helpers} != {'PhotoCatalogWorker', 'LensWorksDecodeWorker'} or any(not path.is_file() or path.is_symlink() or not os.access(path, os.X_OK) for path in helpers):
    raise SystemExit('Require both regular executable PhotoCatalogWorker and LensWorksDecodeWorker helpers')
closure = {}
for entry in [executable] + helpers:
    for path, record in packaging.mac_closure(entry).items():
        previous = closure.get(path)
        if previous is not None and previous != record:
            raise SystemExit('Conflicting dependency closure: ' + str(path))
        closure[path] = record
covered = {name for entry in notice_manifest['components'] for name in entry['libraries']}
external_names = {path.name for path in closure if not path.is_relative_to(source)}
if not external_names <= covered:
    raise SystemExit('Native library notice coverage missing: ' + str(external_names - covered))
required = {'rust-dependencies', 'rust-toolchain', 'adobe-dng-sdk', 'xmp-toolkit', 'libsqlite3-sys'}
if not required <= {entry['component'] for entry in notice_manifest['components']}:
    raise SystemExit('Missing static native/Rust notices')
for entry in notice_manifest['components']:
    for item in entry['files']:
        file = (notice_root / item['path']).resolve()
        if not file.is_relative_to(notice_root) or file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != item['sha256']:
            raise SystemExit('Invalid notice file/hash: ' + str(file))
destination.mkdir(parents=True)
app = destination / source.name
shutil.copytree(source, app, symlinks=True)
for entry in app.rglob('*'):
    if entry.is_symlink() and not entry.resolve().is_relative_to(app):
        raise SystemExit('Escaping application resource symlink: ' + str(entry))
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
relocated = {}
for path in closure:
    if path.is_relative_to(source):
        target = app / path.relative_to(source)
    else:
        target = frameworks / path.name
        if target.exists():
            raise SystemExit('Dependency destination collision: ' + str(target))
        shutil.copy2(path, target)
    relocated[path] = target
for old, target in relocated.items():
    target.chmod(target.stat().st_mode | 0o200)
    for name, dependency in closure[old]['edges'].items():
        relative = pathlib.Path(__import__('os').path.relpath(relocated[dependency], target.parent))
        packaging.run('install_name_tool', '-change', name, '@loader_path/' + str(relative), target)
    for rpath in dict.fromkeys(closure[old]['rpaths']):
        packaging.run('install_name_tool', '-delete_rpath', rpath, target)
    if old != executable.resolve() and old not in helpers:
        packaging.run('install_name_tool', '-id', '@rpath/' + target.name, target)
    packaging.run('codesign', '--force', '--sign', '-', '--timestamp=none', target)
notices = app / 'Contents/Resources/THIRD_PARTY_NOTICES'
notices.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', notices)
shutil.copy2(root / 'DEPENDENCIES.json', notices)
shutil.copy2(root / 'vendor/Compositor/LICENSE', notices / 'Compositor-MIT.txt')
for entry in notice_manifest['components']:
    for index, item in enumerate(entry['files']):
        file = notice_root / item['path']
        installed_name = entry['component'] + '-' + str(index) + '-' + file.name
        shutil.copy2(file, notices / installed_name)
        item['path'] = installed_name
(notices / 'source-manifest.json').write_text(json.dumps(notice_manifest, indent=2) + '\n')
packaging.run('codesign', '--force', '--sign', '-', '--timestamp=none', app)
installed_executable = app / executable.relative_to(source)
report = packaging.mac_audit(app, installed_executable)
helper_reports = [packaging.mac_audit(app, app / helper.relative_to(source)) for helper in helpers]
if any(item['architectures'] != ['arm64'] for item in [report] + helper_reports):
    raise SystemExit('Apple-silicon package must contain arm64 executables')
report['helpers'] = helper_reports
report['status'] = 'DEVELOPMENT_DEPENDENCY_CLOSURE_VERIFIED'
report['distribution'] = 'ad hoc local acceptance build; not notarized or released'
(destination / 'closure.json').write_text(json.dumps(report, indent=2) + '\n')
print(app)
