#!/usr/bin/env python3
"""Seal observed installed close/audit/next-launch chronology; acceptance is separate."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import time
import types

RUNNER = 'd0733d4606bc88d86982241bd125d883c39e1d9d9a928105996ca8575c1d3e3e'
WRAPPER = '4ce893980058bd52d70142b48f8e3d728fa13629abe98eb1fd395329cf9b371f'
AUDITOR = 'efa9657fb1fa0d4ce1ea0bc2e6a727e6996506599c5d554882656ce45aa4aca9'
STORAGE = '3e27f9b58f6ed900dfc71c1ea3c2ac5b4ae7ebe3e8ab088bdd07839376efc6be'
RETAINED = '9a5d2f564eff0004df3fa67d14db0851df9ef08c924036c10c622766cbf5fd98'
COMMON = '3fa500277b4e44d3aca6b1d960df9b879193d9e21f8934367e4e047eace9d2e0'
HELPERS = {'PhotoCatalogWorker': '1a501ed75841c27aad6a8b579f36c192024ea5c2ccab4b78e8f988b1ccab7c72',
           'LensWorksDecodeWorker': '421a01853f1bd87015056ab4c74a0c61b4085f30b58d77217b2547b6e656159e'}
FIELDS = {'previewSettings.thumbnail_root', 'previewSettings.large_root',
          'previewSettings.relocation.source', 'previewSettings.relocation.destination'}
SCHEDULES = {
    'retained_formats': [('thumbnail_delivery', 0, 0, 5, 'thumbnail_root')],
    'storage': [('thumbnail_source_1', 0, 0, 11, 'thumbnail_root'),
                ('thumbnail_partial_1', 0, 0, 11, 'relocation.destination'),
                ('large_source_1', 0, 0, 11, 'large_root'),
                ('thumbnail_destination_2', 1, 1, 3, 'thumbnail_root'),
                ('thumbnail_source_2', 1, 0, 11, 'thumbnail_root'),
                ('large_source_2', 1, 1, 9, 'large_root'),
                ('large_partial_2', 1, 1, 9, 'relocation.destination'),
                ('large_destination_3', 2, 2, 3, 'large_root'),
                ('large_source_3', 2, 1, 9, 'large_root'),
                ('thumbnail_destination_3', 2, 2, 3, 'thumbnail_root')]
}


def require(value, message):
    if not value:
        raise ValueError(message)


def clock(value):
    require(type(value) in (int, float) and math.isfinite(value) and value > 0, 'Invalid observed clock')
    return value


def integer(value, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum, 'Invalid integer authority')
    return value


def monotonic(value):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0, 'Invalid monotonic clock')
    return value


def canonical(path):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts and path == path.resolve(strict=True), 'Artifact alias/traversal')
    return path


def diagnostic(primary, note):
    primary.__notes__ = [*getattr(primary, '__notes__', []), note]
    try:
        print(note, file=sys.stderr)
    except Exception as error:
        failure = 'Diagnostic emission error: ' + str(error)
        primary.__notes__.append(failure)
        primary.diagnostic_emission_errors = [*getattr(primary, 'diagnostic_emission_errors', []), failure]


def close_all(fds, original):
    errors = []
    for fd in reversed(fds):
        identity = None
        try:
            s = os.fstat(fd)
            identity = (s.st_dev, s.st_ino, s.st_mode)
        except OSError as error:
            errors.append(error)
        try:
            os.close(fd)
        except OSError as error:
            errors.append(error)
            if identity is not None:
                try:
                    s = os.fstat(fd)
                    if (s.st_dev, s.st_ino, s.st_mode) == identity:
                        os.close(fd)
                except OSError as second:
                    if second.errno != 9:
                        errors.append(second)
    if errors:
        primary = original if original is not None else errors[0]
        secondary = errors if original is not None else errors[1:]
        if secondary:
            note = 'Descriptor cleanup errors: ' + '; '.join(str(x) for x in secondary)
            diagnostic(primary, note)
        if original is None:
            raise primary


def parent_descriptors(parent):
    fds = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
    try:
        for part in parent.parts[1:]:
            fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        return fds
    except Exception:
        close_all(fds, sys.exc_info()[1])
        raise


def fresh_directory(output, runner):
    canonical(output.parent)
    fds = parent_descriptors(output.parent)
    created = None
    mkdir_attempted = False
    mkdir_returned = False
    try:
        try:
            parent_identity = os.fstat(fds[-1])
            parent_current = canonical(output.parent).stat()
            require((parent_identity.st_dev, parent_identity.st_ino) == (parent_current.st_dev, parent_current.st_ino),
                    'Campaign parent changed before directory creation')
            mkdir_attempted = True
            os.mkdir(output.name, mode=0o700, dir_fd=fds[-1])
            mkdir_returned = True
            created = os.stat(output.name, dir_fd=fds[-1], follow_symlinks=False)
            actual = canonical(output).stat()
            require(stat.S_ISDIR(created.st_mode) and
                    (actual.st_dev, actual.st_ino) == (created.st_dev, created.st_ino), 'Campaign directory admission changed')
        finally:
            close_all(fds, sys.exc_info()[1])
    except Exception as error:
        if mkdir_attempted:
            # mkdir provides no creator inode. Even the first later stat may
            # observe a replacement, so it cannot authorize directory removal.
            receipt = {'status': 'DIRECTORY_CREATION_OWNERSHIP_UNKNOWN', 'path': str(output),
                       'mkdir_attempted': True, 'mkdir_returned': mkdir_returned,
                       'observed_leaf_identity': None if created is None else [created.st_dev, created.st_ino],
                       'cleanup': 'NOT_REMOVED_UNRESOLVED_OWNERSHIP', 'error': str(error),
                       'cleanup_errors': list(getattr(error, '__notes__', [])),
                       'emission_errors': list(getattr(error, 'diagnostic_emission_errors', [])),
                       'limitation': 'Post-mkdir lookup is observation, not creator ownership proof.'}
            error.directory_creation_receipt = receipt
            # No file is written into the uncertain directory or a replaced
            # parent. The structured failure travels with the original error
            # and is emitted to the caller log, including on Python 3.9.
            diagnostic(error, 'Directory creation ownership UNKNOWN: ' + json.dumps(receipt))
            receipt['emission_errors'] = list(getattr(error, 'diagnostic_emission_errors', []))
        raise
    return created


class Custody:
    def __init__(self, seconds):
        self.started = monotonic(time.monotonic())
        self.seconds = seconds
        self.hashes = {}
        self.limits = {}

    def remaining(self):
        elapsed = monotonic(time.monotonic()) - self.started
        require(elapsed >= 0, 'Campaign monotonic clock moved backwards')
        value = self.seconds - elapsed
        require(math.isfinite(value) and value > 0, 'Campaign deadline expired')
        return value

    def read(self, path, limit=8 * 1024 * 1024):
        path = canonical(path)
        self.limits[str(path)] = min(limit, self.limits.get(str(path), limit))
        limit = self.limits[str(path)]
        fds = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
        raw, count, digest = [], 0, hashlib.sha256()
        try:
            for part in path.parts[1:-1]:
                fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fds[-1])
            fds.append(fd)
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= limit,
                    'Artifact must be bounded unique regular file')
            while True:
                self.remaining()
                block = os.read(fd, 65536)
                if not block:
                    break
                count += len(block)
                require(count <= limit, 'Artifact grew beyond read bound')
                digest.update(block)
                raw.append(block)
            after = os.fstat(fd)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink)
            require(identity(before) == identity(after) and count == before.st_size, 'Artifact changed during held read')
        finally:
            close_all(fds, sys.exc_info()[1])
        value = digest.hexdigest()
        require(self.hashes.setdefault(str(path), value) == value, 'Campaign artifact changed')
        return value, b''.join(raw)

    def load(self, path, limit=8 * 1024 * 1024):
        digest, raw = self.read(path, limit)
        return digest, json.loads(raw)

    def stationary(self):
        for path, limit in list(self.limits.items()):
            self.read(path, limit)


def qualified(custody, path, expected):
    digest, raw = custody.read(path, 1024 * 1024)
    require(digest == expected, 'Dependency requires independent requalification: ' + str(path))
    module = types.ModuleType(Path(path).stem)
    module.__file__ = str(path)
    exec(compile(raw, str(path), 'exec'), module.__dict__)
    return module


def executable_name(command):
    try:
        words = shlex.split(command)
        return Path(words[0]).name if words else ''
    except ValueError:
        raise ValueError('Ambiguous process command')


def quiescent(runner, custody, reports, app_executable, native_gate=False):
    # Sample claimed identities explicitly; absence from a ps inventory alone
    # does not establish their retirement. Root owns exact resource admission.
    watched = {}
    for report in reports:
        for raw_pid, identity in report['owned_processes'].items():
            pid = int(raw_pid)
            previous = watched.setdefault(pid, identity)
            require((previous['birth'], previous['parent']) == (identity['birth'], identity['parent']),
                    'Conflicting claimed owner identity; no replacement admission')
    table = runner.processes(timeout=min(10, custody.remaining()), watched=watched)
    for report in reports:
        for pid, identity in report['owned_processes'].items():
            require(runner.owner_state(identity, table.get(int(pid))) == 'gone', 'Owned producer live/unknown')
    executables = [str(app_executable), *[str(app_executable.parent.parent / 'Helpers' / name) for name in HELPERS]]
    helper_root = str(app_executable.parent.parent / 'Helpers') + '/'
    unscoped = []
    for pid, identity in table.items():
        command = identity.get('command')
        if command is None:
            if pid not in watched:
                unscoped.append({'pid': pid, 'classification': 'UNSCOPED_NO_CURRENT_ARGV',
                                 'raw': dict(identity), 'package_association': None,
                                 'owner_admitted': False, 'signal_eligible': False,
                                 'lifecycle_inferred': False})
            continue  # Claimed owners passed strict retirement above; unscoped is not package evidence.
        require(not any(command == path or command.startswith(path + ' ') for path in executables) and
                not runner.package_helper(command, helper_root),
                'Admitted catalog producer prevents quiescent audit')
    # Current checkpoint uncertainty is retained in existing bounded receipts.
    # Unrelated names/no-argv rows do not veto this package or establish exits.
    # Mutable input/output guards remain Custody.stationary/fresh_directory.
    return unscoped


def root_from(selector, journeys):
    require(type(selector) is dict and set(selector) == {'run_index', 'action_index', 'field'}, 'Invalid root selector')
    run = integer(selector['run_index'], 0, len(journeys) - 1)
    actions = journeys[run]['catalogJourney']
    index = integer(selector['action_index'], 0, len(actions) - 1)
    row = actions[index]
    require(row['status'] == 'ok' and type(row['index']) is int and row['index'] == index, 'Root lacks successful public action authority')
    field = selector['field']
    require(type(field) is str and field in FIELDS, 'Unadvertised root selector')
    value = row
    for key in field.split('.'):
        value = value[key]
    require(type(value) is dict and value.get('encoding') == 'UnixBytes', 'Root must be a typed NativePath')
    units = value.get('units')
    require(type(units) is list and 1 <= len(units) <= 32768 and units[0] == 47 and
            all(type(x) is int and 1 <= x <= 255 for x in units) and
            all(x not in (b'', b'.', b'..') for x in bytes(units).split(b'/')[1:]), 'Invalid public root bytes')
    return value


def run(campaign_path, output, seconds):
    custody = Custody(integer(seconds, 10, 7200))
    scripts = canonical(Path(__file__).absolute().parent)
    own_path = canonical(Path(__file__).absolute())
    own_sha, _ = custody.read(own_path, 1024 * 1024)
    runner = qualified(custody, scripts / 'run-installed-catalog-plan.py', RUNNER)
    wrapper = qualified(custody, scripts / 'run-preview-payload-audit.py', WRAPPER)
    require(custody.read(scripts / 'audit-preview-payloads.py', 1024 * 1024)[0] == AUDITOR, 'Auditor changed')
    interpreter = Path(sys.executable).resolve(strict=True)
    interpreter_sha, _ = custody.read(interpreter, 96 * 1024 * 1024)
    campaign_sha, campaign = custody.load(campaign_path, 1024 * 1024)
    require(type(campaign) is dict and type(campaign.get('version')) is int and campaign['version'] == 1, 'Campaign version differs')
    profile = campaign['profile']
    require(type(profile) is str and profile in SCHEDULES, 'Unadvertised campaign profile')
    runs, audits = campaign['runs'], campaign['audits']
    require(type(runs) is list and len(runs) == (3 if profile == 'storage' else 1) and type(audits) is list and
            len(audits) == len(SCHEDULES[profile]), 'Missing required profile runs/audits')
    expected = [{'role': role, 'after_run_index': after, 'root_selector': {
        'run_index': source, 'action_index': action, 'field': 'previewSettings.' + field}}
        for role, after, source, action, field in SCHEDULES[profile]]
    require(audits == expected, 'Profile audit schedule/selector authority differs')
    semantic = qualified(custody, scripts / ('verify-catalog-storage-evidence.py' if profile == 'storage' else
                         'verify-catalog-retained-format-evidence.py'), STORAGE if profile == 'storage' else RETAINED)
    source_manifest = canonical(campaign['source_manifest'])
    _, fixture = custody.load(source_manifest)
    expected_sources = {}
    for item in fixture['sources'] + fixture.get('interruption_sources', []):
        source = canonical(source_manifest.parent / item['relative_path'])
        require(source.is_relative_to(source_manifest.parent) and str(source) not in expected_sources,
                'Fixture source escaped root or is duplicated')
        digest, _ = custody.read(source, 512 * 1024 * 1024)
        require(digest == item['sha256'], 'Original source changed before campaign')
        expected_sources[str(source)] = digest
    admitted_plans = []
    for spec in runs:
        require(type(spec) is dict and set(spec) == {'plan', 'deadline_seconds'}, 'Invalid run specification')
        integer(spec['deadline_seconds'], 10, 1800)
        plan_path = canonical(spec['plan'])
        plan_sha, plan_document = custody.load(plan_path, 1024 * 1024)
        require(type(plan_document.get('version')) is int and plan_document['version'] == 1 and
                type(plan_document.get('actions')) is list and 1 <= len(plan_document['actions']) <= 64 and
                plan_document['actions'][-1].get('kind') == 'close', 'Plan must have version1 and bounded terminal Close')
        admitted_plans.append((plan_path, plan_sha))
    if profile == 'storage':
        prior = campaign['prior_nested']
        require(type(prior) is dict and set(prior) == {'directory', 'plan', 'oracle_sha256'}, 'Missing prior nested prerequisite')
        custody.load(canonical(prior['plan']), 1024 * 1024)
        prior_directory = canonical(prior['directory'])
        for name in ('execution.json', 'journey.json', 'oracle-result.json'):
            custody.load(prior_directory / name)
        prior_sha, prior_oracle = custody.load(prior_directory / 'oracle-result.json')
        require(prior_sha == prior['oracle_sha256'] and prior_oracle['status'] == 'PASS_NESTED_LOCAL_ORACLE',
                'Accepted nested prerequisite missing')
        common = qualified(custody, scripts / 'verify-catalog-plan-evidence.py', COMMON)
        for field, path in [('execution', prior_directory / 'execution.json'), ('journey', prior_directory / 'journey.json'),
                            ('plan', canonical(prior['plan'])), ('manifest', source_manifest),
                            ('verifier', scripts / 'verify-catalog-plan-evidence.py')]:
            require(prior_oracle['artifact_sha256'][field] == custody.hashes[str(path)], 'Accepted nested companion changed')
        _, prior_execution = custody.load(prior_directory / 'execution.json')
        _, prior_journey = custody.load(prior_directory / 'journey.json')
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            (scratch / 'execution.json').write_text(json.dumps(prior_execution))
            (scratch / 'journey.json').write_text(json.dumps(prior_journey))
            common.verify(scratch, canonical(prior['plan']), source_manifest, 'nested')
    else:
        for field in ('compiled_sources', 'contract'):
            custody.load(canonical(campaign[field]), 1024 * 1024)
    app = Path(campaign['app']).resolve(strict=True)
    app_executable = canonical(app / 'Contents/MacOS/LensWorks')
    custody.read(app_executable, 96 * 1024 * 1024)
    provenance_path = canonical(campaign['helper_provenance'])
    provenance_sha, provenance = custody.load(provenance_path, 1024 * 1024)
    require(type(provenance) is list and len(provenance) == 2 and
            {Path(x['helper']).name for x in provenance} == {'PhotoCatalogWorker', 'LensWorksDecodeWorker'},
            'Both installed helpers require provenance')
    for name in ('PhotoCatalogWorker', 'LensWorksDecodeWorker'):
        helper = canonical(app / 'Contents/Helpers' / name)
        record = next(x for x in provenance if Path(x['helper']).name == name)
        require(canonical(record['helper']) == helper and
                record['source_sha256'] == HELPERS[name] and
                custody.read(helper, 96 * 1024 * 1024)[0] == record['signed_sha256'], 'Installed helper differs from provenance')
    roles = set()
    for audit in audits:
        require(type(audit) is dict and type(audit['role']) is str and audit['role'].isascii() and
                1 <= len(audit['role']) <= 64 and all(x.isalnum() or x == '_' for x in audit['role']), 'Invalid audit role')
        require(audit['role'] not in roles, 'Duplicate audit role')
        roles.add(audit['role'])
        after = integer(audit['after_run_index'], 0, len(runs) - 1)
        require(type(audit['root_selector']) is dict and
                integer(audit['root_selector']['run_index'], 0, len(runs) - 1) <= after, 'Audit selects a future run')
        integer(audit['root_selector']['action_index'], 0, 63)
    require({x['after_run_index'] for x in audits} == set(range(len(runs))), 'Every run requires a closed audit barrier')
    output = Path(output)
    require(output.is_absolute() and not os.path.lexists(output), 'Campaign output must be fresh')
    custody.stationary()
    directory_identity = fresh_directory(output, runner)
    reports, journeys, timelines, phases = [], [], [], []
    def publish(path, value):
        current = output.stat()
        require((current.st_dev, current.st_ino) == (directory_identity.st_dev, directory_identity.st_ino), 'Output directory changed')
        runner.publish_fresh(path, value)
        custody.load(path)
    try:
        for index, spec in enumerate(runs):
            custody.stationary()
            unscoped = quiescent(runner, custody, reports, app_executable, True)
            deadline = integer(spec['deadline_seconds'], 10, 1800)
            require(custody.remaining() > deadline + 35, 'Insufficient bounded run/retirement time')
            plan_path, plan_sha = admitted_plans[index]
            manifest_path = source_manifest
            plan_sha, _ = custody.load(plan_path, 1024 * 1024)
            custody.load(manifest_path)
            start, start_mono = clock(time.time()), monotonic(time.monotonic())
            if phases:
                require(all(x['finished_epoch'] < start for x in phases), 'Next launch overlaps previous audit')
            directory = output / ('run-' + str(index))
            runner.run(app, plan_path, directory, deadline, manifest_path)
            execution_sha, report = custody.load(directory / 'execution.json')
            journey_sha, journey = custody.load(directory / 'journey.json')
            require(report['status'] == 'EXECUTED_PENDING_ORACLE_ACCEPTANCE' and report['error'] is None and
                    report['cleanup_errors'] == [] and report['unknown_processes'] == [] and
                    report['observed_surviving_processes'] == [] and report['launcher_reaped'] is True and
                    report['normal_quit_observed'] is True and report['forced_cleanup'] is False and
                    type(report['launcher_exit']) is int and report['launcher_exit'] == 0 and
                    type(report['owner_overflow_count']) is int and report['owner_overflow_count'] == 0,
                    'Runner lacks checked-close eligibility')
            require(report['runner_sha256'] == RUNNER and report['plan_sha256'] == plan_sha and
                    report['journey_sha256'] == journey_sha and report['manifest_sha256'] == custody.hashes[str(manifest_path)] and
                    report['executable_sha256'] == custody.hashes[str(app_executable)], 'Runner artifact binding differs')
            require(type(report['elapsed_seconds']) in (int, float) and math.isfinite(report['elapsed_seconds']) and
                    type(report['deadline_seconds']) is int and report['deadline_seconds'] == deadline and
                    monotonic(report['started_monotonic']) <= monotonic(report['launch_monotonic']) <=
                    monotonic(report['completed_monotonic']) and
                    report['elapsed_seconds'] == report['completed_monotonic'] - report['started_monotonic'] and
                    type(report['source_states']) is list and all(x['state'] == 'unchanged' for x in report['source_states']),
                    'Runner monotonic/source authority invalid')
            source_rows = report['source_states']
            require(len(source_rows) == len(expected_sources) and
                    len({x['path'] for x in source_rows}) == len(source_rows) and
                    {x['path']: x['before'] for x in source_rows} == expected_sources and
                    {x['path']: x['after'] for x in source_rows} == expected_sources and
                    type(report['unchanged_source_count']) is int and report['unchanged_source_count'] == len(expected_sources),
                    'Runner source receipt is not manifest-complete')
            require(journey['error'] == '' and type(journey['catalogJourney']) is list, 'Journey failed')
            terminal = journey['catalogJourney'][-1]
            require(terminal['action'] == 'close' and terminal['status'] == 'ok' and
                    type(terminal['catalogPath']) is str and terminal['catalogPath'] == '' and
                    type(terminal['catalogToken']) is str and terminal['catalogToken'] == '', 'Successful terminal Close missing')
            reports.append(report)
            journeys.append(journey)
            unscoped = quiescent(runner, custody, reports, app_executable)
            custody.stationary()
            closed, closed_mono = clock(time.time()), monotonic(time.monotonic())
            require(start <= clock(report['started_epoch']) <= clock(report['launch_epoch']) <
                    clock(report['checked_closed_epoch']) <= clock(report['completed_epoch']) <= closed and
                    0 <= report['elapsed_seconds'] <= deadline and report['elapsed_seconds'] <= closed - start and
                    0 <= closed_mono - start_mono <= custody.seconds and closed - start >= closed_mono - start_mono - 0.05,
                    'Caller observed lifecycle/clock ordering invalid')
            timeline = {'version': 1, 'role': 'checked_closed_timeline', 'started_epoch': start, 'closed_epoch': closed,
                        'plan_sha256': plan_sha, 'execution_sha256': execution_sha, 'journey_sha256': journey_sha,
                        'helper_provenance_sha256': provenance_sha, 'runner_sha256': RUNNER,
                        'orchestrator_sha256': own_sha, 'observed_surviving_processes': [],
                        'unscoped_process_observations': unscoped}
            timeline_path = output / ('timeline-' + str(index) + '.json')
            publish(timeline_path, timeline)
            timelines.append({'directory': str(directory), 'plan': str(plan_path), 'timeline_receipt': str(timeline_path)})
            for audit in (x for x in audits if x['after_run_index'] == index):
                custody.stationary()
                unscoped = quiescent(runner, custody, reports, app_executable)
                root = root_from(audit['root_selector'], journeys)
                cache = Path(os.fsdecode(bytes(root['units'])))
                require(not output.is_relative_to(cache), 'Campaign evidence is inside cache')
                role = audit['role']
                native_path = output / (role + '-native-root.json')
                publish(native_path, root)
                begin, begin_mono = clock(time.time()), monotonic(time.monotonic())
                require(closed < begin and custody.remaining() > 85, 'Audit must follow sealed close within campaign budget')
                audit_directory = output / ('audit-' + role)
                wrapper.run(native_path, audit_directory)
                owner_sha, owner = custody.load(audit_directory / 'owner.json')
                result_sha, result = custody.load(audit_directory / 'process-result.json')
                payload_sha, payload = custody.load(audit_directory / 'payloads.json')
                integer(owner['pid'], 1, 2**31 - 1)
                integer(result['pid'], 1, 2**31 - 1)
                require(result['pid'] == owner['pid'] and
                        type(result['exit_code']) is int and result['exit_code'] == 0 and result['reaped'] is True and
                        result['timed_out'] is False and result['status'] == 'RECORDED_ONLY' and
                        owner['auditor_sha256'] == AUDITOR and result['auditor_sha256'] == AUDITOR and
                        payload['native_root'] == root, 'Audit failed or inspected a different root')
                command = owner['command']
                require(command == [str(sys.executable), str(scripts / 'audit-preview-payloads.py'), '--native-root',
                                    str(native_path), '--output', str(audit_directory / 'payloads.json')], 'Wrong owned audit operation')
                unscoped = quiescent(runner, custody, reports, app_executable)
                custody.stationary()
                end, end_mono = clock(time.time()), monotonic(time.monotonic())
                actual_start = clock(owner['deadline_epoch']) - 75
                owner_start = datetime.datetime.fromisoformat(owner['start_utc'])
                elapsed = result['elapsed_seconds']
                require(owner_start.tzinfo is not None and type(elapsed) in (int, float) and math.isfinite(elapsed) and
                        0 <= elapsed <= 85 and begin <= actual_start <= owner_start.timestamp() <= actual_start + elapsed <= end and
                        actual_start <= clock(payload['recorded_epoch']) <= actual_start + elapsed and
                        0 <= end_mono - begin_mono and end - begin >= end_mono - begin_mono - 0.05, 'Audit escaped observed clock span')
                phase = {'version': 1, 'role': role, 'started_epoch': begin, 'finished_epoch': end,
                         'execution_sha256': execution_sha, 'journey_sha256': journey_sha,
                         'native_root_sha256': custody.hashes[str(native_path)], 'owner_sha256': owner_sha,
                         'process_result_sha256': result_sha, 'payloads_sha256': payload_sha, 'cache_root': root,
                         'wrapper_sha256': WRAPPER, 'orchestrator_sha256': own_sha, 'interpreter_sha256': interpreter_sha,
                         'root_selector': audit['root_selector'],
                         'root_journey_sha256': custody.hashes[str(output / ('run-' + str(audit['root_selector']['run_index'])) / 'journey.json')],
                         'observed_surviving_processes': [], 'unscoped_process_observations': unscoped}
                phase_path = output / (role + '-quiescence.json')
                publish(phase_path, phase)
                phases.append(phase)
        custody.stationary()
        unscoped = quiescent(runner, custody, reports, app_executable)
        if profile == 'storage':
            bundle = {'prior_nested': campaign['prior_nested'], 'runs': timelines,
                      'audits': {x['role']: {'directory': str(output / ('audit-' + x['role'])),
                                'native_root': str(output / (x['role'] + '-native-root.json')),
                                'quiescence_receipt': str(output / (x['role'] + '-quiescence.json'))} for x in audits}}
        else:
            audit = audits[0]
            role = audit['role']
            bundle = {**timelines[0], 'helper_provenance': str(provenance_path),
                      'compiled_sources': str(canonical(campaign['compiled_sources'])),
                      'contract': str(canonical(campaign['contract'])), 'source_manifest': str(source_manifest),
                      'payload_audit': {'directory': str(output / ('audit-' + role)),
                                       'native_root': str(output / (role + '-native-root.json')),
                                       'quiescence_receipt': str(output / (role + '-quiescence.json'))}}
        bundle_path, oracle_path = output / 'bundle.json', output / 'oracle.json'
        publish(bundle_path, bundle)
        if profile == 'storage':
            semantic.verify(bundle_path, source_manifest, oracle_path)
        else:
            semantic.verify(bundle_path, oracle_path)
        oracle_sha, oracle = custody.load(oracle_path)
        require(oracle['status'] == ('PASS_STORAGE_EVIDENCE' if profile == 'storage' else 'PASS_RETAINED_FORMAT_DELIVERY_LOCAL_ORACLE'),
                'Semantic oracle did not accept scoped evidence')
        custody.stationary()
        unscoped = quiescent(runner, custody, reports, app_executable)
        report = {'status': 'RECORDED_WITH_SCOPED_ORACLE_ACCEPTANCE', 'campaign_sha256': campaign_sha,
                  'oracle_sha256': oracle_sha, 'profile': profile,
                  'orchestrator_sha256': own_sha, 'runs': timelines,
                  'audits': {x['role']: {'directory': str(output / ('audit-' + x['role'])),
                            'native_root': str(output / (x['role'] + '-native-root.json')),
                            'quiescence_receipt': str(output / (x['role'] + '-quiescence.json'))} for x in audits},
                  'unscoped_process_observations': unscoped,
                  'limitation': 'Current checkpoint no-argv rows are unscoped uncertainty, not package/owner/exit evidence or a historical full-tree census. Observed chronology only. Directory admission observes a nofollow path/inode, not creator ownership against an undetected precapture replacement. Semantic, package, UI and whole-story acceptance remain separate.'}
        publish(output / 'campaign.json', report)
        return report
    except Exception as error:
        try:
            publish(output / 'failure.json', {'status': 'FAIL', 'error': str(error), 'completed_runs': len(timelines),
                                             'completed_audits': len(phases), 'orchestrator_sha256': own_sha})
        except Exception as publication_error:
            runner.finish_cleanup([publication_error], error)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--campaign', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deadline-seconds', type=int, default=7200)
    args = parser.parse_args()
    print(json.dumps(run(args.campaign, args.output, args.deadline_seconds)))
