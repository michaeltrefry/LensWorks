#!/usr/bin/env python3
"""Verify eight-source installed delivery and closed-cache bytes; qualify before use.

This verdict excludes full-float math, packaging, UI and complete S04 acceptance.
Caller timeline receipts must come from orchestration, never file mtimes.
"""
import argparse
import datetime
import errno
import hashlib
import importlib.util
import json
import math
import os
import stat
import sys
from pathlib import Path
import re

CONTRACT = 'c83c83e213213c723ac4772e249f21c789e92baf592850acae43a9460cd075d0'
MANIFEST = 'ac2ff98386093131028fda25cd0c5f4de7fbfe55119e186b243cf49a41ff5986'
PLAN = 'f96687bfa29cde88b972ab80050d826c192b612b432cac75bf93d788d02bab34'
PROVENANCE = 'e88eb014b25bab13c9ef7cf5d629a438d7dc5cf3bc2cb102d3c1479b9168f367'
COMMON = '3fa500277b4e44d3aca6b1d960df9b879193d9e21f8934367e4e047eace9d2e0'
STORAGE = '3e27f9b58f6ed900dfc71c1ea3c2ac5b4ae7ebe3e8ab088bdd07839376efc6be'
AUDITOR = 'efa9657fb1fa0d4ce1ea0bc2e6a727e6996506599c5d554882656ce45aa4aca9'
WRAPPER = '4ce893980058bd52d70142b48f8e3d728fa13629abe98eb1fd395329cf9b371f'
SOURCES = 'bfe09e32af44622fa61f051aee36f4aad94476ef9aaccf0cdb81cdde8211ad1c'
HELPERS = {'PhotoCatalogWorker': '1a501ed75841c27aad6a8b579f36c192024ea5c2ccab4b78e8f988b1ccab7c72',
           'LensWorksDecodeWorker': '421a01853f1bd87015056ab4c74a0c61b4085f30b58d77217b2547b6e656159e'}

RUNNER = 'd0733d4606bc88d86982241bd125d883c39e1d9d9a928105996ca8575c1d3e3e'
CATALOG_SOURCE = 'ce448874c1e8718c21c628270def08df978c2749ace2edf3ffc7e203c1b33914'


def require(value, message):
    if not value:
        raise ValueError(message)


def integer(value, maximum, label, minimum=0):
    require(type(value) is int and minimum <= value <= maximum, label)
    return value


def text(value):
    require(type(value) is str and 1 <= len(value.encode('utf-8')) <= 32768, 'Invalid text authority')
    return value


def sha(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256')
    return value


def clock(value):
    require(type(value) in (float, int) and math.isfinite(value) and value > 0, 'Invalid receipt time')
    return value


def artifact_path(value):
    path = Path(value)
    require(path.is_absolute() and '..' not in path.parts, 'Artifact path must be absolute without traversal')
    require(path == path.resolve(strict=True), 'Artifact aliases are not admitted')
    return path


def close_all(descriptors):
    errors = []
    for descriptor in reversed(descriptors):
        identity = None
        try:
            identity = os.fstat(descriptor)
        except OSError as error:
            errors.append(error)
        try:
            os.close(descriptor)
        except OSError as error:
            errors.append(error)
            # A failed close may have closed the descriptor already. Retry once
            # only if it still names the same held object.
            if identity is not None:
                try:
                    current = os.fstat(descriptor)
                    if (current.st_dev, current.st_ino, current.st_mode) == (identity.st_dev, identity.st_ino, identity.st_mode):
                        os.close(descriptor)
                except OSError as retry_error:
                    if retry_error.errno != errno.EBADF:
                        errors.append(retry_error)
    return errors


def finish_cleanup(errors, original):
    if errors:
        primary = original if original is not None else errors[0]
        secondary = errors if original is not None else errors[1:]
        if secondary:
            message = 'Descriptor cleanup errors: ' + '; '.join(str(x) for x in secondary)
            if callable(getattr(primary, 'add_note', None)):
                primary.add_note(message)
            else:
                primary.__notes__ = [*getattr(primary, '__notes__', []), message]
                # Python 3.9 does not render exception notes in tracebacks.
                print(message, file=sys.stderr)
        if original is None:
            raise primary


def rollback_closed_publication(output, created, parent_identity):
    parent = artifact_path(output.parent)
    descriptors = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
    try:
        for part in parent.parts[1:]:
            descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=descriptors[-1]))
        current = os.fstat(descriptors[-1])
        require((current.st_dev, current.st_ino) == (parent_identity.st_dev, parent_identity.st_ino),
                'Cannot roll back through a replaced verdict parent')
        try:
            leaf = os.stat(output.name, dir_fd=descriptors[-1], follow_symlinks=False)
            if (leaf.st_dev, leaf.st_ino) == (created.st_dev, created.st_ino):
                os.unlink(output.name, dir_fd=descriptors[-1])
        except FileNotFoundError:
            pass
    finally:
        original = sys.exc_info()[1]
        finish_cleanup(close_all(descriptors), original)


def jpeg_extent(data, width, height):
    require(data[:2] == b'\xff\xd8' and data[-2:] == b'\xff\xd9', 'JPEG framing missing')
    offset, frame, scan, frame_ids = 2, False, False, set()
    while offset < len(data):
        require(data[offset] == 255, 'Invalid JPEG marker')
        while offset < len(data) and data[offset] == 255:
            offset += 1
        require(offset < len(data), 'Truncated JPEG marker')
        marker = data[offset]; offset += 1
        if marker == 0xd9:
            require(frame and scan and offset == len(data), 'Incomplete JPEG')
            return
        require(marker not in (0, 0xd8) and not 0xd0 <= marker <= 0xd7, 'Unexpected JPEG marker')
        require(offset + 2 <= len(data), 'Truncated JPEG segment')
        length = int.from_bytes(data[offset:offset + 2], 'big')
        require(length >= 2 and offset + length <= len(data), 'Invalid JPEG segment extent')
        segment = data[offset + 2:offset + length]; offset += length
        if 0xc0 <= marker <= 0xcf and marker not in (0xc4, 0xc8, 0xcc):
            require(marker == 0xc0 and not frame and len(segment) == 15 and segment[0] == 8 and
                    int.from_bytes(segment[1:3], 'big') == height and int.from_bytes(segment[3:5], 'big') == width and
                    segment[5] == 3 and all(segment[i] == 0x11 for i in (7, 10, 13)), 'Wrong JPEG geometry or sampling')
            frame_ids = {segment[i] for i in (6, 9, 12)}
            require(len(frame_ids) == 3, 'Duplicate JPEG frame component')
            frame = True
        if marker == 0xda:
            require(frame and not scan and len(segment) == 10 and segment[0] == 3, 'Invalid baseline JPEG scan')
            require({segment[i] for i in (1, 3, 5)} == frame_ids and segment[7:] == bytes([0, 63, 0]),
                    'Invalid baseline JPEG scan components or spectral parameters')
            scan = True
            entropy_bytes = 0
            while offset < len(data):
                if data[offset] != 255:
                    entropy_bytes += 1; offset += 1; continue
                require(offset + 1 < len(data), 'Truncated JPEG entropy')
                if data[offset + 1] == 0 or 0xd0 <= data[offset + 1] <= 0xd7:
                    if data[offset + 1] == 0:
                        entropy_bytes += 1
                    offset += 2; continue
                break
            require(entropy_bytes > 0, 'Empty JPEG entropy stream')
    raise ValueError('JPEG end marker missing')


def publish_fresh(output, report):
    data = (json.dumps(report, indent=2) + '\n').encode('utf-8')
    require(len(data) <= 8 * 1024 * 1024, 'Verdict exceeds finite output bound')
    require(output.is_absolute() and '..' not in output.parts, 'Invalid verdict path')
    parent = artifact_path(output.parent)
    descriptors = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
    created = None
    try:
        for part in parent.parts[1:]:
            descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=descriptors[-1]))
        parent_fd = descriptors[-1]
        parent_identity = os.fstat(parent_fd)
        fd = os.open(output.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent_fd)
        descriptors.append(fd)
        created = os.fstat(fd)
        require(stat.S_ISREG(created.st_mode), 'Verdict must be a regular file')
        offset = 0
        while offset < len(data):
            written = os.write(fd, data[offset:offset + 65536])
            require(written > 0, 'Incomplete verdict write')
            offset += written
        final = os.fstat(fd)
        leaf = os.stat(output.name, dir_fd=parent_fd, follow_symlinks=False)
        require((leaf.st_dev, leaf.st_ino) == (created.st_dev, created.st_ino) and
                final.st_size == len(data), 'Verdict entry changed during publication')
        current_parent = artifact_path(parent).stat()
        require((current_parent.st_dev, current_parent.st_ino) ==
                (parent_identity.st_dev, parent_identity.st_ino), 'Verdict parent changed during publication')
    except BaseException:
        if created is not None:
            try:
                leaf = os.stat(output.name, dir_fd=parent_fd, follow_symlinks=False)
                if (leaf.st_dev, leaf.st_ino) == (created.st_dev, created.st_ino):
                    os.unlink(output.name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        original = sys.exc_info()[1]
        errors = close_all(descriptors)
        if errors and created is not None:
            try:
                rollback_closed_publication(output, created, parent_identity)
            except Exception as rollback_error:
                errors.append(rollback_error)
        finish_cleanup(errors, original)


def verify(bundle_path, output):
    require(not os.path.lexists(output), 'Verdict path must be fresh')
    artifact_path(output.parent)
    hashes = {}

    def read_artifact(path, maximum=96 * 1024 * 1024, retain=False):
        path = artifact_path(path)
        digest = hashlib.sha256()
        count, chunks = 0, []
        descriptors = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
        try:
            for part in path.parts[1:-1]:
                descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1]))
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptors[-1])
            descriptors.append(fd)
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size <= maximum, 'Artifact must be a bounded regular file')
            while block := os.read(fd, 65536):
                count += len(block)
                require(count <= maximum, 'Artifact grew beyond finite read bound')
                digest.update(block)
                if retain:
                    chunks.append(block)
            after = os.fstat(fd)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode, s.st_nlink)
            require(identity(before) == identity(after) and count == before.st_size, 'Artifact changed during held-file read')
        finally:
            original = sys.exc_info()[1]
            finish_cleanup(close_all(descriptors), original)
        digest = digest.hexdigest()
        previous = hashes.setdefault(str(path), digest)
        require(previous == digest, 'Artifact changed during verification')
        return digest, b''.join(chunks)

    def file_hash(path):
        return read_artifact(path)[0]

    def load(path):
        _, data = read_artifact(path, 8 * 1024 * 1024, True)
        return json.loads(data)

    def bind(record, field, path):
        require(sha(record[field]) == file_hash(path), 'Receipt hash mismatch: ' + field)

    scripts = Path(__file__).resolve().parent
    workspace = scripts.parent
    file_hash(Path(__file__).absolute())
    file_hash(Path(sys.executable).resolve(strict=True))
    modules = {}
    for name, expected in [('verify-catalog-plan-evidence', COMMON), ('verify-catalog-storage-evidence', STORAGE)]:
        path = scripts / (name + '.py')
        require(file_hash(path) == expected, 'Qualified dependency changed')
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        modules[name] = module
    common = modules['verify-catalog-plan-evidence']
    native = modules['verify-catalog-storage-evidence'].native
    for name, expected in [('audit-preview-payloads.py', AUDITOR), ('run-preview-payload-audit.py', WRAPPER)]:
        require(file_hash(scripts / name) == expected, 'Qualified auditor changed')

    bundle = load(bundle_path)
    contract = load(bundle['contract'])
    require(file_hash(bundle['contract']) == CONTRACT, 'Source contract changed')
    inputs = contract['inputs']
    require(type(inputs) is list and len(inputs) == 8, 'Expected exactly eight inputs')
    expected = {}
    for item in inputs:
        path = artifact_path(Path(item['source_path']))
        require(path.name == text(item['filename']) and path.name not in expected, 'Duplicate/mismatched source name')
        require(file_hash(path) == sha(item['source_sha256']), 'Original input changed')
        expected[path.name] = item
    for item in contract['artifacts']:
        require(file_hash(workspace / item['path']) == sha(item['sha256']), 'Contract provenance changed')
    compiled = load(bundle['compiled_sources'])
    require(file_hash(bundle['compiled_sources']) == SOURCES and type(compiled) is dict and len(compiled) == 16,
            'Reviewed compiled source manifest changed')
    for path, digest in compiled.items():
        require(file_hash(workspace / path) == sha(digest), 'Guarded production/test source changed')
    provenance_path = workspace / '.build/s04-owned-retained-format-inputs-v1/provenance.json'
    provenance = load(provenance_path)
    require(file_hash(provenance_path) == PROVENANCE, 'Source provenance changed')
    for item in provenance['inputs']:
        require(file_hash(item['origin']) == sha(item['origin_sha256']) == sha(item['sha256']), 'Origin input changed')
    manifest_path = artifact_path(Path(bundle['source_manifest']))
    manifest = load(manifest_path)
    require(file_hash(manifest_path) == MANIFEST and manifest['provenance_sha256'] == PROVENANCE,
            'Qualified source-audit manifest changed')
    require(manifest['interruption_sources'] == [], 'Unexpected interruption inputs')
    expected_paths = {str(artifact_path(x['source_path'])): x['source_sha256'] for x in inputs}
    observed_manifest = {str(artifact_path(manifest_path.parent / x['relative_path'])): x['sha256'] for x in manifest['sources']}
    require(len(manifest['sources']) == 8 and observed_manifest == expected_paths, 'Manifest source set mismatch')

    directory = artifact_path(Path(bundle['directory']))
    execution_path, journey_path = directory / 'execution.json', directory / 'journey.json'
    execution, journey = load(execution_path), load(journey_path)
    require(sha(execution['runner_sha256']) == RUNNER, 'Current runner authority changed')
    plan_path = artifact_path(Path(bundle['plan']))
    plan = load(plan_path)
    require(file_hash(plan_path) == PLAN and plan['version'] == 1 and type(plan['version']) is int, 'Plan mismatch')
    kinds = ['create', 'startImport', 'finishImport', 'browse', 'preview', 'previewSettings', 'close']
    require([x['kind'] for x in plan['actions']] == kinds, 'Wrong ordered plan')
    integer(plan['actions'][2]['timeoutMilliseconds'], 60000, 'Invalid import observation', 1)
    require(plan['actions'][3]['recursive'] is True and plan['actions'][4]['tier'] == 'thumbnail', 'Wrong browse/tier request')
    root = artifact_path(inputs[0]['source_path']).parent
    require(all(artifact_path(x['source_path']).parent == root for x in inputs) and
            plan['actions'][1]['path'] == str(root) and plan['actions'][3]['folderPath'] == str(root), 'Import/browse root mismatch')
    require(execution['status'] == 'EXECUTED_PENDING_ORACLE_ACCEPTANCE' and execution['error'] in (None, '') and
            (execution['error'] is None or type(execution['error']) is str), 'Runner failure or malformed error')
    require(type(execution['launcher_exit']) is int and execution['launcher_exit'] == 0 and
            execution['observed_surviving_processes'] == [] and execution['cleanup_errors'] == [], 'Normal owner retirement missing')
    require(type(journey['error']) is str and journey['error'] == '', 'Application error')
    pids = execution['application_pids']
    require(type(pids) is list and pids and len(set(pids)) == len(pids), 'Invalid observed app owners')
    app = artifact_path(Path(execution['application']))
    executable = app / 'Contents/MacOS/LensWorks'
    require(file_hash(executable) == sha(execution['executable_sha256']), 'Executable changed')
    helper_provenance = load(bundle['helper_provenance'])
    require(type(helper_provenance) is list and len(helper_provenance) == 2, 'Both helper provenance records required')
    helper_names = set()
    for record in helper_provenance:
        helper = artifact_path(Path(record['helper']))
        name = helper.name
        require(name in HELPERS and name not in helper_names and helper == app / 'Contents/Helpers' / name,
                'Wrong or duplicated installed helper')
        helper_names.add(name)
        require(sha(record['catalog_source_digest']) == CATALOG_SOURCE, 'Current owned catalog authority changed')
        require(sha(record['source_sha256']) == HELPERS[name] and file_hash(helper) == sha(record['signed_sha256']),
                'Actual signed helper or retained input hash changed')
    require(sha(execution['plan_sha256']) == PLAN, 'Execution plan mismatch')
    for pid in pids:
        integer(pid, 2**31 - 1, 'Invalid app PID', 1)
        owner = execution['owned_processes'][str(pid)]
        text(owner['started'])
        require(owner['command'] == str(executable) or owner['command'].startswith(str(executable) + ' '), 'Wrong app owner command')
    source_rows = execution['source_states']
    require(type(source_rows) is list and len(source_rows) == 8 and len({x['path'] for x in source_rows}) == 8,
            'Missing/duplicated original source audit')
    require({x['path']: x['before'] for x in source_rows} == expected_paths and
            {x['path']: x['after'] for x in source_rows} == expected_paths and
            all(x['state'] == 'unchanged' for x in source_rows), 'Original preservation failed')
    require(type(execution['unchanged_source_count']) is int and execution['unchanged_source_count'] == 8, 'Original count mismatch')
    timeline = load(bundle['timeline_receipt'])
    for field, path in [('execution_sha256', execution_path), ('journey_sha256', journey_path), ('plan_sha256', plan_path)]:
        bind(timeline, field, path)
    bind(timeline, 'helper_provenance_sha256', bundle['helper_provenance'])
    require(clock(timeline['started_epoch']) < clock(timeline['closed_epoch']) and
            timeline['observed_surviving_processes'] == [], 'Missing caller close chronology')
    deadline = integer(execution['deadline_seconds'], 1800, 'Invalid campaign deadline', 10)
    elapsed = execution['elapsed_seconds']
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 <= elapsed <= deadline and
            elapsed <= timeline['closed_epoch'] - timeline['started_epoch'], 'Execution escaped caller lifecycle/deadline')

    actions = journey['catalogJourney']
    require(type(actions) is list and len(actions) == 7, 'Not all seven actions executed')
    token = text(actions[0]['catalogToken'])
    for index, action in enumerate(actions):
        integer(action['index'], 6, 'Invalid action index')
        require(action['index'] == index and action['action'] == kinds[index] and action['status'] == 'ok', 'Action identity/status mismatch')
        require(action['catalogPath'] == ('' if index == 6 else plan['actions'][0]['path']) and
                action['catalogToken'] == ('' if index == 6 else token), 'Catalog owner changed')
        for key, maximum in [('rowCount', 100), ('rowsHighWater', 100), ('cursorHistoryCount', 64),
                             ('navigationResidency', 364), ('navigationHighWater', 364), ('versionRows', 100),
                             ('versionRowsHighWater', 100), ('selectionProjectionCount', 100)]:
            integer(action[key], maximum, 'Invalid residency ' + key)
        require(action['rowCount'] <= action['rowsHighWater'] and action['versionRows'] <= action['versionRowsHighWater'] and
                action['navigationResidency'] <= action['navigationHighWater'], 'Current residency exceeds high water')
        common.canonical_integer(action['selectionCount'])
        rows = action['rows']
        require(type(rows) is list and len(rows) == action['rowCount'] and len({x['image_id'] for x in rows}) == len(rows), 'Row window mismatch')
        for row in rows:
            for key in ['image_id', 'asset_id', 'variant_id', 'filename']:
                text(row[key])
            common.canonical_integer(row['sequence'], signed=True)
            common.canonical_integer(row['metadata_revision'], signed=True)
        metrics = action['previewMetrics']
        require(set(metrics) == {'active', 'activeHighWater', 'pending', 'pendingHighWater', 'cacheEntries', 'cacheEntriesHighWater', 'cacheBytes', 'cacheBytesHighWater', 'completed', 'canceled'}, 'Preview metric schema mismatch')
        integer(metrics['completed'], 2**63 - 1, 'Invalid completed metric')
        integer(metrics['canceled'], 2**63 - 1, 'Invalid canceled metric')
        for key, maximum in [('active', 4), ('pending', 200), ('cacheEntries', 64), ('cacheBytes', 32 * 1024 * 1024)]:
            integer(metrics[key], maximum, 'Invalid preview ' + key)
            integer(metrics[key + 'HighWater'], maximum, 'Invalid preview high water ' + key)
            require(metrics[key] <= metrics[key + 'HighWater'], 'Preview exceeds high water')
        require(action.get('previews', []) == [] or index == 4, 'Preview delivered by wrong action')
    start, finish = actions[1]['import'], actions[2]['import']
    require(text(start['id']) == text(finish['id']) and native(start['source']) == native(finish['source']) ==
            native({'encoding': 'UnixBytes', 'units': list(bytes(root))}), 'Import attempt/source mismatch')
    counters = ['imported', 'unchanged', 'failed', 'skipped', 'metadata_updated', 'metadata_warnings', 'awaiting_resources']
    for receipt in (start, finish):
        require(receipt['phase'] in {'discovering', 'draining', 'complete'}, 'Invalid active/terminal import phase')
        require(receipt['error'] is None, 'Import error authority present')
        if receipt['error_source'] is not None:
            admitted_paths = [native({'encoding': 'UnixBytes', 'units': list(bytes(artifact_path(x['source_path'])))}) for x in inputs]
            require(receipt is start and receipt['phase'] == 'discovering' and
                    native(receipt['error_source']) in admitted_paths,
                    'Import header source is outside admitted inputs or terminal receipt')
        for key in counters:
            common.canonical_integer(receipt[key])
        integer(receipt['pending_previews'], 2**32 - 1, 'Invalid UInt32 pending preview counter')
        require(common.canonical_integer(receipt['failed']) == 0, 'Import failed counter')
    for key in counters:
        require(common.canonical_integer(start[key]) <= common.canonical_integer(finish[key]), 'Import counter regressed')
    require(finish['pending_previews'] == 0, 'Terminal previews still pending')
    require(finish['phase'] == 'complete' and finish['error'] is None, 'Import did not finish')
    for key, wanted in [('imported', 8), ('unchanged', 0), ('failed', 0), ('skipped', 0), ('awaiting_resources', 0)]:
        require(common.canonical_integer(finish[key]) == wanted, 'Wrong terminal import counter ' + key)
    browse = actions[3]
    require(browse['rowCount'] == 8 and browse['pageComplete'] is True and browse['hasMore'] is False and browse['nextCursor'] == '', 'Incomplete eight-source browse')
    row_by_name = {x['filename']: x for x in browse['rows']}
    require(set(row_by_name) == set(expected) and len({(x['asset_id'], x['variant_id']) for x in browse['rows']}) == 8,
            'Source/variant browse set mismatch')
    require(len({x['asset_id'] for x in browse['rows']}) == 8, 'Distinct source assets required')
    require(actions[4]['rows'] == browse['rows'] and actions[5]['rows'] == browse['rows'] and actions[6]['rows'] == [], 'Admitted row authority changed')
    delivered = {}
    for preview in actions[4]['previews']:
        name = text(preview['filename'])
        require(name in expected and name not in delivered, 'Unexpected/duplicated preview source')
        item, row = expected[name], row_by_name[name]
        require(all(preview[key] == row[key] for key in ['image_id', 'asset_id', 'variant_id']), 'Preview row authority mismatch')
        status = preview['status']
        text(status['ticket']); text(status['viewport'])
        common.preview_authority(preview)
        require(preview['tier'] == 'thumbnail' and native(preview['original']) ==
                native({'encoding': 'UnixBytes', 'units': list(bytes(artifact_path(item['source_path'])))}), 'Preview original/tier mismatch')
        integer(preview['width'], 2**32 - 1, 'Invalid width', 1); integer(preview['height'], 2**32 - 1, 'Invalid height', 1)
        require((preview['width'], preview['height']) == (item['width'], item['height']) and
                preview['colorSpace'] == 'srgb' and preview['alpha'] == 'opaque', 'Oriented preview geometry/color contract mismatch')
        samples = preview['samples']
        require(type(samples) is list and len(samples) == 6, 'Missing six samples')
        for sample, point in zip(samples, item['expected_samples']):
            integer(sample['x'], preview['width'] - 1, 'Invalid sample x'); integer(sample['y'], preview['height'] - 1, 'Invalid sample y')
            require([sample['x'], sample['y']] == point and type(sample['rgba']) is list and len(sample['rgba']) == 4,
                    'Sample coordinate/shape mismatch')
            for value in sample['rgba']:
                integer(value, 255, 'Invalid RGB8 sample')
            require(sample['rgba'][3] == 255, 'Thumbnail is not opaque')
        key = sha(status['diagnostic']['expected_key_digest'])
        delivered[name] = (key, integer(preview['encodedBytes'], 16 * 1024 * 1024, 'Encoded delivery size', 1), sha(preview['encodedSHA256']))
    require(set(delivered) == set(expected) and len({x[0] for x in delivered.values()}) == 8, 'Missing/aliased preview deliveries')
    pair = {x['filename']: x for x in actions[4]['previews']}
    require(pair['generated-irot.avif']['samples'] == pair['generated-irot-exif.avif']['samples'], 'Full six-pixel AVIF pair differs')

    settings = actions[5]['previewSettings']
    require(type(settings['previews_drained']) is bool, 'Required native drain field is not Bool')
    require(settings['relocation_pending'] is False and settings['relocation_tier'] is None and settings['relocation'] is None,
            'Cache relocation prevents a quiescent current-root proof')
    cache_root = native(settings['thumbnail_root']); native(settings['large_root'])
    common.canonical_integer(settings['thumbnail_bytes']); common.canonical_integer(settings['large_bytes'])
    audit = bundle['payload_audit']
    audit_dir = artifact_path(Path(audit['directory']))
    owner, result, payload = load(audit_dir / 'owner.json'), load(audit_dir / 'process-result.json'), load(audit_dir / 'payloads.json')
    phase = load(audit['quiescence_receipt'])
    root_path = artifact_path(Path(audit['native_root']))
    require(native(load(root_path)) == cache_root and phase['cache_root'] == cache_root and
            phase['observed_surviving_processes'] == [], 'Audit root/closed owner mismatch')
    for field, path in [('execution_sha256', execution_path), ('journey_sha256', journey_path), ('native_root_sha256', root_path),
                        ('owner_sha256', audit_dir / 'owner.json'), ('process_result_sha256', audit_dir / 'process-result.json'),
                        ('payloads_sha256', audit_dir / 'payloads.json')]:
        bind(phase, field, path)
    require(sha(phase['wrapper_sha256']) == WRAPPER and owner['auditor_sha256'] == AUDITOR and result['auditor_sha256'] == AUDITOR,
            'Audit qualification provenance mismatch')
    command = owner['command']
    require(type(command) is list and len(command) == 6 and Path(text(command[0])).is_absolute() and Path(command[0]).resolve(strict=True) == Path(sys.executable).resolve(strict=True) and
            artifact_path(command[1]) == scripts / 'audit-preview-payloads.py' and command[2] == '--native-root' and
            artifact_path(command[3]) == root_path and command[4] == '--output' and
            artifact_path(command[5]) == audit_dir / 'payloads.json', 'Wrong audit operation')
    integer(owner['pid'], 2**31 - 1, 'Invalid audit PID', 1)
    require(type(result['pid']) is int and result['pid'] == owner['pid'] and type(result['exit_code']) is int and
            result['exit_code'] == 0 and result['timed_out'] is False and result['reaped'] is True and result['status'] == 'RECORDED_ONLY', 'Audit failed or was not reaped')
    begin, end = clock(phase['started_epoch']), clock(phase['finished_epoch'])
    owner_time = datetime.datetime.fromisoformat(owner['start_utc'])
    elapsed = result['elapsed_seconds']
    require(owner_time.tzinfo is not None and type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 <= elapsed <= 85,
            'Invalid audit duration/time')
    actual_start = clock(owner['deadline_epoch']) - 75
    require(timeline['closed_epoch'] < begin <= actual_start <= owner_time.timestamp() <= actual_start + elapsed <= end and
            actual_start <= clock(payload['recorded_epoch']) <= actual_start + elapsed, 'Audit overlaps app or escaped owned phase')
    raw_root = Path(bytes(cache_root['units']).decode('utf-8', 'surrogateescape'))
    require(not audit_dir.is_relative_to(raw_root) and not root_path.is_relative_to(raw_root), 'Audit inputs/evidence are inside cache')
    require(native(payload['native_root']) == cache_root and str(raw_root) == payload['canonical_root'], 'Auditor inspected wrong root')
    records, objects = payload['records'], {}
    require(type(records) is list and len(records) <= 10000, 'Audit exceeds object bound')
    total = 0
    for record in records:
        key = sha(record['object_key'])
        relative = record['relative_path']
        require(relative == key[:2] + '/' + key[2:4] + '/' + key and key not in objects, 'Payload object path/key mismatch')
        size = integer(record['bytes'], 32 * 1024 * 1024, 'Invalid object size', 1)
        digest = sha(record['sha256']); total += size
        require(total <= 512 * 1024 * 1024, 'Audit exceeds aggregate bytes')
        file = raw_root / relative
        require(not any(parent.is_symlink() for parent in [file, *file.parents]) and
                file.stat().st_size == size and file_hash(file) == digest, 'Actual audited object bytes changed or traversed a symlink')
        objects[key] = (size, digest)
    require(type(payload['objects']) is int and payload['objects'] == len(objects) and type(payload['bytes']) is int and payload['bytes'] == total,
            'Audit aggregate count/bytes mismatch')
    require(all(objects.get(key) == (size, digest) for key, size, digest in delivered.values()), 'Delivered whole JPEG bytes lack cache custody')
    for name, (key, size, digest) in delivered.items():
        _, data = read_artifact(raw_root / (key[:2] + '/' + key[2:4] + '/' + key), 16 * 1024 * 1024, True)
        jpeg_extent(data, expected[name]['width'], expected[name]['height'])
    require(delivered['generated-irot.avif'][1:] == delivered['generated-irot-exif.avif'][1:], 'Audited whole JPEG pair differs')
    for path, digest in list(hashes.items()):
        require(file_hash(path) == digest, 'Input/source/payload changed before verdict')
    report = {'status': 'PASS_RETAINED_FORMAT_DELIVERY_LOCAL_ORACLE', 'checks': ['ordered seven actions and eight exact sources',
              'typed logical/Ready authority and oriented geometry', 'normal owner retirement and original source preservation',
              'whole encoded bytes after checked close', 'full six-pixel relational AVIF pair', 'recorded residency bounds'],
              'artifact_sha256': hashes, 'sources': 8, 'payloads': 8,
              'limitations': 'Delivery only. No absolute tiny-JPEG color, DNG math, ten-bit float precision, S08/editor, packaging, UI or complete S04 acceptance. Those gates require separate actual evidence. Sampled owners/RSS are not hard OS limits. Caller chronology is mandatory; no mtime inference.'}
    publish_fresh(output, report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.bundle.absolute(), args.output.absolute())))
