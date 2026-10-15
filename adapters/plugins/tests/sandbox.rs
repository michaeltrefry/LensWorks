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
    // The whole-run budgets, in full tiles' worth of fuel, and the color range a plugin may write.
    assert_eq!(LIMITS.fuel_run, 272_144_000 * 1_024);
    assert_eq!(LIMITS.fuel_run_agent, 272_144_000 * 256);
    assert_eq!(LIMITS.color_magnitude, 65_504);
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

/// A plugin that spends nearly its whole fuel on every tile and never traps is slow, not stuck: the whole run's
/// budget is what stops it, with the tile it was stopped on left untouched.
#[test]
fn a_run_that_spends_nearly_full_fuel_on_every_tile_is_stopped_by_the_run_budget() {
    let wasm = sample("slow");
    validate(&wasm).unwrap();
    let tile_fuel = LIMITS.fuel_filter_base + LIMITS.fuel_per_pixel * 64;
    // What one spin costs, measured: the fuel two runs of different lengths spend.
    let spent = |spins: f64| {
        let mut instance = Instance::new(&wasm, &[spins]).unwrap();
        let mut tile = pixels(64);
        instance.filter_tile(&mut tile, 8, 8, 0, 0, 8, 8).unwrap();
        LIMITS.fuel_run - instance.run_fuel_left()
    };
    let (short, long) = (spent(1_000.0), spent(101_000.0));
    let per_spin = (long - short) / 100_000;
    assert!(per_spin >= 1, "a spin costs fuel");
    println!("one spin costs {per_spin} fuel; an 8x8 tile with 1,000 spins costs {short}");
    // Ninety-five hundredths of a tile's fuel, on every tile.
    let spins = ((tile_fuel * 95 / 100 - short) / per_spin) as f64;
    let each = spent(spins);
    assert!(
        each > tile_fuel * 9 / 10 && each < tile_fuel,
        "one tile spends {each} of {tile_fuel}"
    );
    // A budget of three and a half such tiles: three succeed and are inverted, the fourth is stopped.
    let budget = each * 7 / 2;
    let mut instance = Instance::with_run_fuel(&wasm, &[spins], budget).unwrap();
    let before = pixels(64);
    for done in 1..=3u64 {
        let mut tile = before.clone();
        instance.filter_tile(&mut tile, 8, 8, 0, 0, 8, 32).unwrap();
        assert_eq!(tile[0], 1.0 - before[0]);
        assert_eq!(instance.run_fuel_left(), budget - each * done);
    }
    let mut tile = before.clone();
    let error = instance
        .filter_tile(&mut tile, 8, 8, 0, 24, 8, 32)
        .unwrap_err();
    assert_eq!(
        error.0,
        format!(
            "It used up its execution budget of {budget} fuel for the whole run and was stopped."
        )
    );
    assert_eq!(tile, before, "the stopped tile is untouched");
    let mut tile = before.clone();
    assert_eq!(
        instance
            .filter_tile(&mut tile, 8, 8, 0, 24, 8, 32)
            .unwrap_err()
            .0,
        "The plugin already failed during this run."
    );
    // With the budget every run has, the same four tiles all succeed.
    let mut instance = Instance::new(&wasm, &[spins]).unwrap();
    for _ in 0..4 {
        let mut tile = before.clone();
        instance.filter_tile(&mut tile, 8, 8, 0, 0, 8, 32).unwrap();
    }
    // The budget can only be tightened.
    assert_eq!(
        Instance::with_run_fuel(&wasm, &[0.0], u64::MAX)
            .unwrap()
            .run_fuel_left(),
        LIMITS.fuel_run
    );
    // An endless loop under a run budget smaller than its tile's fuel is stopped by the run budget, and says so.
    let mut instance = Instance::with_run_fuel(&sample("loop"), &[], 5_000_000).unwrap();
    let mut tile = before.clone();
    assert_eq!(
        instance
            .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
            .unwrap_err()
            .0,
        "It used up its execution budget of 5000000 fuel for the whole run and was stopped."
    );
    // What is left is less than the interpreter's smallest charge.
    assert!(instance.run_fuel_left() < 1_000);
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
    // A color the plugin wrote must lie inside the extended range the renderer keeps, either side of zero.
    for (value, refused) in [
        ("65504", false),
        ("-65504", false),
        ("65505", true),
        ("-65505", true),
        ("3.0e38", true),
        ("-3.0e38", true),
    ] {
        let wasm = with(
            "",
            &format!("(f32.store offset=4 (local.get $ptr) (f32.const {value})) (i32.const 0)"),
        );
        if refused {
            assert_eq!(
                failure(&wasm),
                "It returned a color value outside -65504 through 65504.",
                "{value}"
            );
        } else {
            let mut tile = pixels(64);
            Instance::new(&wasm, &[])
                .unwrap()
                .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
                .unwrap();
            assert_eq!(tile[1], value.parse::<f32>().unwrap());
        }
    }
    // A value past the range that the layer already held, and the plugin passed through untouched, is not the
    // plugin's: the tile is accepted and that value is exactly as it was.
    let mut tile = pixels(64);
    (tile[0], tile[5]) = (1.0e9, -2.5e7);
    Instance::new(&sample("brightness"), &[0.5, 3.0, 0.0, 1.0])
        .unwrap()
        .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
        .unwrap();
    assert_eq!(
        (tile[0], tile[5], tile[2]),
        (1.0e9, -2.5e7, 2.0 / 96.0 + 0.5)
    );
    // The same value changed by the plugin is the plugin's, and refused.
    let mut tile = pixels(64);
    tile[0] = 1.0e9;
    let before = tile.clone();
    let error = Instance::new(&sample("invert"), &[])
        .unwrap()
        .filter_tile(&mut tile, 8, 8, 0, 0, 8, 8)
        .unwrap_err();
    assert_eq!(
        error.0,
        "It returned a color value outside -65504 through 65504."
    );
    assert_eq!(tile, before);
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
                LIMITS.fuel_run,
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
            LIMITS.fuel_run,
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
