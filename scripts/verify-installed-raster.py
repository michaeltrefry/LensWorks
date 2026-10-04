#!/usr/bin/env python3
"""Run a two-process installed-app raster/version acceptance journey."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
output = args.output.absolute()
if output.exists():
    raise SystemExit('Acceptance output must be a new directory')
output.mkdir(parents=True)
media = output / 'Photos'; media.mkdir()
source = media / 'Original.png'
shutil.copy2(root / 'vendor/PhotoCatalog/tests/fixtures/generated-swatches.png', source)
before = hashlib.sha256(source.read_bytes()).hexdigest()
executable = args.app.resolve() / 'Contents/MacOS/LensWorks'
common = [str(executable), '--lensworks-catalog', str(output / 'Catalog'), '--lensworks-output', str(media)]
first = output / 'first.json'; second = output / 'reopened.json'
for phase, extra in [('first', ['--lensworks-create-catalog', '--lensworks-import', str(media), '--lensworks-create-version', '--lensworks-edit-name', 'Persisted Layer', '--lensworks-edit-opacity', '0.6', '--lensworks-evidence', str(first)]), ('reopened', ['--lensworks-evidence', str(second)])]:
    with (output / (phase + '.log')).open('w') as log:
        subprocess.run(common + extra + ['--lensworks-quit'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
a, b = [json.loads(path.read_text()) for path in (first, second)]
if a.get('error') or b.get('error'):
    raise SystemExit('Application reported a failure: ' + str([a.get('error'), b.get('error')]))
for key in ('versionID', 'photoID', 'documentID', 'sourcePath', 'projectPath', 'layerIDs', 'layerNames', 'layerOpacities'):
    if not a.get(key) or a[key] != b[key]:
        raise SystemExit('Restart identity/layer mismatch: ' + key)
if a['assetCount'] != 1 or b['assetCount'] != 1 or a['modified'] or b['modified']:
    raise SystemExit('Catalog count/saved-state mismatch')
if a['layerNames'] != ['Persisted Layer'] or a['layerOpacities'] != [0.6]:
    raise SystemExit('Editable layer change did not survive restart')
after = hashlib.sha256(source.read_bytes()).hexdigest()
if before != after:
    raise SystemExit('Original source bytes changed')
project = pathlib.Path(a['projectPath'])
manifest = json.loads((project / 'manifest.json').read_text())
record = json.loads((project / 'LensWorks.json').read_text())
if manifest['workingVersionID'].lower() != record['id'].lower() or record['photoID'] != a['photoID']:
    raise SystemExit('Durable source/version record mismatch')
report = {'status': 'PASS_INSTALLED_RASTER_TWO_PROCESS_RESTART', 'original_sha256_before': before, 'original_sha256_after': after, 'first': a, 'reopened': b, 'application': str(args.app.resolve()), 'protocol': 'sc-24656 local raster acceptance only'}
(output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS: installed catalog/layer/save/restart; source hash ' + before)
