#!/bin/bash
# Run `xcodebuild test-without-building` and fail loudly when the run proves
# nothing: no tests executed, or macOS refused UI automation.
# usage: xcodebuild_test.sh <result-bundle> <xcodebuild args...>
set -uo pipefail
bundle=$1
shift
log=$(mktemp)
xcodebuild test-without-building "$@" -resultBundlePath "$bundle" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if grep -q "Timed out while enabling automation mode" "$log"; then
  echo "::error::macOS did not grant UI automation mode on this runner, so UI tests did not run. An administrator must authorize automation for the runner's user (System Settings > Privacy & Security, or 'automationmodetool enable-automationmode-without-authentication'). This is a host setting, not a test failure."
fi
# XCTest's "Executed 0 tests" ignores Swift Testing, so count from the bundle.
executed=$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null |
  python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["passedTests"]+s["failedTests"]+s["skippedTests"]+s["expectedFailures"])' 2>/dev/null || echo 0)
echo "Tests executed in $bundle: $executed"
if [[ "$executed" -eq 0 ]]; then
  echo "::error::No tests executed for $bundle; the -only-testing filters matched nothing or the runner never started."
  exit 1
fi
exit "$status"
