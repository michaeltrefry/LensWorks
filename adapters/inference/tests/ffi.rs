//! The exported C ABI exercised exactly as native code calls it: owned strings, synchronous
//! validation errors, borrowed input buffers, callback context lifetime and re-entrant release.

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use lensworks_inference::*;
use serde_json::Value;

fn take_string(raw: *mut c_char) -> Value {
    assert!(!raw.is_null());
    let value = serde_json::from_str(unsafe { CStr::from_ptr(raw) }.to_str().unwrap()).unwrap();
    unsafe { lw_inference_string_free(raw) };
    value
}

#[derive(Default)]
struct Context {
    events: Mutex<Vec<(u32, Value)>>,
    done: Condvar,
    job: AtomicPtr<LwInferenceJob>,
    release_on_first_event: bool,
    after_release: AtomicUsize,
}

unsafe extern "C" fn on_event(context: *mut c_void, event: *const LwInferenceEvent) {
    let ctx = unsafe { &*(context as *const Context) };
    let event = unsafe { &*event };
    if ctx.job.load(Ordering::SeqCst).is_null() && ctx.release_on_first_event {
        ctx.after_release.fetch_add(1, Ordering::SeqCst);
    }
    let json: Value =
        serde_json::from_str(unsafe { CStr::from_ptr(event.json) }.to_str().unwrap()).unwrap();
    ctx.events.lock().unwrap().push((event.kind, json));
    if ctx.release_on_first_event {
        let job = ctx.job.swap(std::ptr::null_mut(), Ordering::SeqCst);
        if !job.is_null() {
            unsafe { lw_inference_job_release(job) };
        }
    }
    ctx.done.notify_all();
}

fn start(
    json: &str,
    inputs: &[LwInferenceImage],
    ctx: &Arc<Context>,
) -> Result<*mut LwInferenceJob, Value> {
    let request = CString::new(json).unwrap();
    let mut error: *mut c_char = std::ptr::null_mut();
    let job = unsafe {
        lw_inference_job_start(
            request.as_ptr(),
            if inputs.is_empty() {
                std::ptr::null()
            } else {
                inputs.as_ptr()
            },
            inputs.len(),
            Some(on_event),
            Arc::as_ptr(ctx) as *mut c_void,
            &mut error,
        )
    };
    if job.is_null() {
        Err(take_string(error))
    } else {
        Ok(job)
    }
}

fn wait_terminal(ctx: &Context) -> (u32, Value) {
    let mut events = ctx.events.lock().unwrap();
    loop {
        if let Some(last) = events.iter().find(|(k, _)| (5..=7).contains(k)) {
            return last.clone();
        }
        let (guard, timeout) = ctx
            .done
            .wait_timeout(events, Duration::from_secs(120))
            .unwrap();
        assert!(!timeout.timed_out(), "terminal event");
        events = guard;
    }
}

#[test]
fn capabilities_and_abi_version_are_owned_json() {
    assert_eq!(lw_inference_abi_version(), 1);
    let doc = take_string(lw_inference_capabilities());
    assert_eq!(doc["ok"], true);
    assert_eq!(doc["result"]["abi_version"], 1);
    unsafe { lw_inference_string_free(std::ptr::null_mut()) };
}

#[test]
fn malformed_requests_and_buffers_fail_synchronously() {
    let ctx = Arc::new(Context::default());
    let err = start("{", &[], &ctx).unwrap_err();
    assert_eq!(err["kind"], "invalid_request");
    let err = start(r#"{"version":1,"task":"generate","provider":"x","weights":{"dir":"relative"},"params":{"prompt":"","width":8,"height":8}}"#, &[], &ctx)
        .unwrap_err();
    assert!(err["message"].as_str().unwrap().contains("absolute"));
    let pixels = [0u8; 16];
    let bad = LwInferenceImage {
        pixels: pixels.as_ptr(),
        byte_length: 16,
        width: 2,
        height: 2,
        row_bytes: 8,
        channels: 4,
        alpha: 0,
        color_space: 1,
    };
    let err = start(r#"{"version":1,"task":"caption","provider":"c","weights":{"dir":"/m"},"params":{"input":0}}"#, &[bad], &ctx).unwrap_err();
    assert_eq!(err["kind"], "invalid_input");
    let short = LwInferenceImage {
        pixels: pixels.as_ptr(),
        byte_length: 4,
        width: 2,
        height: 2,
        row_bytes: 8,
        channels: 4,
        alpha: 1,
        color_space: 1,
    };
    assert_eq!(start(r#"{"version":1,"task":"caption","provider":"c","weights":{"dir":"/m"},"params":{"input":0}}"#, &[short], &ctx).unwrap_err()["kind"], "invalid_input");
    // An edge above the limit is a typed error, checked before the buffer is read.
    let huge = LwInferenceImage {
        pixels: pixels.as_ptr(),
        byte_length: 4,
        width: pixels::MAX_EDGE + 1,
        height: 1,
        row_bytes: (pixels::MAX_EDGE + 1) * 4,
        channels: 4,
        alpha: 1,
        color_space: 1,
    };
    assert_eq!(start(r#"{"version":1,"task":"caption","provider":"c","weights":{"dir":"/m"},"params":{"input":0}}"#, &[huge], &ctx).unwrap_err()["kind"], "input_too_large");
    // NULL callback.
    let request = CString::new("{}").unwrap();
    let mut error: *mut c_char = std::ptr::null_mut();
    let job = unsafe {
        lw_inference_job_start(
            request.as_ptr(),
            std::ptr::null(),
            0,
            None,
            std::ptr::null_mut(),
            &mut error,
        )
    };
    assert!(job.is_null());
    assert_eq!(take_string(error)["kind"], "invalid_request");
    assert!(
        ctx.events.lock().unwrap().is_empty(),
        "no callbacks for rejected submissions"
    );
}

#[test]
fn a_load_failure_arrives_as_a_typed_failed_event_and_inputs_are_copied() {
    let ctx = Arc::new(Context::default());
    let mut pixels = vec![200u8; 8 * 8 * 4];
    let input = LwInferenceImage {
        pixels: pixels.as_ptr(),
        byte_length: pixels.len(),
        width: 8,
        height: 8,
        row_bytes: 32,
        channels: 4,
        alpha: 2,
        color_space: 1,
    };
    let job = start(
        r#"{"version":1,"task":"embed_image","provider":"clip_vit_l14","weights":{"dir":"/nonexistent/lensworks/clip"},"params":{"inputs":[0]}}"#,
        &[input],
        &ctx,
    )
    .unwrap();
    // The caller's buffer may be reused as soon as start returns.
    pixels.fill(0);
    let (kind, json) = wait_terminal(&ctx);
    assert_eq!(kind, 6, "{json}");
    assert_eq!(json["kind"], "load");
    unsafe { lw_inference_job_cancel(job) };
    unsafe { lw_inference_job_release(job) };
    let count = ctx.events.lock().unwrap().len();
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(ctx.events.lock().unwrap().len(), count);
}

#[test]
fn release_from_inside_the_c_callback_is_safe() {
    let ctx = Arc::new(Context {
        release_on_first_event: true,
        ..Default::default()
    });
    let job = start(
        r#"{"version":1,"task":"embed_text","provider":"clip_vit_l14_text","weights":{"dir":"/nonexistent/lensworks/clip"},"params":{"texts":["a","b"]}}"#,
        &[],
        &ctx,
    )
    .unwrap();
    ctx.job.store(job, Ordering::SeqCst);
    // Wait until the callback released the job; then the next job proves the executor is alive.
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    while !ctx.job.load(Ordering::SeqCst).is_null() || ctx.events.lock().unwrap().is_empty() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    let probe = Arc::new(Context::default());
    let next = start(
        r#"{"version":1,"task":"embed_text","provider":"no_such_embedder","weights":{"dir":"/m"},"params":{"texts":["a"]}}"#,
        &[],
        &probe,
    )
    .unwrap();
    assert_eq!(wait_terminal(&probe).1["kind"], "unknown_provider");
    unsafe { lw_inference_job_release(next) };
    assert_eq!(
        ctx.events.lock().unwrap().len(),
        1,
        "exactly the releasing callback ran"
    );
    assert_eq!(ctx.after_release.load(Ordering::SeqCst), 0);
    assert_eq!(lw_inference_release_models(), 0);
}

#[test]
fn the_gpu_self_test_runs_both_kernels_on_the_executor_thread() {
    let value = take_string(lw_inference_self_test());
    assert_eq!(value["version"], 1);
    assert_eq!(value["ok"], true, "{value}");
    let result = &value["result"];
    assert_eq!(result["thread"], "lensworks-inference-executor");
    let ops: Vec<&str> = result["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["op"].as_str().unwrap())
        .collect();
    assert_eq!(ops, ["steel_gemm_f32", "quantized_matmul_q4"]);
    for op in result["ops"].as_array().unwrap() {
        assert!(op["max_rel_error"].as_f64().unwrap() <= op["tolerance"].as_f64().unwrap());
    }
    // No bundled metallib beside the test binary: MLX keeps its own search order.
    assert_eq!(result["metallib_resolution"], "mlx_search_order");
    assert_eq!(result["metallib"], Value::Null);
}
