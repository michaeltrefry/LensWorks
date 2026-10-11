#!/usr/bin/env python3
"""Run the quiescent-root payload auditor with a separate owned process deadline."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def run(native_root, evidence_directory):
    auditor = Path(__file__).with_name('audit-preview-payloads.py')
    auditor_sha = hashlib.sha256(auditor.read_bytes()).hexdigest()
    if auditor_sha != 'efa9657fb1fa0d4ce1ea0bc2e6a727e6996506599c5d554882656ce45aa4aca9':
        raise ValueError('Payload auditor changed; independent requalification required')
    with native_root.open('rb') as supplied:
        raw = supplied.read(1048577)
    if len(raw) > 1048576:
        raise ValueError('Native root record exceeds input bound')
    root = json.loads(raw)
    if (type(root) is not dict or root.get('encoding') != 'UnixBytes' or
            type(root.get('units')) is not list or not root['units'] or
            len(root['units']) > 32768 or root['units'][0] != 47 or
            any(type(x) is not int or not 1 <= x <= 255 for x in root['units'])):
        raise ValueError('Invalid absolute NativePath')
    root_path = os.fsdecode(bytes(root['units']))
    if any(part in ('', '.', '..') for part in root_path.split('/')[1:]):
        raise ValueError('Native root path is not canonical')
    evidence_directory = evidence_directory.resolve()
    if os.path.commonpath([root_path, str(evidence_directory)]) == root_path:
        raise ValueError('Process evidence must remain outside the cache root')
    evidence_directory.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, str(auditor), '--native-root', str(native_root.resolve()),
               '--output', str(evidence_directory / 'payloads.json')]
    def save(name, value):
        (evidence_directory / name).write_text(json.dumps(value, indent=2) + '\n')
    started = time.time()
    timed_out = False
    with (evidence_directory / 'audit.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            save('owner.json', {'pid': process.pid, 'command': command,
                               'start_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                               'deadline_epoch': started + 75, 'auditor_sha256': auditor_sha})
            try:
                exit_code = process.wait(timeout=75)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.terminate()
                try:
                    exit_code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    exit_code = process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    result = {'exit_code': exit_code, 'timed_out': timed_out, 'elapsed_seconds': time.time() - started,
              'pid': process.pid, 'reaped': process.poll() is not None,
              'auditor_sha256': auditor_sha,
              'status': 'RECORDED_ONLY' if exit_code == 0 and not timed_out else 'FAILED',
              'limitation': 'Caller must establish checked-closed/quiescent owner; no app or relocation acceptance.'}
    save('process-result.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-root', type=Path, required=True)
    parser.add_argument('--evidence-directory', type=Path, required=True)
    args = parser.parse_args()
    result = run(args.native_root, args.evidence_directory)
    print(json.dumps(result))
    sys.exit(0 if result['status'] == 'RECORDED_ONLY' else 1)
