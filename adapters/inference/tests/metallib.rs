//! Proves the packaged-app metallib rule: a pinned path is the only metallib MLX loads.
//! Each case runs in a child process because MLX creates its Metal device once per process.

use std::path::PathBuf;
use std::process::Command;

use lensworks_inference::metallib;

const CHILD: &str = "LW_METALLIB_CHILD_PIN";

fn run_child(pin: &std::path::Path) -> std::process::Output {
    Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "child_runs_one_metal_op",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD, pin)
        .output()
        .unwrap()
}

/// Child body: pin, then force Metal device creation with one evaluated MLX op.
#[test]
fn child_runs_one_metal_op() {
    let Some(pin) = std::env::var_os(CHILD) else {
        return;
    };
    metallib::pin(&PathBuf::from(pin));
    let a = mlx_rs::Array::from_slice(&[1.0f32, 2.0, 3.0], &[3]);
    let b = mlx_rs::ops::multiply(&a, &a).expect("multiply");
    b.eval().expect("eval");
    assert_eq!(b.as_slice::<f32>(), &[1.0, 4.0, 9.0]);
    println!("METAL_OP_OK");
    // The self-test reports the file MLX actually loaded.
    let report = lensworks_inference::selftest::run();
    assert_eq!(report["ok"], true, "{report}");
    println!(
        "SELF_TEST_METALLIB={}",
        report["metallib"].as_str().unwrap_or("<none>")
    );
}

#[test]
fn a_pinned_copy_is_loaded_and_a_missing_pin_never_falls_back() {
    let built = PathBuf::from(env!("LW_MLX_BUILD_METALLIB"));
    assert!(built.is_file(), "{}", built.display());
    let dir = tempfile::tempdir().unwrap();
    let copy = dir.path().join("mlx.metallib");
    std::fs::copy(&built, &copy).unwrap();

    let ok = run_child(&copy);
    let out = String::from_utf8_lossy(&ok.stdout);
    assert!(
        ok.status.success() && out.contains("METAL_OP_OK"),
        "{out}\n{}",
        String::from_utf8_lossy(&ok.stderr)
    );
    assert!(
        out.contains(&format!("SELF_TEST_METALLIB={}", copy.display())),
        "the self-test reports the pinned copy: {out}"
    );

    // The compiled-in build path still exists here, yet a missing pin fails rather than
    // falling back to it: so when the pinned file works, it is the one MLX loaded.
    let missing = run_child(&dir.path().join("absent.metallib"));
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&missing.stdout),
        String::from_utf8_lossy(&missing.stderr)
    );
    assert!(
        !missing.status.success() && !text.contains("METAL_OP_OK"),
        "{text}"
    );
    assert!(
        text.contains("Can not load metallib from specified location"),
        "{text}"
    );
}

#[test]
fn without_a_colocated_file_mlx_keeps_its_own_search_order() {
    let dir = metallib::library_dir().expect("library dir");
    assert!(!dir.join("mlx.metallib").exists());
    assert_eq!(metallib::resolve_once(), &metallib::Resolution::MlxSearch);
}
