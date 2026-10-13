#!/usr/bin/env python3
"""Print a Hugging Face "hub" directory whose CLIP files the Swift test host can read, or nothing.

The SceneWorks model cache may live on a volume (~/.cache/huggingface -> /Volumes/Models) that
macOS privacy consent withholds from the ad-hoc signed test host app even where this shell can
read it. The real-query semantic search test therefore reads a staged copy of the two CLIP files
the bundled manifest names, kept in the persistent CI cache (copied once, reused while the sizes
match; the model store still verifies every file's SHA-256 before it admits the model). Nothing
is downloaded. A read that blocks is abandoned at the deadline, never waited on. Staged copies of
revisions the manifest no longer names are removed, so the cache holds one revision.

usage: stage_clip_weights.py [deadline-seconds]   (LW_CLIP_STAGE_DIR overrides the staging directory)
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[2]
deadline = time.monotonic() + float(sys.argv[1] if len(sys.argv) > 1 else 180)
manifest = json.loads((root / 'native/Compositor/LensWorks/LensWorksModels.json').read_text())
component = next(model for model in manifest['models'] if model['id'] == 'clip_vit_l14')['components'][0]
snapshot = pathlib.Path('models--' + component['repository'].replace('/', '--')) / 'snapshots' / component['revision']
source = pathlib.Path(os.environ.get('HF_HUB_CACHE') or pathlib.Path.home() / '.cache/huggingface/hub') / snapshot
stage = pathlib.Path(os.environ.get('LW_CLIP_STAGE_DIR') or pathlib.Path.home() / '.cache/lensworks-ci/clip-hub')
target = stage / snapshot


def staged(file: dict) -> bool:
    path = target / file['path']
    return path.is_file() and path.stat().st_size == file['size']


for file in component['files']:
    if staged(file):
        continue
    destination = target / file['path']
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + '.part')
    # -L: the cache stores snapshot entries as links to its blobs.
    copy = subprocess.Popen(['/bin/cp', '-L', str(source / file['path']), str(partial)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while copy.poll() is None:
        if time.monotonic() > deadline:
            copy.kill()  # blocked in the kernel (privacy consent): abandon it without waiting
            sys.exit(0)
        time.sleep(0.25)
    if copy.returncode != 0 or partial.stat().st_size != file['size']:
        partial.unlink(missing_ok=True)
        sys.exit(0)
    os.replace(partial, destination)
# Only this staging directory's own snapshots of this repository are pruned, and only once the
# named revision is complete.
for other in target.parent.iterdir():
    if other.name != target.name:
        shutil.rmtree(other) if other.is_dir() and not other.is_symlink() else other.unlink()
print(stage)
