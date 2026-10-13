#!/bin/bash
# Rebuilds the sample filter plugins (adapters/plugins/samples/*.lwplugin/filter.wasm) from their WebAssembly text
# sources, and the list of their SHA-256 hashes. Toolchain: the `wat` assembler crate pinned in
# adapters/plugins/Cargo.toml and Cargo.lock, built by the rustc pinned in rust-toolchain.toml. The output is a
# pure function of the source; `cargo test --manifest-path adapters/plugins/Cargo.toml --locked` fails when a
# committed filter.wasm is not what its filter.wat assembles to.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo run --manifest-path adapters/plugins/Cargo.toml --locked --example assemble_samples
