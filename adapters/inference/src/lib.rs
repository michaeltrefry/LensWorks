//! LensWorks-owned C ABI over the pinned SceneWorks inference macOS runtime.
//! See `README.md` and `include/LensWorksInference.h` for the contract.

pub mod capabilities;
pub mod job;
pub mod pixels;
pub mod request;
pub mod routes;

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;

use serde_json::{Value, json};

use crate::job::{EventKind, EventOut, Executor, JobHandle, Sink};
use crate::pixels::{BufferDesc, HostImage};
use crate::request::Request;
use crate::routes::{CatalogProviders, InferenceRunner, ProviderSource};

#[repr(C)]
pub struct LwInferenceImage {
    pub pixels: *const u8,
    pub byte_length: usize,
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
    pub channels: u32,
    pub alpha: u32,
    pub color_space: u32,
}

#[repr(C)]
pub struct LwInferenceEvent {
    pub kind: u32,
    pub json: *const c_char,
    pub pixels: *const u8,
    pub byte_length: usize,
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
    pub channels: u32,
    pub alpha: u32,
    pub color_space: u32,
}

pub type LwInferenceCallback =
    Option<unsafe extern "C" fn(context: *mut c_void, event: *const LwInferenceEvent)>;

/// Opaque job handle owned by the caller until `lw_inference_job_release`.
pub struct LwInferenceJob {
    handle: JobHandle,
}

fn executor() -> &'static Executor {
    static EXECUTOR: OnceLock<Executor> = OnceLock::new();
    EXECUTOR.get_or_init(|| {
        Executor::spawn(InferenceRunner::new(|| {
            CatalogProviders::new().map(|p| Box::new(p) as Box<dyn ProviderSource>)
        }))
    })
}

fn owned_string(value: &Value) -> *mut c_char {
    // serde_json never emits interior NULs (they are escaped).
    CString::new(value.to_string())
        .expect("JSON without NUL")
        .into_raw()
}

/// The weights-free capability document, computed once per process.
pub fn capabilities_document() -> Value {
    static DOCUMENT: OnceLock<Value> = OnceLock::new();
    DOCUMENT
        .get_or_init(|| match runtime_macos::catalog() {
            Ok(catalog) => {
                let snapshot = catalog.snapshot();
                json!({"version": 1, "ok": true, "result": capabilities::capabilities(
                    catalog.media(), catalog.platform(), catalog.backend(), &snapshot.trainer_ids, &snapshot.text_llm_ids)})
            }
            Err(e) => json!({"version": 1, "ok": false, "error": {"kind": "runtime_unavailable", "message": e.to_string()}}),
        })
        .clone()
}

#[unsafe(no_mangle)]
pub extern "C" fn lw_inference_abi_version() -> u32 {
    capabilities::ABI_VERSION
}

/// Returns an owned JSON string; free with `lw_inference_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lw_inference_capabilities() -> *mut c_char {
    let value = catch_unwind(capabilities_document).unwrap_or_else(|_| {
        json!({"version": 1, "ok": false, "error": {"kind": "panic", "message": "capability enumeration panicked"}})
    });
    owned_string(&value)
}

/// # Safety
/// `value` must be NULL or a pointer previously returned by this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_inference_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

struct CallbackTarget {
    callback: unsafe extern "C" fn(*mut c_void, *const LwInferenceEvent),
    context: *mut c_void,
}

// The caller guarantees `context` may be used from the executor thread until release returns.
unsafe impl Send for CallbackTarget {}

impl CallbackTarget {
    fn call(&self, event: &LwInferenceEvent) {
        unsafe { (self.callback)(self.context, event) };
    }
}

fn c_sink(target: CallbackTarget) -> Sink {
    Box::new(move |event: &EventOut<'_>| {
        let json = CString::new(event.json).unwrap_or_default();
        let (pixels, byte_length, width, height, row_bytes, channels, alpha) = match event.image {
            Some(image) => (
                image.pixels.as_ptr(),
                image.pixels.len(),
                image.width,
                image.height,
                image.row_bytes(),
                image.channels,
                if image.channels == 4 {
                    pixels::ALPHA_STRAIGHT
                } else {
                    pixels::ALPHA_NONE
                },
            ),
            None => (std::ptr::null(), 0, 0, 0, 0, 0, 0),
        };
        let raw = LwInferenceEvent {
            kind: event.kind as u32,
            json: json.as_ptr(),
            pixels,
            byte_length,
            width,
            height,
            row_bytes,
            channels,
            alpha,
            color_space: if event.image.is_some() {
                pixels::COLOR_SPACE_SRGB
            } else {
                0
            },
        };
        target.call(&raw);
    })
}

fn error_out(error_out: *mut *mut c_char, kind: &str, message: &str) -> *mut LwInferenceJob {
    if !error_out.is_null() {
        unsafe { *error_out = owned_string(&json!({"kind": kind, "message": message})) };
    }
    std::ptr::null_mut()
}

/// Validate a request and queue it on the executor.
///
/// # Safety
/// `request_json` is a NUL-terminated UTF-8 string; `inputs` points to `input_count` valid
/// image descriptions whose pixel buffers stay readable for the duration of this call only;
/// `context` must stay valid until `lw_inference_job_release` returns. `error_out` may be
/// NULL; when set on failure it receives an owned JSON string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_inference_job_start(
    request_json: *const c_char,
    inputs: *const LwInferenceImage,
    input_count: usize,
    callback: LwInferenceCallback,
    context: *mut c_void,
    error_out_ptr: *mut *mut c_char,
) -> *mut LwInferenceJob {
    if !error_out_ptr.is_null() {
        unsafe { *error_out_ptr = std::ptr::null_mut() };
    }
    let result = catch_unwind(AssertUnwindSafe(
        || -> Result<*mut LwInferenceJob, (String, String)> {
            let Some(callback) = callback else {
                return Err(("invalid_request".into(), "a callback is required".into()));
            };
            if request_json.is_null() {
                return Err(("invalid_request".into(), "request_json is NULL".into()));
            }
            if input_count > 64 || (input_count > 0 && inputs.is_null()) {
                return Err((
                    "invalid_request".into(),
                    "inputs must be non-NULL and at most 64".into(),
                ));
            }
            let json = unsafe { CStr::from_ptr(request_json) }.to_bytes();
            let descriptors = if input_count == 0 {
                &[][..]
            } else {
                unsafe { std::slice::from_raw_parts(inputs, input_count) }
            };
            let mut images = Vec::with_capacity(input_count);
            for (i, d) in descriptors.iter().enumerate() {
                if d.pixels.is_null() {
                    return Err(("invalid_input".into(), format!("input {i}: pixels is NULL")));
                }
                let bytes = unsafe { std::slice::from_raw_parts(d.pixels, d.byte_length) };
                let image = HostImage::ingest(BufferDesc {
                    bytes,
                    width: d.width,
                    height: d.height,
                    row_bytes: d.row_bytes,
                    channels: d.channels,
                    alpha: d.alpha,
                    color_space: d.color_space,
                })
                .map_err(|e| ("invalid_input".to_string(), format!("input {i}: {e}")))?;
                images.push(image);
            }
            let request =
                Request::parse(json, images).map_err(|e| ("invalid_request".to_string(), e.0))?;
            let handle = executor().submit(request, c_sink(CallbackTarget { callback, context }));
            Ok(Box::into_raw(Box::new(LwInferenceJob { handle })))
        },
    ));
    match result {
        Ok(Ok(job)) => job,
        Ok(Err((kind, message))) => error_out(error_out_ptr, &kind, &message),
        Err(_) => error_out(error_out_ptr, "panic", "job submission panicked"),
    }
}

/// Request cooperative cancellation. Safe to call repeatedly and from any thread.
///
/// # Safety
/// `job` is NULL or a live handle from `lw_inference_job_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_inference_job_cancel(job: *const LwInferenceJob) {
    if let Some(job) = unsafe { job.as_ref() } {
        job.handle.cancel();
    }
}

/// Cancel (if still running) and free the handle. When this returns no callback for the job
/// is executing or will ever be invoked, so the caller may free `context`. May be called from
/// inside the job's own callback.
///
/// # Safety
/// `job` is NULL or a live handle from `lw_inference_job_start`, released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_inference_job_release(job: *mut LwInferenceJob) {
    if !job.is_null() {
        let job = unsafe { Box::from_raw(job) };
        let _ = catch_unwind(AssertUnwindSafe(|| job.handle.release()));
    }
}

/// Drop resident models after queued jobs finish; returns how many were released.
#[unsafe(no_mangle)]
pub extern "C" fn lw_inference_release_models() -> usize {
    catch_unwind(|| executor().release_models()).unwrap_or(0)
}

#[doc(hidden)]
pub fn event_kind_name(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Started => "started",
        EventKind::Progress => "progress",
        EventKind::Image => "image",
        EventKind::Mask => "mask",
        EventKind::Completed => "completed",
        EventKind::Failed => "failed",
        EventKind::Cancelled => "cancelled",
    }
}
