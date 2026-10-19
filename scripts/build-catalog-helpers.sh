#!/bin/bash
# Shared by development, CI and the factory prepare recipe (no inference/Metal build).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-toolchain.sh
export CARGO_TARGET_DIR="$PWD/.build/rust-catalog"
export CARGO_BUILD_JOBS=4
: "${PHOTOCATALOG_DNG_SDK:?Set PHOTOCATALOG_DNG_SDK to the fetched, pinned DNG SDK}"
cargo build --manifest-path adapters/catalog/Cargo.toml --locked --release
cargo build --manifest-path engines/catalog/Cargo.toml --locked --release --bin photocatalog --bin organization_probe
cargo build --manifest-path adapters/mcp/Cargo.toml --locked --release
