//! Real-weight runs through the exported C ABI against existing SceneWorks model files.
//! Ignored by default; run with `-- --ignored --test-threads=1`. Weights resolve from the
//! SceneWorks Hugging Face cache unless overridden by the env vars below. With
//! `LW_INFERENCE_REQUIRE_WEIGHTS=1` a missing model fails instead of skipping.
//!
//! * `LW_INFERENCE_SANA_SPRINT_DIR` — SceneWorks/Sana_Sprint_1.6B_1024px_mlx `q4` directory
//! * `LW_INFERENCE_CLIP_DIR` — openai/clip-vit-large-patch14 snapshot
//! * `LW_INFERENCE_SAM2_FILE` — SceneWorks/sam2-mlx `sam2.1_hiera_large.safetensors`
//! * `LW_INFERENCE_SAM3_DIR` — SceneWorks/sam3-mlx snapshot (model.safetensors + tokenizer.json)

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use lensworks_inference::*;
use serde_json::{Value, json};

#[derive(Clone, Debug)]
struct Event {
    kind: u32,
    json: Value,
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    channels: u32,
}

#[derive(Default)]
struct Context {
    events: Mutex<Vec<Event>>,
    signal: Condvar,
}

unsafe extern "C" fn on_event(context: *mut c_void, event: *const LwInferenceEvent) {
    let ctx = unsafe { &*(context as *const Context) };
    let e = unsafe { &*event };
    let pixels = if e.pixels.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(e.pixels, e.byte_length) }.to_vec()
    };
    let json = serde_json::from_str(unsafe { CStr::from_ptr(e.json) }.to_str().unwrap()).unwrap();
    ctx.events.lock().unwrap().push(Event {
        kind: e.kind,
        json,
        pixels,
        width: e.width,
        height: e.height,
        channels: e.channels,
    });
    ctx.signal.notify_all();
}

struct Job {
    ctx: Arc<Context>,
    raw: *mut LwInferenceJob,
}

impl Job {
    fn start(request: Value, inputs: &[LwInferenceImage]) -> Job {
        let ctx = Arc::new(Context::default());
        let json = CString::new(request.to_string()).unwrap();
        let mut error: *mut c_char = std::ptr::null_mut();
        let raw = unsafe {
            lw_inference_job_start(
                json.as_ptr(),
                if inputs.is_empty() {
                    std::ptr::null()
                } else {
                    inputs.as_ptr()
                },
                inputs.len(),
                Some(on_event),
                Arc::as_ptr(&ctx) as *mut c_void,
                &mut error,
            )
        };
        if raw.is_null() {
            let message = unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned();
            unsafe { lw_inference_string_free(error) };
            panic!("start failed: {message}");
        }
        Job { ctx, raw }
    }

    /// Wait until `pred` holds over the events so far.
    fn wait_for(&self, timeout: Duration, pred: impl Fn(&[Event]) -> bool) {
        let mut events = self.ctx.events.lock().unwrap();
        let deadline = std::time::Instant::now() + timeout;
        while !pred(&events) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(
                !left.is_zero(),
                "timed out; events so far: {:?}",
                events
                    .iter()
                    .map(|e| (e.kind, e.json.clone()))
                    .collect::<Vec<_>>()
            );
            events = self.ctx.signal.wait_timeout(events, left).unwrap().0;
        }
    }

    fn finish(&self) -> Vec<Event> {
        self.wait_for(Duration::from_secs(900), |e| {
            e.iter().any(|e| (5..=7).contains(&e.kind))
        });
        self.ctx.events.lock().unwrap().clone()
    }

    fn cancel(&self) {
        unsafe { lw_inference_job_cancel(self.raw) };
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        unsafe { lw_inference_job_release(self.raw) };
    }
}

fn required() -> bool {
    std::env::var("LW_INFERENCE_REQUIRE_WEIGHTS").as_deref() == Ok("1")
}

fn hub_snapshot(repo: &str) -> Option<PathBuf> {
    let root = PathBuf::from(std::env::var("HOME").ok()?)
        .join(".cache/huggingface/hub")
        .join(repo)
        .join("snapshots");
    std::fs::read_dir(root)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .find(|p| p.is_dir())
}

fn resolve(var: &str, fallback: Option<PathBuf>, label: &str) -> Option<PathBuf> {
    let path = std::env::var_os(var)
        .map(PathBuf::from)
        .or(fallback)
        .filter(|p| p.exists());
    if path.is_none() {
        assert!(!required(), "{label} weights are required (set {var})");
        eprintln!("skipping: {label} weights not found (set {var})");
    }
    path
}

fn terminal(events: &[Event]) -> &Event {
    events
        .iter()
        .find(|e| (5..=7).contains(&e.kind))
        .expect("terminal")
}

fn rgb_input(event: &Event) -> LwInferenceImage {
    LwInferenceImage {
        pixels: event.pixels.as_ptr(),
        byte_length: event.pixels.len(),
        width: event.width,
        height: event.height,
        row_bytes: event.width * event.channels,
        channels: event.channels,
        alpha: 0,
        color_space: 1,
    }
}

fn cosine(a: &[f64], b: &[f64]) -> f64 {
    let dot: f64 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let n = |v: &[f64]| v.iter().map(|x| x * x).sum::<f64>().sqrt();
    dot / (n(a) * n(b))
}

fn vector(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

/// One real image job with progress and output, a cancelled run, a failing load, then the
/// embedding and segmentation routes on the generated image. Sequential by design: MLX
/// Metal work is serialised per process and the GPU may be shared with other jobs.
#[test]
#[ignore = "needs local SceneWorks model files; run with --ignored --test-threads=1"]
fn real_image_job_cancel_failure_and_downstream_routes() {
    let Some(sana) = resolve(
        "LW_INFERENCE_SANA_SPRINT_DIR",
        hub_snapshot("models--SceneWorks--Sana_Sprint_1.6B_1024px_mlx").map(|p| p.join("q4")),
        "Sana Sprint 1.6B (q4)",
    ) else {
        return;
    };
    let generate = |prompt: &str, steps: u32, residency: &str| {
        json!({"version": 1, "task": "generate", "provider": "sana_sprint_1600m", "weights": {"dir": sana},
               "load": {"residency": residency},
               "params": {"prompt": prompt, "width": 512, "height": 512, "steps": steps, "seed": 4242}})
    };

    // 1. A real job: typed progress, one RGB output, provenance.
    let job = Job::start(
        generate(
            "a single red apple on a white table, studio photograph",
            2,
            "keep_loaded",
        ),
        &[],
    );
    let events = job.finish();
    let done = terminal(&events);
    assert_eq!(done.kind, 5, "{}", done.json);
    let steps: Vec<(u64, u64)> = events
        .iter()
        .filter(|e| e.kind == 2 && e.json["phase"] == "step")
        .map(|e| {
            (
                e.json["current"].as_u64().unwrap(),
                e.json["total"].as_u64().unwrap(),
            )
        })
        .collect();
    assert_eq!(steps, vec![(1, 2), (2, 2)], "typed step progress");
    let images: Vec<&Event> = events.iter().filter(|e| e.kind == 3).collect();
    assert_eq!(images.len(), 1);
    let image = images[0].clone();
    assert_eq!((image.width, image.height, image.channels), (512, 512, 3));
    assert_eq!(image.pixels.len(), 512 * 512 * 3);
    assert_eq!(image.json["color_space"], "srgb");
    let distinct: std::collections::BTreeSet<_> = image
        .pixels
        .chunks(3)
        .take(4096)
        .map(|p| (p[0], p[1], p[2]))
        .collect();
    assert!(
        distinct.len() > 64,
        "a real rendered image, not a flat fill"
    );
    assert_eq!(done.json["model_reused"], false);
    assert_eq!(
        done.json["inference_revision"],
        capabilities::INFERENCE_REVISION
    );
    drop(job);

    // 2. Cancel mid-run on the resident model: stops at a step boundary, no output.
    let job = Job::start(generate("a lighthouse at dusk", 4, "keep_loaded"), &[]);
    job.wait_for(Duration::from_secs(600), |e| {
        e.iter().any(|e| e.kind == 2 && e.json["phase"] == "step") || e.iter().any(|e| e.kind >= 5)
    });
    job.cancel();
    let events = job.finish();
    let end = terminal(&events);
    assert_eq!(end.kind, 7, "cancelled: {}", end.json);
    assert!(
        events.iter().all(|e| e.kind != 3),
        "a cancelled job delivers no output"
    );
    assert!(events.iter().filter(|e| e.json["phase"] == "step").count() < 4);
    assert_eq!(
        events
            .iter()
            .find(|e| e.kind == 1)
            .map(|e| e.json["model_reused"].clone()),
        Some(json!(true))
    );
    drop(job);
    assert_eq!(lw_inference_release_models(), 1);

    // 3. Failure path: an empty weights directory fails the load, typed.
    let empty = tempfile::tempdir().unwrap();
    let mut bad = generate("x", 2, "unload_after");
    bad["weights"] = json!({"dir": empty.path()});
    let events = Job::start(bad, &[]).finish();
    let end = terminal(&events);
    assert_eq!(
        (end.kind, end.json["kind"].as_str()),
        (6, Some("load")),
        "{}",
        end.json
    );

    // 4. Paired CLIP image/text embeddings rank the matching caption first.
    if let Some(clip) = resolve(
        "LW_INFERENCE_CLIP_DIR",
        hub_snapshot("models--openai--clip-vit-large-patch14"),
        "CLIP ViT-L/14",
    ) {
        let input = rgb_input(&image);
        let events = Job::start(json!({"version": 1, "task": "embed_image", "provider": "clip_vit_l14", "weights": {"dir": clip},
                                       "params": {"inputs": [0]}}), &[input]).finish();
        let img = terminal(&events);
        assert_eq!(img.kind, 5, "{}", img.json);
        let texts = Job::start(json!({"version": 1, "task": "embed_text", "provider": "clip_vit_l14_text", "weights": {"dir": clip},
                                      "params": {"texts": ["a red apple", "a city skyline at night"]}}), &[]).finish();
        let txt = terminal(&texts);
        assert_eq!(txt.kind, 5, "{}", txt.json);
        assert_eq!(img.json["space"], txt.json["space"]);
        let iv = vector(&img.json["embeddings"][0]);
        assert_eq!(
            iv.len(),
            img.json["embedding_dim"].as_u64().unwrap() as usize
        );
        let apple = cosine(&iv, &vector(&txt.json["embeddings"][0]));
        let city = cosine(&iv, &vector(&txt.json["embeddings"][1]));
        assert!(apple > city, "apple {apple} vs city {city}");
    }

    // 5. SAM2 box mask at the source size.
    if let Some(sam2) = resolve(
        "LW_INFERENCE_SAM2_FILE",
        hub_snapshot("models--SceneWorks--sam2-mlx")
            .map(|p| p.join("sam2.1_hiera_large.safetensors")),
        "SAM 2.1 hiera large",
    ) {
        let input = rgb_input(&image);
        let events = Job::start(json!({"version": 1, "task": "segment_sam2_box", "provider": "sam2", "weights": {"file": sam2},
                                       "params": {"input": 0, "box_xyxy": [96.0, 96.0, 416.0, 416.0], "model_size": "large"}}), &[input]).finish();
        let end = terminal(&events);
        assert_eq!(end.kind, 5, "{}", end.json);
        let mask = events.iter().find(|e| e.kind == 4).expect("mask event");
        assert_eq!((mask.width, mask.height, mask.channels), (512, 512, 1));
        assert!(mask.pixels.iter().all(|&v| v == 0 || v == 255));
        let on = mask.pixels.iter().filter(|&&v| v == 255).count();
        assert!(on > 0 && on < mask.pixels.len(), "a partial mask ({on} px)");
    }

    // 6. SAM3 open-vocabulary concept masks.
    if let Some(sam3) = resolve(
        "LW_INFERENCE_SAM3_DIR",
        hub_snapshot("models--SceneWorks--sam3-mlx"),
        "SAM3",
    ) {
        let input = rgb_input(&image);
        let events = Job::start(json!({"version": 1, "task": "segment_sam3_concept", "provider": "sam3",
                                       "weights": {"file": sam3.join("model.safetensors")}, "tokenizer": sam3.join("tokenizer.json"),
                                       "params": {"input": 0, "concept": "apple"}}), &[input]).finish();
        let end = terminal(&events);
        assert_eq!(end.kind, 5, "{}", end.json);
        let masks: Vec<&Event> = events.iter().filter(|e| e.kind == 4).collect();
        assert!(!masks.is_empty(), "SAM3 found the apple");
        assert!(
            masks
                .iter()
                .all(|m| (m.width, m.height, m.channels) == (512, 512, 1))
        );
        assert!(masks[0].json["score"].as_f64().unwrap() > 0.0);
    }
    assert_eq!(
        lw_inference_release_models(),
        0,
        "nothing stays resident under unload_after"
    );
}
