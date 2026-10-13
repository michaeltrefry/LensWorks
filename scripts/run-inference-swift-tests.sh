#!/bin/bash
# Run the Swift inference boundary tests against the dylib embedded by build-native.sh.
# usage: run-inference-swift-tests.sh <result-bundle> [derived-data-path]
#
# The real-weight test needs the SceneWorks Sana Sprint q4 snapshot. Its location is resolved
# here, outside the test host: the model cache may live on another volume (for example
# ~/.cache/huggingface -> /Volumes/Models) whose directories macOS privacy consent blocks the
# test host app from listing, which would hang the runner. The probe has a deadline; when the
# weights are not readable from this context the real-weight suite is reported as skipped,
# unless LW_REQUIRE_REAL=1, which makes that a failure. The test host repeats the probe on the
# weight files themselves (it may be denied where this shell is not), with the same rule.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=$1
derived=${2:-.build/xcode-inference}
library="$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app/Contents/Helpers/liblensworks_inference.dylib"
test -f "$library"
sana=${LW_INFERENCE_SANA_SPRINT_DIR:-}
if [[ -z "$sana" ]]; then
  sana=$(./scripts/ci/probe_sana_weights.sh 30)
fi
export TEST_RUNNER_LW_INFERENCE_LIBRARY="$library"
if [[ "${LW_REQUIRE_REAL:-}" == 1 ]]; then
  export TEST_RUNNER_LW_REQUIRE_REAL=1
else
  # The test host probes the weight files itself (open + 4 KB read with a deadline) and skips
  # with a warning when macOS privacy consent denies or blocks it, even if this shell could list them.
  export XCODEBUILD_TEST_ALLOW_SKIPPED=CompositorTests/LensWorksInferenceRealWeightTests
fi
# The semantic search real-query test (SEMANTIC_SEARCH_FIXTURES.json) needs CLIP ViT-L/14. Its two
# files are small enough to stage where the test host can read them (see the staging script), so
# the test runs wherever this shell can read the SceneWorks cache; nothing is downloaded. Once they
# are staged the test must run: only a run without them may report it as skipped.
clip=${LW_INFERENCE_CLIP_HUB:-$(python3 scripts/ci/stage_clip_weights.py 180)}
if [[ -n "$clip" && -d "$clip" ]]; then
  echo "Semantic search real-query test uses $clip"
  export TEST_RUNNER_LW_INFERENCE_CLIP_HUB="$clip"
elif [[ "${LW_REQUIRE_REAL:-}" == 1 ]]; then
  echo "::error::LW_REQUIRE_REAL=1 but the CLIP ViT-L/14 weights are not readable here (missing, or the model volume needs macOS access for this process)."
  exit 1
else
  echo "::warning::CLIP ViT-L/14 weights are not readable here (missing, or the model volume needs macOS access for this process); the semantic search real-query test is skipped."
  export XCODEBUILD_TEST_ALLOW_SKIPPED="${XCODEBUILD_TEST_ALLOW_SKIPPED:-} CompositorTests/LensWorksSemanticSearchRealWeightTests"
fi
if [[ -n "$sana" && -d "$sana" ]]; then
  echo "Real-weight test uses $sana"
  export TEST_RUNNER_LW_INFERENCE_REAL_WEIGHTS=1 TEST_RUNNER_LW_INFERENCE_SANA_SPRINT_DIR="$sana"
elif [[ "${LW_REQUIRE_REAL:-}" == 1 ]]; then
  echo "::error::LW_REQUIRE_REAL=1 but the Sana Sprint q4 weights are not readable here (missing, or the model volume needs macOS access for this process)."
  exit 1
else
  echo "::warning::Sana Sprint q4 weights are not readable here (missing, or the model volume needs macOS access for this process); the real-weight Swift test is skipped."
fi
exec ./scripts/ci/xcodebuild_test.sh "$bundle" -project native/Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -parallel-testing-enabled NO \
  -only-testing:CompositorTests/LensWorksInferenceBufferTests \
  -only-testing:CompositorTests/LensWorksRealWeightGateTests \
  -only-testing:CompositorTests/LensWorksInferenceRuntimeTests \
  -only-testing:CompositorTests/LensWorksInferenceRealWeightTests \
  -only-testing:CompositorTests/LensWorksModelStoreTests \
  -only-testing:CompositorTests/LensWorksSemanticIndexTests \
  -only-testing:CompositorTests/LensWorksSemanticSearchServiceTests \
  -only-testing:CompositorTests/LensWorksSemanticFixtureTests \
  -only-testing:CompositorTests/LensWorksSemanticSearchRealWeightTests
