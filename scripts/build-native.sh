#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'LensWorks requires Apple silicon.' >&2
  exit 1
fi
python3 scripts/verify-dependencies.py
python3 vendor/PhotoCatalog/scripts/fetch_dng_sdk.py --destination .build/deps
export PHOTOCATALOG_DNG_SDK="$PWD/.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1"
export CARGO_TARGET_DIR="$PWD/.build/rust-catalog"
export CARGO_BUILD_JOBS=4
export MACOSX_DEPLOYMENT_TARGET=26.2
cargo build --manifest-path adapters/catalog/Cargo.toml --locked --release
python3 scripts/audit-native-floor.py
xcodebuild -project native/Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile -jobs 4 CODE_SIGN_IDENTITY=- build "$@"
