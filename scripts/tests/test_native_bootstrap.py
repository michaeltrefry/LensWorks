"""Bounded toolchain/packaging contracts; no Rust, Xcode or GPU build runs here."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin', CALLS=str(self.log), HOME=str(self.home))
        for key in ('DEVELOPER_DIR', 'SDKROOT', 'CC', 'CXX', 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTUP_HOME', 'RUSTUP_TOOLCHAIN',
                    'LW_NATIVE_FLAGS_SET', 'LW_NATIVE_TOOLCHAIN_ID', 'CFLAGS', 'CXXFLAGS'):
            self.env.pop(key, None)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)
        return path

    def run_script(self, script, *args, env=None):
        return subprocess.run(['/bin/bash', str(ROOT / script), *map(str, args)],
                              env=env or self.env, text=True, capture_output=True, timeout=10)

    def toolchain(self):
        # The script derives its root, so copy it into a disposable checkout.
        scripts = self.root / 'scripts'
        scripts.mkdir()
        script = scripts / 'native-toolchain.sh'
        shutil.copyfile(ROOT / 'scripts/native-toolchain.sh', script)
        shutil.copyfile(ROOT / 'rust-toolchain.toml', self.root / 'rust-toolchain.toml')
        self.sdk = self.root / 'Xcode 26.5.app' / 'SDKs' / 'MacOSX26.5.sdk'
        self.sdk.mkdir(parents=True)
        self.stub('xcode-select', 'echo /selected/Xcode/Contents/Developer')
        self.stub('xcrun', '''case "$*" in
  '--sdk macosx --show-sdk-path') echo "$TEST_SDK";;
  '--sdk macosx --show-sdk-version') echo 26.5;;
  '--sdk macosx --find clang') command -v selected-clang;;
  '--sdk macosx --find clang++') command -v selected-clang++;;
  *) exit 99;;
esac''')
        for name in ('selected-clang', 'selected-clang++', 'cmake'):
            self.stub(name, 'echo stub-version')
        self.stub('rustc', f'echo "rustc {self.pin()} (stub)"')
        self.stub('cargo', f'echo "cargo {self.pin()} (stub)"')
        self.stub('xcodebuild', 'echo "Xcode ${TEST_XCODE_VERSION:-26.5}"')
        self.env['TEST_SDK'] = str(self.sdk)
        return script

    @staticmethod
    def pin():
        import re
        return re.search(r'^channel = "([0-9.]+)"$', (ROOT / 'rust-toolchain.toml').read_text(), re.M).group(1)

    def pinned_toolchain(self, rustc=None, cargo=None):
        bin = self.home / '.rustup/toolchains' / f'{self.pin()}-aarch64-apple-darwin' / 'bin'
        bin.mkdir(parents=True)
        for name, version in (('rustc', rustc or self.pin()), ('cargo', cargo or self.pin())):
            path = bin / name
            path.write_text(f'#!/bin/bash\nset -eu\necho "pinned-{name} $*" >> "$CALLS"\necho "{name} {version} (pinned)"\n')
            path.chmod(0o755)
        return bin

    def github_selection(self, script):
        envfile = self.root / 'github-env'
        output = self.root / 'github-output'
        envfile.write_text('')
        output.write_text('')
        env = dict(self.env, GITHUB_ENV=str(envfile), GITHUB_OUTPUT=str(output))
        result = subprocess.run(['/bin/bash', str(script), '--github'], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split('=', 1) for line in envfile.read_text().splitlines())

    def test_selected_xcode_sdk_and_compilers_reach_cmake_and_cargo(self):
        script = self.toolchain()
        self.env.update(SDKROOT='/wrong/CLT27.sdk', CC='/wrong/cc', CXX='/wrong/c++')
        values = self.github_selection(script)
        self.assertEqual(values['SDKROOT'], str(self.sdk))
        self.assertEqual(values['CC'], str(self.bin / 'selected-clang'))
        self.assertEqual(values['CXX'], str(self.bin / 'selected-clang++'))
        cmake = Path(values['CMAKE_TOOLCHAIN_FILE']).read_text()
        for key in ('SDKROOT', 'CC', 'CXX'):
            self.assertIn(values[key], cmake)
        self.assertIn('CMAKE_OSX_SYSROOT', cmake)
        self.assertIn('CMAKE_OSX_DEPLOYMENT_TARGET 26.2', cmake)
        self.assertNotIn('CXXFLAGS', values)  # SDKROOT/toolchain, not whitespace-split flags.
        self.assertIn(values['LW_NATIVE_TOOLCHAIN_ID'], values['RUSTFLAGS'])
        self.assertNotIn('CARGO_ENCODED_RUSTFLAGS', values)  # Empty encoded flags override RUSTFLAGS.

    def test_toolchain_upgrade_changes_cargo_and_cmake_cache_identity(self):
        script = self.toolchain()
        first = self.github_selection(script)
        self.env['TEST_XCODE_VERSION'] = '27.0'
        second = self.github_selection(script)
        self.assertNotEqual(first['LW_NATIVE_TOOLCHAIN_ID'], second['LW_NATIVE_TOOLCHAIN_ID'])
        self.assertNotEqual(first['CMAKE_TOOLCHAIN_FILE'], second['CMAKE_TOOLCHAIN_FILE'])
        self.assertNotEqual(first['RUSTFLAGS'], second['RUSTFLAGS'])
        self.env.update(CARGO_ENCODED_RUSTFLAGS='--cfg=caller_flag')
        encoded = self.github_selection(script)['CARGO_ENCODED_RUSTFLAGS']
        self.assertTrue(encoded.startswith('--cfg=caller_flag\x1f--cfg=lensworks_toolchain='))
        self.env['CARGO_ENCODED_RUSTFLAGS'] = ''
        encoded = self.github_selection(script)['CARGO_ENCODED_RUSTFLAGS']
        self.assertTrue(encoded.startswith('--cfg=lensworks_toolchain='))

    def test_deployment_change_segregates_native_cache_and_reaches_cmake(self):
        script = self.toolchain()
        first = self.github_selection(script)
        script.write_text(script.read_text().replace('export MACOSX_DEPLOYMENT_TARGET=26.2', 'export MACOSX_DEPLOYMENT_TARGET=26.3'))
        second = self.github_selection(script)
        self.assertNotEqual(first['LW_NATIVE_TOOLCHAIN_ID'], second['LW_NATIVE_TOOLCHAIN_ID'])
        self.assertEqual(second['MACOSX_DEPLOYMENT_TARGET'], '26.3')
        self.assertIn('CMAKE_OSX_DEPLOYMENT_TARGET 26.3', Path(second['CMAKE_TOOLCHAIN_FILE']).read_text())

    def test_repeated_sourcing_preserves_caller_flags_and_native_cache_identity(self):
        script = self.toolchain()
        self.env.update(CFLAGS='-Wall', CXXFLAGS='-Wextra')
        first = self.github_selection(script)
        self.env.update(first)
        second = self.github_selection(script)
        for key in ('CFLAGS', 'CXXFLAGS', 'RUSTFLAGS', 'LW_NATIVE_TOOLCHAIN_ID'):
            self.assertEqual(first[key], second[key])
        self.assertEqual(second['CFLAGS'], '-Wall')
        self.assertEqual(second['CXXFLAGS'], '-Wextra')

    def test_cmake_parses_space_containing_sdk_and_preserves_other_flags(self):
        cmake = shutil.which('cmake')
        if not cmake:
            self.skipTest('CMake is not installed (no compilation is performed)')
        script = self.toolchain()
        values = self.github_selection(script)
        probe = self.root / 'probe.cmake'
        probe.write_text('set(CMAKE_C_FLAGS [[-fPIC -isysroot ' + str(self.sdk) + ' -Wall]])\n'
                         'set(CMAKE_CXX_FLAGS [[-fPIC -isysroot ' + str(self.sdk) + ' -Wextra]])\n'
                         'include([[' + values['CMAKE_TOOLCHAIN_FILE'] + ']])\n'
                         'if(NOT CMAKE_C_FLAGS STREQUAL [[-fPIC -isysroot "' + str(self.sdk) + '" -Wall]])\n'
                         '  message(FATAL_ERROR "C sysroot flags malformed: ${CMAKE_C_FLAGS}")\nendif()\n'
                         'if(NOT CMAKE_CXX_FLAGS STREQUAL [[-fPIC -isysroot "' + str(self.sdk) + '" -Wextra]])\n'
                         '  message(FATAL_ERROR "CXX sysroot flags malformed: ${CMAKE_CXX_FLAGS}")\nendif()\n')
        result = subprocess.run([cmake, '-P', str(probe)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_selected_sdk_fails_before_any_build(self):
        script = self.toolchain()
        self.env['TEST_SDK'] = str(self.root / 'absent')
        result = subprocess.run(['/bin/bash', str(script)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unavailable', result.stderr)

    def test_rust_other_than_the_pin_on_path_fails_before_any_build(self):
        # The factory's sandbox PATH resolves Homebrew's rustc, not the rust-toolchain.toml pin.
        script = self.toolchain()
        self.stub('rustc', 'echo "rustc 1.99.1 (58cf8f9c3 2026-10-13) (Homebrew)"')
        self.stub('cargo', 'echo "cargo 1.99.1 (Homebrew)"')
        result = subprocess.run(['/bin/bash', str(script)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f'Rust {self.pin()} is pinned', result.stderr)
        self.assertIn('rustc 1.99.1', result.stderr)
        self.assertIn(f'rustup toolchain install {self.pin()}', result.stderr)
        self.assertFalse((self.root / '.build/toolchains').exists())

    def test_cargo_of_another_release_than_the_pinned_rustc_fails(self):
        script = self.toolchain()
        self.stub('cargo', 'echo "cargo 1.99.1 (Homebrew)"')
        result = subprocess.run(['/bin/bash', str(script)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cargo 1.99.1', result.stderr)

    def test_pinned_rustup_toolchain_is_selected_by_path_over_another_rust(self):
        script = self.toolchain()
        self.stub('rustc', 'echo "rustc 1.99.1 (Homebrew)"')
        self.stub('cargo', 'echo "cargo 1.99.1 (Homebrew)"')
        pinned = self.pinned_toolchain()
        envfile, output, github_path = (self.root / name for name in ('github-env', 'github-output', 'github-path'))
        for path in (envfile, output, github_path):
            path.write_text('')
        env = dict(self.env, GITHUB_ENV=str(envfile), GITHUB_OUTPUT=str(output), GITHUB_PATH=str(github_path))
        result = subprocess.run(['/bin/bash', str(script), '--github'], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(github_path.read_text().splitlines(), [str(pinned)])
        calls = self.log.read_text()
        self.assertIn('pinned-rustc -Vv', calls)
        self.assertIn('pinned-cargo -V', calls)

    def test_factory_helper_build_runs_the_pinned_cargo(self):
        self.toolchain()
        self.stub('rustc', 'echo "rustc 1.99.1 (Homebrew)"')
        self.stub('cargo', 'echo homebrew-cargo-ran >> "$CALLS"; echo "cargo 1.99.1 (Homebrew)"')
        pinned = self.pinned_toolchain()
        (pinned / 'cargo').write_text(f'''#!/bin/bash
set -eu
if [[ "$1" == -V ]]; then echo "cargo {self.pin()} (pinned)"; exit 0; fi
echo "pinned-cargo $*" >> "$CALLS"
mkdir -p "$CARGO_TARGET_DIR/release"
for name in photocatalog lensworks-decode-worker lensworks-mcp; do printf x > "$CARGO_TARGET_DIR/release/$name"; done
''')
        script = self.root / 'scripts/build-catalog-helpers.sh'
        shutil.copyfile(ROOT / 'scripts/build-catalog-helpers.sh', script)
        self.env['PHOTOCATALOG_DNG_SDK'] = str(self.root / 'pinned-adobe-sdk')
        result = subprocess.run(['/bin/bash', str(script)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertNotIn('homebrew-cargo-ran', calls)
        self.assertEqual(sum(line.startswith('pinned-cargo build') for line in calls.splitlines()), 3)

    def helpers(self, configuration='Debug'):
        app = self.root / f'xcode-s47/Build/Products/{configuration}/LensWorks.app'
        (app / 'Contents').mkdir(parents=True)
        release = self.root / 'release'
        release.mkdir()
        for name in ('photocatalog', 'lensworks-decode-worker', 'lensworks-mcp'):
            path = release / name
            path.write_text('#!/bin/bash\necho source-bound-' + name + '\n')
            path.chmod(0o755)
        helpers = app / 'Contents/Helpers'
        helpers.mkdir()
        for source, target in [('photocatalog', 'PhotoCatalogWorker'), ('lensworks-decode-worker', 'LensWorksDecodeWorker'), ('lensworks-mcp', 'LensWorksMCP')]:
            shutil.copy2(release / source, helpers / target)
        self.stub('codesign', '''printf '%s\\n' "$*" >> "$CALLS"
if [[ "${FAIL_SIGN:-}" == 1 ]]; then exit 7; fi''')
        return app, release

    def test_native_xcode_phase_copies_and_signs_every_helper_before_app_seal(self):
        project = ROOT / 'native/Compositor.xcodeproj/project.pbxproj'
        data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)], text=True))
        objects = data['objects']
        phase_id, phase = next((key, value) for key, value in objects.items() if value.get('name') == 'Embed native helpers')
        self.assertEqual(phase['isa'], 'PBXCopyFilesBuildPhase')
        self.assertEqual(str(phase['dstSubfolderSpec']), '1')  # Wrapper-relative, not another DerivedData app.
        self.assertEqual(phase['dstPath'], 'Contents/Helpers')
        self.assertEqual(len(phase['files']), 3)
        sources = set()
        for build_id in phase['files']:
            build = objects[build_id]
            self.assertIn('CodeSignOnCopy', build['settings']['ATTRIBUTES'])
            path = objects[build['fileRef']]['path']
            self.assertTrue(path.startswith('../.build/native-helpers/'))
            sources.add(Path(path).name)
        self.assertEqual(sources, {'PhotoCatalogWorker', 'LensWorksDecodeWorker', 'LensWorksMCP'})
        app = next(value for value in objects.values() if value.get('productType') == 'com.apple.product-type.application')
        self.assertEqual(app['buildPhases'][-1], phase_id)

    def test_missing_helper_or_signing_failure_is_not_accepted(self):
        app, release = self.helpers()
        worker = app / 'Contents/Helpers/LensWorksDecodeWorker'
        worker.unlink()
        result = self.run_script('scripts/verify-native-helpers.sh', app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing native helper', result.stderr)
        shutil.copy2(release / 'lensworks-decode-worker', worker)
        result = self.run_script('scripts/verify-native-helpers.sh', app, env=dict(self.env, FAIL_SIGN='1'))
        self.assertNotEqual(result.returncode, 0)

    def test_test_wrapper_refuses_missing_or_unsigned_host_before_xcodebuild(self):
        app, release = self.helpers()
        self.stub('xcodebuild', 'echo launched >> "$CALLS"; exit 88')
        shutil.rmtree(app / 'Contents/Helpers')
        derived = app.parents[3]
        result = self.run_script('scripts/ci/xcodebuild_test.sh', 'unused.xcresult',
                                 '-derivedDataPath', derived)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
        helpers = app / 'Contents/Helpers'
        helpers.mkdir()
        for source, target in [('photocatalog', 'PhotoCatalogWorker'), ('lensworks-decode-worker', 'LensWorksDecodeWorker'), ('lensworks-mcp', 'LensWorksMCP')]:
            shutil.copy2(release / source, helpers / target)
        self.log.write_text('')
        result = self.run_script('scripts/ci/xcodebuild_test.sh', 'unused.xcresult',
                                 '-derivedDataPath', derived, env=dict(self.env, FAIL_SIGN='1'))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('launched', self.log.read_text())

    def test_test_wrapper_checks_helper_and_app_signatures_before_launch(self):
        app, release = self.helpers()
        self.log.write_text('')
        self.stub('xcodebuild', 'echo launched >> "$CALLS"; exit 88')
        self.stub('xcrun', 'exit 1')  # No test result: this stub never pretends tests passed.
        result = self.run_script('scripts/ci/xcodebuild_test.sh', 'unused.xcresult',
                                 '-derivedDataPath', app.parents[3])
        self.assertNotEqual(result.returncode, 0)
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[-1], 'launched')
        self.assertEqual(lines[-2], '--verify --strict --deep ' + str(app))
        self.assertEqual(sum('Contents/Helpers/' in line for line in lines), 3)

    def test_release_test_run_verifies_release_host_not_stale_debug_host(self):
        app, release = self.helpers('Release')
        self.log.write_text('')
        self.stub('xcodebuild', 'echo launched >> "$CALLS"; exit 88')
        self.stub('xcrun', 'exit 1')
        result = self.run_script('scripts/ci/xcodebuild_test.sh', 'unused.xcresult',
                                 '-derivedDataPath', app.parents[3], '-configuration', 'Release')
        self.assertNotEqual(result.returncode, 0)  # No fabricated passing test evidence.
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[-1], 'launched')
        self.assertEqual(lines[-2], '--verify --strict --deep ' + str(app))
        self.assertNotIn('/Debug/', self.log.read_text())

    def test_factory_helper_build_uses_selected_toolchain_for_every_binary(self):
        self.toolchain()
        script = self.root / 'scripts/build-catalog-helpers.sh'
        shutil.copyfile(ROOT / 'scripts/build-catalog-helpers.sh', script)
        version = f'if [[ "${{1:-}}" == -V ]]; then echo "cargo {self.pin()} (stub)"; exit 0; fi\n'
        self.stub('cargo', version + '''printf '%s | %s | %s | %s\\n' "$*" "$SDKROOT" "$CMAKE_TOOLCHAIN_FILE" "$CARGO_TARGET_DIR" >> "$CALLS"
mkdir -p "$CARGO_TARGET_DIR/release"
for name in photocatalog lensworks-decode-worker lensworks-mcp; do
  printf 'source-bound-%s' "$name" > "$CARGO_TARGET_DIR/release/$name"
  chmod 755 "$CARGO_TARGET_DIR/release/$name"
done''')
        self.env['PHOTOCATALOG_DNG_SDK'] = str(self.root / 'pinned-adobe-sdk')
        result = subprocess.run(['/bin/bash', str(script)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.log.read_text().splitlines()
        self.assertEqual(len(lines), 3)
        for line in lines:
            self.assertIn(str(self.sdk), line)
            self.assertIn('/.build/toolchains/', line)
            self.assertIn(str(self.root / '.build/rust-catalog'), line)
        self.assertIn('adapters/catalog/Cargo.toml', lines[0])
        self.assertIn('--bin photocatalog --bin organization_probe', lines[1])
        self.assertIn('adapters/mcp/Cargo.toml', lines[2])
        for source, target in [('photocatalog', 'PhotoCatalogWorker'), ('lensworks-decode-worker', 'LensWorksDecodeWorker'), ('lensworks-mcp', 'LensWorksMCP')]:
            staged = self.root / '.build/native-helpers' / target
            self.assertEqual(staged.read_bytes(), (self.root / '.build/rust-catalog/release' / source).read_bytes())
            self.assertTrue(os.access(staged, os.X_OK))

    def test_all_native_ci_paths_and_factory_share_bootstrap(self):
        workflows = ROOT / '.github/workflows'
        for path in workflows.glob('*.yml'):
            self.assertIn('scripts/native-toolchain.sh --github', path.read_text(), path)
        unit = (workflows / 'unit-tests.yml').read_text()
        self.assertIn('steps.native-toolchain.outputs.identity', unit)
        self.assertNotIn('restore-keys:', unit)
        for path in ('scripts/build-native.sh', '.github/workflows/unit-tests.yml', '.factory/prepare.yaml'):
            self.assertIn('scripts/build-catalog-helpers.sh', (ROOT / path).read_text())
        build = (ROOT / 'scripts/build-catalog-helpers.sh').read_text()
        self.assertIn('--bin photocatalog --bin organization_probe', build)
        self.assertIn('adapters/catalog/Cargo.toml', build)
        self.assertIn('adapters/mcp/Cargo.toml', build)
        project = (ROOT / 'native/Compositor.xcodeproj/project.pbxproj').read_text()
        self.assertIn('PBXCopyFilesBuildPhase', project)
        self.assertIn('CodeSignOnCopy', project)
        self.assertIn('dstPath = Contents/Helpers', project)


if __name__ == '__main__':
    unittest.main()
