#!/usr/bin/env python3
"""Verify LensWorks-owned catalog bytes; upstream Git revision is provenance only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'engines/catalog'
MANIFEST = SOURCE / 'SOURCE_PROVENANCE.json'
ALGORITHM = 'sha256-canonical-file-ledger-v1'
# Only source identity metadata and known build outputs are outside the ledger.
EXCLUDED_FILES = {'SOURCE_PROVENANCE.json'}
VOLATILE_DIRECTORIES = {'.build', 'target', '__pycache__', 'desktop/node_modules',
                        'desktop/dist', 'desktop/src-tauri/target'}


def file_record(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 512 * 1024 * 1024:
            raise ValueError('Catalog source must be a bounded private regular file: ' + str(path))
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > before.st_size:
                raise ValueError('Catalog source changed during read: ' + str(path))
            digest.update(chunk)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode)
        if size != before.st_size or identity(before) != identity(after):
            raise ValueError('Catalog source changed during read: ' + str(path))
        return {'path': path.relative_to(SOURCE).as_posix(),
                'mode': '100755' if before.st_mode & 0o111 else '100644',
                'bytes': size, 'sha256': digest.hexdigest()}
    finally:
        os.close(fd)


def source_ledger():
    if not SOURCE.is_dir() or SOURCE.is_symlink() or SOURCE.resolve() != SOURCE:
        raise ValueError('Owned catalog source must be a regular physical directory')
    files = []
    for directory, names, leaves in os.walk(SOURCE, followlinks=False):
        base = Path(directory)
        for name in list(names):
            path = base / name
            relative = path.relative_to(SOURCE).as_posix()
            if relative in VOLATILE_DIRECTORIES:
                names.remove(name)
            elif path.is_symlink() or name == '.git':
                raise ValueError('Owned source cannot contain a Git checkout or redirected directory: ' + relative)
        for name in leaves:
            path = base / name
            relative = path.relative_to(SOURCE).as_posix()
            if relative not in EXCLUDED_FILES:
                files.append(file_record(path))
        if len(files) > 10000:
            raise ValueError('Owned catalog source file limit exceeded')
    files.sort(key=lambda row: row['path'])
    serialized = json.dumps(files, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    return files, hashlib.sha256(serialized).hexdigest()


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 8 * 1024 * 1024:
            raise ValueError('Source authority must be bounded private regular JSON: ' + str(path))
        chunks = []
        size = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            size += len(chunk)
            if size > before.st_size:
                raise ValueError('Source authority changed during read: ' + str(path))
            chunks.append(chunk)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode)
        if size != before.st_size or identity(before) != identity(after):
            raise ValueError('Source authority changed during read: ' + str(path))
        return json.loads(b''.join(chunks))
    finally:
        os.close(fd)


def verify():
    recorded = read_json(MANIFEST)
    dependencies = read_json(ROOT / 'DEPENDENCIES.json')['PhotoCatalog']
    files, digest = source_ledger()
    if recorded['schema'] != 1 or recorded['algorithm'] != ALGORITHM or recorded['source_files'] != files:
        raise ValueError('Owned catalog source ledger differs; review changes and regenerate deliberately')
    if recorded['source_digest'] != digest or dependencies['source_digest'] != digest:
        raise ValueError('Owned catalog source digest differs')
    if dependencies['source'] != 'engines/catalog' or dependencies['ownership'] != 'LensWorks-owned regular source':
        raise ValueError('Catalog source must be LensWorks-owned, not a Git dependency')
    if dependencies['source_manifest'] != 'engines/catalog/SOURCE_PROVENANCE.json':
        raise ValueError('Catalog source manifest authority differs')
    baseline = read_json(SOURCE / 'UPSTREAM_SNAPSHOT.json')
    baseline_sha = file_record(SOURCE / 'UPSTREAM_SNAPSHOT.json')['sha256']
    if baseline_sha != dependencies['upstream_snapshot_sha256'] or recorded['upstream_snapshot_sha256'] != baseline_sha:
        raise ValueError('Original copy provenance changed')
    if baseline['revision'] != dependencies['revision'] or baseline['repository'] != dependencies['repository']:
        raise ValueError('Original upstream provenance differs')
    return digest


def write():
    """Explicit owner action after reviewing source changes, never build-time repair."""
    dependencies_path = ROOT / 'DEPENDENCIES.json'
    dependencies = read_json(dependencies_path)
    files, digest = source_ledger()
    snapshot_sha = file_record(SOURCE / 'UPSTREAM_SNAPSHOT.json')['sha256']
    expected_snapshot = dependencies['PhotoCatalog']['upstream_snapshot_sha256']
    if snapshot_sha != expected_snapshot:
        raise ValueError('Do not rewrite original copy provenance')
    data = {'schema': 1, 'algorithm': ALGORITHM, 'source_digest': digest,
            'scope': 'Complete LensWorks-owned catalog snapshot, including all executable/build inputs and retained services/tests/licenses. Adapter source has separate LensWorks build/ABI authority.',
            'upstream_snapshot_sha256': snapshot_sha,
            'excluded_files': sorted(EXCLUDED_FILES), 'volatile_directories': sorted(VOLATILE_DIRECTORIES),
            'source_files': files}
    MANIFEST.write_text(json.dumps(data, indent=2) + '\n')
    dependencies['PhotoCatalog']['source_digest'] = digest
    dependencies_path.write_text(json.dumps(dependencies, indent=2) + '\n')
    return verify()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Refresh current owned identity after a reviewed source edit')
    parser.add_argument('--print-digest', action='store_true', help='Print only verified owned source SHA256 for compilation')
    args = parser.parse_args()
    digest = write() if args.write else verify()
    print(digest if args.print_digest else 'Owned catalog source verified: ' + digest)


if __name__ == '__main__':
    main()
