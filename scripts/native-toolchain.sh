#!/bin/bash
# Source before Rust/CMake builds. Never mix a selected Xcode linker with the CLT SDK.
# Executing with --github also exports the selection to later Actions steps.
set -euo pipefail
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx --find clang)"
CXX="$(xcrun --sdk macosx --find clang++)"
export SDKROOT CC CXX
export MACOSX_DEPLOYMENT_TARGET=26.2
[[ -d "$SDKROOT" && -x "$CC" && -x "$CXX" ]] || { echo 'Selected Xcode SDK/compiler is unavailable' >&2; exit 1; }
# Include versions, not just paths: an Xcode upgrade can replace the same directory.
xcode_version=$(xcodebuild -version)
compiler_version=$("$CC" --version)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
cmake_version=$(cmake --version)
rust_version=$(rustc -Vv)
LW_NATIVE_TOOLCHAIN_ID="$(printf '%s\n' "$DEVELOPER_DIR" "$SDKROOT" "$CC" "$CXX" "$xcode_version" "$compiler_version" "$sdk_version" "$cmake_version" "$rust_version" | shasum -a 256 | awk '{print $1}')"
export LW_NATIVE_TOOLCHAIN_ID
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/.build/toolchains"
export CMAKE_TOOLCHAIN_FILE="$root/.build/toolchains/$LW_NATIVE_TOOLCHAIN_ID.cmake"
cat > "$CMAKE_TOOLCHAIN_FILE" <<EOF
set(CMAKE_C_COMPILER [[$CC]] CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER [[$CXX]] CACHE FILEPATH "" FORCE)
set(CMAKE_OSX_SYSROOT [[$SDKROOT]] CACHE PATH "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.2 CACHE STRING "" FORCE)
# cmake-rs joins cc-rs argv into flag strings without quoting SDK paths. Repair
# only that generated sysroot argument; preserve every other caller/native flag.
foreach(lang C CXX)
  string(REPLACE [[-isysroot $SDKROOT]] [[-isysroot "$SDKROOT"]] fixed "\${CMAKE_\${lang}_FLAGS}")
  set(CMAKE_\${lang}_FLAGS "\${fixed}" CACHE STRING "" FORCE)
endforeach()
EOF
# cc-rs reads SDKROOT directly; CMake gets the explicit toolchain file. Do not
# inject sysroot text into CFLAGS: whitespace splitting breaks SDK paths with spaces
# and repeated sourcing would change Cargo's native build-script fingerprints.
# Cargo fingerprints include rustflags. Force a fresh build-script OUT_DIR (and hence
# CMake cache) when the selected toolchain changes, even in a persistent target dir.
# Retain callers' flags, including Cargo's higher-precedence encoded form.
if [[ -z "${LW_NATIVE_FLAGS_SET:-}" || "$LW_NATIVE_FLAGS_SET" != "$LW_NATIVE_TOOLCHAIN_ID" ]]; then
  if [[ "${CARGO_ENCODED_RUSTFLAGS+x}" == x ]]; then
    export CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:+${CARGO_ENCODED_RUSTFLAGS}$'\037'}--cfg=lensworks_toolchain=\"$LW_NATIVE_TOOLCHAIN_ID\""
  else
    export RUSTFLAGS="${RUSTFLAGS:-} --cfg=lensworks_toolchain=\"$LW_NATIVE_TOOLCHAIN_ID\""
  fi
fi
export LW_NATIVE_FLAGS_SET="$LW_NATIVE_TOOLCHAIN_ID"
printf 'Native toolchain %s: SDK %s; C %s; C++ %s\n' "$LW_NATIVE_TOOLCHAIN_ID" "$SDKROOT" "$CC" "$CXX"
if [[ "${1:-}" == --github ]]; then
  for key in DEVELOPER_DIR SDKROOT CC CXX MACOSX_DEPLOYMENT_TARGET CMAKE_TOOLCHAIN_FILE CFLAGS CXXFLAGS RUSTFLAGS CARGO_ENCODED_RUSTFLAGS LW_NATIVE_TOOLCHAIN_ID LW_NATIVE_FLAGS_SET; do
    if [[ -n "${!key-}" ]]; then printf '%s=%s\n' "$key" "${!key}" >> "$GITHUB_ENV"; fi
  done
  echo "identity=$LW_NATIVE_TOOLCHAIN_ID" >> "$GITHUB_OUTPUT"
fi
