#!/bin/bash
# This job is scheduled only on the maintained Apple-silicon native runner. Its image is
# provisioned with the exact DEPENDENCIES.json Homebrew/pkg-config inventory; this script
# rejects drift instead of installing floating Homebrew formulas on a hosted image.
set -euo pipefail
cd "$(dirname "$0")/../.."
test "${RUNNER_ENVIRONMENT:-self-hosted}" = self-hosted
test "$(uname -m)" = arm64
git submodule status --recursive
xcodebuild -version
cargo --version
python3 scripts/verify-dependencies.py
python3 engines/catalog/scripts/fetch_dng_sdk.py --destination .build/deps
