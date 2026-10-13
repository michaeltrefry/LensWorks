//! The sandbox: what a plugin may import, every bound it runs under, and that each way of failing is reported
//! with the caller's pixels left untouched.

use lensworks_plugins::{Instance, LIMITS, validate};
use std::{fs, path::PathBuf};

fn sample(name: &str) -> Vec<u8> {
    fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("samples")
            .join(format!("{name}.lwplugin/filter.wasm")),
    )
    .unwrap()
}
fn module(text: &str) -> Vec<u8> {
    wat::parse_str(text).unwrap()
}
/// A module with the interface's memory and exports around `extra` declarations and a filter `body`.
fn with(extra: &str, body: &str) -> Vec<u8> {
    module(&format!(
        r#"(module {extra}
            (memory (export "memory") 17)
            (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 65536))
            (func (export "lw_filter_tile") (param $ptr i32) (param i32 i32 i32 i32 i32 i32) (result i32) {body}))"#
    ))
}
fn pixels(count: usize) -> Vec<f32> {
    (0..count * 4)
        .map(|index| {
            if index % 4 == 3 {
                0.5
            } else {
                (index % 97) as f32 / 96.0
            }
        })
        .collect()
}
/// Runs one 8×8 tile and returns the refusal, checking the pixels were left as given.
fn failure(wasm: &[u8]) -> String {
    let mut instance = Instance::new(wasm, &[]).unwrap();
    let before = pixels(64);
    let mut tile = before.clone();
    let error = instance
        .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
        .unwrap_err()
        .0;
    assert_eq!(
        tile, before,
        "a failed tile must leave the pixels untouched"
    );
    let again = instance
        .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
        .unwrap_err()
        .0;
    assert_eq!(again, "The plugin already failed during this run.");
    error
}

#[test]
fn the_limits_are_the_documented_values() {
    assert_eq!(LIMITS.module_bytes, 4 * 1024 * 1024);
    assert_eq!(LIMITS.memory_bytes, 16 * 1024 * 1024);
    assert_eq!(LIMITS.table_elements, 4_096);
    assert_eq!(LIMITS.stack_bytes, 1024 * 1024);
    assert_eq!(LIMITS.recursion_depth, 1_024);
    assert_eq!(LIMITS.tile_pixels, 65_536);
    assert_eq!(
        (
            LIMITS.fuel_buffer_call,
            LIMITS.fuel_filter_base,
            LIMITS.fuel_per_pixel
        ),
        (1_000_000, 10_000_000, 4_000)
    );
    assert_eq!((LIMITS.parameters, LIMITS.interface_version), (16, 1));
}

#[test]
fn invert_changes_color_and_keeps_alpha() {
    validate(&sample("invert")).unwrap();
    let mut instance = Instance::new(&sample("invert"), &[]).unwrap();
    let before = pixels(64);
    let mut tile = before.clone();
    instance.filter_tile(&mut tile, 8, 8, 0, 0, 8, 8).unwrap();
    for (index, (old, new)) in before.iter().zip(&tile).enumerate() {
        if index % 4 == 3 {
            assert_eq!(old, new)
        } else {
            assert_eq!(*new, 1.0 - *old)
        }
    }
}

#[test]
fn brightness_reads_its_parameters_by_index() {
    let wasm = sample("brightness");
    // amount 0.25, channel green (index 2), clamp on, repeat 2: green gains 0.5 and is clamped to 1.
    let mut instance = Instance::new(&wasm, &[0.25, 2.0, 1.0, 2.0]).unwrap();
    let mut tile = vec![0.25, 0.75, 0.5, 1.0];
    instance.filter_tile(&mut tile, 1, 1, 0, 0, 1, 1).unwrap();
    assert_eq!(tile, [0.25, 1.0, 0.5, 1.0]);
    // An index past the supplied parameters answers 0, so nothing is added.
    let mut bare = Instance::new(&wasm, &[]).unwrap();
    let mut tile = vec![0.25, 0.75, 0.5, 1.0];
    bare.filter_tile(&mut tile, 1, 1, 0, 0, 1, 1).unwrap();
    assert_eq!(tile, [0.25, 0.75, 0.5, 1.0]);
    assert!(
        Instance::new(&wasm, &[f64::NAN])
            .is_err_and(|e| e.0 == "Every plugin parameter must be a finite number.")
    );
    assert!(
        Instance::new(&wasm, &[0.0; 17])
            .is_err_and(|e| e.0 == "A plugin takes at most 16 parameters.")
    );
}

#[test]
fn tiles_and_one_whole_frame_agree() {
    for (name, parameters) in [
        ("invert", &[][..]),
        ("brightness", &[0.125, 0.0, 0.0, 3.0][..]),
        ("gradient", &[][..]),
    ] {
        let (width, height) = (37u32, 23u32);
        let source = pixels((width * height) as usize);
        let mut whole = source.clone();
        Instance::new(&sample(name), parameters)
            .unwrap()
            .filter_tile(&mut whole, width, height, 0, 0, width, height)
            .unwrap();
        let mut tiled = source.clone();
        let mut instance = Instance::new(&sample(name), parameters).unwrap();
        let side = 8u32;
        for ty in (0..height).step_by(side as usize) {
            for tx in (0..width).step_by(side as usize) {
                let (w, h) = (side.min(width - tx), side.min(height - ty));
                let mut tile = Vec::new();
                for row in 0..h {
                    let start = (((ty + row) * width + tx) * 4) as usize;
                    tile.extend_from_slice(&source[start..start + (w * 4) as usize]);
                }
                instance
                    .filter_tile(&mut tile, w, h, tx, ty, width, height)
                    .unwrap();
                for row in 0..h {
                    let start = (((ty + row) * width + tx) * 4) as usize;
                    tiled[start..start + (w * 4) as usize].copy_from_slice(
                        &tile[(row * w * 4) as usize..((row + 1) * w * 4) as usize],
                    );
                }
            }
        }
        assert!(
            whole == tiled,
            "{name}: tiled and whole-frame results differ"
        );
        assert!(whole != source, "{name} changed nothing");
    }
}

#[test]
fn an_import_outside_the_filter_interface_is_refused_by_name() {
    let error = validate(&sample("forbidden-import")).unwrap_err().0;
    assert_eq!(
        error,
        "The module imports “wasi_snapshot_preview1.fd_write”, which the filter interface does not provide. A plugin may import only lensworks_filter_v1.param."
    );
    assert_eq!(
        Instance::new(&sample("forbidden-import"), &[])
            .err()
            .unwrap()
            .0,
        error,
        "checked again at load"
    );
    for (import, named) in [
        (r#"(import "env" "memory" (memory 1))"#, "env.memory"),
        (r#"(import "env" "table" (table 1 funcref))"#, "env.table"),
        (r#"(import "env" "now" (global i64))"#, "env.now"),
        (
            r#"(import "lensworks_filter_v1" "random" (func (result f64)))"#,
            "lensworks_filter_v1.random",
        ),
        (
            r#"(import "wasi_snapshot_preview1" "clock_time_get" (func (param i32 i64 i32) (result i32)))"#,
            "wasi_snapshot_preview1.clock_time_get",
        ),
        (
            r#"(import "wasi_snapshot_preview1" "random_get" (func (param i32 i32) (result i32)))"#,
            "wasi_snapshot_preview1.random_get",
        ),
        (
            r#"(import "wasi" "thread-spawn" (func (param i32) (result i32)))"#,
            "wasi.thread-spawn",
        ),
    ] {
        // The imported memory case declares its own export from the import.
        let wasm = if import.contains("(memory 1)") {
            module(&format!(
                r#"(module {import} (export "memory" (memory 0))
                (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
                (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#
            ))
        } else {
            with(import, "(i32.const 0)")
        };
        let error = validate(&wasm).unwrap_err().0;
        assert!(
            error.starts_with(&format!(
                "The module imports “{named}”, which the filter interface does not provide."
            )),
            "{error}"
        );
        assert!(Instance::new(&wasm, &[]).is_err());
    }
    // The one allowed import must have the declared type.
    let wrong = with(
        r#"(import "lensworks_filter_v1" "param" (func (param i32) (result i32)))"#,
        "(i32.const 0)",
    );
    assert_eq!(
        validate(&wrong).unwrap_err().0,
        "The module imports “lensworks_filter_v1.param” with the wrong type: it is a function (i32) -> f64."
    );
    // A hostile name is shown as bounded printable text.
    let long = "x".repeat(400);
    let error = validate(&with(
        &format!(r#"(import "a\n\u{{202e}}b" "{long}" (func))"#),
        "(i32.const 0)",
    ))
    .unwrap_err()
    .0;
    assert!(
        error.contains("a??b.")
            && error.len() < 480
            && !error.contains('\n')
            && !error.contains('\u{202e}'),
        "{error}"
    );
}

#[test]
fn a_module_that_is_malformed_or_outside_the_interface_is_refused() {
    assert_eq!(
        validate(b"").unwrap_err().0,
        "The file is not a WebAssembly module."
    );
    assert_eq!(
        validate(b"not wasm at all").unwrap_err().0,
        "The file is not a WebAssembly module."
    );
    let good = sample("invert");
    for cut in [8, 9, good.len() / 2, good.len() - 1] {
        assert!(
            validate(&good[..cut]).is_err(),
            "a module truncated to {cut} bytes"
        );
    }
    // f32.sub (0x93) becomes i32.add (0x6a): well-formed bytes that fail type validation.
    let mut flipped = good.clone();
    let at = flipped.iter().position(|byte| *byte == 0x93).unwrap();
    flipped[at] = 0x6a;
    assert!(
        validate(&flipped)
            .unwrap_err()
            .0
            .starts_with("The module is not valid WebAssembly for this host:")
    );
    let mut huge = good.clone();
    huge.resize(LIMITS.module_bytes as usize + 1, 0);
    assert_eq!(
        validate(&huge).unwrap_err().0,
        "The module is 4194305 bytes, over the 4194304-byte limit."
    );
    let missing = module(
        r#"(module (memory (export "memory") 1) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0)))"#,
    );
    assert_eq!(
        validate(&missing).unwrap_err().0,
        "The module does not export the function “lw_filter_tile”."
    );
    let no_memory = module(
        r#"(module (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
        (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
    );
    assert_eq!(
        validate(&no_memory).unwrap_err().0,
        "The module does not export its memory as “memory”."
    );
    let wrong = module(
        r#"(module (memory (export "memory") 1) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
        (func (export "lw_filter_tile") (param i32) (result i32) (i32.const 0)))"#,
    );
    assert_eq!(
        validate(&wrong).unwrap_err().0,
        "The module exports “lw_filter_tile” with the wrong type: it takes 7 i32 and returns i32."
    );
    // More initial memory than the limit, a start function, a second memory, a shared (threaded) memory, tail calls.
    let big = module(
        r#"(module (memory (export "memory") 257) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
        (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
    );
    assert_eq!(
        validate(&big).unwrap_err().0,
        "The module’s memory starts over the 16777216-byte limit."
    );
    assert!(
        validate(&with("(func $s) (start $s)", "(i32.const 0)")).is_err(),
        "a start function"
    );
    assert!(
        validate(&with("(memory 1)", "(i32.const 0)")).is_err(),
        "a second memory"
    );
    for text in [
        r#"(module (memory (export "memory") 1 2 shared) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
            (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
        r#"(module (memory (export "memory") 1) (func (export "lw_tile_buffer") (param i32) (result i32) (return_call 0 (local.get 0)))
            (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
        r#"(module (memory (export "memory") i64 1) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const 0))
            (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
    ] {
        assert!(validate(&module(text)).is_err(), "{text}");
    }
}

#[test]
fn an_endless_loop_is_stopped_by_its_fuel_budget() {
    validate(&sample("loop")).unwrap();
    let started = std::time::Instant::now();
    assert_eq!(
        failure(&sample("loop")),
        "It ran past its execution budget of 10256000 fuel for this call (an endless loop?) and was stopped."
    );
    println!(
        "endless loop on an 8x8 tile stopped after {:?}",
        started.elapsed()
    );
    // An endless loop in the buffer call is stopped too.
    let wasm = module(
        r#"(module (memory (export "memory") 1) (func (export "lw_tile_buffer") (param i32) (result i32) (loop $l (br $l)) (i32.const 0))
        (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#,
    );
    assert_eq!(
        failure(&wasm),
        "It ran past its execution budget of 1000000 fuel for this call (an endless loop?) and was stopped."
    );
}

#[test]
fn unbounded_recursion_is_stopped_by_the_stack_limit() {
    assert_eq!(
        failure(&sample("recursion")),
        "It exceeded the stack limit of 1024 calls deep or 1048576 bytes (unbounded recursion?) and was stopped."
    );
}

#[test]
fn a_memory_bomb_is_stopped_at_the_memory_limit() {
    assert_eq!(
        failure(&sample("memory-bomb")),
        "It asked for more than its limit of 16777216 bytes of memory or 4096 table elements and was stopped."
    );
    // A table grown without end is stopped the same way.
    let table = with(
        "(table $t 1 funcref)",
        "(loop $more (drop (table.grow $t (ref.null func) (i32.const 1024))) (br $more)) (i32.const 0)",
    );
    assert_eq!(
        failure(&table),
        "It asked for more than its limit of 16777216 bytes of memory or 4096 table elements and was stopped."
    );
    // Growing inside the limit is allowed.
    let fine = with("", "(drop (memory.grow (i32.const 16))) (i32.const 0)");
    let mut tile = pixels(4);
    Instance::new(&fine, &[])
        .unwrap()
        .filter_tile(&mut tile, 2, 2, 0, 0, 2, 2)
        .unwrap();
}

#[test]
fn a_trap_and_a_write_outside_memory_are_reported() {
    assert_eq!(
        failure(&sample("trap")),
        "It trapped (reached unreachable code) and was stopped."
    );
    assert_eq!(
        failure(&sample("oob-write")),
        "It read or wrote outside its own memory and was stopped."
    );
    assert_eq!(
        failure(&with("", "(i32.div_u (i32.const 1) (i32.const 0))"))
            .split(':')
            .next()
            .unwrap(),
        "It trapped and was stopped"
    );
    assert_eq!(
        failure(&with("", "(i32.const 7)")),
        "It reported failure (code 7)."
    );
}

#[test]
fn a_buffer_or_result_the_host_cannot_use_is_refused() {
    assert_eq!(
        failure(&sample("not-a-number")),
        "It returned a value that is not a finite number."
    );
    assert_eq!(
        failure(&with(
            "",
            "(f32.store offset=12 (local.get $ptr) (f32.const 1.5)) (i32.const 0)"
        )),
        "It returned an alpha value outside 0 through 1."
    );
    assert_eq!(
        failure(&with(
            "",
            "(f32.store (local.get $ptr) (f32.const inf)) (i32.const 0)"
        )),
        "It returned a value that is not a finite number."
    );
    for pointer in ["0", "-16", "1114100", "2147483632"] {
        let wasm = module(&format!(
            r#"(module (memory (export "memory") 17) (func (export "lw_tile_buffer") (param i32) (result i32) (i32.const {pointer}))
            (func (export "lw_filter_tile") (param i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))"#
        ));
        assert_eq!(
            failure(&wasm),
            "It did not provide a 1024-byte tile buffer inside its own memory.",
            "pointer {pointer}"
        );
    }
}

#[test]
fn a_tile_outside_the_bounds_is_refused_before_the_plugin_runs() {
    let mut instance = Instance::new(&sample("invert"), &[]).unwrap();
    let mut empty: Vec<f32> = Vec::new();
    assert!(instance.filter_tile(&mut empty, 0, 0, 0, 0, 8, 8).is_err());
    let mut tile = pixels(64);
    assert_eq!(
        Instance::new(&sample("invert"), &[])
            .unwrap()
            .filter_tile(&mut tile, 8, 8, 1, 0, 8, 8)
            .unwrap_err()
            .0,
        "The tile does not lie inside its layer."
    );
    assert_eq!(
        Instance::new(&sample("invert"), &[])
            .unwrap()
            .filter_tile(&mut tile, 4, 8, 0, 0, 8, 8)
            .unwrap_err()
            .0,
        "A tile carries from 1 through 65536 pixels."
    );
    let mut large = vec![0.0f32; 4 * 65_537];
    assert_eq!(
        Instance::new(&sample("invert"), &[])
            .unwrap()
            .filter_tile(&mut large, 65_537, 1, 0, 0, 70_000, 1)
            .unwrap_err()
            .0,
        "A tile carries from 1 through 65536 pixels."
    );
    // The largest tile there is fits the sample's buffer and runs inside its fuel budget.
    let mut full = pixels(65_536);
    Instance::new(&sample("invert"), &[])
        .unwrap()
        .filter_tile(&mut full, 256, 256, 0, 0, 256, 256)
        .unwrap();
}

#[test]
fn the_c_interface_reports_failures_as_bounded_messages() {
    use lensworks_plugins::ffi::*;
    let mut message = [0 as std::ffi::c_char; 64];
    let text = |message: &[std::ffi::c_char]| {
        unsafe { std::ffi::CStr::from_ptr(message.as_ptr()) }
            .to_str()
            .unwrap()
            .to_owned()
    };
    unsafe {
        let bad = sample("forbidden-import");
        assert_eq!(
            lw_plugin_validate(bad.as_ptr(), bad.len(), message.as_mut_ptr(), message.len()),
            1
        );
        assert!(
            text(&message).starts_with("The module imports “wasi_snapshot_preview1.fd_write”")
                && text(&message).len() < 64
        );
        assert!(
            lw_plugin_open(
                bad.as_ptr(),
                bad.len(),
                std::ptr::null(),
                0,
                message.as_mut_ptr(),
                message.len()
            )
            .is_null()
        );
        assert_eq!(
            lw_plugin_validate(std::ptr::null(), 4, message.as_mut_ptr(), message.len()),
            1
        );
        let good = sample("invert");
        assert_eq!(
            lw_plugin_validate(
                good.as_ptr(),
                good.len(),
                message.as_mut_ptr(),
                message.len()
            ),
            0
        );
        assert_eq!(text(&message), "");
        let instance = lw_plugin_open(
            good.as_ptr(),
            good.len(),
            std::ptr::null(),
            0,
            message.as_mut_ptr(),
            message.len(),
        );
        assert!(!instance.is_null());
        let mut tile = vec![0.25f32, 0.5, 1.0, 1.0];
        assert_eq!(
            lw_plugin_filter_tile(
                instance,
                tile.as_mut_ptr(),
                4,
                1,
                1,
                0,
                0,
                1,
                1,
                message.as_mut_ptr(),
                message.len()
            ),
            0
        );
        assert_eq!(tile, [0.75, 0.5, 0.0, 1.0]);
        assert_eq!(
            lw_plugin_filter_tile(
                instance,
                tile.as_mut_ptr(),
                4,
                1,
                1,
                5,
                0,
                1,
                1,
                message.as_mut_ptr(),
                message.len()
            ),
            1
        );
        assert_eq!(text(&message), "The tile does not lie inside its layer.");
        assert_eq!(
            lw_plugin_filter_tile(
                std::ptr::null_mut(),
                tile.as_mut_ptr(),
                4,
                1,
                1,
                0,
                0,
                1,
                1,
                message.as_mut_ptr(),
                message.len()
            ),
            1
        );
        lw_plugin_close(instance);
        lw_plugin_close(std::ptr::null_mut());
        let mut limits = std::mem::zeroed::<lensworks_plugins::Limits>();
        lw_plugin_limits(&mut limits);
        assert_eq!(limits, LIMITS);
    }
}
