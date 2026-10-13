//! Assembles every sample plugin's `filter.wat` into `filter.wasm` and rewrites `samples/SHA256SUMS`.
//! Run through scripts/build-sample-plugins.sh. The assembler is the `wat` crate pinned in Cargo.toml and
//! Cargo.lock, so the same source always yields the same bytes; `tests/samples.rs` holds the committed files to it.

use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};

fn main() {
    let samples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("samples");
    let mut packages: Vec<_> = fs::read_dir(&samples)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|e| e == "lwplugin"))
        .collect();
    packages.sort();
    let mut sums = String::new();
    for package in packages {
        let wasm =
            wat::parse_file(package.join("filter.wat")).unwrap_or_else(|error| panic!("{error}"));
        fs::write(package.join("filter.wasm"), &wasm).unwrap();
        let name = package.file_name().unwrap().to_string_lossy().into_owned();
        sums += &format!("{:x}  {name}/filter.wasm\n", Sha256::digest(&wasm));
    }
    fs::write(samples.join("SHA256SUMS"), &sums).unwrap();
    print!("{sums}");
}
