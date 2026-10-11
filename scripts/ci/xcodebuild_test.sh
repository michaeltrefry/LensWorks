#!/bin/bash
# Run `xcodebuild test-without-building` and fail loudly when the run proves
# less than it claims: every `-only-testing:` filter must match tests that all
# passed in the result bundle (a skipped or missing test fails the run), and a
# refused macOS UI automation mode is reported as a host problem.
# usage: xcodebuild_test.sh <result-bundle> <xcodebuild args...>
# A filter listed (space-separated) in XCODEBUILD_TEST_ALLOW_SKIPPED may skip.
set -uo pipefail
bundle=$1
shift
log=$(mktemp)
xcodebuild test-without-building "$@" -resultBundlePath "$bundle" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if grep -q "Timed out while enabling automation mode" "$log"; then
  echo "::error::macOS did not grant UI automation mode on this runner, so UI tests did not run. An administrator must authorize automation for the runner's user (System Settings > Privacy & Security, or 'automationmodetool enable-automationmode-without-authentication'). This is a host setting, not a test failure."
fi
filters=()
for argument in "$@"; do
  if [[ "$argument" == -only-testing:* ]]; then filters+=("${argument#-only-testing:}"); fi
done
# XCTest's "Executed N tests" ignores Swift Testing, so verify from the bundle.
results=$(mktemp)
if ! xcrun xcresulttool get test-results tests --path "$bundle" > "$results" 2>/dev/null; then
  echo "::error::No readable test results in $bundle; the runner never started."
  exit 1
fi
python3 - "$results" "${XCODEBUILD_TEST_ALLOW_SKIPPED:-}" "${filters[@]+"${filters[@]}"}" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
allowed = set(sys.argv[2].split())
filters = sys.argv[3:]
cases = []  # (bundle, suite, identifier "Suite/test", result)
def walk(node, bundle=None, suite=None):
    kind = node.get('nodeType')
    if kind in ('Unit test bundle', 'UI test bundle'):
        bundle = node.get('name')
    elif kind == 'Test Suite':
        suite = node.get('name')
    elif kind == 'Test Case':
        cases.append((bundle, suite, node.get('nodeIdentifier') or '', node.get('result')))
        return
    for child in node.get('children', []):
        walk(child, bundle, suite)
for node in tree.get('testNodes', []):
    walk(node)
def matches(case, parts):
    bundle, suite, identifier, _ = case
    if parts[0] != bundle:
        return False
    if len(parts) == 1:
        return True
    if len(parts) == 2:
        return parts[1] in (suite, identifier.split('/')[0])
    # XCTest reports `Suite/testName()`; filters may omit the parentheses.
    return identifier in (parts[1] + '/' + parts[2], parts[1] + '/' + parts[2] + '()')
errors = [] if cases else ['no tests executed']
for name in filters:
    selected = [case for case in cases if matches(case, name.split('/'))]
    if not selected:
        errors.append(name + ': matched no executed test')
    for bundle, _, identifier, result in selected:
        if result != 'Passed' and not (result == 'Skipped' and name in allowed):
            errors.append(f'{name}: {bundle}/{identifier} {result}')
passed = sum(1 for case in cases if case[3] == 'Passed')
print(f'Tests in result bundle: {len(cases)} ({passed} passed); -only-testing filters verified: {len(filters)}')
for error in errors:
    print('::error::' + error)
sys.exit(1 if errors else 0)
PY
verified=$?
if [[ "$verified" -ne 0 ]]; then
  echo "::error::$bundle does not prove that every requested test ran and passed."
  exit 1
fi
exit "$status"
