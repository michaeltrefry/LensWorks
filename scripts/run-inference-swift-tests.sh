#!/bin/bash
# Run the Swift inference boundary tests against the dylib embedded by build-native.sh.
# usage: run-inference-swift-tests.sh <result-bundle> [derived-data-path]
#
# The real-weight test needs the SceneWorks Sana Sprint q4 snapshot. Its location is resolved
# here, outside the test host: the model cache may live on another volume (for example
# ~/.cache/huggingface -> /Volumes/Models) whose directories macOS privacy consent blocks the
# test host app from listing, which would hang the runner. The probe has a deadline; when the
# weights are not readable from this context the real-weight suite is reported as skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=$1
derived=${2:-.build/xcode-inference}
library="$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app/Contents/Helpers/liblensworks_inference.dylib"
test -f "$library"
sana=${LW_INFERENCE_SANA_SPRINT_DIR:-}
if [[ -z "$sana" ]]; then
  hub="$HOME/.cache/huggingface/hub"
  sana=$(perl -e 'alarm shift; exec @ARGV' 30 /bin/bash -c \
    'ls -d "$1"/models--SceneWorks--Sana_Sprint_1.6B_1024px_mlx/snapshots/*/q4 2>/dev/null | head -1' _ "$hub") || sana=""
fi
export TEST_RUNNER_LW_INFERENCE_LIBRARY="$library"
if [[ -n "$sana" && -d "$sana" ]]; then
  echo "Real-weight test uses $sana"
  export TEST_RUNNER_LW_INFERENCE_REAL_WEIGHTS=1 TEST_RUNNER_LW_INFERENCE_SANA_SPRINT_DIR="$sana"
else
  echo "::warning::Sana Sprint q4 weights are not readable here (missing, or the model volume needs macOS access for this process); the real-weight Swift test is skipped."
  export XCODEBUILD_TEST_ALLOW_SKIPPED=CompositorTests/LensWorksInferenceRealWeightTests
fi
exec ./scripts/ci/xcodebuild_test.sh "$bundle" -project native/Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -parallel-testing-enabled NO \
  -only-testing:CompositorTests/LensWorksInferenceBufferTests \
  -only-testing:CompositorTests/LensWorksInferenceRuntimeTests \
  -only-testing:CompositorTests/LensWorksInferenceRealWeightTests
