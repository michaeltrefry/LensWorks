#!/usr/bin/env python3
"""Run a two-process installed-app raster/version acceptance journey."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--launch-mode', choices=('launch-services', 'direct'), default='launch-services')
args = parser.parse_args()
output = args.output.absolute()
if output.exists():
    raise SystemExit('Acceptance output must be a new directory')
output.mkdir(parents=True)
media = output / 'Photos'; media.mkdir()
source = media / 'Original.png'
shutil.copy2(root / 'engines/catalog/tests/fixtures/generated-swatches.png', source)
before = hashlib.sha256(source.read_bytes()).hexdigest()
executable = args.app.resolve() / 'Contents/MacOS/LensWorks'
common = [str(executable), '--lensworks-catalog', str(output / 'Catalog'), '--lensworks-output', str(media)]

def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,args='], text=True)
    return {int(parts[0]): (int(parts[1]), ' '.join(parts[2:7]), parts[7])
            for line in rows.splitlines()
            if len(parts := line.strip().split(None, 7)) == 8}

def same_process(identity, current):
    return current is not None and identity[1:] == current[1:]

def is_app(command):
    return command == str(executable) or command.startswith(str(executable) + ' ')

def launch(phase, extra, log):
    if any(is_app(command) for _, _, command in processes().values()):
        raise RuntimeError('Acceptance app already running; ownership is ambiguous')
    arguments = common[1:] + extra + ['--lensworks-quit']
    command = ([str(executable)] + arguments if args.launch_mode == 'direct' else
               ['/usr/bin/open', '-W', '-n', str(args.app.resolve()), '--args'] + arguments)
    owned = {}
    app_pids = set()
    started = time.monotonic()
    launcher = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    launcher_identity = processes().get(launcher.pid)
    if launcher_identity is not None:
        owned[launcher.pid] = launcher_identity
    failure = None
    try:
        while True:
            current = processes()
            app_pids.update(pid for pid, (_, _, command) in current.items()
                            if is_app(command) and (pid not in owned or
                               same_process(owned[pid], current[pid])))
            parents = {pid for pid, identity in owned.items()
                       if same_process(identity, current.get(pid))}
            parents |= {pid for pid in app_pids if pid not in owned}
            while True:
                descendants = {pid for pid, (parent, _, _) in current.items()
                               if parent in parents and
                               (pid not in owned or same_process(owned[pid], current[pid]))}
                enlarged = parents | descendants
                if enlarged == parents:
                    break
                parents = enlarged
            for pid in parents:
                if pid in current and pid not in owned:
                    owned[pid] = current[pid]
            status = launcher.poll()
            if status is not None:
                if status != 0:
                    raise RuntimeError(f'Launcher exited {status}')
                current = processes()
                live = {pid for pid, identity in owned.items() if pid != launcher.pid and
                        same_process(identity, current.get(pid))}
                if live:
                    raise RuntimeError(f'Application/helper processes survived normal Quit: {sorted(live)}')
                if not app_pids:
                    raise RuntimeError('No distinct application process observed')
                break
            if time.monotonic() - started >= 120:
                raise TimeoutError('Installed app exceeded the 120-second acceptance deadline')
            time.sleep(0.1)
    except BaseException as error:
        failure = str(error)
        # Only identities captured from this launch are eligible for cleanup.
        for stop_signal in (signal.SIGTERM, signal.SIGKILL):
            current = processes()
            for pid, identity in owned.items():
                if same_process(identity, current.get(pid)):
                    try:
                        os.kill(pid, stop_signal)
                    except ProcessLookupError:
                        pass
            if stop_signal == signal.SIGTERM:
                time.sleep(1)
        if launcher.poll() is None:
            launcher.kill()
        launcher.wait()
        raise
    finally:
        (output / (phase + '-launch.json')).write_text(json.dumps({
            'mode': args.launch_mode, 'application_pids': sorted(app_pids),
            'owned_processes': {str(pid): identity for pid, identity in owned.items()},
            'launcher_exit': launcher.poll(), 'elapsed_seconds': time.monotonic() - started,
            'error': failure}, indent=2) + '\n')

first = output / 'first.json'; second = output / 'reopened.json'
for phase, extra in [('first', ['--lensworks-create-catalog', '--lensworks-import', str(media), '--lensworks-create-version', '--lensworks-edit-name', 'Persisted Layer', '--lensworks-edit-opacity', '0.6', '--lensworks-evidence', str(first)]), ('reopened', ['--lensworks-evidence', str(second)])]:
    with (output / (phase + '.log')).open('w') as log:
        launch(phase, extra, log)
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
if not project.stem.endswith(a['versionID'].split('-')[0]):
    raise SystemExit('Ordinary saves changed the initially created working-version identity')
manifest = json.loads((project / 'manifest.json').read_text())
record = json.loads((project / 'LensWorks.json').read_text())
if manifest['workingVersionID'].lower() != record['id'].lower() or record['photoID'] != a['photoID']:
    raise SystemExit('Durable source/version record mismatch')
report = {'status': 'PASS_INSTALLED_RASTER_TWO_PROCESS_RESTART', 'original_sha256_before': before, 'original_sha256_after': after, 'first': a, 'reopened': b, 'application': str(args.app.resolve()), 'protocol': 'sc-24656 local raster acceptance only'}
(output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS: installed catalog/layer/save/restart; source hash ' + before)
