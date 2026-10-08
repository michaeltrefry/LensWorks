#!/usr/bin/env python3
"""Record bounded installed-plan ownership and immutable chronology; oracles accept separately."""
import argparse
import ctypes
import errno
import hashlib
import json
import math
import os
import re
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import time


def require(value, message):
    if not value:
        raise ValueError(message)


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


PROC_PIDTBSDINFO = 3
DARWIN_SZOMB = 5  # sys/proc.h: SZOMB, awaiting collection by parent
MAXCOMLEN = 16  # <sys/param.h>


class ProcBsdInfo(ctypes.Structure):
    # Field order and widths from <sys/proc_info.h>, struct proc_bsdinfo.
    _fields_ = [('flags', ctypes.c_uint32), ('status', ctypes.c_uint32),
                ('xstatus', ctypes.c_uint32), ('pid', ctypes.c_uint32),
                ('ppid', ctypes.c_uint32), ('uid', ctypes.c_uint32),
                ('gid', ctypes.c_uint32), ('ruid', ctypes.c_uint32),
                ('rgid', ctypes.c_uint32), ('svuid', ctypes.c_uint32),
                ('svgid', ctypes.c_uint32), ('reserved', ctypes.c_uint32),
                ('comm', ctypes.c_char * MAXCOMLEN),
                ('name', ctypes.c_char * (2 * MAXCOMLEN)),
                ('nfiles', ctypes.c_uint32), ('pgid', ctypes.c_uint32),
                ('pjobc', ctypes.c_uint32), ('tdev', ctypes.c_uint32),
                ('tpgid', ctypes.c_uint32), ('nice', ctypes.c_int32),
                ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


_libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
_proc_pidinfo = _libproc.proc_pidinfo
_proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                          ctypes.c_void_p, ctypes.c_int]
_proc_pidinfo.restype = ctypes.c_int


def process_birth(pid):
    info = ProcBsdInfo()
    ctypes.set_errno(0)
    size = _proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
    error = ctypes.get_errno()
    if size != ctypes.sizeof(info) or info.pid != pid:
        return None, error or errno.EIO
    return {'pid': info.pid, 'parent': info.ppid,
            'birth': [info.start_sec, info.start_usec], 'status': info.status}, None


def raw_processes(timeout=10):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,rss=,args='], text=True, timeout=timeout)
    result = {}
    for line in rows.splitlines():
        fields = line.strip().split(None, 8)
        if len(fields) == 9:
            result[int(fields[0])] = {'parent': int(fields[1]), 'started': ' '.join(fields[2:7]),
                                     'rss_kib': int(fields[7]), 'command': fields[8]}
    return result


def processes(timeout=10, watched=(), _recapture=True, _helper_root=None):
    # The first ps result is PID inventory only. Take procinfo, then obtain the
    # sole argv/PPID sample, then procinfo again. Never pair inventory argv or
    # PPID with a later birth record.
    sample_started = time.monotonic()
    def remaining():
        value = timeout - (time.monotonic() - sample_started)
        require(finite_clock(value, True), 'Process observation budget exhausted')
        return value
    inventory = raw_processes(remaining())
    expected_owners = watched if isinstance(watched, dict) else {}
    watched = set(watched)
    before_ids = {pid: process_birth(pid) for pid in sorted(set(inventory) | watched)}
    current = raw_processes(remaining())
    after_ids = {pid: process_birth(pid) for pid in sorted(set(inventory) | set(current) | watched)}
    result = {}
    pids = set(inventory) | set(current) | watched
    for pid in sorted(pids):
        row = current.get(pid)
        old_identity, old_error = before_ids.get(pid, (None, errno.ESRCH))
        new_identity, new_error = after_ids.get(pid, (None, errno.ESRCH))
        if pid not in inventory and row is None and old_error == errno.ESRCH and new_error == errno.ESRCH:
            result[pid] = {'parent': None, 'started': None, 'rss_kib': 0, 'command': None,
                           'listed': False, 'gone_confirmed': True, 'birth': None,
                           'status': None, 'identity_stable': True, 'identity_error': errno.ESRCH,
                           'parent_identity': None, 'inventory_only': False, 'inventory_listed': False,
                           'status_pair': {'before': None, 'after': None},
                           'identity_pair': {'before_birth': None, 'after_birth': None,
                                             'before_parent': None, 'after_parent': None,
                                             'before_error': old_error, 'after_error': new_error}}
            continue
        same_birth = (old_identity is not None and new_identity is not None and
                      old_identity['birth'] == new_identity['birth'])
        same_parent = (same_birth and old_identity['parent'] == new_identity['parent'] and
                       row is not None and row['parent'] == old_identity['parent'] and
                       row['parent'] == new_identity['parent'])
        current_row = dict(row or {})
        parent = new_identity['parent'] if new_identity is not None else None
        parent_before, parent_before_error = before_ids.get(parent, (None, errno.ESRCH)) if parent is not None else (None, errno.ESRCH)
        parent_after, parent_after_error = after_ids.get(parent, (None, errno.ESRCH)) if parent is not None else (None, errno.ESRCH)
        parent_identity_stable = (parent_before is not None and parent_after is not None and
                                  parent_before['birth'] == parent_after['birth'] and
                                  parent_before['parent'] == parent_after['parent'])
        current_row.update({
            'ps_parent': row['parent'] if row is not None else None,
            'parent': parent if parent is not None else None,
            'birth': new_identity['birth'] if new_identity is not None else None,
            'status': new_identity['status'] if new_identity is not None else None,
            'status_pair': {'before': old_identity['status'] if old_identity else None,
                            'after': new_identity['status'] if new_identity else None},
            'identity_stable': bool(same_birth and same_parent),
            'identity_pair': {'before_birth': old_identity['birth'] if old_identity else None,
                              'after_birth': new_identity['birth'] if new_identity else None,
                              'before_parent': old_identity['parent'] if old_identity else None,
                              'after_parent': new_identity['parent'] if new_identity else None,
                              'before_error': old_error, 'after_error': new_error},
            'identity_error': None if same_birth and same_parent else (new_error or old_error or errno.EIO),
            'listed': row is not None,
            'inventory_only': pid in inventory and row is None,
            'inventory_listed': pid in inventory,
            'gone_confirmed': False,
            'command_transition': None,
            'parent_transition': ([old_identity['parent'], new_identity['parent']]
                                  if old_identity is not None and new_identity is not None and
                                  old_identity['parent'] != new_identity['parent'] else None),
            'parent_consistent': bool(same_parent and parent_identity_stable),
            'parent_identity': ([parent, parent_after['birth']]
                                if parent_identity_stable else None),
            'parent_identity_pair': {'before_birth': parent_before['birth'] if parent_before else None,
                                     'after_birth': parent_after['birth'] if parent_after else None,
                                     'before_error': parent_before_error,
                                     'after_error': parent_after_error}})
        result[pid] = current_row
    if _recapture:
        pending = {}
        for pid, row in result.items():
            pair = row.get('identity_pair') or {}
            before, after = before_ids.get(pid, (None, errno.ESRCH))[0], after_ids.get(pid, (None, errno.ESRCH))[0]
            expected_owner = expected_owners.get(pid)
            retirement = (expected_owner is not None and expected_owner.get('birth') is not None
                          and absence_boundary(row))
            if retirement:
                pending[pid] = ('retirement_absence', expected_owner)
                continue
            if row.get('identity_stable'):
                continue
            # Only recorded sampling boundaries get ONE new bracket.
            # Observed reuse, PPID mismatch, and non-ESRCH errors are never retried.
            parent_owner = expected_owners.get(row.get('parent'))
            newborn = (pid not in expected_owners and row.get('listed') and pid not in inventory and before is None and pair.get('before_error') == errno.ESRCH
                       and after is not None and row.get('ps_parent') == after['parent']
                       and _helper_root is not None and package_helper(row.get('command'), _helper_root)
                       and parent_owner is not None and owner_state(parent_owner, result.get(after['parent'])) == 'live'
                       and row.get('parent_identity') == [after['parent'], parent_owner.get('birth')])
            expected_owner = expected_owners.get(pid)
            crossing = (expected_owner is not None and before is not None and after is None
                        and pair.get('after_error') == errno.ESRCH
                        and (not row.get('listed') or row.get('ps_parent') == before['parent'])
                        and before['birth'] == expected_owner.get('birth')
                        and before['parent'] == expected_owner.get('parent'))
            parent_owner = expected_owners.get(before['parent']) if before is not None else None
            unadmitted_crossing = (pid not in expected_owners and before is not None and after is None and
                                   row.get('listed') is True and row.get('inventory_listed') is True and
                                   _helper_root is not None and package_helper(row.get('command'), _helper_root) and
                                   row.get('ps_parent') == before['parent'] and
                                   pair.get('before_birth') == before['birth'] and
                                   pair.get('before_parent') == before['parent'] and
                                   pair.get('before_error') is None and
                                   pair.get('after_birth') is None and pair.get('after_parent') is None and
                                   pair.get('after_error') == errno.ESRCH and parent_owner is not None and
                                   owner_state(parent_owner, result.get(before['parent'])) == 'live')
            if newborn or crossing or unadmitted_crossing:
                if newborn:
                    pending[pid] = ('newborn', after)
                elif crossing:
                    pending[pid] = ('exit_crossing', before)
                else:
                    pending[pid] = ('unadmitted_exit_crossing',
                                    {'pid': before['parent'], 'birth': parent_owner.get('birth')})
        if pending:
            fresh = processes(timeout=remaining(), watched=pending, _recapture=False, _helper_root=_helper_root)
            for pid, (kind, expected) in pending.items():
                initial = result[pid]
                latest = fresh.get(pid)
                resolution = 'unresolved'
                if latest is not None and latest.get('gone_confirmed'):
                    resolution = 'confirmed_absent'
                elif kind == 'retirement_absence' and latest is not None and absence_boundary(latest):
                    resolution = 'awaiting_absence'
                elif kind == 'exit_crossing' and owned_exit_inventory_pending(expected_owners.get(pid), initial, latest):
                    resolution = 'awaiting_absence'
                elif kind == 'unadmitted_exit_crossing' and unadmitted_exit_crossing_pending(expected, initial, latest, _helper_root):
                    resolution = 'awaiting_absence'
                elif kind == 'newborn' and latest is not None and latest.get('identity_stable') and latest.get('parent_consistent'):
                    if (latest.get('birth') == expected['birth'] and latest.get('parent') == expected['parent']
                            and latest.get('parent_identity') == initial.get('parent_identity')
                            and latest.get('command') == initial.get('command')):
                        resolution = 'fresh_stable_birth_parent_command'
                # Exact held crossing may remain pending through inventory-only
                # ESRCH; it resolves ONLY by later complete watched absence.
                # Returned live, reused, churned, or missing rows remain FAIL.
                row = dict(latest if latest is not None else initial)
                if resolution in ('unresolved', 'awaiting_absence'):
                    row.update(identity_stable=False, parent_consistent=False,
                               identity_error=errno.EIO, gone_confirmed=False)
                row['pending_boundary'] = {'kind': kind, 'resolution': resolution,
                    'initial': boundary_record(initial), 'recapture': boundary_record(latest)}
                if kind == 'retirement_absence' or (kind == 'exit_crossing' and resolution == 'awaiting_absence'):
                    row['pending_boundary']['expected_owner'] = {
                        'birth': expected['birth'], 'parent': expected.get('parent')}
                elif kind == 'unadmitted_exit_crossing' and resolution == 'awaiting_absence':
                    row['pending_boundary']['expected_parent'] = expected
                result[pid] = row
    return result


def boundary_record(row):
    if row is None:
        return None
    return {name: row.get(name) for name in ('command', 'ps_parent', 'parent', 'birth',
        'status', 'status_pair', 'identity_pair', 'parent_identity', 'identity_error',
        'listed', 'gone_confirmed', 'identity_stable', 'inventory_only', 'inventory_listed')}


def absence_boundary(row):
    # A raw PID observation with two ESRCH reads is not yet complete absence.
    # Neither raw command text nor guessed process status establishes retirement.
    pair = row.get('identity_pair') or {} if row is not None else {}
    return bool(row is not None and not row.get('gone_confirmed') and
                (row.get('listed') or row.get('inventory_only')) and
                pair.get('before_birth') is None and pair.get('after_birth') is None and
                pair.get('before_error') == errno.ESRCH and pair.get('after_error') == errno.ESRCH)


def retirement_boundary_matches_owner(identity, current):
    boundary = current.get('pending_boundary') or {} if current is not None else {}
    expected = boundary.get('expected_owner') or {}
    return bool(identity is not None and identity.get('birth') is not None and
                (boundary.get('kind') == 'retirement_absence' or
                 (boundary.get('kind') == 'exit_crossing' and boundary.get('resolution') == 'awaiting_absence' and
                  owned_exit_inventory_pending(identity, boundary.get('initial'), boundary.get('recapture')))) and
                expected.get('birth') == identity.get('birth') and
                expected.get('parent') == identity.get('parent'))


def owned_exit_inventory_pending(identity, initial, recapture):
    # Only the held owner's exact raw argv/PPID crossing can extend the existing
    # retirement wait. Inventory-only ESRCH is pending, never lifecycle proof.
    pair = initial.get('identity_pair') or {} if initial is not None else {}
    later = recapture.get('identity_pair') or {} if recapture is not None else {}
    statuses = recapture.get('status_pair') or {} if recapture is not None else {}
    fields = {'before_birth', 'after_birth', 'before_parent', 'after_parent', 'before_error', 'after_error'}
    return bool(identity is not None and identity.get('birth') is not None and identity.get('parent') is not None and
                type(identity.get('last_command')) is str and bool(identity['last_command']) and
                initial is not None and initial.get('listed') is True and
                initial.get('command') == identity['last_command'] and initial.get('ps_parent') == identity['parent'] and
                set(pair) >= fields and pair['before_birth'] == identity['birth'] and
                pair['before_parent'] == identity['parent'] and pair['before_error'] is None and
                pair['after_birth'] is None and pair['after_parent'] is None and pair['after_error'] == errno.ESRCH and
                inventory_only_esrch(recapture) and set(later) >= fields and
                recapture.get('command') is None and recapture.get('status') is None and
                recapture.get('parent_identity') is None and recapture.get('identity_error') == errno.ESRCH and
                set(statuses) >= {'before', 'after'} and statuses['before'] is None and statuses['after'] is None)


def retirement_pending_events(pid, identity, current):
    # Retain the original held owner. The pending state never admits a new birth
    # or signal; a later live/reused/error row is still a receipt failure.
    events = []
    if retirement_boundary_matches_owner(identity, current) and not identity.get('retirement_pending'):
        identity['retirement_pending'] = True
        identity['signal_eligible'] = False
        events.append({'kind': 'retirement_pending_entered', 'pid': pid,
                       'expected_birth': identity['birth'], 'raw': boundary_record(current)})
    if identity.get('retirement_pending') and current is not None and current.get('gone_confirmed'):
        identity['retirement_pending'] = False
        events.append({'kind': 'retirement_pending_confirmed_absent', 'pid': pid,
                       'expected_birth': identity['birth'], 'raw': boundary_record(current)})
    return events


def held_display_exit_uncertainty(identity, current):
    # Parenthesized ps text does not attest argv, status, or exit. An already
    # held native identity may only wait unsignalably for complete absence.
    boundary = current.get('pending_boundary') or {} if current is not None else {}
    first, later = boundary.get('initial') or {}, boundary.get('recapture') or {}
    pair = first.get('identity_pair') or {}
    fields = {'before_birth', 'after_birth', 'before_parent', 'after_parent', 'before_error', 'after_error'}
    raw = first.get('command')
    return bool(identity is not None and identity.get('birth') is not None and identity.get('parent') is not None and
                type(identity.get('last_command')) is str and bool(identity['last_command']) and
                identity.get('last_command') == identity.get('command') and
                boundary.get('kind') == 'exit_crossing' and boundary.get('resolution') == 'unresolved' and
                first.get('listed') is True and first.get('ps_parent') == identity['parent'] and
                type(raw) is str and re.fullmatch(r'\([^()\r\n]+\)', raw) and
                set(pair) >= fields and pair['before_birth'] == identity['birth'] and
                pair['before_parent'] == identity['parent'] and pair['before_error'] is None and
                pair['after_birth'] is None and pair['after_parent'] is None and pair['after_error'] == errno.ESRCH and
                commandless_inventory_uncertainty(later) and inventory_only_esrch(current) and
                current.get('command') is None and current.get('ps_parent') is None and
                current.get('status') is None and current.get('parent_identity') is None)


def commandless_inventory_uncertainty(current):
    statuses = current.get('status_pair') or {} if current is not None else {}
    pair = current.get('identity_pair') or {} if current is not None else {}
    fields = {'before_birth', 'after_birth', 'before_parent', 'after_parent', 'before_error', 'after_error'}
    return bool(inventory_only_esrch(current) and current.get('command') is None and
                current.get('ps_parent') is None and set(pair) >= fields and
                current.get('status') is None and current.get('parent_identity') is None and
                current.get('identity_error') == errno.ESRCH and
                set(statuses) >= {'before', 'after'} and statuses['before'] is None and statuses['after'] is None)


def inventory_only_esrch(row):
    pair = row.get('identity_pair') or {} if row is not None else {}
    return bool(row is not None and row.get('inventory_listed') is True and
                row.get('inventory_only') is True and row.get('listed') is False and
                row.get('birth') is None and row.get('parent') is None and
                pair.get('before_birth') is None and pair.get('after_birth') is None and
                pair.get('before_parent') is None and pair.get('after_parent') is None and
                pair.get('before_error') == errno.ESRCH and pair.get('after_error') == errno.ESRCH)


def newborn_pending_entry(pid, row, owned, helper_root):
    boundary = row.get('pending_boundary') or {} if row is not None else {}
    initial, recapture = boundary.get('initial') or {}, boundary.get('recapture')
    pair = initial.get('identity_pair') or {}
    parent = owned.get(initial.get('parent'))
    if (pid in owned or boundary.get('kind') != 'newborn' or
            boundary.get('resolution') != 'unresolved' or not inventory_only_esrch(recapture) or
            not inventory_only_esrch(row) or initial.get('inventory_listed') is not False or
            initial.get('listed') is not True or not package_helper(initial.get('command'), helper_root) or
            pair.get('before_birth') is not None or pair.get('before_parent') is not None or
            pair.get('before_error') != errno.ESRCH or pair.get('after_error') is not None or
            initial.get('birth') is None or pair.get('after_birth') != initial.get('birth') or
            pair.get('after_parent') != initial.get('parent') or
            initial.get('ps_parent') != initial.get('parent') or parent is None or
            parent.get('birth') is None or
            initial.get('parent_identity') != [initial.get('parent'), parent['birth']]):
        return None
    # The real processes() newborn predicate checked the initial live held
    # parent. This record retains that proof without owning or signaling child.
    return {'state': 'pending', 'initial': initial, 'recapture': recapture}


def newborn_pending_state(record, current):
    if current is None:
        return 'failed'
    pair = current.get('identity_pair') or {}
    if (current.get('gone_confirmed') is True and current.get('listed') is False and
            current.get('inventory_listed') is False and current.get('birth') is None and
            current.get('parent') is None and pair.get('before_parent') is None and
            pair.get('after_parent') is None and
            pair.get('before_birth') is None and pair.get('after_birth') is None and
            pair.get('before_error') == errno.ESRCH and pair.get('after_error') == errno.ESRCH):
        return 'resolved_absent'
    initial = record['initial']
    if (current.get('listed') is True and current.get('identity_stable') is True and
            current.get('parent_consistent') is True and current.get('birth') == initial['birth'] and
            current.get('parent') == initial['parent'] and current.get('ps_parent') == initial['parent'] and
            pair.get('before_birth') == initial['birth'] and pair.get('after_birth') == initial['birth'] and
            pair.get('before_parent') == initial['parent'] and pair.get('after_parent') == initial['parent'] and
            pair.get('before_error') is None and pair.get('after_error') is None and
            current.get('identity_error') is None and
            current.get('parent_identity') == initial['parent_identity'] and
            current.get('command') == initial['command']):
        return 'resolved_stable'
    return 'pending' if inventory_only_esrch(current) else 'failed'


def newborn_admission_allowed(records, pid):
    return pid not in records or records[pid]['state'] == 'resolved_stable'


def same_birth(identity, current):
    return (current is not None and identity.get('birth') is not None and
            current.get('birth') == identity['birth'])


def owner_state(identity, current):
    if current is None:
        return 'unknown'
    if current.get('gone_confirmed'):
        if identity.get('display_exit_uncertainty') and not complete_watched_absence(current):
            return 'unknown'
        return 'gone'
    if current.get('birth') is not None and current.get('birth') != identity.get('birth'):
        return 'reused'
    boundary = current.get('pending_boundary') or {}
    if (retirement_boundary_matches_owner(identity, current) and
            boundary.get('resolution') == 'awaiting_absence' and absence_boundary(current)):
        return 'pending'
    if identity.get('display_exit_uncertainty'):
        return 'pending' if (held_display_exit_uncertainty(identity, current) or
                             commandless_inventory_uncertainty(current)) else 'unknown'
    if identity.get('retirement_pending'):
        return 'unknown'
    if not current.get('identity_stable'):
        return 'unknown'
    if current.get('birth') == identity.get('birth') and terminal_status_confirmed(current):
        return 'terminal'
    if (current.get('status_pair') or {}).get('before') == DARWIN_SZOMB:
        return 'unknown'
    if identity.get('terminal_status_seen') and current.get('listed'):
        return 'unknown'
    if current.get('birth') is None:
        if not current.get('listed') and current.get('identity_error') == errno.ESRCH:
            return 'gone'
        return 'unknown'
    if current['birth'] != identity.get('birth'):
        return 'reused'
    if not current.get('listed'):
        return 'unknown'
    return 'live' if current['command'] == identity.get('command') else 'changed'


def terminal_status_confirmed(row):
    statuses = row.get('status_pair') or {}
    return bool(row.get('identity_stable') and
                statuses.get('before') == DARWIN_SZOMB and statuses.get('after') == DARWIN_SZOMB)


def command_transition_fails(state, identity, current):
    return bool(current is not None and current.get('listed') and
                current.get('command') != identity.get('last_command') and state != 'terminal')


def package_helper(command, helper_root):
    return isinstance(command, str) and command.startswith(helper_root)


def launcher_row_admissible(row, pid, launcher_pid, runner_pid, runner_birth):
    return bool(row is not None and pid == launcher_pid and row.get('birth') is not None and
                row.get('identity_stable') and row.get('parent_consistent') and
                row.get('parent') == runner_pid and runner_birth is not None and
                row.get('parent_identity') == [runner_pid, runner_birth])


def is_direct_launcher_pid(pid, launcher_pid, admission_failed=False):
    return launcher_pid is not None and pid == launcher_pid and not admission_failed


def reaped_launcher_residue(pid, identity, current, launcher_pid, launcher_exit,
                            launcher_reaped, admission_failed):
    # Only the exact strongly admitted, exclusive Popen's successful waitpid
    # receipt can settle its unidentified raw residue. This grants no signal.
    if (not is_direct_launcher_pid(pid, launcher_pid, admission_failed) or
            launcher_reaped is not True or type(launcher_exit) is not int or launcher_exit != 0 or
            identity is None or identity.get('birth') is None or identity.get('parent') is None or
            current is None or current.get('birth') is not None or current.get('parent') is not None):
        return False
    pair = current.get('identity_pair') or {}
    if not (pair.get('before_birth') is None and pair.get('after_birth') is None and
            pair.get('before_parent') is None and pair.get('after_parent') is None and
            pair.get('before_error') == errno.ESRCH and pair.get('after_error') == errno.ESRCH):
        return False
    if current.get('listed') and current.get('ps_parent') != identity.get('parent'):
        return False
    boundary = current.get('pending_boundary') or {}
    initial = boundary.get('initial')
    if initial is not None:
        first = initial.get('identity_pair') or {}
        if not (first.get('after_birth') is None and first.get('after_parent') is None and
                first.get('after_error') == errno.ESRCH and
                ((first.get('before_birth') == identity['birth'] and
                  first.get('before_parent') == identity['parent'] and first.get('before_error') is None) or
                 (first.get('before_birth') is None and first.get('before_parent') is None and
                  first.get('before_error') == errno.ESRCH))):
            return False
        if initial.get('listed') and initial.get('ps_parent') != identity.get('parent'):
            return False
    return True


def complete_watched_absence(row):
    pair = row.get('identity_pair') or {} if row is not None else {}
    return bool(row is not None and row.get('gone_confirmed') is True and
                row.get('listed') is False and row.get('inventory_listed') is False and
                row.get('birth') is None and row.get('parent') is None and
                pair.get('before_birth') is None and pair.get('after_birth') is None and
                pair.get('before_parent') is None and pair.get('after_parent') is None and
                pair.get('before_error') == errno.ESRCH and pair.get('after_error') == errno.ESRCH)


def direct_launcher_exit_residue_pending(pid, identity, current, launcher_pid, launcher_reaped, admission_failed):
    # This is observational deferral only: an exact direct Popen child can cross
    # exit between its normal poll and raw snapshot. Raw <defunct> text does not
    # establish status, cause, retirement, or signal authority.
    if (not is_direct_launcher_pid(pid, launcher_pid, admission_failed) or
            launcher_reaped is True or identity is None or
            identity.get('birth') is None or identity.get('parent') is None or
            current is None):
        return False
    if not identity.get('direct_reap_pending') and identity.get('signal_eligible') is not True:
        return False
    boundary = current.get('pending_boundary') or {}
    initial, recapture = boundary.get('initial') or {}, boundary.get('recapture') or {}
    first, later = initial.get('identity_pair') or {}, recapture.get('identity_pair') or {}
    statuses = recapture.get('status_pair') or {}
    fields = {'before_birth', 'after_birth', 'before_parent', 'after_parent', 'before_error', 'after_error'}
    return bool(boundary.get('kind') == 'exit_crossing' and
                boundary.get('resolution') == 'unresolved' and
                initial.get('listed') is True and initial.get('ps_parent') == identity['parent'] and
                set(first) >= fields and first['before_birth'] == identity['birth'] and
                first['before_parent'] == identity['parent'] and first['before_error'] is None and
                first['after_birth'] is None and first['after_parent'] is None and
                first['after_error'] == errno.ESRCH and
                recapture.get('command') == '<defunct>' and recapture.get('listed') is True and
                recapture.get('ps_parent') == identity['parent'] and
                recapture.get('birth') is None and recapture.get('parent') is None and
                recapture.get('status') is None and recapture.get('parent_identity') is None and
                recapture.get('identity_error') == errno.ESRCH and
                set(later) >= fields and later['before_birth'] is None and later['after_birth'] is None and
                later['before_parent'] is None and later['after_parent'] is None and
                later['before_error'] == errno.ESRCH and later['after_error'] == errno.ESRCH and
                set(statuses) >= {'before', 'after'} and statuses['before'] is None and statuses['after'] is None)


def direct_launcher_complete_absence_pending(pid, identity, current, launcher_pid, launcher_reaped, admission_failed):
    # The marker was admitted only by the exact crossing predicate. Before the
    # retained Popen is reaped, complete raw absence remains observationally
    # pending and unsignalable; it is not retirement proof.
    return bool(is_direct_launcher_pid(pid, launcher_pid, admission_failed) and
                launcher_reaped is False and identity is not None and
                identity.get('direct_reap_pending') is True and
                identity.get('birth') is not None and identity.get('parent') is not None and
                complete_watched_absence(current))


def helper_birth_unavailable_event(pid, row, held):
    return {'kind': 'helper_birth_unavailable', 'pid': pid, 'held': held,
            'raw': boundary_record(row)}



def unadmitted_exit_crossing_pending(expected_parent, initial, recapture, helper_root):
    # This is an observation-only classification. The before procinfo sample
    # proves neither a child lifecycle nor an owner. It solely lets the runner
    # watch this raw package PID until a later complete absence.
    pair = initial.get('identity_pair') or {} if initial is not None else {}
    later = recapture.get('identity_pair') or {} if recapture is not None else {}
    statuses = initial.get('status_pair') or {} if initial is not None else {}
    fields = {'before_birth', 'after_birth', 'before_parent', 'after_parent', 'before_error', 'after_error'}
    return bool(expected_parent is not None and type(expected_parent.get('pid')) is int and
                expected_parent.get('birth') is not None and initial is not None and
                initial.get('listed') is True and initial.get('inventory_listed') is True and
                package_helper(initial.get('command'), helper_root) and
                initial.get('ps_parent') == expected_parent['pid'] and
                initial.get('birth') is None and initial.get('parent') is None and
                initial.get('parent_identity') is None and initial.get('status') is None and
                initial.get('identity_stable') is False and initial.get('identity_error') == errno.ESRCH and
                set(pair) >= fields and pair['before_birth'] is not None and
                pair['before_parent'] == expected_parent['pid'] and pair['before_error'] is None and
                pair['after_birth'] is None and pair['after_parent'] is None and
                pair['after_error'] == errno.ESRCH and
                set(statuses) >= {'before', 'after'} and statuses['after'] is None and
                inventory_only_esrch(recapture) and set(later) >= fields and
                recapture.get('command') is None and recapture.get('status') is None and
                recapture.get('parent_identity') is None and recapture.get('identity_error') == errno.ESRCH)


def unadmitted_exit_crossing_entry(pid, row, owned, newborn_records, helper_observations,
                                    records, helper_root):
    boundary = row.get('pending_boundary') or {} if row is not None else {}
    initial, recapture = boundary.get('initial') or {}, boundary.get('recapture')
    expected = boundary.get('expected_parent') or {}
    parent = owned.get(expected.get('pid'))
    if (pid in owned or pid in newborn_records or pid in records or
            any(key[0] == pid for key in helper_observations) or
            boundary.get('kind') != 'unadmitted_exit_crossing' or
            boundary.get('resolution') != 'awaiting_absence' or parent is None or
            parent.get('birth') != expected.get('birth') or
            not unadmitted_exit_crossing_pending(expected, initial, recapture, helper_root)):
        return None
    return {'state': 'pending', 'expected_parent': expected,
            'initial': initial, 'recapture': recapture}


def unadmitted_exit_crossing_state(record, current):
    if complete_watched_absence(current):
        return 'resolved_absent'
    # A raw inventory-only ESRCH row is incomplete, never retirement evidence.
    return 'pending' if inventory_only_esrch(current) else 'failed'


def unbound_helper_uncertainty(pid, row, owned, newborn_records, helper_observations, helper_root):
    # Raw argv is not identity or lineage. This classification never admits an
    # owner, retrospectively binds a later identity, or establishes an exit.
    if (pid in owned or pid in newborn_records or
            any(key[0] == pid for key in helper_observations) or row.get('pending_boundary') is not None):
        return False
    pair = row.get('identity_pair') or {}
    statuses = row.get('status_pair') or {}
    return (package_helper(row.get('command'), helper_root) and row.get('listed') is True and
            row.get('birth') is None and row.get('parent') is None and
            row.get('parent_identity') is None and row.get('status') is None and
            row.get('identity_stable') is False and row.get('identity_error') == errno.ESRCH and
            set(pair) >= {'before_birth', 'after_birth', 'before_parent', 'after_parent',
                          'before_error', 'after_error'} and
            all(pair[name] is None for name in ('before_birth', 'after_birth', 'before_parent', 'after_parent')) and
            pair['before_error'] == errno.ESRCH and pair['after_error'] == errno.ESRCH and
            set(statuses) >= {'before', 'after'} and statuses['before'] is None and statuses['after'] is None)


def signal_target_eligible(identity, current):
    statuses = current.get('status_pair') or {} if current is not None else {}
    return bool(identity.get('signal_eligible') and owner_state(identity, current) == 'live' and
                statuses.get('before') != DARWIN_SZOMB and statuses.get('after') != DARWIN_SZOMB and
                not identity.get('terminal_status_seen'))


def owners_retired(owned, current, launcher_pid, launcher_exit, launcher_reaped, app_pids, helpers):
    if (launcher_exit != 0 or not launcher_reaped or not app_pids or helpers or
            any(identity.get('direct_reap_pending') for identity in owned.values())):
        return False
    return all(owner_state(identity, current.get(pid)) == 'gone'
               for pid, identity in owned.items()
               if not (launcher_reaped and pid == launcher_pid))


def census_unowned_helpers(current, owned, helper_root):
    found = []
    for pid, row in current.items():
        command = row.get('command')
        if not package_helper(command, helper_root):
            continue
        identity = owned.get(pid)
        state = owner_state(identity, row) if identity else 'unowned'
        if state not in ('live', 'changed', 'terminal'):
            found.append({'pid': pid, 'birth': row.get('birth'),
                          'parent': row.get('parent'), 'parent_identity': row.get('parent_identity'),
                          'command': command, 'ownership': state})
    return found


def valid_closed_journey(result, document):
    if result.get('error'):
        return False
    rows = result.get('catalogJourney')
    if (type(rows) is not list or len(rows) != len(document['actions']) or
            not all(type(row.get('index')) is int and row['index'] == i and
                    row.get('action') == request['kind'] and row.get('status') == 'ok'
                    for i, (row, request) in enumerate(zip(rows, document['actions'])))):
        return False
    return (type(rows[-1].get('catalogToken')) is str and rows[-1]['catalogToken'] == '' and
            type(rows[-1].get('catalogPath')) is str and rows[-1]['catalogPath'] == '')


def launch_direct_app(executable, plan, evidence, stdout):
    command = [str(executable), '--lensworks-catalog-plan', str(plan),
               '--lensworks-evidence', str(evidence), '--lensworks-quit']
    return subprocess.Popen(command, stdout=stdout, stderr=subprocess.STDOUT)


def wait_launcher(launcher, timeout):
    return launcher.wait(timeout=timeout)


def finite_clock(value, positive=False):
    return type(value) in (int, float) and math.isfinite(value) and (value > 0 if positive else value >= 0)


def before_deadline(started, now, deadline):
    return finite_clock(started) and finite_clock(now) and finite_clock(deadline, True) and 0 <= now - started < deadline


def run(app, plan, output, deadline, manifest):
    started_epoch, started = time.time(), time.monotonic()
    require(finite_clock(started_epoch, True) and finite_clock(started), 'Invalid start clock')
    hashes, limits = {}, {}

    def read_file(path, maximum, retain=False):
        path = artifact_path(path)
        limits[str(path)] = min(limits.get(str(path), maximum), maximum)
        maximum = limits[str(path)]
        descriptors = [os.open('/', os.O_RDONLY | os.O_DIRECTORY)]
        chunks, count, digest = [], 0, hashlib.sha256()
        try:
            for part in path.parts[1:-1]:
                descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1]))
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptors[-1])
            descriptors.append(fd)
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size <= maximum, 'Artifact must be bounded regular file')
            while True:
                require(before_deadline(started, time.monotonic(), deadline), 'Artifact capture exceeded campaign deadline')
                block = os.read(fd, 65536)
                if not block:
                    break
                count += len(block)
                require(count <= maximum, 'Artifact grew beyond read bound')
                digest.update(block)
                if retain:
                    chunks.append(block)
            after = os.fstat(fd)
            identity = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns, x.st_ctime_ns, x.st_mode, x.st_nlink)
            require(identity(before) == identity(after) and count == before.st_size, 'Artifact changed during held read')
        finally:
            finish_cleanup(close_all(descriptors), sys.exc_info()[1])
        value = digest.hexdigest()
        require(hashes.setdefault(str(path), value) == value, 'Artifact changed during campaign')
        return value, b''.join(chunks)

    def load(path, maximum=8 * 1024 * 1024):
        digest, raw = read_file(path, maximum, True)
        return digest, json.loads(raw)

    # Explicit program symlink exception; evidence/source aliases are rejected.
    app = Path(app).resolve(strict=True)
    executable = artifact_path(app / 'Contents/MacOS/LensWorks')
    plan = artifact_path(plan)
    output = Path(output)
    require(output.is_absolute() and not os.path.lexists(output), 'Output must be a fresh absolute directory')
    artifact_path(output.parent)
    runner_path = artifact_path(Path(__file__).absolute())
    runner_hash = read_file(runner_path, 96 * 1024 * 1024)[0]
    executable_hash = read_file(executable, 96 * 1024 * 1024)[0]
    plan_hash, document = load(plan, 1024 * 1024)
    require(type(document.get('version')) is int and document['version'] == 1 and type(document.get('actions')) is list and
            1 <= len(document['actions']) <= 64 and document['actions'][-1].get('kind') == 'close',
            'Plan must have version1, 1..64 actions and terminal close')
    source_records, source_results, cleanup_errors = [], [], []
    manifest_hash = None
    if manifest:
        manifest = artifact_path(manifest)
        manifest_hash, fixture = load(manifest)
        for item in fixture['sources'] + fixture.get('interruption_sources', []):
            source = artifact_path(manifest.parent / item['relative_path'])
            require(source.is_relative_to(manifest.parent), 'Fixture source escapes manifest root')
            digest = read_file(source, 512 * 1024 * 1024)[0]
            require(digest == item['sha256'], 'Fixture source hash already mismatched')
            require(source not in [p for p, _ in source_records], 'Duplicate source fixture')
            source_records.append((source, digest))

    def is_app(command):
        return command == str(executable) or command.startswith(str(executable) + ' ')

    evidence = output / 'journey.json'
    def this_app(command):
        if not is_app(command):
            return False
        suffix = command[len(str(executable)):].strip()
        expected = ['--lensworks-catalog-plan', str(plan), '--lensworks-evidence', str(evidence), '--lensworks-quit']
        # ps may preserve argv spaces without quotes; compare exact expected text,
        # or an exactly parsed quoted representation, never substring membership.
        return suffix == ' '.join(expected) or shlex.split(suffix) == expected

    helper_root = str(app / 'Contents/Helpers') + '/'

    preflight = processes(_helper_root=helper_root)
    require(not any(x.get('command') and is_app(x['command']) for x in preflight.values()),
            'Acceptance app already running; ownership ambiguous')
    require(not any(x.get('command') and package_helper(x['command'], helper_root) for x in preflight.values()),
            'Acceptance package helper already running; ownership ambiguous')
    output.mkdir(mode=0o700)
    output_identity = artifact_path(output).stat()
    output_fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    log_fd = None
    launcher = None
    launcher_admission_failed = False
    owned, app_pids, peak_rss = {}, set(), {}
    newborn_records = {}  # Unadmitted evidence; never a cleanup/signal owner.
    unadmitted_exit_records = {}  # Observed raw crossings; permanently unowned and unsignalable.
    failure, code, journey_hash = None, None, None
    forced, launcher_reaped, normal_quit = False, False, False
    checked_closed_epoch = None
    cleanup_actions, unknown, survivors, direct_reap_pending = [], [], None, []
    launch_epoch = launch_monotonic = None
    cleanup_attempted = False
    # Campaign observation limits, not product capability limits.
    history_limit, live_limit, cleanup_budget = 4096, 128, 15
    overflow_count, overflow_sample = 0, []
    transition_limit, transition_history = 4096, []
    transition_byte_limit, transition_bytes, transition_overflow = 2 * 1024 * 1024, 0, False
    static_event_keys = set()
    observation_failures, helper_unknown = [], []
    helper_observations = {}

    def note_failure(reason):
        if reason not in observation_failures:
            observation_failures.append(reason)

    def record_event(event):
        nonlocal transition_bytes, transition_overflow
        event_key = json.dumps(event, sort_keys=True, ensure_ascii=False)
        if event.get('kind') in ('pid_reuse', 'identity_uncertain', 'unadmitted_child_observation', 'unadmitted_plan_app') and event_key in static_event_keys:
            return
        size = len((json.dumps(event, ensure_ascii=False) + '\n').encode('utf-8'))
        if len(transition_history) >= transition_limit or transition_bytes + size > transition_byte_limit:
            transition_overflow = True
            note_failure('Process transition history budget exceeded; receipt history incomplete')
            return
        transition_history.append(event)
        transition_bytes += size
        if event.get('kind') in ('pid_reuse', 'identity_uncertain', 'unadmitted_child_observation', 'unadmitted_plan_app'):
            static_event_keys.add(event_key)

    def owner_key(pid, identity):
        return (pid, tuple(identity['birth']))

    def parent_key(row):
        value = row.get('parent_identity')
        return (value[0], tuple(value[1])) if value is not None else None

    def direct_reaped_residue(pid, row):
        return reaped_launcher_residue(pid, owned.get(pid), row,
            launcher.pid if launcher is not None else None,
            launcher.poll() if launcher is not None else None,
            launcher_reaped, launcher_admission_failed)

    def record_transitions(current):
        for pid, identity in owned.items():
            row = current.get(pid)
            if direct_reaped_residue(pid, row):
                # A held direct launcher can have raw <defunct> residue after
                # waitpid. Keep its already-recorded boundary pending until a
                # later watched row proves complete raw absence.
                if identity.get('direct_reap_pending') and not complete_watched_absence(row):
                    identity['signal_eligible'] = False
                    continue
                identity.pop('direct_reap_pending', None)
                identity['signal_eligible'] = False
                record_event({'kind': 'direct_reaped_raw_unidentified', 'pid': pid,
                              'expected_birth': identity['birth'], 'raw': boundary_record(row)})
                continue
            if direct_launcher_exit_residue_pending(
                    pid, identity, row, launcher.pid if launcher is not None else None,
                    launcher_reaped, launcher_admission_failed):
                if not identity.get('direct_reap_pending'):
                    record_event({'kind': 'direct_reap_residue_pending', 'pid': pid,
                                  'expected_birth': identity['birth'], 'raw': boundary_record(row)})
                identity['direct_reap_pending'] = True
                identity['signal_eligible'] = False
                continue
            if direct_launcher_complete_absence_pending(
                    pid, identity, row, launcher.pid if launcher is not None else None,
                    launcher_reaped, launcher_admission_failed):
                identity['signal_eligible'] = False
                continue
            if identity.pop('direct_reap_pending', None) is not None:
                note_failure('Direct launcher exit residue changed or lacked direct reap/absence; no signal authority')
            if (not identity.get('display_exit_uncertainty') and identity.get('signal_eligible') is True and
                    held_display_exit_uncertainty(identity, row)):
                identity['display_exit_uncertainty'] = True
                identity['retirement_pending'] = True
                identity['signal_eligible'] = False
                record_event({'kind': 'held_display_exit_uncertainty_pending', 'pid': pid,
                              'expected_birth': identity['birth'], 'expected_parent': identity['parent'],
                              'initial': row['pending_boundary']['initial'],
                              'recapture': row['pending_boundary']['recapture'],
                              'argv_attested': False, 'exit_inferred': False, 'signal_eligible': False})
            for event in retirement_pending_events(pid, identity, row):
                record_event(event)
            state = owner_state(identity, row)
            if state == 'reused':
                identity['signal_eligible'] = False
                event = {'kind': 'pid_reuse', 'pid': pid, 'birth': identity['birth'],
                         'previous_command': identity.get('last_command'),
                         'observed_birth': row.get('birth'), 'observed_parent': row.get('parent'),
                         'observed_command': row.get('command'),
                         'identity_pair': row.get('identity_pair'),
                         'parent_transition': row.get('parent_transition'),
                         'command_transition': row.get('command_transition')}
                record_event(event)
                note_failure('Owned PID birth changed; replacement not admitted')
                continue
            if state == 'unknown':
                identity['signal_eligible'] = False
                if row is not None:
                    record_event({'kind': 'identity_uncertain', 'pid': pid,
                                  'expected_birth': identity.get('birth'),
                                  'previous_command': identity.get('last_command'),
                                  'identity_pair': row.get('identity_pair'),
                                  'parent_transition': row.get('parent_transition'),
                                  'command_transition': row.get('command_transition'),
                                  'sampled_parent': row.get('parent'),
                                  'sampled_command': row.get('command')})
                note_failure('Owned process identity unavailable; retirement unknown')
            if row is not None and state in ('live', 'changed', 'terminal') and row.get('listed'):
                if row.get('command_transition'):
                    old_command, new_command = row['command_transition']
                    record_event({'kind': 'command_transition', 'pid': pid,
                                  'birth': identity['birth'], 'previous_command': old_command,
                                  'command': new_command, 'sampled_command': row.get('command'),
                                  'parent_identity': row.get('parent_identity')})
                    identity['signal_eligible'] = False
                    if state != 'terminal':
                        note_failure('Same-birth command transition observed; receipt remains failed')
                if row.get('parent_transition'):
                    record_event({'kind': 'parent_transition', 'pid': pid,
                                  'birth': identity['birth'],
                                  'previous_parent': row['parent_transition'][0],
                                  'parent': row['parent_transition'][1],
                                  'parent_identity': row.get('parent_identity')})
                    identity['signal_eligible'] = False
                    if state != 'terminal':
                        note_failure('Same-birth parent transition observed; receipt remains failed')
                if row.get('command') != identity.get('last_command'):
                    transition_fails = command_transition_fails(state, identity, row)
                    event = {'kind': 'command_transition', 'pid': pid,
                             'birth': identity['birth'], 'previous_command': identity.get('last_command'),
                             'parent_identity': row.get('parent_identity'),
                             'command': row.get('command')}
                    record_event(event)
                    identity['last_command'] = row.get('command')
                    identity['signal_eligible'] = False
                    if transition_fails:
                        note_failure('Same-birth command transition observed; receipt remains failed')
                if row.get('parent_identity') != identity.get('last_parent_identity'):
                    event = {'kind': 'parent_transition', 'pid': pid,
                             'birth': identity['birth'],
                             'previous_parent_identity': identity.get('last_parent_identity'),
                             'parent_identity': row.get('parent_identity')}
                    record_event(event)
                    identity['last_parent_identity'] = row.get('parent_identity')
                    identity['signal_eligible'] = False
                    if state != 'terminal':
                        note_failure('Observed parent identity transition; receipt remains failed')
                if state == 'terminal':
                    first_terminal_observation = not identity.get('terminal_status_seen')
                    identity['terminal_status_seen'] = True
                    identity['signal_eligible'] = False
                    if first_terminal_observation:
                        record_event({'kind': 'terminal_status_observed', 'pid': pid,
                                      'birth': identity['birth'], 'status': row.get('status'),
                                      'status_pair': row.get('status_pair'),
                                      'command': row.get('command'),
                                      'parent_identity': row.get('parent_identity')})

    def observation_owners():
        # None only requests a watched identity pair; it is not an owner and
        # prevents another newborn recapture for an already-pending PID.
        return {**{pid: None for pid, record in newborn_records.items()
                   if record['state'] in ('pending', 'failed')},
                **{pid: None for pid, record in unadmitted_exit_records.items()
                   if record['state'] in ('pending', 'failed')}, **owned}

    def advance_unadmitted_exit_pending(current):
        for pid, record in unadmitted_exit_records.items():
            if record['state'] != 'pending':
                continue
            state = unadmitted_exit_crossing_state(record, current.get(pid))
            record['state'] = state
            record['latest'] = boundary_record(current.get(pid))
            record_event({'kind': 'unadmitted_exit_crossing_observed', 'pid': pid,
                          'state': state, 'raw': record['latest'],
                          'owner_admitted': False, 'signal_eligible': False,
                          'lifecycle_inferred': False})
            if state == 'failed':
                note_failure('Unadmitted helper exit crossing changed or incomplete; no signal authority')

    def advance_newborn_pending(current):
        for pid, record in newborn_records.items():
            if record['state'] != 'pending':
                continue
            state = newborn_pending_state(record, current.get(pid))
            record['state'] = state
            record['latest'] = boundary_record(current.get(pid))
            record_event({'kind': 'unadmitted_newborn_observed', 'pid': pid,
                          'state': state, 'raw': record['latest']})
            if state == 'failed':
                note_failure('Unadmitted newborn identity changed or incomplete; no signal authority')

    def record_pending_boundaries(current):
        nonlocal overflow_count, overflow_sample
        for pid, row in current.items():
            boundary = row.get('pending_boundary') if row is not None else None
            if boundary is not None:
                record_event({'kind': 'pending_boundary_observed', 'pid': pid,
                              'boundary_kind': boundary['kind'], 'raw': boundary['initial']})
                record_event({'kind': ('pending_boundary_pending' if boundary['resolution'] == 'awaiting_absence'
                                      else 'pending_boundary_resolved'), 'pid': pid,
                              'resolution': boundary['resolution'], 'raw': boundary['recapture']})
                if (boundary['resolution'] == 'awaiting_absence' and
                        boundary.get('kind') == 'unadmitted_exit_crossing'):
                    entry = unadmitted_exit_crossing_entry(pid, row, owned, newborn_records,
                                                           helper_observations, unadmitted_exit_records, helper_root)
                    if entry is not None:
                        if len(set(owned) | set(newborn_records) | set(unadmitted_exit_records)) >= history_limit:
                            overflow_count = max(overflow_count, 1)
                            overflow_sample = [pid]
                            raise RuntimeError('Campaign owner history budget exceeded; unadmitted crossing unknown')
                        unadmitted_exit_records[pid] = entry
                        record_event({'kind': 'unadmitted_exit_crossing_pending', 'pid': pid,
                                      'initial': entry['initial'], 'recapture': entry['recapture'],
                                      'expected_parent': entry['expected_parent'],
                                      'owner_admitted': False, 'signal_eligible': False,
                                      'lifecycle_inferred': False})
                    elif pid not in unadmitted_exit_records:
                        note_failure('Pending process sampling boundary remains unresolved; no signal authority')
                elif (boundary['resolution'] == 'unresolved' and not direct_reaped_residue(pid, row) and
                        not owned.get(pid, {}).get('direct_reap_pending') and
                        not (owned.get(pid, {}).get('display_exit_uncertainty') and
                             held_display_exit_uncertainty(owned[pid], row))):
                    entry = newborn_pending_entry(pid, row, owned, helper_root)
                    if entry is not None and pid not in newborn_records:
                        if len(set(owned) | set(newborn_records) | set(unadmitted_exit_records)) >= history_limit:
                            overflow_count = max(overflow_count, 1)
                            overflow_sample = [pid]
                            raise RuntimeError('Campaign owner history budget exceeded; unadmitted newborn unknown')
                        newborn_records[pid] = entry
                        record_event({'kind': 'unadmitted_newborn_pending', 'pid': pid,
                                      'initial': entry['initial'], 'recapture': entry['recapture']})
                    else:
                        note_failure('Pending process sampling boundary remains unresolved; no signal authority')

    def discover(current, permit_foreign=False):
        nonlocal overflow_count, overflow_sample
        advance_unadmitted_exit_pending(current)
        advance_newborn_pending(current)
        record_pending_boundaries(current)
        for pid, row in current.items():
            if row.get('command') and is_app(row['command']):
                if not this_app(row['command']):
                    if pid in owned and owner_state(owned[pid], row) == 'changed':
                        # Preserve the observed argv transition, keep this PID
                        # under birth-based observation, and keep the receipt failed.
                        continue
                    if permit_foreign:
                        continue
                    raise RuntimeError('Unrelated same-executable app observed; never owned')
                if not is_direct_launcher_pid(pid, launcher.pid if launcher is not None else None):
                    record_event({'kind': 'unadmitted_plan_app', 'pid': pid,
                                  'birth': row.get('birth'), 'parent': row.get('parent'),
                                  'parent_identity': row.get('parent_identity'),
                                  'command': row.get('command')})
                    note_failure('Exact-plan application lacks direct launch custody; never adopted')
                    continue
                if launcher_admission_failed:
                    note_failure('Launcher lacked initial strong identity; application never admitted')
                    continue
                if not launcher_row_admissible(row, pid, launcher.pid, os.getpid(), runner_birth):
                    note_failure('Application process birth or contemporaneous parent identity unavailable')
                    continue
                if pid not in owned:
                    if len(set(owned) | set(newborn_records) | set(unadmitted_exit_records)) >= history_limit:
                        overflow_count = max(overflow_count, 1)
                        overflow_sample = [pid]
                        raise RuntimeError('Campaign owner history budget exceeded; overflow unknown')
                    owned[pid] = dict(row, last_command=row['command'], signal_eligible=True,
                                      last_parent_identity=row.get('parent_identity'))
                    app_pids.add(pid)
                else:
                    require(owner_state(owned[pid], row) != 'reused', 'Invocation PID reused; new birth not admitted')
        parents = {owner_key(pid, row) for pid, row in owned.items()
                   if owner_state(row, current.get(pid)) in ('live', 'changed')}
        parent_pids = {pid for pid, _ in parents}
        for pid, row in current.items():
            if row.get('parent') in parent_pids and (not row.get('parent_consistent') or
                    row.get('birth') is None or parent_key(row) not in parents):
                record_event({'kind': 'unadmitted_child_observation', 'pid': pid,
                              'birth': row.get('birth'), 'parent': row.get('parent'),
                              'parent_identity': row.get('parent_identity'),
                              'command': row.get('command')})
                note_failure('Descendant identity or contemporaneous parent evidence unavailable')
        while True:
            new = {pid for pid, row in current.items()
                   if parent_key(row) in parents and row.get('birth') is not None and
                   row.get('parent_consistent') and pid not in owned and
                   pid not in unadmitted_exit_records and
                   newborn_admission_allowed(newborn_records, pid)}
            if not new:
                break
            capacity = history_limit - len(set(owned) | set(newborn_records) | set(unadmitted_exit_records))
            reserved = sorted(pid for pid in new if pid in newborn_records)
            unseen = sorted(new - set(reserved))
            admitted = reserved + unseen[:capacity]
            for pid in admitted:
                row = current[pid]
                owned[pid] = dict(row, last_command=row.get('command'), signal_eligible=True,
                                  last_parent_identity=row.get('parent_identity'))
            parents |= {owner_key(pid, owned[pid]) for pid in admitted}
            if len(unseen) > capacity:
                overflow_count = max(overflow_count, len(unseen) - capacity)
                overflow_sample = unseen[capacity:capacity + 64]
                raise RuntimeError('Campaign owner history budget exceeded; overflow unknown')
        require(len(parents) + sum(x['state'] in ('pending', 'failed') for x in newborn_records.values()) +
                sum(x['state'] in ('pending', 'failed') for x in unadmitted_exit_records.values()) <= live_limit,
                'Campaign live owner budget exceeded')
        for pid, birth in parents:
            row = current.get(pid)
            if row is not None and row.get('birth') == list(birth):
                peak_rss[pid] = max(peak_rss.get(pid, 0), row['rss_kib'])

    def census_helpers(current):
        return census_unowned_helpers(current, owned, helper_root)

    def observe_helpers(current):
        for pid, row in current.items():
            command = row.get('command')
            if not command:
                continue
            if not package_helper(command, helper_root):
                continue
            if row.get('birth') is None:
                record_event(helper_birth_unavailable_event(pid, row, pid in owned))
                if pid in owned and owner_state(owned[pid], row) == 'pending':
                    continue  # No new helper admission or signal; final pending still blocks PASS.
                if pid in unadmitted_exit_records:
                    continue  # This PID stays permanently unowned and unsignalable while watched.
                if unbound_helper_uncertainty(pid, row, owned, newborn_records,
                                              helper_observations, helper_root):
                    record_event({'kind': 'unowned_unsignalable_uncertainty', 'pid': pid,
                                  'classification': 'UNOWNED_UNSIGNALABLE_UNCERTAINTY',
                                  'raw': boundary_record(row), 'owner_admitted': False,
                                  'signal_eligible': False, 'lifecycle_inferred': False})
                    continue  # The fresh final raw package census still must be empty.
                note_failure('Bundled helper birth identity unavailable')
                continue
            key = (pid, tuple(row['birth']))
            previous = helper_observations.get(key)
            if previous is None:
                helper_observations[key] = {'command': command,
                                            'parent_identity': row.get('parent_identity')}
                if pid not in owned or not same_birth(owned[pid], row):
                    record_event({'kind': 'unowned_helper_observed', 'pid': pid,
                                  'birth': row['birth'], 'parent_identity': row.get('parent_identity'),
                                  'command': command})
                    note_failure('Unadmitted bundled helper observed; no signal authority')
                continue
            if command != previous['command']:
                record_event({'kind': 'helper_command_transition', 'pid': pid,
                              'birth': row['birth'], 'previous_command': previous['command'],
                              'parent_identity': row.get('parent_identity'), 'command': command})
                previous['command'] = command
                note_failure('Bundled helper command transition observed; receipt remains failed')
            if row.get('parent_identity') != previous['parent_identity']:
                record_event({'kind': 'helper_parent_transition', 'pid': pid,
                              'birth': row['birth'],
                              'previous_parent_identity': previous['parent_identity'],
                              'parent_identity': row.get('parent_identity')})
                previous['parent_identity'] = row.get('parent_identity')

    def admit_launcher(current, expected_argv):
        nonlocal launcher_admission_failed
        row = current.get(launcher.pid)
        if not launcher_row_admissible(row, launcher.pid, launcher.pid, os.getpid(), runner_birth):
            note_failure('Launcher strong initial birth identity unavailable')
            launcher_admission_failed = True
            return
        if launcher.pid not in owned:
            argv_matches = False
            try:
                argv_matches = shlex.split(row['command']) == expected_argv
            except (ValueError, TypeError):
                pass
            owned[launcher.pid] = dict(row, last_command=row.get('command'),
                                       signal_eligible=argv_matches,
                                       last_parent_identity=row.get('parent_identity'))
            if argv_matches:
                app_pids.add(launcher.pid)
            if not argv_matches:
                note_failure('Launcher command unavailable at initial identity capture')
                launcher_admission_failed = True

    try:
        log_fd = os.open('launch.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=output_fd)
        launch_epoch, launch_monotonic = time.time(), time.monotonic()
        require(finite_clock(launch_epoch, True) and finite_clock(launch_monotonic) and
                started_epoch <= launch_epoch and before_deadline(started, launch_monotonic, deadline), 'Invalid launch chronology')
        command = [str(executable), '--lensworks-catalog-plan', str(plan),
                   '--lensworks-evidence', str(evidence), '--lensworks-quit']
        launcher = launch_direct_app(executable, plan, evidence, log_fd)
        runner_identity, runner_error = process_birth(os.getpid())
        runner_birth = runner_identity['birth'] if runner_identity is not None else None
        if runner_error is not None or runner_birth is None:
            note_failure('Runner birth identity unavailable for direct-child provenance')
        launch_method = 'DIRECT_EXEC_AND_REAP_CUSTODY'
        current = processes(_helper_root=helper_root)
        admit_launcher(current, command)
        discover(current)
        observe_helpers(current)
        while True:
            # Retained Popen owns waitpid authority; reap before stale zombie argv checks.
            code = launcher.poll()
            if code is not None:
                wait_launcher(launcher, timeout=10)
                launcher_reaped = True
            current = processes(watched=observation_owners(), _helper_root=helper_root)
            if launcher.pid not in owned and not launcher_reaped and not launcher_admission_failed:
                admit_launcher(current, command)
            record_transitions(current)
            discover(current)
            observe_helpers(current)
            unresolved = [pid for pid, row in owned.items()
                          if not (pid == launcher.pid and launcher_reaped) and
                          not row.get('direct_reap_pending') and
                          owner_state(row, current.get(pid)) in ('unknown', 'reused', 'changed')]
            if unresolved:
                note_failure('Live changed/unknown process observed; continue natural Quit observation')
            if code is not None:
                require(code == 0, 'Launcher exited ' + str(code))
                wait_launcher(launcher, timeout=10)
                launcher_reaped = True
                current = processes(watched=observation_owners(), _helper_root=helper_root)
                record_transitions(current)
                discover(current)
                observe_helpers(current)
                states = {pid: owner_state(row, current.get(pid)) for pid, row in owned.items()
                          if not (launcher is not None and pid == launcher.pid and launcher_reaped)}
                if (not any(x['state'] == 'pending' for x in newborn_records.values()) and
                        not any(x['state'] == 'pending' for x in unadmitted_exit_records.values()) and
                        owners_retired(owned, current, launcher.pid, code, launcher_reaped,
                                       app_pids, census_helpers(current))):
                    normal_quit = True
                    break
                require(before_deadline(started, time.monotonic(), deadline), 'Normal Quit owner retirement unavailable by deadline')
                time.sleep(0.1)
                continue
            require(before_deadline(started, time.monotonic(), deadline), 'Installed plan exceeded owned deadline')
            time.sleep(0.1)
        journey_hash, result = load(evidence)
        require(not result.get('error'), 'Application reported: ' + str(result.get('error')))
        require(valid_closed_journey(result, document), 'Requested checked Close journey incomplete')
        if observation_failures:
            failure = '; '.join(observation_failures)
    except BaseException as error:
        failure = str(error)
        if launcher is not None:
            cleanup_attempted = True
            cleanup_started = time.monotonic()
            cleanup_end = cleanup_started + cleanup_budget
            cleanup_candidates = []
            cleanup_snapshot = None
            try:
                cleanup_snapshot = processes(timeout=2, watched=observation_owners(), _helper_root=helper_root)
                record_transitions(cleanup_snapshot)
                current = cleanup_snapshot
                discover(current, permit_foreign=True)
                observe_helpers(current)
            except Exception as cleanup_error:
                cleanup_errors.append('Cleanup owner discovery: ' + str(cleanup_error))
            finally:
                # Admission failure must not suppress retirement of captured owners.
                if cleanup_snapshot is not None:
                    cleanup_candidates = [(pid, identity) for pid, identity in owned.items()
                                          if identity.get('signal_eligible') and
                                          owner_state(identity, cleanup_snapshot.get(pid)) == 'live']
            for stop_signal in (signal.SIGTERM, signal.SIGKILL):
                for pid, identity in cleanup_candidates:
                    if launcher_reaped and pid == launcher.pid:
                        continue
                    remaining = cleanup_end - time.monotonic()
                    if not finite_clock(remaining, True):
                        cleanup_errors.append('Aggregate cleanup budget exhausted; ownership incomplete')
                        break
                    try:
                        current = processes(timeout=min(2, remaining), watched={pid: identity}, _helper_root=helper_root).get(pid)
                        for event in retirement_pending_events(pid, identity, current):
                            record_event(event)
                        record_pending_boundaries({pid: current})
                        if signal_target_eligible(identity, current):
                            os.kill(pid, stop_signal)
                            forced = True
                            cleanup_actions.append({'pid': pid, 'signal': int(stop_signal)})
                    except ProcessLookupError:
                        pass
                    except Exception as cleanup_error:
                        cleanup_errors.append('Owned signal: ' + str(cleanup_error))
                if time.monotonic() >= cleanup_end:
                    break
                if stop_signal == signal.SIGTERM:
                    time.sleep(min(1, max(0, cleanup_end - time.monotonic())))
    finally:
        if launcher is not None and not launcher_reaped:
            try:
                try:
                    wait_launcher(launcher, timeout=5)
                    launcher_reaped = True
                except Exception as cleanup_error:
                    cleanup_errors.append('Owned Popen wait: ' + str(cleanup_error))
            except Exception as cleanup_error:
                cleanup_errors.append('Owned launcher retirement: ' + str(cleanup_error))
        for source, digest in source_records:
            try:
                after = read_file(source, limits[str(source)])[0]
                source_results.append({'path': str(source), 'before': digest, 'after': after, 'state': 'unchanged'})
            except Exception as source_error:
                source_results.append({'path': str(source), 'before': digest, 'after': None, 'state': 'unknown', 'error': str(source_error)})
        try:
            for path, value in list(hashes.items()):
                require(read_file(Path(path), limits[path])[0] == value, 'Artifact changed during execution')
        except Exception as artifact_error:
            cleanup_errors.append('Final artifact custody: ' + str(artifact_error))
        try:
            current = processes(watched=observation_owners(), _helper_root=helper_root)
            record_transitions(current)
            discover(current)
            observe_helpers(current)
            survivors = [pid for pid, row in owned.items() if not (launcher is not None and pid == launcher.pid and launcher_reaped) and owner_state(row, current.get(pid)) in ('live', 'changed')]
            unknown = [pid for pid, row in owned.items() if not (launcher is not None and pid == launcher.pid and launcher_reaped) and owner_state(row, current.get(pid)) in ('unknown', 'reused', 'pending')]
            direct_reap_pending = sorted(pid for pid, identity in owned.items()
                                         if identity.get('direct_reap_pending'))
            unknown = sorted(set(unknown) | set(direct_reap_pending) |
                             {pid for pid, record in newborn_records.items()
                              if record['state'] in ('pending', 'failed') or
                              (record['state'] == 'resolved_stable' and pid not in owned)} |
                             {pid for pid, record in unadmitted_exit_records.items()
                              if record['state'] in ('pending', 'failed')})
            helper_unknown = census_helpers(current)
        except Exception as cleanup_error:
            cleanup_errors.append('Final ownership snapshot unavailable: ' + str(cleanup_error))
            survivors, unknown, direct_reap_pending = None, None, None
        descriptor_errors = close_all([output_fd] + ([log_fd] if log_fd is not None else []))
        cleanup_errors.extend('Descriptor cleanup: ' + str(x) for x in descriptor_errors)
        try:
            current_output = artifact_path(output).stat()
            require((current_output.st_dev, current_output.st_ino) == (output_identity.st_dev, output_identity.st_ino), 'Campaign output directory changed')
        except Exception as output_error:
            cleanup_errors.append('Output custody: ' + str(output_error))
        completed_epoch, completed = time.time(), time.monotonic()
        eligible = (failure is None and not cleanup_errors and not observation_failures and
                    not helper_unknown and not transition_overflow and normal_quit and not forced and launcher_reaped and
                    survivors == [] and unknown == [] and direct_reap_pending == [] and overflow_count == 0 and all(x['state'] == 'unchanged' for x in source_results) and
                    finite_clock(completed_epoch, True) and finite_clock(completed) and
                    finite_clock(launch_epoch, True) and finite_clock(launch_monotonic) and
                    started <= launch_monotonic <= completed and 0 <= completed - started <= deadline and
                    started_epoch <= launch_epoch <= completed_epoch and
                    completed_epoch - started_epoch >= completed - started - 0.05)
        if eligible:
            checked_closed_epoch = completed_epoch
        elif failure is None:
            failure = 'Final checked-close receipt eligibility failed'
        report = {'status': 'EXECUTED_PENDING_ORACLE_ACCEPTANCE' if eligible else 'FAIL', 'error': failure,
                  'application': str(app), 'plan': str(plan), 'plan_sha256': plan_hash,
                  'executable_sha256': executable_hash, 'manifest_sha256': manifest_hash, 'journey_sha256': journey_hash,
                  'launch_method': launch_method if launcher is not None else None,
                  'runner_sha256': runner_hash, 'artifact_sha256': hashes, 'application_pids': sorted(app_pids),
                  'owned_processes': owned, 'unadmitted_newborn_observations': newborn_records,
                  'unadmitted_exit_crossing_observations': unadmitted_exit_records,
                  'process_transitions': transition_history,
                  'process_transition_history_complete': not transition_overflow,
                  'observation_failures': observation_failures,
                  'unowned_package_helpers': helper_unknown,
                  'observed_peak_rss_kib_by_pid': peak_rss,
                  'launcher_exit': launcher.poll() if launcher is not None else None, 'launcher_reaped': launcher_reaped,
                  'normal_quit_observed': normal_quit and not forced, 'forced_cleanup': forced, 'cleanup_attempted': cleanup_attempted, 'cleanup_actions': cleanup_actions,
                  'owner_overflow_count': overflow_count, 'owner_overflow_pid_sample': overflow_sample,
                  'campaign_owner_history_limit': history_limit, 'campaign_live_owner_limit': live_limit,
                  'campaign_signal_cleanup_seconds': cleanup_budget,
                  'campaign_direct_reap_seconds': 10, 'campaign_final_snapshot_seconds': 10,
                  'started_epoch': started_epoch, 'started_monotonic': started, 'launch_epoch': launch_epoch,
                  'launch_monotonic': launch_monotonic, 'completed_epoch': completed_epoch,
                  'completed_monotonic': completed, 'checked_closed_epoch': checked_closed_epoch,
                  'elapsed_seconds': completed - started, 'deadline_seconds': deadline,
                  'unchanged_source_count': sum(x['state'] == 'unchanged' for x in source_results),
                  'source_states': source_results, 'observed_surviving_processes': survivors,
                  'unknown_processes': unknown, 'direct_reap_pending_processes': direct_reap_pending, 'cleanup_errors': cleanup_errors,
                  'limitations': 'Checked close requires public Close, unforced direct Quit/reap, strict retirement for every claimed owner, and a fresh empty raw package-helper census. Identityless raw package rows remain unowned unsignalable uncertainty; a separately watched unadmitted exit crossing resolves only at a later complete raw and inventory absence, without inferring an exit or full-tree enumeration. Sampled descendants/RSS, not exact internal exit timestamp or hard OS bound. Separate oracle acceptance required.'}
        try:
            publish_fresh(output / 'execution.json', report)
        except Exception as publication_error:
            if failure is not None:
                original = RuntimeError(failure + ('; cleanup: ' + '; '.join(cleanup_errors) if cleanup_errors else ''))
                finish_cleanup([publication_error], original)
                raise original from publication_error
            raise
    if failure:
        raise RuntimeError(failure + ('; cleanup: ' + '; '.join(cleanup_errors) if cleanup_errors else ''))
    print('Executed installed catalog plan; oracle acceptance remains required')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--deadline-seconds', type=int, default=180)
    args = parser.parse_args()
    if not 10 <= args.deadline_seconds <= 1800:
        parser.error('Deadline must be 10..1800 seconds')
    run(args.app, args.plan, args.output.absolute(), args.deadline_seconds, args.manifest)
