"""Reuse exact pinned notice obligations, never an old dependency inventory."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import tarfile


MISSING = {
    'aom': 'embedded/patent notice retrieval requires --fetch',
    'libvmaf': 'embedded/patent notice retrieval requires --fetch',
    'libraw': 'exact corresponding source requires --fetch',
}
SUPPLEMENTS = {
    'aom': {'PATENTS'},
    'libvmaf': {'libvmaf/src/svm.h', 'libvmaf/src/feature/third_party/xiph/psnr_hvs.c'},
    'libraw': set(),
}
FILES = {
    'aom': {'aom.txt'}, 'libvmaf': {'libvmaf.txt'},
    'libraw': {'libraw.txt', 'libraw-source.tar.gz', 'libraw-build-recipe.rb'},
}
NOTICE = re.compile(r'^(?:licen[cs]e|copying|copyright|notice|unlicense|ofl|patents|authors)(?:[._-].*)?$', re.I)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Inputs:
    """Bounded same-descriptor reads; first authority is rechecked before copying."""
    def __init__(self):
        self.records = {}

    def read(self, path, limit=64 * 1024 * 1024):
        path = Path(path).absolute()
        require(path.resolve(strict=True) == path, 'Notice input aliases are not allowed: ' + str(path))
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= limit,
                    'Notice input must be a bounded regular file: ' + str(path))
            chunks = []
            count = 0
            while True:
                chunk = os.read(fd, min(1024 * 1024, limit + 1 - count))
                if not chunk:
                    break
                chunks.append(chunk)
                count += len(chunk)
                require(count <= limit, 'Notice input exceeded byte cap: ' + str(path))
            after = os.fstat(fd)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            require(identity(before) == identity(after) and count == before.st_size,
                    'Notice input changed during read: ' + str(path))
            data = b''.join(chunks)
        finally:
            os.close(fd)
        record = (identity(after), sha(data), limit)
        if path in self.records:
            require(self.records[path][:2] == record[:2], 'Notice input changed: ' + str(path))
        else:
            self.records[path] = record
        return data

    def check(self, exclude=()):
        for path, (_, _, limit) in list(self.records.items()):
            if path not in exclude:
                self.read(path, limit)


def keyed(rows):
    require(isinstance(rows, list), 'Notice component list required')
    result = {}
    for row in rows:
        name = row['component']
        require(name not in result, 'Duplicate notice component: ' + name)
        result[name] = row
    return result


def aggregate_entries(data):
    """Validate the retained collector's complete verbatim-file envelope."""
    prefix = b'\n===== '
    end = b'\n===== END UPSTREAM FILE =====\n'
    files = {}
    while data:
        require(data.startswith(prefix), 'Notice aggregate identity/framing mismatch')
        header, separator, tail = data[len(prefix):].partition(b' =====\n')
        require(bool(separator), 'Notice aggregate header missing')
        name, separator, digest = header.rpartition(b' / SHA256 ')
        require(bool(separator) and re.fullmatch(rb'[0-9a-f]{64}', digest), 'Notice aggregate digest malformed')
        payload, separator, data = tail.partition(end)
        require(bool(separator) and sha(payload) == digest.decode(), 'Notice aggregate payload mismatch')
        identity, separator, name = name.decode('utf-8').partition(' / ')
        require(separator and identity, 'Notice aggregate identity missing')
        require((identity, name) not in files and name and not Path(name).is_absolute() and '..' not in Path(name).parts,
                'Notice aggregate path duplicate/invalid')
        files[identity, name] = payload
    return files


def aggregate_files(data, identity):
    entries = aggregate_entries(data)
    require(all(key[0] == identity for key in entries), 'Notice aggregate identity/framing mismatch')
    return {name: data for (_, name), data in entries.items()}


def recipe_pin(text, field, pattern):
    match = re.search(pattern, text, re.M)
    require(match is not None, 'Installed formula missing ' + field)
    return match[1]


def reuse_native_notices(output, report, reuse, inventory_sha256, manifest_sha256):
    """Fill only matching current aom/VMAF/LibRaw omissions from explicit pins.

    All validation precedes artifact mutation. The caller owns a fresh collector
    output and publishes the returned manifest and current report afterwards.
    """
    output, reuse = Path(output).absolute(), Path(reuse).absolute()
    require(output.resolve(strict=True) == output and reuse.resolve(strict=True) == reuse and output != reuse,
            'Notice directories must be distinct canonical directories')
    inputs = Inputs()
    old_bytes = inputs.read(reuse / 'inventory.json', 16 * 1024 * 1024)
    manifest_bytes = inputs.read(reuse / 'manifest.json', 1024 * 1024)
    require(re.fullmatch('[0-9a-f]{64}', inventory_sha256 or '') and sha(old_bytes) == inventory_sha256,
            'Reuse inventory pin mismatch')
    require(re.fullmatch('[0-9a-f]{64}', manifest_sha256 or '') and sha(manifest_bytes) == manifest_sha256,
            'Reuse manifest pin mismatch')
    old = json.loads(old_bytes)
    old_manifest = json.loads(manifest_bytes)
    require(old.get('protocol') == 1 and old.get('status') == 'NOTICE_INVENTORY_COMPLETE' and old.get('missing') == [],
            'Reuse inventory must be an explicitly complete prior native inventory')
    require(report.get('protocol') == 1 and old_manifest.get('protocol') == 1, 'Unsupported notice protocol')
    manifest = json.loads(inputs.read(output / 'manifest.json', 1024 * 1024))
    require(manifest.get('protocol') == 1, 'Unsupported current notice manifest')
    current_rows, old_rows = keyed(report['native']), keyed(old['native'])
    current_components, old_components = keyed(manifest['components']), keyed(old_manifest['components'])
    artifacts, updates = {}, {}
    recipes = {}
    for name, reason in MISSING.items():
        require(report['missing'].count({'component': name, 'reason': reason}) == 1,
                'Expected exact current missing obligation: ' + name)
        current, prior = current_rows[name], old_rows[name]
        for field in ('root', 'receipt', 'libraries'):
            require(current[field] == prior[field], 'Installed native identity changed: ' + name + '/' + field)
        directory = Path(current['root'])
        require(directory.resolve(strict=True) == directory, 'Installed native root alias')
        # Also bind the current directory's actual dylib names and resolved files;
        # a stale inventory cannot hide a replacement library or new dependency.
        actual_libraries = {p.name: str(p.resolve(strict=True)) for p in (directory / 'lib').glob('*.dylib')}
        require(actual_libraries == {key: value['path'] for key, value in current['libraries'].items()},
                'Installed library set changed: ' + name)
        for record in [current['receipt'], *current['libraries'].values()]:
            data = inputs.read(record['path'])
            require(sha(data) == record['sha256'] and len(data) == record['bytes'], 'Installed file identity changed: ' + record['path'])
        require(set(prior['notices']) == set(current['notices']) | SUPPLEMENTS[name]
                and all(prior['notices'][key] == value for key, value in current['notices'].items()),
                'Installed local notices changed: ' + name)
        actual_notices = {str(path.relative_to(directory)): sha(inputs.read(path, 16 * 1024 * 1024))
                          for path in directory.rglob('*') if path.is_file() and not path.is_symlink()
                          and NOTICE.fullmatch(path.name)}
        require(actual_notices == current['notices'], 'Installed local notice files changed: ' + name)
        component = old_components[name]
        require(component['libraries'] == sorted(current['libraries']) and
                {x['path'] for x in component['files']} == FILES[name] and len(component['files']) == len(FILES[name]),
                'Reuse component file/library set mismatch: ' + name)
        for record in component['files']:
            data = inputs.read(reuse / record['path'])
            require(sha(data) == record['sha256'], 'Reuse artifact digest mismatch: ' + record['path'])
            artifacts[record['path']] = data
        files = aggregate_files(artifacts[name + '.txt'], current['root'])
        require({key: sha(data) for key, data in files.items()} == prior['notices'], 'Reuse notice envelope mismatch: ' + name)
        # Check the fresh collector's complete local aggregate too, not only its JSON.
        fresh_record = current_components[name]
        require(fresh_record['libraries'] == component['libraries'] and fresh_record['files'] ==
                [{'path': name + '.txt', 'sha256': sha(inputs.read(output / (name + '.txt')))}],
                'Current notice artifact mismatch: ' + name)
        require({key: sha(data) for key, data in aggregate_files(inputs.read(output / (name + '.txt')), current['root']).items()}
                == current['notices'], 'Current local notice envelope mismatch: ' + name)
        recipe_path = directory / '.brew' / (name + '.rb')
        recipe = inputs.read(recipe_path, 1024 * 1024)
        text = recipe.decode('utf-8')
        recipes[name] = {'path': str(recipe_path), 'sha256': sha(recipe), 'bytes': len(recipe)}
        if name == 'aom':
            revision = recipe_pin(text, 'revision', r'revision: "([0-9a-f]{40})"')
            expected = [{'url': f'https://aomedia.googlesource.com/aom/+/{revision}/PATENTS?format=TEXT',
                         'sha256': sha(files['PATENTS']), 'installed_revision': revision}]
            require(prior['supplemental_sources'] == expected, 'AOM installed revision/notice mismatch')
        else:
            url = recipe_pin(text, 'source URL', r'^  url "(https://[^"]+)"')
            digest = recipe_pin(text, 'source checksum', r'^  sha256 "([0-9a-f]{64})"')
            if name == 'libvmaf':
                expected = [{'source_archive': url, 'archive_sha256': digest, 'path': key, 'sha256': sha(files[key])}
                            for key in sorted(SUPPLEMENTS[name])]
                require(sorted(prior['supplemental_sources'], key=lambda x: x['path']) == expected,
                        'VMAF installed source/embedded notices mismatch')
            else:
                source = prior['included_source']
                require(source['url'] == url and source['sha256'] == digest and source['recipe'] == recipes[name]
                        and sha(artifacts['libraw-source.tar.gz']) == digest and artifacts['libraw-build-recipe.rb'] == recipe,
                        'LibRaw corresponding source/build recipe mismatch')
        update = copy.deepcopy(current)
        update['notices'] = prior['notices']
        update['supplemental_sources'] = prior['supplemental_sources']
        if name == 'libraw':
            update['included_source'] = prior['included_source']
        updates[name] = update
    inputs.check()
    for name in artifacts:
        if not name.endswith('.txt'):
            require(not os.path.lexists(output / name), 'Corresponding-source output must be new: ' + name)
    # Replace only known fresh collector text files; never clobber an unrelated
    # source artifact. The fresh output is not published complete until return.
    for name, data in artifacts.items():
        path = output / name
        if name.endswith('.txt'):
            fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
            try:
                expected_identity = inputs.records[path][0]
                observed = os.fstat(fd)
                require((observed.st_dev, observed.st_ino, observed.st_mode, observed.st_size, observed.st_mtime_ns, observed.st_ctime_ns)
                        == expected_identity, 'Current notice output changed before replacement')
                os.ftruncate(fd, 0)
                with os.fdopen(fd, 'wb', closefd=False) as stream:
                    stream.write(data)
            finally:
                os.close(fd)
        else:
            with path.open('xb') as stream:
                stream.write(data)
    inputs.check(exclude={output / name for name in artifacts})
    for name in MISSING:
        current_rows[name].clear()
        current_rows[name].update(updates[name])
        current_components[name].clear()
        current_components[name].update(copy.deepcopy(old_components[name]))
    report['missing'] = [entry for entry in report['missing'] if entry not in
                         [{'component': name, 'reason': reason} for name, reason in MISSING.items()]]
    report['native_notice_reuse'] = {'directory': str(reuse), 'inventory_sha256': inventory_sha256,
        'manifest_sha256': manifest_sha256, 'components': sorted(MISSING), 'installed_recipes': recipes,
        'artifacts': {name: {'sha256': sha(data), 'bytes': len(data)} for name, data in artifacts.items()},
        'formula_evidence': {'aom': 'Installed source revision matches prior PATENTS URL; current recipe captured, prior full recipe was not retained.',
                             'libvmaf': 'Installed source URL/archive checksum matches prior embedded notices; current recipe captured, prior full recipe was not retained.',
                             'libraw': 'Exact full installed build recipe bytes and corresponding-source archive checksum match prior retained files.'},
        'basis': 'Exact current native receipts/libraries/local notices plus associated upstream source pins; LibRaw also requires full recipe equality. Current Rust/dependency inventory independently collected.'}
    return manifest


# These are the two current archives whose upstream notices were omitted from
# their published crates. No other missing dependency is implicitly covered.
CRATE_REUSE = {'zune-core@0.4.12', 'zune-jpeg@0.4.21'}


def reuse_crate_notices(output, report, manifest, reuse, inventory_sha256, manifest_sha256, cargo_home=None):
    """Associate only exact crate archives/VCS metadata with pinned prior text."""
    import tomllib  # The collection CLI requires Python >=3.11.
    output, reuse = Path(output).absolute(), Path(reuse).absolute()
    require(output.resolve(strict=True) == output and reuse.resolve(strict=True) == reuse and output != reuse,
            'Notice directories must be distinct canonical directories')
    inputs = Inputs()
    old_bytes = inputs.read(reuse / 'inventory.json', 16 * 1024 * 1024)
    manifest_bytes = inputs.read(reuse / 'manifest.json', 1024 * 1024)
    require(sha(old_bytes) == inventory_sha256 and sha(manifest_bytes) == manifest_sha256,
            'Crate reuse inventory/manifest pin mismatch')
    prior = json.loads(old_bytes)
    require(prior.get('protocol') == 1 and prior.get('status') == 'NOTICE_INVENTORY_COMPLETE' and prior.get('missing') == [],
            'Crate reuse requires complete pinned prior inventory')
    require(report.get('protocol') == 1 and manifest.get('protocol') == 1, 'Unsupported current crate notice protocol')
    def rust_rows(rows):
        result = {}
        for row in rows:
            require(row['identity'] not in result, 'Duplicate Rust notice identity')
            result[row['identity']] = row
        return result
    old_rows, rows = rust_rows(prior['rust']), rust_rows(report['rust'])
    old_component = keyed(json.loads(manifest_bytes)['components'])['rust-dependencies']
    component = keyed(manifest['components'])['rust-dependencies']
    require(old_component['libraries'] == [] and len(old_component['files']) == 1 and
            old_component['files'][0]['path'] == 'rust-dependencies.txt', 'Prior Rust notice component malformed')
    old_aggregate = inputs.read(reuse / 'rust-dependencies.txt')
    require(sha(old_aggregate) == old_component['files'][0]['sha256'], 'Prior Rust notice artifact mismatch')
    old_entries = aggregate_entries(old_aggregate)
    current_path = output / 'rust-dependencies.txt'
    current = inputs.read(current_path)
    require(component['libraries'] == [] and component['files'] ==
            [{'path': current_path.name, 'sha256': sha(current)}], 'Current Rust notice artifact mismatch')
    current_entries = aggregate_entries(current)
    # Preserve and verify every currently collected notice, even though none of
    # the old aggregate's unrelated dependencies will be reused.
    require({(row['identity'], name): digest for row in report['rust'] for name, digest in row.get('notices', {}).items()}
            == {key: sha(data) for key, data in current_entries.items()}, 'Current Rust notice envelope mismatch')
    additions, updates, archives, resolved_missing = {}, {}, {}, []
    cargo_home = Path(cargo_home) if cargo_home is not None else Path.home() / '.cargo'
    for identity in sorted(CRATE_REUSE):
        matches = [item for item in report['missing'] if item.get('identity') == identity]
        require(len(matches) == 1 and matches[0].get('reason') == 'upstream notice absent',
                'Expected exact missing crate notice obligation: ' + identity)
        row, old = rows[identity], old_rows[identity]
        for field in ('identity', 'source', 'checksum', 'license', 'repository', 'archive'):
            require(row[field] == old[field], 'Crate notice identity changed: ' + identity + '/' + field)
        require(row['source'] == 'registry+https://github.com/rust-lang/crates.io-index' and
                not row.get('notices') and not row.get('error') and row.get('upstream_notices') == [],
                'Crate missing-notice state mismatch: ' + identity)
        name, version = identity.split('@')
        archive_path = cargo_home / 'registry/cache/index.crates.io-1949cf8c6b5b557f' / (name + '-' + version + '.crate')
        data = inputs.read(archive_path)
        require(sha(data) == row['checksum'], 'Cached crate checksum mismatch: ' + identity)
        selected = {}
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            for index, member in enumerate(archive):
                require(index < 10000, 'Crate member count exceeds bound')
                require(member.name.startswith(name + '-' + version + '/'), 'Crate member identity mismatch')
                relative = member.name.split('/', 1)[1]
                require(not Path(relative).is_absolute() and '..' not in Path(relative).parts, 'Crate member path invalid')
                if member.isfile() and (relative in ('Cargo.toml', '.cargo_vcs_info.json') or NOTICE.fullmatch(Path(relative).name)):
                    require(0 <= member.size <= 16 * 1024 * 1024 and relative not in selected, 'Crate metadata/notice duplicate or oversized')
                    selected[relative] = archive.extractfile(member).read()
                    require(sum(map(len, selected.values())) <= 32 * 1024 * 1024, 'Crate metadata/notice total exceeds bound')
        meta = tomllib.loads(selected['Cargo.toml'].decode())['package']
        vcs = json.loads(selected['.cargo_vcs_info.json'])
        require(meta == matches[0]['metadata'] and meta['name'] == name and meta['version'] == version and
                meta.get('license') == row['license'] and meta.get('repository') == row['repository'],
                'Cached crate metadata association mismatch: ' + identity)
        require(not any(NOTICE.fullmatch(Path(key).name) for key in selected), 'Cached crate already contains notices')
        repo = meta.get('repository', meta.get('homepage', '')).removesuffix('.git').rstrip('/').split('/tree/')[0]
        revision = vcs.get('git', {}).get('sha1', '')
        require(repo == 'https://github.com/etemesi254/zune-image' and re.fullmatch('[0-9a-f]{40}', revision),
                'Cached crate upstream association missing')
        expected_url = f'https://raw.githubusercontent.com/etemesi254/zune-image/{revision}/LICENSE.md'
        payload = old_entries[identity, 'upstream-LICENSE.md']
        digest = sha(payload)
        require(payload and old.get('notices') == {'upstream-LICENSE.md': digest} and
                old.get('upstream_notices') == [{'url': expected_url, 'sha256': digest}],
                'Prior crate notice/VCS association mismatch: ' + identity)
        require(row['archive'] == f'https://static.crates.io/crates/{name}/{name}-{version}.crate', 'Crate archive URL mismatch')
        additions[identity, 'upstream-LICENSE.md'] = payload
        updated = copy.deepcopy(row)
        updated.update(notices=copy.deepcopy(old['notices']), upstream_notices=copy.deepcopy(old['upstream_notices']))
        updates[identity] = updated
        archives[identity] = {'path': str(archive_path.absolute()), 'sha256': sha(data), 'bytes': len(data),
                              'vcs_revision': revision, 'notice_url': expected_url, 'notice_sha256': digest}
        resolved_missing.append(matches[0])
    result = current + b''.join(f'\n===== {identity} / {name} / SHA256 {sha(data)} =====\n'.encode() +
            data + b'\n===== END UPSTREAM FILE =====\n' for (identity, name), data in sorted(additions.items()))
    require(len(result) <= 64 * 1024 * 1024, 'Combined Rust notice artifact exceeds bound')
    inputs.check()
    fd = os.open(current_path, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        require((s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns) == inputs.records[current_path][0],
                'Current Rust notice output changed before replacement')
        os.ftruncate(fd, 0)
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(result)
    finally:
        os.close(fd)
    inputs.check(exclude={current_path})
    component['files'][0]['sha256'] = sha(result)
    for identity, updated in updates.items():
        rows[identity].clear()
        rows[identity].update(updated)
    report['missing'] = [item for item in report['missing'] if item not in resolved_missing]
    report['crate_notice_reuse'] = {'directory': str(reuse), 'inventory_sha256': inventory_sha256,
        'manifest_sha256': manifest_sha256, 'prior_rust_artifact_sha256': sha(old_aggregate),
        'current_rust_artifact_before_sha256': sha(current), 'current_rust_artifact_after_sha256': sha(result),
        'archives': archives, 'basis': 'Exact current crate archive checksum and Cargo metadata/VCS revision bind only the associated pinned prior upstream notice; all current dependency identities retained.'}
    return manifest
