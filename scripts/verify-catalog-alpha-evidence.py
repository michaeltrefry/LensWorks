#!/usr/bin/env python3
"""Verify installed linear-alpha fixtures; tool qualification is separate from app proof."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(directory, plan_path, manifest_path):
    common_path = Path(__file__).with_name('verify-catalog-plan-evidence.py')
    require(hashlib.sha256(common_path.read_bytes()).hexdigest() ==
            '3fa500277b4e44d3aca6b1d960df9b879193d9e21f8934367e4e047eace9d2e0',
            'Common evidence verifier changed; requalify this composition')
    spec = importlib.util.spec_from_file_location('catalog_evidence', common_path)
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    require(hashlib.sha256(manifest_path.read_bytes()).hexdigest() == '5752903f67e04bbb60dc06bd4329a2f211a539771b687d71ebeeb896fb4eb136',
            'Independently qualified alpha fixture manifest changed')
    manifest = json.loads(manifest_path.read_text())
    plan = json.loads(plan_path.read_text())
    journey = json.loads((directory / 'journey.json').read_text())
    require(type(journey.get('error')) is str and journey['error'] == '',
            'Journey must provide the native empty text success error field')
    actions = journey['catalogJourney']
    require([x['kind'] for x in plan['actions']] ==
            ['create', 'startImport', 'finishImport', 'browse', 'preview', 'close'],
            'Alpha proof requires the complete six-action installed journey')
    require(len(actions) == 6, 'Alpha journey incomplete')
    sources = manifest['sources']
    require(len(sources) == 3 and {x['encoded_alpha_u16'] for x in sources} == {0, 32768, 65535},
            'All three quantized-alpha fixtures required')
    names = {Path(x['relative_path']).name: x for x in sources}
    require(len(names) == 3, 'Duplicate source names')
    parents = {(manifest_path.parent / source['relative_path']).resolve().parent for source in sources}
    require(len(parents) == 1, 'Alpha source roots differ')
    source_root = str(next(iter(parents)))
    require(plan['actions'][1]['path'] == source_root and
            plan['actions'][3]['folderPath'] == source_root,
            'Requested import/browse root differs from qualified sources')
    timeout = plan['actions'][2]['timeoutMilliseconds']
    require(type(timeout) is int and 1 <= timeout <= 60000, 'Invalid import observer budget')
    require(plan['actions'][4]['tier'] == 'thumbnail', 'Requested preview tier differs')
    execution = json.loads((directory / 'execution.json').read_text())
    require(type(execution['application_pids']) is list and bool(execution['application_pids']) and
            all(type(pid) is int and 0 < pid < 2**31 for pid in execution['application_pids']) and
            len(set(execution['application_pids'])) == len(execution['application_pids']),
            'Application process identities must be positive integer PIDs')
    require(type(execution['launcher_exit']) is int and execution['launcher_exit'] == 0 and
            type(execution['observed_surviving_processes']) is list and
            execution['observed_surviving_processes'] == [] and
            type(execution['cleanup_errors']) is list and execution['cleanup_errors'] == [],
            'Launch/retirement records must have exact normal-result types')
    for action in actions:
        for row in action['rows'] + action.get('previews', []):
            require(all(type(row[key]) is str and bool(row[key])
                        for key in ('image_id', 'asset_id', 'variant_id', 'filename')),
                    'Logical/source identities must be nonempty text')
    progress = actions[2]['import']
    require(progress['phase'] == 'complete' and progress['error_source'] is None and progress['error'] is None,
            'Import did not complete without a source error')
    require(common.canonical_integer(progress['imported']) == 3 and
            common.canonical_integer(progress['unchanged']) == 0 and
            common.canonical_integer(progress['failed']) == 0,
            'Import did not admit exactly three fresh sources')
    require(common.canonical_integer(progress['skipped']) == 0 and
            common.canonical_integer(progress['awaiting_resources']) == 0, 'Import skipped or awaits a source')
    native = progress['source']
    require(type(native) is dict and native['encoding'] == 'UnixBytes' and type(native['units']) is list,
            'Invalid import NativePath shape')
    for unit in native['units']:
        common.bounded_integer(unit, 255, 'Import NativePath byte')
    require(type(progress['id']) is str and bool(progress['id']) and
            progress['source'] == {'encoding': 'UnixBytes', 'units': list(bytes(Path(plan['actions'][1]['path'])))},
            'Import attempt/source authority mismatch')
    previews = actions[4]['previews']
    require(len(previews) == 3 and {x['filename'] for x in previews} == set(names),
            'All three actual previews required exactly once')
    require({x['filename'] for x in actions[3]['rows']} == set(names) and
            len(actions[3]['rows']) == 3, 'Physical browse membership differs from source set')
    keys = ('image_id', 'asset_id', 'variant_id')
    browsed = {row['filename']: tuple(row[key] for key in keys) for row in actions[3]['rows']}
    rendered = {row['filename']: tuple(row[key] for key in keys) for row in previews}
    require(browsed == rendered and len({value[1:] for value in browsed.values()}) == 3,
            'Distinct source VariantKeys must survive browse-to-preview unchanged')
    for preview in previews:
        source = names[preview['filename']]
        require(all(type(preview['status'][key]) is str and bool(preview['status'][key])
                    for key in ('ticket', 'viewport')), 'Preview ticket/viewport must be nonempty text')
        require(preview['tier'] == 'thumbnail', 'Wrong preview tier')
        require(type(source['encoded_alpha_u16']) is int and 0 <= source['encoded_alpha_u16'] <= 65535,
                'Malformed source alpha')
        gray = source['encoded_gray_u16']
        require(gray == [0, 205, 11796, 32768, 65535, 65535] and all(type(x) is int for x in gray),
                'Malformed source gray samples')
        require(len(preview['samples']) == 6, 'Six patch samples required')
        alpha = source['encoded_alpha_u16'] / 65535
        for observed, encoded in zip(preview['samples'], gray):
            linear = (encoded / 65535) * alpha + 1 - alpha
            encoded_srgb = 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
            expected = math.floor(min(1, max(0, encoded_srgb)) * 255 + 0.5)
            rgba = observed['rgba']
            require(len(rgba) == 4 and all(type(x) is int and 0 <= x <= 255 for x in rgba),
                    'Malformed actual pixel sample')
            require(rgba[3] == 255 and all(abs(x - expected) <= 3 for x in rgba[:3]),
                    'Independent quantized linear-alpha white-composite oracle failed')
        require(type(preview['encodedBytes']) is int and 0 < preview['encodedBytes'] < 2**63 and
                type(preview['encodedSHA256']) is str and
                len(preview['encodedSHA256']) == 64 and
                all(x in '0123456789abcdef' for x in preview['encodedSHA256']),
                'Missing actual encoded payload identity')
    # This also checks exact source SHA/paths, typed preview authority, geometry,
    # action identities, resident bounds, normal launch/Quit and observed reap.
    report = common.verify(directory, plan_path, manifest_path, 'alpha')
    report['checks'].append('all three actual quantized-alpha previews match independent linear white-composite sRGB oracle')
    report['artifact_sha256']['alpha_verifier'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['limitations'] = 'Local SDR thumbnail alpha evidence only; no float editor, HDR, export or complete S04 acceptance.'
    (directory / 'oracle-result.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--execution', required=True, type=Path)
    parser.add_argument('--plan', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.execution.resolve(), args.plan.resolve(), args.manifest.resolve())))
