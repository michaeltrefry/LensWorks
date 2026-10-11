"""Offline reuse must prove the current identity, not inherit an old inventory."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_notice_reuse as reuse


def envelope(root, files):
    return b''.join((f'\n===== {root} / {name} / SHA256 {reuse.sha(data)} =====\n'.encode()
                     + data + b'\n===== END UPSTREAM FILE =====\n') for name, data in sorted(files.items()))


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.old_dir, self.out = self.base / 'prior', self.base / 'current'
        self.old_dir.mkdir()
        self.out.mkdir()
        self.prior = {'protocol': 1, 'status': 'NOTICE_INVENTORY_COMPLETE', 'missing': [], 'native': []}
        self.report = {'protocol': 1, 'native': [], 'rust': [{'identity': 'fresh-rust-only'}],
                       'missing': [{'component': n, 'reason': r} for n, r in reuse.MISSING.items()]}
        self.old_manifest = {'protocol': 1, 'components': []}
        self.manifest = {'protocol': 1, 'components': []}
        self.roots = {}
        for name in reuse.MISSING:
            root = self.base / name
            self.roots[name] = root
            (root / 'lib').mkdir(parents=True)
            (root / '.brew').mkdir()
            (root / 'INSTALL_RECEIPT.json').write_bytes(b'exact installed receipt')
            (root / 'lib' / (name + '.dylib')).write_bytes(b'actual installed library')
            (root / 'LICENSE').write_bytes(b'local license\n')
            source = b'exact LibRaw corresponding-source archive'
            recipe = ('  revision: "' + 'a' * 40 + '"\n') if name == 'aom' else (
                '  url "https://example.org/' + name + '.tar.gz"\n  sha256 "' + reuse.sha(source) + '"\n')
            (root / '.brew' / (name + '.rb')).write_text(recipe)
            ref = lambda p: {'path': str(p), 'sha256': reuse.sha(p.read_bytes()), 'bytes': len(p.read_bytes())}
            current = {'component': name, 'root': str(root), 'receipt': ref(root / 'INSTALL_RECEIPT.json'),
                       'libraries': {name + '.dylib': ref(root / 'lib' / (name + '.dylib'))},
                       'notices': {'LICENSE': reuse.sha(b'local license\n')}, 'supplemental_sources': []}
            prior = copy.deepcopy(current)
            files = {'LICENSE': b'local license\n'}
            files.update({p: ('verbatim upstream ' + p).encode() for p in reuse.SUPPLEMENTS[name]})
            prior['notices'] = {p: reuse.sha(b) for p, b in files.items()}
            if name == 'aom':
                prior['supplemental_sources'] = [{'url': 'https://aomedia.googlesource.com/aom/+/' + 'a'*40 + '/PATENTS?format=TEXT',
                    'sha256': reuse.sha(files['PATENTS']), 'installed_revision': 'a'*40}]
            elif name == 'libvmaf':
                prior['supplemental_sources'] = [{'source_archive': 'https://example.org/libvmaf.tar.gz',
                    'archive_sha256': reuse.sha(source), 'path': p, 'sha256': reuse.sha(files[p])}
                    for p in sorted(reuse.SUPPLEMENTS[name])]
            else:
                prior['included_source'] = {'url': 'https://example.org/libraw.tar.gz', 'sha256': reuse.sha(source),
                    'recipe': ref(root / '.brew/libraw.rb'), 'basis': 'exact installed formula source and build recipe'}
                (self.old_dir / 'libraw-source.tar.gz').write_bytes(source)
                (self.old_dir / 'libraw-build-recipe.rb').write_text(recipe)
            (self.old_dir / (name + '.txt')).write_bytes(envelope(str(root), files))
            (self.out / (name + '.txt')).write_bytes(envelope(str(root), {'LICENSE': b'local license\n'}))
            self.prior['native'].append(prior)
            self.report['native'].append(current)
            self.old_manifest['components'].append({'component': name, 'libraries': [name+'.dylib'],
                'files': [{'path': p, 'sha256': reuse.sha((self.old_dir / p).read_bytes())} for p in sorted(reuse.FILES[name])]})
            self.manifest['components'].append({'component': name, 'libraries': [name+'.dylib'],
                'files': [{'path': name+'.txt', 'sha256': reuse.sha((self.out / (name+'.txt')).read_bytes())}]})
        (self.out / 'manifest.json').write_text(json.dumps(self.manifest))
        self.pin()

    def tearDown(self):
        self.temp.cleanup()

    def pin(self):
        (self.old_dir / 'inventory.json').write_text(json.dumps(self.prior))
        (self.old_dir / 'manifest.json').write_text(json.dumps(self.old_manifest))
        self.inventory_pin = reuse.sha((self.old_dir / 'inventory.json').read_bytes())
        self.manifest_pin = reuse.sha((self.old_dir / 'manifest.json').read_bytes())

    def run_reuse(self):
        return reuse.reuse_native_notices(self.out, self.report, self.old_dir, self.inventory_pin, self.manifest_pin)

    def rejected(self, reason):
        before = {p.name: p.read_bytes() for p in self.out.iterdir()}
        with self.assertRaisesRegex(ValueError, reason):
            self.run_reuse()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.out.iterdir()})

    def test_matching_three_components_preserve_current_inventory_and_unknown_missing(self):
        self.report['missing'].append({'component': 'other', 'reason': 'still missing'})
        result = self.run_reuse()
        self.assertEqual(self.report['rust'], [{'identity': 'fresh-rust-only'}])
        self.assertEqual(self.report['missing'], [{'component': 'other', 'reason': 'still missing'}])
        self.assertEqual(result, self.old_manifest)
        for name in set.union(*reuse.FILES.values()):
            self.assertEqual((self.out / name).read_bytes(), (self.old_dir / name).read_bytes())

    def test_inventory_pin_changed(self):
        self.inventory_pin = '0'*64
        self.rejected('inventory pin mismatch')

    def test_manifest_pin_changed(self):
        self.manifest_pin = '0'*64
        self.rejected('manifest pin mismatch')

    def test_incomplete_prior_rejected_even_with_explicit_pins(self):
        self.prior['missing'] = [{'component': 'unknown'}]
        self.pin()
        self.rejected('complete prior')

    def test_changed_library(self):
        (self.roots['aom'] / 'lib/aom.dylib').write_bytes(b'changed')
        self.rejected('Installed file identity changed')

    def test_changed_receipt(self):
        (self.roots['aom'] / 'INSTALL_RECEIPT.json').write_bytes(b'changed')
        self.rejected('Installed file identity changed')

    def test_added_library(self):
        (self.roots['aom'] / 'lib/new.dylib').write_bytes(b'new')
        self.rejected('library set changed')

    def test_changed_local_notice(self):
        (self.roots['aom'] / 'LICENSE').write_bytes(b'changed')
        self.rejected('local notice files changed')

    def test_added_local_notice(self):
        (self.roots['aom'] / 'PATENTS').write_bytes(b'new installed patent notice')
        self.rejected('local notice files changed')

    def test_changed_aom_formula_revision(self):
        (self.roots['aom'] / '.brew/aom.rb').write_text('revision: "' + 'b'*40 + '"')
        self.rejected('AOM installed revision')

    def test_changed_vmaf_formula_checksum(self):
        p = self.roots['libvmaf'] / '.brew/libvmaf.rb'
        p.write_text('  url "https://example.org/libvmaf.tar.gz"\n  sha256 "' + 'b'*64 + '"')
        self.rejected('VMAF installed source')

    def test_changed_libraw_recipe(self):
        p = self.roots['libraw'] / '.brew/libraw.rb'
        p.write_text(p.read_text() + '\n# changed build instruction\n')
        self.rejected('LibRaw corresponding source')

    def test_corresponding_source_corrupt(self):
        (self.old_dir / 'libraw-source.tar.gz').write_bytes(b'corrupt')
        self.rejected('Reuse artifact digest mismatch')

    def test_embedded_notices_corrupt(self):
        (self.old_dir / 'libvmaf.txt').write_bytes(b'corrupt')
        self.rejected('Reuse artifact digest mismatch')

    def test_duplicate_component(self):
        self.prior['native'].append(copy.deepcopy(self.prior['native'][0]))
        self.pin()
        self.rejected('Duplicate notice component')

    def test_unrelated_artifact_path(self):
        self.old_manifest['components'][0]['files'][0]['path'] = '../unrelated'
        self.pin()
        self.rejected('file/library set mismatch')

    def test_missing_obligation_wrong_reason(self):
        self.report['missing'][0]['reason'] = 'an unrelated failure'
        self.rejected('exact current missing obligation')

    def test_reuse_symlink_rejected(self):
        path = self.old_dir / 'aom.txt'
        path.rename(self.old_dir / 'moved')
        path.symlink_to(self.old_dir / 'moved')
        self.rejected('aliases are not allowed')

    def test_preexisting_source_output_preserved(self):
        (self.out / 'libraw-source.tar.gz').write_bytes(b'foreign file')
        self.rejected('Corresponding-source output must be new')

    def test_rehashed_but_invalid_notice_envelope(self):
        path = self.old_dir / 'aom.txt'
        path.write_bytes(path.read_bytes().replace(b'verbatim upstream PATENTS', b'corrupt upstream PATENTS!'))
        for record in self.old_manifest['components'][0]['files']:
            record['sha256'] = reuse.sha(path.read_bytes())
        self.pin()
        self.rejected('Notice aggregate payload mismatch')

    def test_nonregular_fifo_rejected_without_reading(self):
        import os
        path = self.old_dir / 'aom.txt'
        path.unlink()
        os.mkfifo(path)
        self.rejected('bounded regular file')

    def test_read_cap(self):
        path = self.base / 'oversized'
        path.write_bytes(b'123456')
        with self.assertRaisesRegex(ValueError, 'bounded regular file'):
            reuse.Inputs().read(path, limit=5)

    def test_current_input_changes_before_copy(self):
        original = reuse.Inputs.check
        def mutate_then_check(inputs, *args, **kwargs):
            (self.roots['aom'] / 'lib/aom.dylib').write_bytes(b'changed after first read')
            return original(inputs, *args, **kwargs)
        with patch.object(reuse.Inputs, 'check', mutate_then_check):
            self.rejected('Notice input changed')


if __name__ == '__main__':
    unittest.main()
