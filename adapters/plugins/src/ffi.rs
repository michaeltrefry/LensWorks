//! The C interface the app calls (adapters/plugins/include/LensWorksPlugins.h). Every entry point catches panics,
//! so nothing a module does can unwind into the app, and reports failure as a bounded UTF-8 message.

use crate::{Instance, LIMITS, Limits, PluginError};
use std::ffi::{c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Writes `message` into `buffer` as a NUL-terminated string cut at a character boundary.
unsafe fn report(message: &str, buffer: *mut c_char, capacity: usize) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let mut end = message.len().min(capacity - 1);
    while !message.is_char_boundary(end) {
        end -= 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), buffer.cast::<u8>(), end);
        *buffer.add(end) = 0;
    }
}

unsafe fn guarded(
    buffer: *mut c_char,
    capacity: usize,
    body: impl FnOnce() -> Result<(), PluginError>,
) -> i32 {
    unsafe { report("", buffer, capacity) };
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            unsafe { report(&error.0, buffer, capacity) };
            1
        }
        Err(_) => {
            unsafe {
                report(
                    "The plugin runtime failed unexpectedly and the plugin was stopped.",
                    buffer,
                    capacity,
                )
            };
            2
        }
    }
}

unsafe fn bytes<'a>(data: *const u8, length: usize) -> Result<&'a [u8], PluginError> {
    if data.is_null() && length != 0 {
        return Err(PluginError("No module was supplied.".into()));
    }
    Ok(if length == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, length) }
    })
}

/// Fills `out` with the bounds every plugin runs under.
///
/// # Safety
/// `out` is null or points to a writable `LWPluginLimits`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_plugin_limits(out: *mut Limits) {
    if !out.is_null() {
        unsafe { *out = LIMITS };
    }
}

/// Validates a module without running it. Returns 0 when it conforms to the filter interface.
///
/// # Safety
/// `wasm` points to `length` readable bytes; `message` to `capacity` writable bytes (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_plugin_validate(
    wasm: *const u8,
    length: usize,
    message: *mut c_char,
    capacity: usize,
) -> i32 {
    unsafe { guarded(message, capacity, || crate::validate(bytes(wasm, length)?)) }
}

/// Validates and instantiates a module whose tiles together may spend at most `run_fuel` (never more than the
/// limits' `fuel_run`). Returns null on failure, with the reason in `message`.
///
/// # Safety
/// As `lw_plugin_validate`; `parameters` points to `count` readable doubles (or is null when `count` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_plugin_open(
    wasm: *const u8,
    length: usize,
    parameters: *const f64,
    count: usize,
    run_fuel: u64,
    message: *mut c_char,
    capacity: usize,
) -> *mut c_void {
    let mut opened: *mut c_void = std::ptr::null_mut();
    unsafe {
        guarded(message, capacity, || {
            if parameters.is_null() && count != 0 {
                return Err(PluginError("No parameters were supplied.".into()));
            }
            let values = if count == 0 {
                &[][..]
            } else {
                std::slice::from_raw_parts(parameters, count)
            };
            let instance = Instance::with_run_fuel(bytes(wasm, length)?, values, run_fuel)?;
            opened = Box::into_raw(Box::new(instance)).cast();
            Ok(())
        });
    }
    opened
}

/// Filters one tile of `width × height` RGBA float32 pixels in place. Returns 0 on success; otherwise the pixels
/// are unchanged and `message` says why.
///
/// # Safety
/// `instance` came from `lw_plugin_open` and is used from one thread at a time; `pixels` points to `count`
/// writable floats.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lw_plugin_filter_tile(
    instance: *mut c_void,
    pixels: *mut f32,
    count: usize,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    frame_width: u32,
    frame_height: u32,
    message: *mut c_char,
    capacity: usize,
) -> i32 {
    unsafe {
        guarded(message, capacity, || {
            if instance.is_null() || pixels.is_null() {
                return Err(PluginError(
                    "No plugin instance or pixels were supplied.".into(),
                ));
            }
            let instance = &mut *instance.cast::<Instance>();
            instance.filter_tile(
                std::slice::from_raw_parts_mut(pixels, count),
                width,
                height,
                x,
                y,
                frame_width,
                frame_height,
            )
        })
    }
}

/// Releases an instance from `lw_plugin_open`.
///
/// # Safety
/// `instance` is null or came from `lw_plugin_open` and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_plugin_close(instance: *mut c_void) {
    if !instance.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(instance.cast::<Instance>()) })
        }));
    }
}
