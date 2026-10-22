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
source scripts/native-toolchain.sh
export CARGO_TARGET_DIR="$PWD/.build/rust-catalog"
export CARGO_BUILD_JOBS=4
./scripts/build-catalog-helpers.sh
# The inference adapter is a runtime-loaded dylib (the app never links MLX). Its own target
# directory may live outside the workspace (LW_INFERENCE_TARGET_DIR) so CI reuses the build.
inference_target="${LW_INFERENCE_TARGET_DIR:-$PWD/.build/rust-inference}"
CARGO_TARGET_DIR="$inference_target" cargo build --manifest-path adapters/inference/Cargo.toml --locked --release
python3 scripts/audit-native-floor.py
xcodebuild -project native/Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-app \
  -configuration Debug -onlyUsePackageVersionsFromResolvedFile -jobs 4 CODE_SIGN_IDENTITY=- build

# Xcode embeds/signs the catalog helpers in every app, including build-for-testing.
helpers="$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app/Contents/Helpers"
# The inference runtime sits beside the helpers; its mlx.metallib is a resource, sealed by the
# app's own signature. The adapter pins Contents/Resources/mlx.metallib strictly before any
# Metal work, so the build machine's compiled-in metallib path is never used.
app="$PWD/.build/xcode-app/Build/Products/Debug/LensWorks.app"
cp "$inference_target/release/liblensworks_inference.dylib" "$helpers/liblensworks_inference.dylib"
# Exactly the metallib this library was compiled against (its embedded MLX build path).
metallib=$(strings -a "$inference_target/release/liblensworks_inference.dylib" | awk '/^\/.*\/mlx\.metallib$/ && !found { print; found = 1 }')
test -f "$metallib"
rm -f "$helpers/mlx.metallib"
cp "$metallib" "$app/Contents/Resources/mlx.metallib"
install_name_tool -id @rpath/liblensworks_inference.dylib "$helpers/liblensworks_inference.dylib"
codesign --force --sign - --timestamp=none "$helpers/liblensworks_inference.dylib"
# Re-seal the app over the added helpers and resource, keeping the entitlements and code
# signing flags (including the hardened runtime, when enabled) that Xcode signed it with.
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements,flags,runtime "$app"
codesign --verify --strict --deep "$app"
