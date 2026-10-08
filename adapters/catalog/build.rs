use std::path::PathBuf;
use std::process::Command;

fn main() {
    let root = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let source = root.join("engines/catalog");
    let verifier = root.join("scripts/catalog_source.py");
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", verifier.display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("DEPENDENCIES.json").display()
    );
    let output = Command::new("python3")
        .arg(verifier)
        .arg("--print-digest")
        .current_dir(&root)
        .output()
        .expect("owned catalog identity verifier");
    assert!(
        output.status.success(),
        "owned catalog identity failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let digest = String::from_utf8(output.stdout).expect("owned source SHA256 UTF8");
    let digest = digest.trim();
    assert!(
        digest.len() == 64
            && digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "invalid owned source digest"
    );
    println!("cargo:rustc-env=LENSWORKS_CATALOG_SOURCE_DIGEST={digest}");
}
