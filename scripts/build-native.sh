#!/bin/bash
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'This acceptance build uses the fixed Debug configuration and output path; no overrides are supported.' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'LensWorks requires Apple silicon.' >&2
  exit 1
fi
python3 scripts/verify-dependencies.py
python3 engines/catalog/scripts/fetch_dng_sdk.py --destination .build/deps
export PHOTOCATALOG_DNG_SDK="$PWD/.build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1"
export CARGO_TARGET_DIR="$PWD/.build/rust-catalog"
export CARGO_BUILD_JOBS=4
export MACOSX_DEPLOYMENT_TARGET=26.2
cargo build --manifest-path adapters/catalog/Cargo.toml --locked --release
cargo build --manifest-path engines/catalog/Cargo.toml --locked --release --bin photocatalog
python3 scripts/audit-native-floor.py
xcodebuild -project native/Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-app \
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile -jobs 4 CODE_SIGN_IDENTITY=- build

# The managed public bridge spawns this complete retained mode dispatcher.
# Worker stdout/stderr remain framed protocol streams, never user-facing logs.
helpers="$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app/Contents/Helpers"
mkdir -p "$helpers"
cp "$CARGO_TARGET_DIR/release/photocatalog" "$helpers/PhotoCatalogWorker"
cp "$CARGO_TARGET_DIR/release/lensworks-decode-worker" "$helpers/LensWorksDecodeWorker"
codesign --force --sign - --timestamp=none "$helpers/PhotoCatalogWorker"
codesign --force --sign - --timestamp=none "$helpers/LensWorksDecodeWorker"
codesign --force --sign - --timestamp=none "$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app"
