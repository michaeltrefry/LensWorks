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
# The inference adapter is a runtime-loaded dylib (the app never links MLX). Its own target
# directory may live outside the workspace (LW_INFERENCE_TARGET_DIR) so CI reuses the build.
inference_target="${LW_INFERENCE_TARGET_DIR:-$PWD/.build/rust-inference}"
CARGO_TARGET_DIR="$inference_target" cargo build --manifest-path adapters/inference/Cargo.toml --locked --release
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
# The inference runtime sits beside the helpers. The adapter pins the mlx.metallib next to
# itself (strictly, before any Metal work), so the build machine's path is never used.
cp "$inference_target/release/liblensworks_inference.dylib" "$helpers/liblensworks_inference.dylib"
# Exactly the metallib this library was compiled against (its embedded MLX build path).
metallib=$(strings -a "$inference_target/release/liblensworks_inference.dylib" | awk '/^\/.*\/mlx\.metallib$/ && !found { print; found = 1 }')
test -f "$metallib"
cp "$metallib" "$helpers/mlx.metallib"
install_name_tool -id @rpath/liblensworks_inference.dylib "$helpers/liblensworks_inference.dylib"
codesign --force --sign - --timestamp=none "$helpers/liblensworks_inference.dylib"
# A data file in a nested-code directory carries its own signature for the app seal.
codesign --force --sign - --timestamp=none "$helpers/mlx.metallib"
codesign --force --sign - --timestamp=none "$helpers/PhotoCatalogWorker"
codesign --force --sign - --timestamp=none "$helpers/LensWorksDecodeWorker"
codesign --force --sign - --timestamp=none "$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app"
