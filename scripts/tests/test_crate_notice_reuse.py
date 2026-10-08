"""Exact per-crate notice association and preservation of fresh Rust inventory."""
import copy
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_notice_reuse as reuse


def envelope(entries):
    return b''.join(f'\n===== {identity} / {name} / SHA256 {reuse.sha(data)} =====\n'.encode()
                   + data + b'\n===== END UPSTREAM FILE =====\n' for (identity, name), data in sorted(entries.items()))


class CrateReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.old_dir, self.out, self.cargo = [self.base / name for name in ('prior', 'current', 'cargo')]
        for path in (self.old_dir, self.out, self.cargo):
            path.mkdir()
        self.cache = self.cargo / 'registry/cache/index.crates.io-1949cf8c6b5b557f'
        self.cache.mkdir(parents=True)
        self.prior = {'protocol': 1, 'status': 'NOTICE_INVENTORY_COMPLETE', 'missing': [], 'rust': []}
        self.report = {'protocol': 1, 'rust': [], 'missing': []}
        self.metadata, self.vcs, self.archives = {}, {}, {}
        old_entries = {('old-unrelated@9', 'LICENSE'): b'old unrelated text, must not be reused'}
        for index, identity in enumerate(sorted(reuse.CRATE_REUSE)):
            name, version = identity.split('@')
            meta = {'name': name, 'version': version, 'license': 'MIT OR Apache-2.0 OR Zlib'}
            meta['homepage' if name == 'zune-core' else 'repository'] = 'https://github.com/etemesi254/zune-image/tree/dev/crates/' + name
            self.metadata[identity] = meta
            self.vcs[identity] = {'git': {'sha1': str(index + 1) * 40}, 'path_in_vcs': 'crates/' + name}
            self.archives[identity] = self.cache / (name + '-' + version + '.crate')
            digest = self.archive(identity)
            row = {'identity': identity, 'source': 'registry+https://github.com/rust-lang/crates.io-index',
                'checksum': digest, 'license': meta['license'], 'repository': meta.get('repository'),
                'archive': f'https://static.crates.io/crates/{name}/{name}-{version}.crate', 'upstream_notices': []}
            old = copy.deepcopy(row)
            notice = b'actual synthetic upstream test license text\n'
            old_entries[identity, 'upstream-LICENSE.md'] = notice
            old['notices'] = {'upstream-LICENSE.md': reuse.sha(notice)}
            old['upstream_notices'] = [{'url': 'https://raw.githubusercontent.com/etemesi254/zune-image/' + str(index+1)*40 + '/LICENSE.md',
                                       'sha256': reuse.sha(notice)}]
            self.report['rust'].append(row)
            self.prior['rust'].append(old)
            self.report['missing'].append({'identity': identity, 'reason': 'upstream notice absent', 'metadata': copy.deepcopy(meta)})
        self.fresh = envelope({('current-unrelated@1', 'LICENSE'): b'current independently collected license'})
        self.report['rust'].append({'identity': 'current-unrelated@1', 'checksum': 'fresh-only',
                                   'notices': {'LICENSE': reuse.sha(b'current independently collected license')}})
        (self.out / 'rust-dependencies.txt').write_bytes(self.fresh)
        (self.old_dir / 'rust-dependencies.txt').write_bytes(envelope(old_entries))
        self.manifest = {'protocol': 1, 'components': [{'component': 'rust-dependencies', 'libraries': [],
            'files': [{'path': 'rust-dependencies.txt', 'sha256': reuse.sha(self.fresh)}]}]}
        self.old_manifest = {'protocol': 1, 'components': [{'component': 'rust-dependencies', 'libraries': [],
            'files': [{'path': 'rust-dependencies.txt', 'sha256': reuse.sha((self.old_dir / 'rust-dependencies.txt').read_bytes())}]}]}
        self.pin()

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, identity, extra=()):
        name, version = identity.split('@')
        meta = self.metadata[identity]
        cargo = '[package]\n' + ''.join(key + ' = ' + json.dumps(value) + '\n' for key, value in meta.items())
        files = [('Cargo.toml', cargo.encode()), ('.cargo_vcs_info.json', json.dumps(self.vcs[identity]).encode()), *extra]
        with tarfile.open(self.archives[identity], 'w:gz') as archive:
            for relative, data in files:
                info = tarfile.TarInfo(name + '-' + version + '/' + relative)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return reuse.sha(self.archives[identity].read_bytes())

    def repin_archive(self, identity, extra=()):
        digest = self.archive(identity, extra)
        for report in (self.prior, self.report):
            next(row for row in report['rust'] if row['identity'] == identity)['checksum'] = digest
        self.pin()

    def pin(self):
        (self.old_dir / 'inventory.json').write_text(json.dumps(self.prior))
        (self.old_dir / 'manifest.json').write_text(json.dumps(self.old_manifest))
        self.inventory_pin = reuse.sha((self.old_dir / 'inventory.json').read_bytes())
        self.manifest_pin = reuse.sha((self.old_dir / 'manifest.json').read_bytes())

    def run_reuse(self):
        return reuse.reuse_crate_notices(self.out, self.report, self.manifest, self.old_dir,
                                        self.inventory_pin, self.manifest_pin, self.cargo)

    def rejected(self, reason, exception=ValueError):
        before = (self.out / 'rust-dependencies.txt').read_bytes()
        before_report = copy.deepcopy(self.report)
        with self.assertRaisesRegex(exception, reason):
            self.run_reuse()
        self.assertEqual(before, (self.out / 'rust-dependencies.txt').read_bytes())
        self.assertEqual(before_report, self.report)

    def test_verified_text_only_preserves_current_graph_and_unknown_missing(self):
        identities = [(x['identity'], x['checksum']) for x in self.report['rust']]
        self.report['missing'].append({'identity': 'other@1', 'reason': 'unrelated obligation'})
        manifest = self.run_reuse()
        result = (self.out / 'rust-dependencies.txt').read_bytes()
        self.assertTrue(result.startswith(self.fresh))
        self.assertNotIn(b'old unrelated text', result)
        self.assertEqual(identities, [(x['identity'], x['checksum']) for x in self.report['rust']])
        self.assertEqual(self.report['missing'], [{'identity': 'other@1', 'reason': 'unrelated obligation'}])
        self.assertEqual(len(reuse.aggregate_entries(result)), 3)
        self.assertEqual(manifest['components'][0]['files'][0]['sha256'], reuse.sha(result))

    def test_changed_checksum(self):
        self.report['rust'][0]['checksum'] = '0' * 64
        self.rejected('Crate notice identity changed')

    def test_changed_license(self):
        self.report['rust'][0]['license'] = 'MIT'
        self.rejected('Crate notice identity changed')

    def test_changed_registry(self):
        self.report['rust'][0]['source'] = 'different-registry'
        self.rejected('Crate notice identity changed')

    def test_changed_archive_bytes(self):
        self.archives['zune-core@0.4.12'].write_bytes(b'changed')
        self.rejected('Cached crate checksum mismatch')

    def test_missing_archive(self):
        self.archives['zune-core@0.4.12'].unlink()
        self.rejected('No such file', FileNotFoundError)

    def test_cached_archive_symlink(self):
        path = self.archives['zune-core@0.4.12']
        data = path.read_bytes()
        path.unlink()
        target = self.base / 'elsewhere'
        target.write_bytes(data)
        path.symlink_to(target)
        self.rejected('aliases are not allowed')

    def test_archive_metadata_mismatch(self):
        self.metadata['zune-core@0.4.12']['license'] = 'different'
        self.repin_archive('zune-core@0.4.12')
        self.rejected('Cached crate metadata association mismatch')

    def test_changed_vcs_revision(self):
        self.vcs['zune-core@0.4.12']['git']['sha1'] = 'f'*40
        self.repin_archive('zune-core@0.4.12')
        self.rejected('Prior crate notice/VCS association mismatch')

    def test_missing_vcs(self):
        self.vcs['zune-core@0.4.12'] = {}
        self.repin_archive('zune-core@0.4.12')
        self.rejected('Cached crate upstream association missing')

    def test_wrong_prior_notice_url(self):
        self.prior['rust'][0]['upstream_notices'][0]['url'] = 'https://example.org/guessed-license'
        self.pin()
        self.rejected('Prior crate notice/VCS association mismatch')

    def test_wrong_prior_notice_hash(self):
        self.prior['rust'][0]['notices']['upstream-LICENSE.md'] = '0'*64
        self.pin()
        self.rejected('Prior crate notice/VCS association mismatch')

    def test_prior_aggregate_corruption(self):
        (self.old_dir / 'rust-dependencies.txt').write_bytes(b'changed')
        self.rejected('Prior Rust notice artifact mismatch')

    def test_current_aggregate_corruption(self):
        (self.out / 'rust-dependencies.txt').write_bytes(b'changed')
        self.rejected('Current Rust notice artifact mismatch')

    def test_duplicate_current_identity(self):
        self.report['rust'].append(copy.deepcopy(self.report['rust'][0]))
        self.rejected('Duplicate Rust notice identity')

    def test_wrong_missing_reason(self):
        self.report['missing'][0]['reason'] = 'a different failure'
        self.rejected('Expected exact missing crate notice obligation')

    def test_matching_archive_with_already_included_notice(self):
        self.repin_archive('zune-core@0.4.12', [('LICENSE', b'included notice')])
        self.rejected('Cached crate already contains notices')

    def test_current_archive_changes_before_copy(self):
        original = reuse.Inputs.check
        def mutate_then_check(inputs, *args, **kwargs):
            self.archives['zune-core@0.4.12'].write_bytes(b'changed after validation')
            return original(inputs, *args, **kwargs)
        with patch.object(reuse.Inputs, 'check', mutate_then_check):
            self.rejected('Notice input changed')


if __name__ == '__main__':
    unittest.main()
