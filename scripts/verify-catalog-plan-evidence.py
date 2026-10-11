#!/usr/bin/env python3
"""Check actual installed S04 journey evidence against independent fixture oracles."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical_integer(value, signed=False):
    require(type(value) is str and re.fullmatch(r'0|-?[1-9][0-9]*' if signed else r'0|[1-9][0-9]*', value) is not None,
            'Noncanonical integer authority')
    number = int(value)
    require(-(2**63) <= number < 2**63 if signed else 0 <= number < 2**64, 'Integer authority out of range')
    return number


def bounded_integer(value, ceiling, label):
    require(type(value) is int and 0 <= value <= ceiling, label + ' must be a nonnegative bounded integer')


def preview_authority(preview):
    status = preview['status']
    require(status['state'] == 'ready' and status['ticket'] and status['viewport'], 'Preview was not delivered Ready with owned authority')
    require(status['key'] == {'asset_id': preview['asset_id'], 'variant_id': preview['variant_id']}, 'Preview VariantKey mismatch')
    canonical_integer(status['revision'], signed=True)
    canonical_integer(status['generation'])
    require(re.fullmatch(r'[0-9a-f]{64}', status['recipe_digest']) is not None, 'Malformed recipe digest')


def verify(directory, plan_path, manifest_path, scenario, prior_directory=None):
    execution = json.loads((directory / 'execution.json').read_text())
    evidence = json.loads((directory / 'journey.json').read_text())
    plan = json.loads(plan_path.read_text())
    require(execution['status'] == 'EXECUTED_PENDING_ORACLE_ACCEPTANCE', 'Runner did not finish normally')
    require(execution['plan_sha256'] == hashlib.sha256(plan_path.read_bytes()).hexdigest(), 'Plan hash mismatch')
    require(execution['application_pids'] and execution['launcher_exit'] == 0, 'Application launch not observed')
    require(execution['observed_surviving_processes'] == [] and not execution['cleanup_errors'], 'Owner retirement not verified')
    require(not evidence.get('error'), 'Application reported an error')
    require(all(row['state'] == 'unchanged' and row['before'] == row['after'] for row in execution['source_states']), 'Original preservation failed or unknown')
    manifest = json.loads(manifest_path.read_text()) if manifest_path else None
    require(manifest is not None or scenario == 'scale', 'Real-image verification requires the source manifest')
    if manifest:
        expected_sources = {str((manifest_path.parent / row['relative_path']).resolve()): row['sha256']
                            for row in manifest['sources'] + manifest.get('interruption_sources', [])}
        observed = execution['source_states']
        require(len(observed) == len(expected_sources) and len({row['path'] for row in observed}) == len(observed), 'Source audit paths missing or duplicated')
        require({row['path']: row['before'] for row in observed} == expected_sources and
                {row['path']: row['after'] for row in observed} == expected_sources, 'Source audit does not match manifest hashes')
        require(type(execution['unchanged_source_count']) is int and execution['unchanged_source_count'] == len(expected_sources), 'Audited source count mismatch')
    actions = evidence['catalogJourney']
    require(len(actions) == len(plan['actions']), 'Not every requested action executed')
    for index, (action, request) in enumerate(zip(actions, plan['actions'])):
        bounded_integer(action['index'], 63, 'Action index')
        require(action['index'] == index and action['action'] == request['kind'] and action['status'] == 'ok', 'Action identity/status mismatch')
        bounded_integer(action['rowCount'], 100, 'Row count')
        bounded_integer(action['rowsHighWater'], 100, 'Row high water')
        bounded_integer(action['cursorHistoryCount'], 64, 'Cursor history')
        require(len(action['rows']) == action['rowCount'] <= 100 and action['rowsHighWater'] <= 100, 'Image window exceeded 100 rows')
        require(action['cursorHistoryCount'] <= 64, 'Cursor history exceeded 64')
        require(len({row['image_id'] for row in action['rows']}) == len(action['rows']), 'Duplicate logical image identities')
        require(all(row['image_id'] and row['asset_id'] and row['variant_id'] for row in action['rows']), 'Incomplete variant authority')
        metrics = action['previewMetrics']
        for key, value in metrics.items():
            bounded_integer(value, 2**64 - 1, 'Preview metric ' + key)
        require(metrics['activeHighWater'] <= 4 and metrics['pendingHighWater'] <= 200, 'Preview owner bounds exceeded')
        require(metrics['cacheEntriesHighWater'] <= 64 and metrics['cacheBytesHighWater'] <= 32 * 1024 * 1024, 'Decoded cache bounds exceeded')
        for key, ceiling in (('active', 4), ('pending', 200), ('cacheEntries', 64), ('cacheBytes', 32 * 1024 * 1024)):
            bounded_integer(metrics[key], ceiling, 'Current preview ' + key)
            require(metrics[key] <= metrics[key + 'HighWater'], 'Current preview usage exceeds recorded high water')
        for preview in action.get('previews', []):
            preview_authority(preview)
            require(manifest is not None, 'Preview geometry requires independent source fixtures')
            source_matches = [item for item in manifest['sources'] if Path(item['relative_path']).name == preview['filename']]
            require(len(source_matches) == 1, 'Preview is not one exact fixture source')
            source = source_matches[0]
            native = preview['original']
            require(type(native) is dict and native.get('encoding') == 'UnixBytes' and type(native.get('units')) is list,
                    'Preview native source encoding mismatch')
            for unit in native['units']:
                bounded_integer(unit, 255, 'Native path byte')
            require(preview['original'] == {'encoding': 'UnixBytes', 'units': list(bytes((manifest_path.parent / source['relative_path']).resolve()))}, 'Preview original NativePath mismatch')
            row_matches = [row for row in action['rows'] if row['image_id'] == preview['image_id']]
            require(len(row_matches) == 1 and all(row_matches[0][key] == preview[key] for key in ('asset_id', 'variant_id', 'filename')), 'Preview is not the admitted browser row/variant')
            bounded_integer(preview['width'], 2**32 - 1, 'Preview width')
            bounded_integer(preview['height'], 2**32 - 1, 'Preview height')
            require(preview['width'] == source['expected_width'] and preview['height'] == source['expected_height'], 'Oriented preview geometry mismatch')
            require(preview['colorSpace'] == 'srgb' and preview['alpha'] == 'opaque', 'Preview color/alpha contract mismatch')
            require(len(preview['samples']) == 6, 'Six actual preview patch samples required')
            for sample, center in zip(preview['samples'], source['expected_sample_centers']):
                bounded_integer(sample['x'], preview['width'] - 1, 'Sample x')
                bounded_integer(sample['y'], preview['height'] - 1, 'Sample y')
                require([sample['x'], sample['y']] == center, 'Preview sample geometry mismatch')
                require(len(sample['rgba']) == 4 and all(type(value) is int and 0 <= value <= 255 for value in sample['rgba']) and
                        sample['rgba'][3] == 255, 'Preview samples must be exact opaque RGB8 values')
    checks = ['ordered actual actions', 'normal Quit and observed owner retirement', 'source preservation', 'bounded row/history/preview residency']
    if scenario == 'nested':
        require(manifest_path is not None, 'Nested verification needs the independent fixture manifest')
        require(execution['unchanged_source_count'] == len(manifest['sources']) + len(manifest['interruption_sources']), 'Not every fixture source was audited')
        for action, request in zip(actions, plan['actions']):
            if request['kind'] == 'browse' and request.get('folderPath'):
                folder = Path(request['folderPath'])
                expected = {Path(row['relative_path']).name for row in manifest['sources']
                            if ((manifest_path.parent / row['relative_path']).parent == folder or
                                request.get('recursive') and (manifest_path.parent / row['relative_path']).is_relative_to(folder))}
                require({row['filename'] for row in action['rows']} == expected, 'Physical direct/recursive membership mismatch')
        initial = next(action for action in actions if action['action'] == 'preview')
        rendered = {row['filename']: row for row in initial['previews']}
        require(len(rendered) == len(initial['previews']), 'Duplicate preview source names')
        require(set(rendered) == {Path(row['relative_path']).name for row in manifest['sources']}, 'All orientation/color sources were not delivered')
        canonical_rows = {row['filename']: tuple(row[key] for key in ('image_id', 'asset_id', 'variant_id')) for row in initial['rows']}
        for action, request in zip(actions, plan['actions']):
            if request['kind'] == 'browse' and request.get('folderPath'):
                require(all(tuple(row[key] for key in ('image_id', 'asset_id', 'variant_id')) == canonical_rows[row['filename']]
                            for row in action['rows']), 'Physical scope changed logical photo/variant identities')
        for source in manifest['sources']:
            row = rendered[Path(source['relative_path']).name]
            expected_path = (manifest_path.parent / source['relative_path']).resolve()
            require(row['original'] == {'encoding': 'UnixBytes', 'units': list(bytes(expected_path))}, 'Preview original NativePath mismatch')
            matching = [item for item in initial['rows'] if item['filename'] == row['filename']]
            require(len(matching) == 1 and all(matching[0][key] == row[key] for key in ('image_id', 'asset_id', 'variant_id')), 'Preview and browser logical identities differ')
            require((row['width'], row['height']) == (source['expected_width'], source['expected_height']), 'Oriented preview dimensions mismatch')
            require(row['colorSpace'] == 'srgb' and row['alpha'] == 'opaque', 'Preview color/alpha contract mismatch')
            require(len(row['samples']) == 6, 'Six independent patch centers were not sampled')
            for sample, center, expected in zip(row['samples'], source['expected_sample_centers'], source['expected_srgb_rgb8']):
                require([sample['x'], sample['y']] == center, 'Patch sample coordinates mismatch')
                require(len(sample['rgba']) == 4 and sample['rgba'][3] == 255, 'Opaque JPEG alpha mismatch')
                # Solid 32px interiors isolate 8-bit JPEG quantization from subsampled patch edges.
                require(all(abs(actual - target) <= 3 for actual, target in zip(sample['rgba'][:3], expected)), 'Independent sRGB/orientation patch oracle failed (3 code values)')
        edit_index = next(index for index, action in enumerate(actions) if action['action'] == 'editPreview')
        before, after = actions[edit_index]['beforeVariant'], actions[edit_index]['afterVariant']
        require(before['key'] == after['key'] and canonical_integer(after['revision'], True) > canonical_integer(before['revision'], True), 'Edit changed identity or did not advance revision')
        requested_exposure = plan['actions'][edit_index]['exposureEV']
        old_recipe, new_recipe = before['recipe'], after['recipe']
        require(old_recipe['version'] == new_recipe['version'] == '1', 'Edit recipe version authority mismatch')
        old_settings, new_settings = old_recipe['settings'].copy(), new_recipe['settings'].copy()
        observed_exposure = new_settings.pop('exposure_ev')
        require(type(observed_exposure) in (int, float) and type(requested_exposure) in (int, float) and
                observed_exposure == requested_exposure and math.isfinite(requested_exposure), 'Exposure request was not applied')
        old_settings.pop('exposure_ev')
        require(old_settings == new_settings, 'Exposure edit changed unrelated controls')
        require(before['recipe_digest'] != after['recipe_digest'], 'Edit recipe authority did not change')
        old = next(action for action in reversed(actions[:edit_index]) if action['action'] == 'preview')['previews'][0]
        new = next(action for action in actions[edit_index + 1:] if action['action'] == 'preview')['previews'][0]
        require(old['image_id'] == new['image_id'] and old['asset_id'] == new['asset_id'], 'Preview edit changed photo identity')
        require(old['status']['recipe_digest'] != new['status']['recipe_digest'] and old['samples'] != new['samples'], 'Edited pixels/authority were not invalidated')
        require(old['status']['key'] == before['key'] == after['key'] == new['status']['key'] and
                old['status']['revision'] == before['revision'] and new['status']['revision'] == after['revision'] and
                old['status']['recipe_digest'] == before['recipe_digest'] and new['status']['recipe_digest'] == after['recipe_digest'], 'Preview authority does not match edited variant')
        source = next(item for item in manifest['sources'] if Path(item['relative_path']).name == new['filename'])
        def exposure(value):
            encoded = value / 255
            linear = encoded / 12.92 if encoded <= 0.04045 else ((encoded + 0.055) / 1.055) ** 2.4
            linear = min(1, linear * 2 ** requested_exposure)
            return round(255 * (12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055))
        for sample, expected in zip(new['samples'], source['expected_srgb_rgb8']):
            require(all(abs(actual - exposure(target)) <= 3 for actual, target in zip(sample['rgba'][:3], expected)), 'Independent edited exposure pixel oracle failed')
        checks += ['exact direct/recursive identities', 'all eight orientations and nonidentity linear ICC pixels', 'actual edit-aware preview invalidation']
    elif scenario == 'interruption':
        require(manifest_path is not None, 'Interruption verification needs the source count')
        wait = next(action for action in actions if action['action'] == 'waitImport')['import']
        canceled = next(action for action in actions if action['action'] == 'cancelImport')['import']
        resumed = next(action for action in actions if action['action'] == 'resumeImport')['import']
        finished = next(action for action in actions if action['action'] == 'finishImport')['import']
        require(wait['phase'] in ('discovering', 'draining') and canonical_integer(wait['imported']) >= 1, 'Import did not genuinely interrupt active progress')
        require(canceled['id'] == wait['id'] and canceled['phase'] == 'canceled', 'Matching import was not retired as canceled')
        require(resumed['id'] != canceled['id'] and finished['id'] == resumed['id'], 'Resume reused an old attempt identity')
        require(resumed['phase'] in ('discovering', 'draining', 'complete'), 'Resumed attempt has an impossible terminal phase')
        require(finished['phase'] == 'complete' and canonical_integer(finished['failed']) == 0, 'Re-walk did not complete successfully')
        require(canonical_integer(finished['imported']) + canonical_integer(finished['unchanged']) == len(manifest['interruption_sources']), 'Resume lost or duplicated source registrations')
        source_request = next(request for request in plan['actions'] if request['kind'] == 'startImport')
        expected_source = {'encoding': 'UnixBytes', 'units': list(bytes(Path(source_request['path']).resolve()))}
        resume_request = next(request for request in plan['actions'] if request['kind'] == 'resumeImport')
        require({'encoding': 'UnixBytes', 'units': list(bytes(Path(resume_request['path']).resolve()))} == expected_source,
                'Resume requests a different source')
        observations = [action for action in actions if action['action'] == 'observeImport']
        target_count = len(manifest['interruption_sources'])
        for status in [wait, canceled, resumed] + [observed['import'] for observed in observations] + [finished]:
            require(type(status.get('id')) is str and status['id'], 'Import attempt identity must be nonempty text')
            native = status.get('source')
            require(type(native) is dict and native.get('encoding') == 'UnixBytes' and type(native.get('units')) is list,
                    'Import source NativePath has invalid shape')
            for unit in native['units']:
                bounded_integer(unit, 255, 'Import native path byte')
            require(status['source'] == expected_source, 'Import source differs from admitted physical source')
            require(status.get('error') is None and canonical_integer(status['failed']) == 0, 'Import has a reported error')
            count = canonical_integer(status['imported']) + canonical_integer(status['unchanged'])
            require(count <= target_count, 'Import completion count exceeds source set')
            if status['phase'] == 'complete':
                require(count == target_count, 'Complete import has a partial source set')
        require(len(observations) == 9, 'Nine bounded full-workload observations required')
        prior_count = canonical_integer(resumed['imported']) + canonical_integer(resumed['unchanged'])
        for observed in observations:
            status = observed['import']
            timed_out = observed.get('importObservationTimedOut')
            require(type(timed_out) is bool, 'Typed import observation outcome missing')
            require(status['id'] == resumed['id'] and status['source'] == resumed['source'], 'Observation changed owned attempt or source')
            require(canonical_integer(status['failed']) == 0, 'Observed import failed')
            count = canonical_integer(status['imported']) + canonical_integer(status['unchanged'])
            require(count >= prior_count, 'Import completion counters regressed')
            if timed_out:
                require(status['phase'] in ('discovering', 'draining') and count > prior_count, 'Timed observation made no actual completion progress')
            else:
                require(status['phase'] == 'complete', 'Non-timeout observation is not terminal Complete')
            prior_count = count
        prior_imported, prior_unchanged = canonical_integer(resumed['imported']), canonical_integer(resumed['unchanged'])
        completed = resumed['phase'] == 'complete'
        for status in [observed['import'] for observed in observations] + [finished]:
            imported, unchanged = canonical_integer(status['imported']), canonical_integer(status['unchanged'])
            require(imported >= prior_imported and unchanged >= prior_unchanged, 'Individual import counters regressed')
            require(not completed or status['phase'] == 'complete', 'Completed attempt returned to active progress')
            completed = completed or status['phase'] == 'complete'
            prior_imported, prior_unchanged = imported, unchanged
        requests = [request for request in plan['actions'] if request['kind'] in ('observeImport', 'finishImport')]
        require(len(requests) == 10 and all(type(request.get('timeoutMilliseconds')) is int and
                0 < request['timeoutMilliseconds'] <= 60000 for request in requests) and
                sum(request['timeoutMilliseconds'] for request in requests) <= 600000, 'Workload observer budget invalid')
        start = next(i for i, action in enumerate(actions) if action['action'] == 'browse')
        pages = [actions[start]]
        for action in actions[start + 1:]:
            if action['action'] != 'nextPage': break
            pages.append(action)
        rows = [row for page in pages for row in page['rows']]
        require(all(type(row.get(key)) is str and row[key] for row in rows
                    for key in ('image_id', 'asset_id', 'variant_id', 'filename')), 'Paged source identities must be nonempty text')
        expected_names = {Path(row['relative_path']).name for row in manifest['interruption_sources']}
        require(len(expected_names) == len(manifest['interruption_sources']), 'Interruption fixture names are not unique')
        require(len(rows) == len(expected_names) and {row['filename'] for row in rows} == expected_names,
                'Paged resumed source set missing or duplicated')
        require(len({row['image_id'] for row in rows}) == len(rows) and
                len({(row['asset_id'], row['variant_id']) for row in rows}) == len(rows), 'Resumed source identities duplicate')
        checks += ['active cancellation and matching terminal identity', 'bounded progressing observations',
                   'new re-walk attempt and exact paged source identities']
    elif scenario == 'scale':
        forward = next(action['pagingSteps'] for action, request in zip(actions, plan['actions']) if request.get('direction') == 'next')
        backward = next(action['pagingSteps'] for action, request in zip(actions, plan['actions']) if request.get('direction') == 'previous')
        require(len(forward) >= 128 and len(backward) >= 32, 'Paging did not cross the cursor residency cap')
        require(len({step['pageDigest'] for step in forward}) == len(forward), 'Forward paging repeated result pages')
        for step in forward + backward:
            bounded_integer(step['rowCount'], 100, 'Scale row count')
            bounded_integer(step['cursorHistoryCount'], 64, 'Scale cursor history')
            require(type(step['pageDigest']) is str and re.fullmatch(r'[0-9a-f]{64}', step['pageDigest']) is not None, 'Malformed scale page identity digest')
            require(step['rowCount'] == 100 and step['cursorHistoryCount'] <= 64, 'Scale page/continuation bounds mismatch')
            require(step['firstImageID'] and step['lastImageID'], 'Scale page identities are missing')
        expected = [step['pageDigest'] for step in forward[:-1]][::-1][:len(backward)]
        require([step['pageDigest'] for step in backward] == expected, 'Backward paging changed retained logical result pages')
        checks += ['128 forward pages over bounded history', 'exact backward page identity digests']
    elif scenario == 'reopened':
        require(prior_directory is not None, 'Restart verification requires the accepted prior execution')
        prior_report = json.loads((prior_directory / 'oracle-result.json').read_text())
        require(prior_report['status'] == 'PASS_NESTED_LOCAL_ORACLE', 'Prior nested journey was not accepted')
        prior_hashes = prior_report['artifact_sha256']
        require(prior_hashes['execution'] == hashlib.sha256((prior_directory / 'execution.json').read_bytes()).hexdigest() and
                prior_hashes['journey'] == hashlib.sha256((prior_directory / 'journey.json').read_bytes()).hexdigest(), 'Accepted prior execution/journey changed')
        require(prior_hashes['manifest'] == hashlib.sha256(manifest_path.read_bytes()).hexdigest() and
                prior_hashes['verifier'] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest() and
                prior_hashes['plan'] == hashlib.sha256(Path(prior_report['plan']).read_bytes()).hexdigest(), 'Accepted prior manifest/plan/verifier changed')
        prior_execution = json.loads((prior_directory / 'execution.json').read_text())
        require(set(execution['application_pids']).isdisjoint(prior_execution['application_pids']), 'Restart did not observe distinct app processes')
        prior_actions = json.loads((prior_directory / 'journey.json').read_text())['catalogJourney']
        prior_group = next(action for action in reversed(prior_actions) if action['action'] == 'browse' and action['rowCount'] == 1)
        current_group = next(action for action, request in zip(actions, plan['actions']) if request.get('groupName'))
        keys = ('image_id', 'asset_id', 'variant_id', 'filename')
        require(prior_group['catalogPath'] == current_group['catalogPath'], 'Catalog authority changed on reopen')
        require([[row[key] for key in keys] for row in prior_group['rows']] ==
                [[row[key] for key in keys] for row in current_group['rows']], 'Persisted group/photo/variant identity changed')
        old = next(action for action in reversed(prior_actions) if action['action'] == 'preview')['previews']
        new = next(action for action in actions if action['action'] == 'preview')['previews']
        require(len(old) == len(new) == 1, 'Restart preview fixture changed cardinality')
        require(old[0]['status']['recipe_digest'] == new[0]['status']['recipe_digest'] and
                old[0]['samples'] == new[0]['samples'], 'Recipe/pixels changed on restart')
        require(old[0]['status']['key'] == new[0]['status']['key'] and old[0]['status']['revision'] == new[0]['status']['revision'], 'Reopened preview revision/variant authority changed')
        checks += ['distinct app process restart', 'durable group/photo/variant identities and edited preview recipe/pixels']
    report = {'status': 'PASS_' + scenario.upper() + '_LOCAL_ORACLE', 'checks': checks,
              'execution': str(directory), 'plan': str(plan_path), 'plan_sha256': execution['plan_sha256'],
              'artifact_sha256': {'execution': hashlib.sha256((directory / 'execution.json').read_bytes()).hexdigest(),
                                  'journey': hashlib.sha256((directory / 'journey.json').read_bytes()).hexdigest(),
                                  'plan': hashlib.sha256(plan_path.read_bytes()).hexdigest(),
                                  'manifest': hashlib.sha256(manifest_path.read_bytes()).hexdigest() if manifest_path else None,
                                  'verifier': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
              'limitations': 'This scenario is local evidence only; full S04 matrix, UI inspection, retained regressions and scale cardinality provenance remain required.'}
    (directory / 'oracle-result.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execution', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--scenario', choices=('nested', 'interruption', 'scale', 'reopened'), required=True)
    parser.add_argument('--prior-execution', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.execution.resolve(), args.plan.resolve(), args.manifest.resolve() if args.manifest else None,
                            args.scenario, args.prior_execution.resolve() if args.prior_execution else None)))
