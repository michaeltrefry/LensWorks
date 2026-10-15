//! The committed sample plugins are exactly what their sources assemble to with the pinned assembler.

use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};

fn samples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("samples")
}

#[test]
fn every_committed_sample_is_what_its_source_assembles_to() {
    let mut names: Vec<String> = fs::read_dir(samples())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".lwplugin"))
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            "brightness",
            "forbidden-import",
            "gradient",
            "invert",
            "loop",
            "memory-bomb",
            "not-a-number",
            "oob-write",
            "recursion",
            "slow",
            "trap"
        ]
        .map(|name| format!("{name}.lwplugin"))
    );
    let mut sums = String::new();
    for name in &names {
        let package = samples().join(name);
        let rebuilt =
            wat::parse_file(package.join("filter.wat")).unwrap_or_else(|error| panic!("{error}"));
        let committed = fs::read(package.join("filter.wasm")).unwrap();
        assert!(
            rebuilt == committed,
            "{name}/filter.wasm is not what filter.wat assembles to; run scripts/build-sample-plugins.sh"
        );
        assert!(
            package.join("plugin.json").is_file(),
            "{name} has no manifest"
        );
        sums += &format!("{:x}  {name}/filter.wasm\n", Sha256::digest(&committed));
    }
    assert_eq!(
        fs::read_to_string(samples().join("SHA256SUMS")).unwrap(),
        sums,
        "samples/SHA256SUMS is stale; run scripts/build-sample-plugins.sh"
    );
}
