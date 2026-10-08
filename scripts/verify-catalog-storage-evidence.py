#!/usr/bin/env python3
"""Verify three closed-owner storage journeys; qualification precedes actual use."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import errno
import os
import stat
import sys
from pathlib import Path
import re
import tempfile

COMMON = '3fa500277b4e44d3aca6b1d960df9b879193d9e21f8934367e4e047eace9d2e0'
MANIFEST = 'a0d04ab1aadac7539081586cbae994e2376d6487cd5e898ff259f13e3e4d0507'
AUDITOR = 'efa9657fb1fa0d4ce1ea0bc2e6a727e6996506599c5d554882656ce45aa4aca9'
WRAPPER = '4ce893980058bd52d70142b48f8e3d728fa13629abe98eb1fd395329cf9b371f'


def require(value, message):
    if not value:
        raise ValueError(message)


def integer(value, ceiling, label, minimum=0):
    require(type(value) is int and minimum <= value <= ceiling, label)
    return value


def epoch(value):
    require(type(value) in (int, float) and math.isfinite(value) and value > 0,
            'Invalid chronological receipt time')
    return value


def digest(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256')
    return value


def native(value):
    require(type(value) is dict and value.get('encoding') == 'UnixBytes', 'Invalid NativePath')
    units = value.get('units')
    require(type(units) is list and 1 <= len(units) <= 32768 and units[0] == 47,
            'Invalid absolute NativePath')
    for unit in units:
        integer(unit, 255, 'Invalid NativePath byte', 1)
    require(all(part not in (b'', b'.', b'..') for part in bytes(units).split(b'/')[1:]),
            'Noncanonical NativePath')
    return value


def path_native(value):
    require(type(value) is str, 'Path must be text')
    return native({'encoding': 'UnixBytes', 'units': list(value.encode('utf-8'))})


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


def verify(bundle_path, manifest_path, output):
    output = Path(output)
    require(not os.path.lexists(output), 'Use a new verdict path; never reuse a prior PASS')
    artifact_path(output.parent)
    bundle_path, manifest_path = artifact_path(bundle_path), artifact_path(manifest_path)
    self_path = artifact_path(Path(__file__).absolute())
    hashes, limits = {}, {}

    def read_artifact(path, maximum=96 * 1024 * 1024, retain=False):
        path = artifact_path(path)
        previous_limit = limits.setdefault(str(path), maximum)
        maximum = min(maximum, previous_limit)
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

    def load(path, maximum=8 * 1024 * 1024):
        _, data = read_artifact(path, maximum, True)
        return json.loads(data)

    file_hash(self_path)
    interpreter = Path(sys.executable).resolve(strict=True)
    file_hash(interpreter)

    def bound(receipt, field, path):
        require(digest(receipt[field]) == hashes[str(artifact_path(path))], 'Receipt artifact changed: ' + field)

    common_path = Path(__file__).with_name('verify-catalog-plan-evidence.py')
    for name, expected_sha in [('verify-catalog-plan-evidence.py', COMMON),
                               ('audit-preview-payloads.py', AUDITOR),
                               ('run-preview-payload-audit.py', WRAPPER)]:
        path = artifact_path(Path(__file__).with_name(name).absolute())
        file_hash(path)
        require(hashes[str(path)] == expected_sha, 'Qualified evidence tool changed: ' + name)
    require(file_hash(common_path) == COMMON, 'Requalify common verifier')
    spec = importlib.util.spec_from_file_location('storage_common', common_path)
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    manifest = load(manifest_path)
    require(hashes[str(artifact_path(manifest_path))] == MANIFEST, 'Qualified color manifest changed')
    require(len(manifest['sources']) == 9, 'Nine independent source fixtures required')
    bundle = load(bundle_path)
    prior = bundle['prior_nested']
    prior_directory, prior_plan_path = artifact_path(prior['directory']), artifact_path(prior['plan'])
    prior_execution = load(prior_directory / 'execution.json')
    prior_journey = load(prior_directory / 'journey.json')
    prior_plan = load(prior_plan_path, 1024 * 1024)
    prior_verdict = load(prior_directory / 'oracle-result.json')
    require(prior_verdict['status'] == 'PASS_NESTED_LOCAL_ORACLE', 'Accepted nested color proof required')
    bound(prior, 'oracle_sha256', prior_directory / 'oracle-result.json')
    for field, path in [('execution', prior_directory / 'execution.json'),
                        ('journey', prior_directory / 'journey.json'), ('plan', prior_plan_path),
                        ('manifest', manifest_path), ('verifier', common_path)]:
        require(prior_verdict['artifact_sha256'][field] == hashes[str(artifact_path(path))], 'Accepted nested artifact changed')
    with tempfile.TemporaryDirectory() as temporary:
        scratch = Path(temporary)
        (scratch / 'execution.json').write_text(json.dumps(prior_execution))
        (scratch / 'journey.json').write_text(json.dumps(prior_journey))
        common.verify(scratch, prior_plan_path, manifest_path, 'nested')
    prior_rows = prior_journey['catalogJourney']
    color_authority = {}
    for action in prior_rows:
        for preview in action.get('previews', []):
            color_authority[preview['filename']] = preview
    names = {Path(s['relative_path']).name for s in manifest['sources']}
    require(set(color_authority) == names, 'Prior proof lacks the full color source set')
    edit_index = next(i for i, a in enumerate(prior_rows) if a['action'] == 'editPreview')
    edited = prior_rows[edit_index]['afterVariant']
    edit_ev = prior_plan['actions'][edit_index]['exposureEV']

    def expected_rgb(source, preview):
        values = source['expected_srgb_rgb8']
        if preview['status']['key'] != edited['key']:
            return values
        def exposure(value):
            encoded = value / 255
            linear = encoded / 12.92 if encoded <= 0.04045 else ((encoded + 0.055) / 1.055) ** 2.4
            linear = min(1, linear * 2 ** edit_ev)
            return round(255 * (12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055))
        return [[exposure(value) for value in patch] for patch in values]
    runs = bundle['runs']
    require(type(runs) is list and len(runs) == 3, 'Three fresh process runs required')
    expected = [
        ['open', 'browse', 'preview', 'preview', 'previewSettings', 'setPreviewBudgets',
         'beginRootReview', 'resumeSettings', 'waitSettings', 'beginRelocation',
         'stepRelocation', 'pauseSettings', 'close'],
        ['open', 'previewSettings', 'resumeSettings', 'waitSettings', 'resumePreviews',
         'browse', 'preview', 'beginRelocation', 'stepRelocation', 'pauseSettings', 'close'],
        ['open', 'previewSettings', 'resumeSettings', 'waitSettings', 'resumePreviews',
         'browse', 'preview', 'close']]
    actions, plans, receipts, pids = [], [], [], set()
    executable = catalog = None
    source_root = path_native(str(artifact_path(manifest_path.parent / 'Sources')))
    delivered = {}
    for index, run in enumerate(runs):
        directory, plan_path = artifact_path(run['directory']), artifact_path(run['plan'])
        plan, execution, journey = load(plan_path, 1024 * 1024), load(directory / 'execution.json'), load(directory / 'journey.json')
        receipt = load(run['timeline_receipt'])
        for field, path in [('plan_sha256', plan_path), ('execution_sha256', directory / 'execution.json'),
                            ('journey_sha256', directory / 'journey.json')]:
            bound(receipt, field, path)
        require(epoch(receipt['started_epoch']) < epoch(receipt['closed_epoch']), 'Invalid run chronology')
        if receipts:
            require(receipts[-1]['closed_epoch'] < receipt['started_epoch'], 'Process runs overlap')
        require([a['kind'] for a in plan['actions']] == expected[index], 'Storage plan sequence differs')
        require(type(journey['error']) is str and journey['error'] == '', 'Native journey failed')
        require(execution['error'] is None and type(execution['launcher_exit']) is int and
                execution['launcher_exit'] == 0 and execution['cleanup_errors'] == [] and
                execution['observed_surviving_processes'] == [], 'Normal owner retirement missing')
        observed = execution['application_pids']
        require(type(observed) is list and bool(observed) and len(set(observed)) == len(observed), 'Invalid app PIDs')
        for pid in observed:
            integer(pid, 2**31 - 1, 'Invalid app PID', 1)
        require(pids.isdisjoint(observed), 'Not distinct fresh processes')
        pids.update(observed)
        digest(execution['executable_sha256'])
        executable = executable or execution['executable_sha256']
        require(executable == execution['executable_sha256'], 'App executable changed across runs')
        # The stationary generic verifier supplies source, geometry and residency checks.
        # Its intermediate result stays in a temporary directory, never a PASS artifact.
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            (scratch / 'execution.json').write_text(json.dumps(execution))
            (scratch / 'journey.json').write_text(json.dumps(journey))
            common.verify(scratch, plan_path, manifest_path, 'storage')
        rows = journey['catalogJourney']
        require(type(rows) is list and len(rows) == len(expected[index]), 'Incomplete actual actions')
        catalog = catalog or plan['actions'][0]['path']
        require(plan['actions'][0]['path'] == catalog, 'Catalog changed across storage processes')
        require(catalog == prior_plan['actions'][0]['path'] and executable == prior_execution['executable_sha256'],
                'Storage catalog or executable differs from accepted color proof')
        tier_roles = [['thumbnail', 'large'], ['thumbnail'], ['large']]
        require([a['tier'] for a in plan['actions'] if a['kind'] == 'preview'] == tier_roles[index], 'Wrong tier role')
        if index == 0:
            budget = next(a for a in plan['actions'] if a['kind'] == 'setPreviewBudgets')
            roots_request = next(a for a in plan['actions'] if a['kind'] == 'beginRootReview')
            require(budget['thumbnailBytes'] == '67108864' and budget['largeBytes'] == '134217728', 'Wrong budget request')
            require([path_native(p) for p in roots_request['paths']] == [source_root], 'Wrong original-root review request')
        for action, request in zip(rows, plan['actions']):
            require(action['catalogPath'] == ('' if request['kind'] == 'close' else catalog), 'Catalog authority mismatch')
            require(type(action['catalogToken']) is str and
                    bool(action['catalogToken']) == (request['kind'] != 'close'), 'Catalog token mismatch')
            for row in action['rows'] + action.get('previews', []):
                require(all(type(row[k]) is str and row[k] for k in ('image_id', 'asset_id', 'variant_id', 'filename')),
                        'Incomplete typed image identity')
            if request['kind'] == 'browse':
                require(path_native(request['folderPath']) == source_root and request['recursive'] is True,
                        'Wrong storage source scope')
                require(len(action['rows']) == 9 and {r['filename'] for r in action['rows']} == names,
                        'Storage browse does not contain exact nine-source membership')
                require(all(tuple(r[k] for k in ('image_id', 'asset_id', 'variant_id')) ==
                            tuple(color_authority[r['filename']][k] for k in ('image_id', 'asset_id', 'variant_id'))
                            for r in action['rows']), 'Browse identity differs from color authority')
            if request['kind'] == 'waitSettings':
                integer(request['timeoutMilliseconds'], 60000, 'Invalid settings observer budget', 1)
            if request['kind'] == 'preview':
                tier = request['tier']
                previews = action['previews']
                names = {Path(s['relative_path']).name for s in manifest['sources']}
                require(len(previews) == 9 and {p['filename'] for p in previews} == names, 'Both tiers require all nine sources')
                rendered = {}
                for preview in previews:
                    require(preview['tier'] == tier, 'Preview tier mismatch')
                    status = preview['status']
                    prior_preview = color_authority[preview['filename']]
                    require(all(preview[k] == prior_preview[k] for k in ('image_id', 'asset_id', 'variant_id')) and
                            all(status[k] == prior_preview['status'][k] for k in ('key', 'revision', 'recipe_digest')),
                            'Current preview differs from accepted recipe/variant authority')
                    require(preview['colorSpace'] == 'srgb' and preview['alpha'] == 'opaque', 'Wrong color/alpha contract')
                    source = next(s for s in manifest['sources'] if Path(s['relative_path']).name == preview['filename'])
                    for observed, target in zip(preview['samples'], expected_rgb(source, preview)):
                        require(all(abs(value - expected) <= 3 for value, expected in zip(observed['rgba'][:3], target)),
                                'Independent current-recipe RGB oracle failed')
                    require({r['filename']: tuple(r[k] for k in ('image_id', 'asset_id', 'variant_id')) for r in action['rows']} ==
                            {n: tuple(p[k] for k in ('image_id', 'asset_id', 'variant_id')) for n, p in color_authority.items()},
                            'Preview-action browse projection differs from actual source authority')
                    require(type(status['ticket']) is str and status['ticket'] and
                            type(status['viewport']) is str and status['viewport'], 'Invalid preview owner authority')
                    integer(preview['encodedBytes'], 16 * 1024 * 1024, 'Invalid encoded bytes', 1)
                    diagnostic = status['diagnostic']
                    key = diagnostic.get('selected_key_digest')
                    if key is None:
                        require(diagnostic['route'] == 'original_render', 'Expected-key fallback requires actual original render')
                        key = diagnostic['expected_key_digest']
                    digest(key)
                    rendered[preview['filename']] = (
                        preview['image_id'], preview['asset_id'], preview['variant_id'],
                        status['revision'], status['recipe_digest'], key,
                        preview['encodedBytes'], digest(preview['encodedSHA256']))
                require(len({x[1:3] for x in rendered.values()}) == 9, 'Duplicate source VariantKeys')
                if tier in delivered:
                    require(rendered == delivered[tier], 'Fresh-session preview payload or identity changed')
                else:
                    delivered[tier] = rendered
        require(rows[-1]['rows'] == [] and rows[-1]['rowCount'] == 0, 'Closed catalog retained visible rows')
        actions.append(rows); plans.append(plan['actions']); receipts.append(receipt)
    require(set(delivered) == {'thumbnail', 'large'}, 'Both tiers required')

    def settings(run, kind, occurrence=0):
        return [a['previewSettings'] for a in actions[run] if a['action'] == kind][occurrence]

    def ready(status):
        require(status['thumbnail_bytes'] == '67108864' and status['large_bytes'] == '134217728', 'Budgets changed')
        roots = status['original_roots']
        require(roots['state'] == 'ready' and roots['roots'] == [source_root] and roots['review'] is None and
                roots['uncovered'] is None and roots['message'] is None, 'Original roots not verified')
        common.canonical_integer(roots['checked_directories'])
        native(status['thumbnail_root']); native(status['large_root'])

    review = settings(0, 'beginRootReview')['original_roots']
    require(review['state'] == 'reviewing' and type(review['review']) is str and review['review'] and
            review['roots'] == [source_root], 'No real original-root review authority')
    roots = []
    for run, tier in ((0, 'thumbnail'), (1, 'large')):
        initial, stepped, paused = settings(run, 'beginRelocation'), settings(run, 'stepRelocation'), settings(run, 'pauseSettings')
        for status in (initial, stepped, paused):
            ready(status)
            require(status['relocation_pending'] is True and status['relocation_tier'] == tier, 'Relocation tier missing')
        relocation = stepped['relocation']
        request = next(a for a in plans[run] if a['kind'] == 'beginRelocation')
        step_request = next(a for a in plans[run] if a['kind'] == 'stepRelocation')
        require(request['tier'] == tier and step_request['tier'] == tier and
                type(step_request['objects']) is int and step_request['objects'] == 1 and
                step_request['bytes'] == '1048576', 'Wrong actual one-object step')
        source, destination = native(relocation['source']), path_native(request['path'])
        require(source != destination and relocation['destination'] == destination, 'Relocation roots mismatch')
        require(initial['relocation']['source'] == source and initial['relocation']['destination'] == destination and
                initial['relocation']['phase'] == 'copy' and initial['relocation']['objects'] == '0' and
                initial['relocation']['bytes'] == '0', 'Relocation did not begin in empty copy phase')
        require(initial['relocation']['total_objects'] == relocation['total_objects'] and
                initial['relocation']['total_bytes'] == relocation['total_bytes'], 'Relocation begin totals changed')
        require(all(status[tier + '_root'] == source for status in (initial, stepped, paused)), 'Relocation source is not current public root')
        other = 'large' if tier == 'thumbnail' else 'thumbnail'
        require(initial[other + '_root'] == stepped[other + '_root'] == paused[other + '_root'], 'Unmoved tier root changed')
        require(relocation['phase'] == 'copy' and relocation['objects'] == '1', 'Not a genuine partial copy')
        copied = common.canonical_integer(relocation['bytes'])
        require(0 < copied <= 1048576 and common.canonical_integer(relocation['total_objects']) > 1 and
                common.canonical_integer(relocation['total_bytes']) >= copied, 'Invalid partial counters/totals')
        reopened = settings(run + 1, 'previewSettings')
        ready(reopened)
        require(paused == actions[run][-1]['previewSettings'] == reopened and paused['relocation'] == relocation,
                'Same-phase paused checkpoint changed across fresh reopen')
        require(settings(run + 1, 'previewSettings')['relocation_pending'] is True and
                settings(run + 1, 'previewSettings')['relocation_tier'] == tier, 'Paused relocation disappeared')
        finished = settings(run + 1, 'waitSettings')
        ready(finished)
        require(finished[tier + '_root'] == destination and finished['relocation_pending'] is False and
                finished['relocation'] is None and finished['relocation_tier'] is None, 'Relocation did not promote destination')
        require(finished[other + '_root'] == paused[other + '_root'], 'Completion changed the other tier root')
        roots.append((source, destination, relocation))

    root_pair = [native(settings(0, 'previewSettings')[tier + '_root']) for tier in ('thumbnail', 'large')]
    for run, rows in enumerate(actions):
        for row in rows:
            status = row.get('previewSettings')
            if status is None:
                continue
            if run in (1, 2) and row['action'] == 'waitSettings':
                root_pair[run - 1] = roots[run - 1][1]
            require([native(status[tier + '_root']) for tier in ('thumbnail', 'large')] == root_pair,
                    'Public tier roots changed outside their completed relocation')

    expected_audits = {
        'thumbnail_source_1': (0, roots[0][0]), 'thumbnail_partial_1': (0, roots[0][1]),
        'large_source_1': (0, roots[1][0]), 'thumbnail_destination_2': (1, roots[0][1]),
        'thumbnail_source_2': (1, roots[0][0]), 'large_source_2': (1, roots[1][0]),
        'large_partial_2': (1, roots[1][1]), 'large_destination_3': (2, roots[1][1]),
        'large_source_3': (2, roots[1][0]), 'thumbnail_destination_3': (2, roots[0][1])}
    require(type(bundle['audits']) is dict and set(bundle['audits']) == set(expected_audits), 'Missing or extra audit roles')
    payloads = {}
    audit_directories = set()
    for role, (run, root) in expected_audits.items():
        supplied = bundle['audits'][role]
        directory = artifact_path(supplied['directory'])
        require(directory not in audit_directories, 'Audit roles must have unique directories')
        audit_directories.add(directory)
        owner, result, report = load(directory / 'owner.json'), load(directory / 'process-result.json'), load(directory / 'payloads.json')
        phase = load(supplied['quiescence_receipt'])
        bound(phase, 'execution_sha256', Path(runs[run]['directory']) / 'execution.json')
        bound(phase, 'journey_sha256', Path(runs[run]['directory']) / 'journey.json')
        bound(phase, 'payloads_sha256', directory / 'payloads.json')
        bound(phase, 'process_result_sha256', directory / 'process-result.json')
        bound(phase, 'owner_sha256', directory / 'owner.json')
        root_path = artifact_path(supplied['native_root'])
        require(native(load(root_path, 1024 * 1024)) == root, 'Audit input differs from public root')
        bound(phase, 'native_root_sha256', root_path)
        raw_root = bytes(root['units']).decode('utf-8', 'surrogateescape')
        require(not directory.is_relative_to(Path(raw_root)) and not root_path.is_relative_to(Path(raw_root)),
                'Audit evidence or NativeRoot input is inside cache')
        command = owner['command']
        require(type(command) is list and len(command) == 6 and
                type(command[0]) is str and Path(command[0]).is_absolute() and
                Path(command[0]).resolve(strict=True) == interpreter and
                artifact_path(command[1]) == artifact_path(Path(__file__).with_name('audit-preview-payloads.py').absolute()) and
                command[2] == '--native-root' and artifact_path(command[3]) == root_path and
                command[4] == '--output' and artifact_path(command[5]) == directory / 'payloads.json',
                'Audit owner command is not the qualified root/output operation')
        require(phase['observed_surviving_processes'] == [] and phase['cache_root'] == root,
                'Caller closed-owner quiescence missing')
        begin, end = epoch(phase['started_epoch']), epoch(phase['finished_epoch'])
        owner_time = datetime.datetime.fromisoformat(owner['start_utc'])
        require(owner_time.tzinfo is not None, 'Audit owner time lacks timezone')
        require(receipts[run]['closed_epoch'] < begin <= owner_time.timestamp() <= end and
                begin <= epoch(report['recorded_epoch']) <= end, 'Audit did not follow checked close')
        actual_start = epoch(owner['deadline_epoch']) - 75
        elapsed = result['elapsed_seconds']
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 <= elapsed <= 85,
                'Invalid or unbounded audit duration')
        require(begin <= actual_start <= owner_time.timestamp() <= actual_start + elapsed <= end and
                actual_start <= report['recorded_epoch'] <= actual_start + elapsed, 'Audit actual lifecycle escaped phase receipt')
        if run < 2:
            require(end < receipts[run + 1]['started_epoch'], 'Cache audit overlaps next app process')
        require(digest(phase['wrapper_sha256']) == WRAPPER and owner['auditor_sha256'] == AUDITOR and
                result['auditor_sha256'] == AUDITOR, 'Qualified audit provenance changed')
        integer(owner['pid'], 2**31 - 1, 'Invalid audit owner PID', 1)
        require(type(result['pid']) is int and result['pid'] == owner['pid'] and type(result['exit_code']) is int and
                result['exit_code'] == 0 and result['timed_out'] is False and result['reaped'] is True and
                result['status'] == 'RECORDED_ONLY', 'Audit failed, timed out or did not reap')
        require(native(report['native_root']) == root and path_native(report['canonical_root']) == root, 'Wrong audited public root')
        records = report['records']
        require(type(records) is list and len(records) <= 10000, 'Payload object bound exceeded')
        table = {}
        paths = set()
        for record in records:
            key = digest(record['object_key'])
            require(key not in table, 'Duplicate payload key')
            relative = record['relative_path']
            require(type(relative) is str and 1 <= len(relative.encode('utf-8')) <= 32768,
                    'Invalid relative payload path')
            parts = relative.split('/')
            require(parts == [key[:2], key[2:4], key] and relative not in paths, 'Payload path/key/depth mismatch')
            paths.add(relative)
            size = integer(record['bytes'], 32 * 1024 * 1024, 'Payload size invalid', 1)
            table[key] = (size, digest(record['sha256']))
        require(type(report['objects']) is int and report['objects'] == len(table), 'Payload count mismatch')
        total = integer(report['bytes'], 512 * 1024 * 1024, 'Aggregate payload bytes invalid')
        require(total == sum(x[0] for x in table.values()), 'Payload byte sum mismatch')
        payloads[role] = table
    for tier, source_role, partial_role, final_role, empty_role in (
            ('thumbnail', 'thumbnail_source_1', 'thumbnail_partial_1', 'thumbnail_destination_2', 'thumbnail_source_2'),
            ('large', 'large_source_1', 'large_partial_2', 'large_destination_3', 'large_source_3')):
        baseline, partial = payloads[source_role], payloads[partial_role]
        relocation = roots[0 if tier == 'thumbnail' else 1][2]
        require(len(baseline) > 1 and len(partial) == 1 and all(baseline.get(k) == v for k, v in partial.items()), 'Partial copy not exact baseline subset')
        require(common.canonical_integer(relocation['total_objects']) == len(baseline) and
                common.canonical_integer(relocation['total_bytes']) == sum(v[0] for v in baseline.values()) and
                common.canonical_integer(relocation['bytes']) == sum(v[0] for v in partial.values()), 'Public counters differ from actual payloads')
        require(payloads[final_role] == baseline and payloads[empty_role] == {}, 'Full payload conservation or source cleanup failed')
        for row in delivered[tier].values():
            require(baseline.get(row[5]) == (row[6], row[7]), 'Delivered encoded bytes do not bind actual cached object')
    require(payloads['large_source_2'] == payloads['large_source_1'] and
            payloads['thumbnail_destination_3'] == payloads['thumbnail_source_1'], 'Other tier payloads changed during relocation')
    require(all(read_artifact(Path(path), limits[path])[0] == value for path, value in list(hashes.items())),
            'Evidence or qualified source changed during verification')
    report = {'status': 'PASS_STORAGE_EVIDENCE', 'artifact_sha256': hashes,
              'verifier_sha256': hashes[str(self_path)],
              'limitation': 'Defined three-process storage evidence only; no full S04, RAW, HDR, CI or supported-host acceptance.'}
    require(str(output) not in hashes, 'Output would overwrite input evidence')
    publish_fresh(output, report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.bundle.absolute(), args.manifest.absolute(), args.output.absolute())))
