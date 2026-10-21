#!/bin/bash
# Source before Rust/CMake builds. Never mix a selected Xcode linker with the CLT SDK.
# Executing with --github also exports the selection to later Actions steps.
# When sourced, these shell options also apply to the caller.
set -euo pipefail
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx --find clang)"
CXX="$(xcrun --sdk macosx --find clang++)"
export SDKROOT CC CXX
export MACOSX_DEPLOYMENT_TARGET=26.2
[[ -d "$SDKROOT" && -x "$CC" && -x "$CXX" ]] || { echo 'Selected Xcode SDK/compiler is unavailable' >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rust: the repository's pin (rust-toolchain.toml), never whichever rustc PATH finds first. rustup's
# proxies honour the pin by themselves. Without them first on PATH (the Dark Factory runs a prepare
# recipe as its sandbox user with a fixed PATH that resolves Homebrew's rustc, and a recipe cannot
# set PATH) the pinned rustup toolchain is selected by its absolute path. Either way the rustc and
# cargo that build must report exactly the pinned release, or nothing is built.
rust_channel=$(sed -n 's/^channel[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$root/rust-toolchain.toml")
[[ "$rust_channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'rust-toolchain.toml must pin an exact Rust release (channel = "X.Y.Z")' >&2; exit 1; }
rust_pinned_bin="${RUSTUP_HOME:-${HOME:-/nonexistent}/.rustup}/toolchains/$rust_channel-aarch64-apple-darwin/bin"
rust_selected=
if [[ -x "$rust_pinned_bin/rustc" && -x "$rust_pinned_bin/cargo" ]]; then
  export PATH="$rust_pinned_bin:$PATH"
  rust_selected=1
fi
rust_version=$(rustc -Vv 2>/dev/null) || rust_version=
cargo_version=$(cargo -V 2>/dev/null) || cargo_version=
if [[ "$rust_version" != "rustc $rust_channel "* || "$cargo_version" != "cargo $rust_channel "* ]]; then
  printf 'Rust %s is pinned (rust-toolchain.toml), but rustc is %s (%s) and cargo is %s (%s).\n' \
    "$rust_channel" "$(command -v rustc || echo missing)" "$(printf %s "$rust_version" | head -n 1)" "$(command -v cargo || echo missing)" "$cargo_version" >&2
  printf 'Install the pinned toolchain for this user (rustup toolchain install %s --profile minimal, into %s); refusing to build with another Rust.\n' \
    "$rust_channel" "${rust_pinned_bin%/bin}" >&2
  exit 1
fi
# Include versions, not just paths: an Xcode upgrade can replace the same directory.
xcode_version=$(xcodebuild -version)
compiler_version=$("$CC" --version)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
cmake_version=$(cmake --version)
LW_NATIVE_TOOLCHAIN_ID="$(printf '%s\n' "$DEVELOPER_DIR" "$SDKROOT" "$CC" "$CXX" "$MACOSX_DEPLOYMENT_TARGET" "$xcode_version" "$compiler_version" "$sdk_version" "$cmake_version" "$rust_version" | shasum -a 256 | awk '{print $1}')"
export LW_NATIVE_TOOLCHAIN_ID
mkdir -p "$root/.build/toolchains"
export CMAKE_TOOLCHAIN_FILE="$root/.build/toolchains/$LW_NATIVE_TOOLCHAIN_ID.cmake"
cat > "$CMAKE_TOOLCHAIN_FILE" <<EOF
set(CMAKE_C_COMPILER [[$CC]] CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER [[$CXX]] CACHE FILEPATH "" FORCE)
set(CMAKE_OSX_SYSROOT [[$SDKROOT]] CACHE PATH "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET $MACOSX_DEPLOYMENT_TARGET CACHE STRING "" FORCE)
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
  if [[ -n "$rust_selected" ]]; then echo "$rust_pinned_bin" >> "$GITHUB_PATH"; fi
  echo "identity=$LW_NATIVE_TOOLCHAIN_ID" >> "$GITHUB_OUTPUT"
fi
