//! Weights-free route tests: every non-generator route (transform, captioner, image and text
//! embedders, SAM2 box and SAM3 concept/box segmentation) runs against a scripted provider
//! loaded through the `ProviderSource` hooks. They check input conversion (what the provider
//! receives), output mapping (what the caller receives) and cooperative cancellation.
//! Captioner and embedder descriptors are the real registry ones; the pinned catalog registers
//! no image transform, so the transform route uses a scripted descriptor.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lensworks_inference::job::{EventKind, EventOut, Executor, JobHandle};
use lensworks_inference::pixels::{self, HostImage};
use lensworks_inference::request::{Request, Sam2Size};
use lensworks_inference::routes::{
    InferenceRunner, ProviderSource, Sam2Utility, Sam3Instance, Sam3Utility,
};
use runtime_macos::gen_core::{
    self, CaptionFinishReason, CaptionOutput, CaptionRequest, Captioner, CaptionerDescriptor,
    Image, ImageEmbedder, ImageEmbedderDescriptor, LoadSpec, Progress, ProviderRegistry,
    ProviderRegistryBuilder, TargetSize, TextEmbedder, TextEmbedderDescriptor, Transform,
    TransformCapabilities, TransformDescriptor, TransformRegistration, TransformRequest,
};
use serde_json::{Value, json};

const TRANSFORM: &str = "lw_scripted_upscale";
const CAPTIONER: &str = "fancyfeast/llama-joycaption-beta-one-hf-llava";
const IMAGE_EMBEDDER: &str = "clip_vit_l14";
const TEXT_EMBEDDER: &str = "clip_vit_l14_text";

fn transform_descriptor() -> TransformDescriptor {
    TransformDescriptor {
        id: TRANSFORM,
        family: "upscale",
        backend: "mlx",
        capabilities: TransformCapabilities {
            scale: true,
            min_edge: false,
            resolution: true,
            max_scale: 4.0,
            is_diffusion: true,
            supports_strength: true,
            mac_only: true,
        },
    }
}

fn no_registry_load(_: &LoadSpec) -> gen_core::Result<Box<dyn Transform>> {
    Err(gen_core::Error::Msg(
        "loaded through the ProviderSource hook".into(),
    ))
}

/// What every scripted provider shares with the test: received inputs, load count and a gate
/// that holds the forward pass until the test has cancelled.
#[derive(Default)]
struct Script {
    received: Mutex<Vec<Value>>,
    loads: AtomicUsize,
    gated: AtomicBool,
    entered: Mutex<Option<mpsc::Sender<()>>>,
    go: Mutex<Option<mpsc::Receiver<()>>>,
    /// Embedders return vectors one shorter than the advertised dimension.
    wrong_dim: AtomicBool,
}

impl Script {
    fn record(&self, value: Value) {
        self.received.lock().unwrap().push(value);
    }

    fn last(&self) -> Value {
        self.received
            .lock()
            .unwrap()
            .last()
            .cloned()
            .expect("provider ran")
    }

    /// The forward pass: when gated, report entry and wait for the test to release it.
    fn pass(&self) {
        if self.gated.load(Ordering::SeqCst) {
            if let Some(tx) = self.entered.lock().unwrap().as_ref() {
                let _ = tx.send(());
            }
            if let Some(rx) = self.go.lock().unwrap().as_ref() {
                rx.recv_timeout(Duration::from_secs(30)).expect("released");
            }
        }
    }
}

fn image_json(image: &Image) -> Value {
    json!({"width": image.width, "height": image.height, "pixels": image.pixels})
}

struct ScriptedTransform(TransformDescriptor, Arc<Script>);

impl Transform for ScriptedTransform {
    fn descriptor(&self) -> &TransformDescriptor {
        &self.0
    }
    fn validate(&self, _req: &TransformRequest) -> gen_core::Result<()> {
        Ok(())
    }
    fn apply(
        &self,
        req: &TransformRequest,
        on_progress: &mut dyn FnMut(Progress),
    ) -> gen_core::Result<Image> {
        let factor = match req.target {
            TargetSize::Scale(f) => f as u32,
            _ => 1,
        };
        self.1.record(json!({"image": image_json(&req.image), "factor": factor, "seed": req.seed, "strength": req.strength}));
        on_progress(Progress::Step {
            current: 1,
            total: 1,
        });
        self.1.pass();
        let (w, h) = (req.image.width * factor, req.image.height * factor);
        Ok(Image {
            width: w,
            height: h,
            pixels: (0..w * h * 3).map(|i| (i * 5 % 256) as u8).collect(),
        })
    }
}

struct ScriptedCaptioner(CaptionerDescriptor, Arc<Script>);

impl Captioner for ScriptedCaptioner {
    fn descriptor(&self) -> &CaptionerDescriptor {
        &self.0
    }
    fn validate(&self, _req: &CaptionRequest) -> gen_core::Result<()> {
        Ok(())
    }
    fn caption(
        &self,
        req: &CaptionRequest,
        _on_progress: &mut dyn FnMut(Progress),
    ) -> gen_core::Result<CaptionOutput> {
        self.1.record(json!({
            "image": image_json(&req.image), "prompt": req.prompt, "caption_type": req.options.caption_type,
            "caption_length": req.options.caption_length, "max_new_tokens": req.sampling.max_new_tokens, "seed": req.sampling.seed,
        }));
        self.1.pass();
        Ok(CaptionOutput {
            text: "a gray square".into(),
            generated_tokens: Some(4),
            finish_reason: Some(CaptionFinishReason::StopToken),
        })
    }
}

struct ScriptedImageEmbedder(ImageEmbedderDescriptor, Arc<Script>);

impl ImageEmbedder for ScriptedImageEmbedder {
    fn descriptor(&self) -> &ImageEmbedderDescriptor {
        &self.0
    }
    fn embed(&self, _image: &Image) -> gen_core::Result<Vec<f32>> {
        unreachable!("the route embeds in one batch")
    }
    fn embed_batch(&self, images: &[Image]) -> gen_core::Result<Vec<Vec<f32>>> {
        self.1
            .record(json!({"images": images.iter().map(image_json).collect::<Vec<_>>()}));
        self.1.pass();
        let dim = self.0.embedding_dim - usize::from(self.1.wrong_dim.load(Ordering::SeqCst));
        Ok(images
            .iter()
            .map(|image| vec![f32::from(image.pixels[0]); dim])
            .collect())
    }
}

struct ScriptedTextEmbedder(TextEmbedderDescriptor, Arc<Script>);

impl TextEmbedder for ScriptedTextEmbedder {
    fn descriptor(&self) -> &TextEmbedderDescriptor {
        &self.0
    }
    fn embed_text(&self, _text: &str) -> gen_core::Result<Vec<f32>> {
        unreachable!("the route embeds in one batch")
    }
    fn embed_text_batch(&self, texts: &[&str]) -> gen_core::Result<Vec<Vec<f32>>> {
        self.1.record(json!({"texts": texts}));
        self.1.pass();
        Ok(texts
            .iter()
            .map(|t| vec![t.len() as f32; self.0.embedding_dim])
            .collect())
    }
}

struct ScriptedSam2(Arc<Script>);

impl Sam2Utility for ScriptedSam2 {
    fn segment(&self, image: &Image, b: [f32; 4]) -> gen_core::Result<Vec<u8>> {
        self.0.record(json!({"image": image_json(image), "box": b}));
        self.0.pass();
        let mut mask = vec![0u8; (image.width * image.height) as usize];
        for y in b[1] as u32..b[3] as u32 {
            for x in b[0] as u32..b[2] as u32 {
                mask[(y * image.width + x) as usize] = 255;
            }
        }
        Ok(mask)
    }
}

struct ScriptedSam3(Arc<Script>);

/// Two 2x2-grid instances: one in the top-left quadrant, one filling the bottom row.
fn sam3_instances() -> Vec<Sam3Instance> {
    vec![
        Sam3Instance {
            score: 0.9,
            box_xyxy: [0.0, 0.0, 2.0, 2.0],
            grid: vec![1.0, 0.0, 0.0, 0.0],
            grid_width: 2,
            grid_height: 2,
        },
        Sam3Instance {
            score: 0.7,
            box_xyxy: [0.0, 2.0, 4.0, 4.0],
            grid: vec![0.0, 0.0, 1.0, 1.0],
            grid_width: 2,
            grid_height: 2,
        },
    ]
}

impl Sam3Utility for ScriptedSam3 {
    fn segment(
        &self,
        image: &Image,
        concept: &str,
        prompt_box: Option<[f32; 4]>,
        threshold: f32,
        mask_threshold: f32,
    ) -> gen_core::Result<Vec<Sam3Instance>> {
        self.0.record(
            json!({"image": image_json(image), "concept": concept, "box": prompt_box,
                             "threshold": threshold, "mask_threshold": mask_threshold}),
        );
        self.0.pass();
        Ok(sam3_instances())
    }
}

struct ScriptedProviders {
    registry: ProviderRegistry,
    script: Arc<Script>,
}

impl ScriptedProviders {
    fn new(script: Arc<Script>) -> Result<Self, String> {
        let catalog = runtime_macos::catalog().map_err(|e| e.to_string())?;
        let media = catalog.media();
        let mut builder =
            ProviderRegistryBuilder::new().register_transform(TransformRegistration {
                descriptor: transform_descriptor,
                load: no_registry_load,
            });
        for r in media.captioners() {
            builder = builder.register_captioner(*r);
        }
        for r in media.image_embedders() {
            builder = builder.register_image_embedder(*r);
        }
        for r in media.text_embedders() {
            builder = builder.register_text_embedder(*r);
        }
        let registry = builder.build().map_err(|e| e.to_string())?;
        Ok(Self { registry, script })
    }

    fn loaded(&self) {
        self.script.loads.fetch_add(1, Ordering::SeqCst);
    }
}

impl ProviderSource for ScriptedProviders {
    fn registry(&self) -> &ProviderRegistry {
        &self.registry
    }
    fn load_transform(&self, id: &str, _spec: &LoadSpec) -> gen_core::Result<Box<dyn Transform>> {
        self.loaded();
        assert_eq!(id, TRANSFORM);
        Ok(Box::new(ScriptedTransform(
            transform_descriptor(),
            self.script.clone(),
        )))
    }
    fn load_captioner(&self, id: &str, _spec: &LoadSpec) -> gen_core::Result<Box<dyn Captioner>> {
        self.loaded();
        let d = self
            .registry
            .captioners()
            .map(|r| (r.descriptor)())
            .find(|d| d.id == id)
            .unwrap();
        Ok(Box::new(ScriptedCaptioner(d, self.script.clone())))
    }
    fn load_image_embedder(
        &self,
        id: &str,
        _spec: &LoadSpec,
    ) -> gen_core::Result<Box<dyn ImageEmbedder>> {
        self.loaded();
        let d = self
            .registry
            .image_embedders()
            .map(|r| (r.descriptor)())
            .find(|d| d.id == id)
            .unwrap();
        Ok(Box::new(ScriptedImageEmbedder(d, self.script.clone())))
    }
    fn load_text_embedder(
        &self,
        id: &str,
        _spec: &LoadSpec,
    ) -> gen_core::Result<Box<dyn TextEmbedder>> {
        self.loaded();
        let d = self
            .registry
            .text_embedders()
            .map(|r| (r.descriptor)())
            .find(|d| d.id == id)
            .unwrap();
        Ok(Box::new(ScriptedTextEmbedder(d, self.script.clone())))
    }
    fn load_sam2(&self, weights: &Path, size: Sam2Size) -> gen_core::Result<Box<dyn Sam2Utility>> {
        self.loaded();
        assert!(weights.is_file());
        assert_eq!(size, Sam2Size::Small);
        Ok(Box::new(ScriptedSam2(self.script.clone())))
    }
    fn load_sam3(
        &self,
        weights: &Path,
        tokenizer: &Path,
        quantize_bits: Option<i32>,
    ) -> gen_core::Result<Box<dyn Sam3Utility>> {
        self.loaded();
        assert!(weights.is_file() && tokenizer.is_file());
        assert_eq!(quantize_bits, Some(8));
        Ok(Box::new(ScriptedSam3(self.script.clone())))
    }
}

struct Harness {
    executor: Executor,
    script: Arc<Script>,
    files: tempfile::TempDir,
}

impl Harness {
    fn new() -> Self {
        let script = Arc::new(Script::default());
        let s = script.clone();
        let executor = Executor::spawn(InferenceRunner::new(move || {
            ScriptedProviders::new(s.clone()).map(|p| Box::new(p) as Box<dyn ProviderSource>)
        }));
        let files = tempfile::tempdir().unwrap();
        for name in ["sam.safetensors", "tokenizer.json"] {
            std::fs::write(files.path().join(name), b"scripted").unwrap();
        }
        Self {
            executor,
            script,
            files,
        }
    }

    fn file(&self, name: &str) -> PathBuf {
        self.files.path().join(name)
    }

    fn gate(&self) -> (mpsc::Receiver<()>, mpsc::Sender<()>) {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (go_tx, go_rx) = mpsc::channel();
        *self.script.entered.lock().unwrap() = Some(entered_tx);
        *self.script.go.lock().unwrap() = Some(go_rx);
        self.script.gated.store(true, Ordering::SeqCst);
        (entered_rx, go_tx)
    }
}

#[derive(Clone, Debug)]
struct Recorded {
    kind: EventKind,
    json: Value,
    image: Option<HostImage>,
}

type Log = Arc<Mutex<Vec<Recorded>>>;

fn run(h: &Harness, request: Request) -> (JobHandle, Log, mpsc::Receiver<EventKind>) {
    let log: Log = Arc::default();
    let (tx, rx) = mpsc::channel();
    let l = log.clone();
    let handle = h.executor.submit(
        request,
        Box::new(move |event: &EventOut<'_>| {
            l.lock().unwrap().push(Recorded {
                kind: event.kind,
                json: serde_json::from_str(event.json).unwrap(),
                image: event.image.cloned(),
            });
            let _ = tx.send(event.kind);
        }),
    );
    (handle, log, rx)
}

fn wait_terminal(rx: &mpsc::Receiver<EventKind>) {
    while !rx
        .recv_timeout(Duration::from_secs(30))
        .expect("terminal event")
        .is_terminal()
    {}
}

fn finish(h: &Harness, request: Request) -> Vec<Recorded> {
    let (handle, log, rx) = run(h, request);
    wait_terminal(&rx);
    handle.release();
    log.lock().unwrap().clone()
}

fn completed(events: &[Recorded]) -> Value {
    let last = events.last().unwrap();
    assert_eq!(last.kind, EventKind::Completed, "{:?}", last.json);
    last.json.clone()
}

fn outputs(events: &[Recorded], kind: EventKind) -> Vec<(HostImage, Value)> {
    events
        .iter()
        .filter(|e| e.kind == kind)
        .map(|e| (e.image.clone().unwrap(), e.json.clone()))
        .collect()
}

fn request(json: Value, inputs: Vec<HostImage>) -> Request {
    Request::parse(json.to_string().as_bytes(), inputs).expect("valid request")
}

fn rgba(width: u32, height: u32, pixels: Vec<u8>) -> HostImage {
    HostImage {
        width,
        height,
        channels: 4,
        pixels,
    }
}

/// Straight RGBA: half-transparent red, then opaque blue. Over white: [255,127,127], [0,0,255].
fn translucent() -> HostImage {
    rgba(2, 1, vec![255, 0, 0, 128, 0, 0, 255, 255])
}

const OVER_WHITE: [u8; 6] = [255, 127, 127, 0, 0, 255];

fn transform_request() -> Request {
    request(
        json!({"version": 1, "task": "transform", "provider": TRANSFORM, "weights": {"dir": "/models/upscale"},
               "params": {"input": 0, "target": {"mode": "scale", "factor": 2.0}, "seed": 9, "strength": 0.25}}),
        vec![translucent()],
    )
}

fn caption_request(input: HostImage, extra: Value) -> Request {
    let mut params = json!({"input": 0, "caption_type": "Straightforward", "caption_length": "short", "max_new_tokens": 64, "seed": 3});
    params
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    request(
        json!({"version": 1, "task": "caption", "provider": CAPTIONER, "weights": {"dir": "/models/joycaption"}, "params": params}),
        vec![input],
    )
}

fn embed_image_request() -> Request {
    request(
        json!({"version": 1, "task": "embed_image", "provider": IMAGE_EMBEDDER, "weights": {"dir": "/models/clip"},
               "params": {"inputs": [0, 1]}}),
        vec![
            translucent(),
            HostImage {
                width: 1,
                height: 1,
                channels: 1,
                pixels: vec![42],
            },
        ],
    )
}

fn embed_text_request() -> Request {
    request(
        json!({"version": 1, "task": "embed_text", "provider": TEXT_EMBEDDER, "weights": {"dir": "/models/clip"},
               "params": {"texts": ["a", "three"]}}),
        vec![],
    )
}

fn sam2_request(h: &Harness) -> Request {
    request(
        json!({"version": 1, "task": "segment_sam2_box", "provider": "sam2", "weights": {"file": h.file("sam.safetensors")},
               "params": {"input": 0, "box_xyxy": [1.0, 0.0, 3.0, 2.0], "model_size": "small"}}),
        vec![rgba(4, 2, [255, 0, 0, 128].repeat(8))],
    )
}

fn sam3_request(h: &Harness, prompt_box: Option<[f32; 4]>) -> Request {
    let (task, params) = match prompt_box {
        None => (
            "segment_sam3_concept",
            json!({"input": 0, "concept": "dog", "threshold": 0.4}),
        ),
        Some(b) => (
            "segment_sam3_box",
            json!({"input": 0, "box_xyxy": b, "concept": "dog"}),
        ),
    };
    request(
        json!({"version": 1, "task": task, "provider": "sam3", "weights": {"file": h.file("sam.safetensors")},
               "tokenizer": h.file("tokenizer.json"), "load": {"quantize": "q8"}, "params": params}),
        vec![rgba(4, 4, [0, 0, 255, 255].repeat(16))],
    )
}

#[test]
fn transform_converts_rgba_over_white_and_maps_the_rgb_output() {
    let h = Harness::new();
    let events = finish(&h, transform_request());
    let result = completed(&events);
    let got = h.script.last();
    assert_eq!(got["image"]["pixels"], json!(OVER_WHITE));
    assert_eq!(
        (got["factor"].as_u64(), got["seed"].as_u64()),
        (Some(2), Some(9))
    );
    assert_eq!(got["strength"].as_f64(), Some(0.25));
    let images = outputs(&events, EventKind::Image);
    assert_eq!(images.len(), 1);
    let (image, meta) = &images[0];
    assert_eq!((image.width, image.height, image.channels), (4, 2, 3));
    assert_eq!(
        image.pixels,
        (0..24u32).map(|i| (i * 5 % 256) as u8).collect::<Vec<_>>()
    );
    assert_eq!(
        (meta["alpha"].as_str(), meta["color_space"].as_str()),
        (Some("none"), Some("srgb"))
    );
    assert_eq!(result["images"], 1);
    assert!(
        result["input_conversions"][0]
            .as_str()
            .unwrap()
            .contains("composited over white")
    );
    // An unsupported target is refused before loading.
    let refused = finish(
        &h,
        request(
            json!({"version": 1, "task": "transform", "provider": TRANSFORM, "weights": {"dir": "/m"},
                   "params": {"input": 0, "target": {"mode": "min_edge", "edge": 512}}}),
            vec![translucent()],
        ),
    );
    assert_eq!(refused.last().unwrap().json["kind"], "unsupported");
    assert_eq!(h.script.loads.load(Ordering::SeqCst), 1);
}

#[test]
fn caption_replicates_gray_maps_options_and_returns_the_text() {
    let h = Harness::new();
    let gray = HostImage {
        width: 2,
        height: 1,
        channels: 1,
        pixels: vec![10, 200],
    };
    let events = finish(&h, caption_request(gray, json!({})));
    let result = completed(&events);
    let got = h.script.last();
    assert_eq!(got["image"]["pixels"], json!([10, 10, 10, 200, 200, 200]));
    assert_eq!(got["prompt"], "", "the provider renders its own template");
    assert_eq!(
        (got["caption_type"].as_str(), got["caption_length"].as_str()),
        (Some("Straightforward"), Some("short"))
    );
    assert_eq!(
        (got["max_new_tokens"].as_u64(), got["seed"].as_u64()),
        (Some(64), Some(3))
    );
    assert_eq!(result["caption"], "a gray square");
    assert_eq!(result["generated_tokens"], 4);
    assert_eq!(result["finish_reason"], "stoptoken");
    assert!(
        result["input_conversions"][0]
            .as_str()
            .unwrap()
            .contains("gray8 replicated")
    );
    assert!(outputs(&events, EventKind::Image).is_empty());
}

#[test]
fn caption_requests_outside_the_shared_floor_are_refused_before_loading() {
    let h = Harness::new();
    // JoyCaption advertises images up to 8192 pixels.
    let wide = HostImage {
        width: 9000,
        height: 1,
        channels: 1,
        pixels: vec![0; 9000],
    };
    let events = finish(&h, caption_request(wide, json!({})));
    let last = events.last().unwrap();
    assert_eq!(last.json["kind"], "invalid_request", "{:?}", last.json);
    assert!(events.iter().all(|e| e.kind != EventKind::Started));
    assert_eq!(
        h.script.loads.load(Ordering::SeqCst),
        0,
        "no captioner loaded"
    );
}

#[test]
fn image_embeddings_convert_each_input_and_map_vectors_in_order() {
    let h = Harness::new();
    let events = finish(&h, embed_image_request());
    let result = completed(&events);
    let got = h.script.last();
    assert_eq!(got["images"][0]["pixels"], json!(OVER_WHITE));
    assert_eq!(got["images"][1]["pixels"], json!([42, 42, 42]));
    let embeddings = result["embeddings"].as_array().unwrap();
    assert_eq!(embeddings.len(), 2);
    assert_eq!(result["embedding_dim"], 768);
    assert_eq!(result["space"], "clip-vit-l14");
    assert_eq!(result["normalized"], false);
    assert_eq!(embeddings[0].as_array().unwrap().len(), 768);
    assert!(embeddings[0].as_array().unwrap().iter().all(|v| v == 255.0));
    assert!(embeddings[1].as_array().unwrap().iter().all(|v| v == 42.0));
    // A provider that breaks the advertised dimension is a typed engine failure.
    h.script.wrong_dim.store(true, Ordering::SeqCst);
    let events = finish(&h, embed_image_request());
    assert_eq!(events.last().unwrap().json["kind"], "engine");
}

#[test]
fn text_embeddings_map_one_vector_per_text() {
    let h = Harness::new();
    let events = finish(&h, embed_text_request());
    let result = completed(&events);
    assert_eq!(h.script.last()["texts"], json!(["a", "three"]));
    let embeddings = result["embeddings"].as_array().unwrap();
    assert_eq!(embeddings.len(), 2);
    assert!(embeddings[0].as_array().unwrap().iter().all(|v| v == 1.0));
    assert!(embeddings[1].as_array().unwrap().iter().all(|v| v == 5.0));
    assert_eq!(result["input_conversions"], json!([]));
}

#[test]
fn sam2_receives_rgb_and_the_box_and_returns_one_source_sized_mask() {
    let h = Harness::new();
    let events = finish(&h, sam2_request(&h));
    let result = completed(&events);
    let got = h.script.last();
    assert_eq!(got["box"], json!([1.0, 0.0, 3.0, 2.0]));
    assert_eq!(got["image"]["pixels"], json!([255, 127, 127].repeat(8)));
    let masks = outputs(&events, EventKind::Mask);
    assert_eq!(masks.len(), 1);
    let (mask, meta) = &masks[0];
    assert_eq!((mask.width, mask.height, mask.channels), (4, 2, 1));
    assert_eq!(mask.pixels, vec![0, 255, 255, 0, 0, 255, 255, 0]);
    assert_eq!(meta["coordinates"], "source pixels");
    assert_eq!(result["masks"], 1);
}

#[test]
fn sam3_concept_maps_every_instance_to_a_source_sized_mask() {
    let h = Harness::new();
    let events = finish(&h, sam3_request(&h, None));
    let result = completed(&events);
    let got = h.script.last();
    assert_eq!(got["concept"], "dog");
    assert_eq!(got["box"], Value::Null);
    assert!((got["threshold"].as_f64().unwrap() - 0.4).abs() < 1e-6);
    assert_eq!(
        got["mask_threshold"].as_f64(),
        Some(0.5),
        "default mask threshold"
    );
    let masks = outputs(&events, EventKind::Mask);
    assert_eq!(masks.len(), 2);
    for ((mask, meta), instance) in masks.iter().zip(sam3_instances()) {
        assert_eq!((mask.width, mask.height, mask.channels), (4, 4, 1));
        assert_eq!(
            mask.pixels,
            pixels::resize_binary_mask(&instance.grid, 2, 2, 4, 4)
        );
        assert!((meta["score"].as_f64().unwrap() - f64::from(instance.score)).abs() < 1e-6);
    }
    assert_eq!(masks[0].0.pixels[0], 255);
    assert_eq!(masks[0].0.pixels[15], 0);
    assert_eq!(masks[1].0.pixels[15], 255);
    assert_eq!(result["masks"], 2);
    assert_eq!(result["concept"], "dog");
}

#[test]
fn sam3_box_selects_the_instance_with_most_area_inside_the_box() {
    let h = Harness::new();
    let score = |events: &[Recorded]| {
        outputs(events, EventKind::Mask)[0].1["score"]
            .as_f64()
            .unwrap()
    };
    // The bottom half holds the second instance only.
    let events = finish(&h, sam3_request(&h, Some([0.0, 2.0, 4.0, 4.0])));
    completed(&events);
    assert_eq!(h.script.last()["box"], json!([0.0, 2.0, 4.0, 4.0]));
    assert_eq!(outputs(&events, EventKind::Mask).len(), 1);
    assert!((score(&events) - 0.7).abs() < 1e-6);
    // The top-left quadrant holds the first.
    let events = finish(&h, sam3_request(&h, Some([0.0, 0.0, 2.0, 2.0])));
    assert!((score(&events) - 0.9).abs() < 1e-6);
    // Both overlap the whole-image box; the second covers more of it (2 grid cells vs 1).
    let events = finish(&h, sam3_request(&h, Some([0.0, 0.0, 4.0, 4.0])));
    assert_eq!(outputs(&events, EventKind::Mask).len(), 1);
    assert!((score(&events) - 0.7).abs() < 1e-6);
    // Nothing in the top-right quadrant.
    let events = finish(&h, sam3_request(&h, Some([2.0, 0.0, 4.0, 2.0])));
    assert_eq!(events.last().unwrap().json["kind"], "no_result");
    assert!(outputs(&events, EventKind::Mask).is_empty());
}

#[test]
fn every_route_honours_a_cancel_during_its_forward_pass() {
    let h = Harness::new();
    let cases: Vec<(&str, Request)> = vec![
        ("transform", transform_request()),
        ("caption", caption_request(translucent(), json!({}))),
        ("embed_image", embed_image_request()),
        ("embed_text", embed_text_request()),
        ("segment_sam2_box", sam2_request(&h)),
        ("segment_sam3_concept", sam3_request(&h, None)),
        (
            "segment_sam3_box",
            sam3_request(&h, Some([0.0, 2.0, 4.0, 4.0])),
        ),
    ];
    for (task, request) in cases {
        let (entered, go) = h.gate();
        let (handle, log, rx) = run(&h, request);
        entered
            .recv_timeout(Duration::from_secs(30))
            .unwrap_or_else(|_| panic!("{task}: forward pass reached"));
        handle.cancel();
        go.send(()).unwrap();
        wait_terminal(&rx);
        let events = log.lock().unwrap().clone();
        let last = events.last().unwrap();
        assert_eq!(last.kind, EventKind::Cancelled, "{task}: {:?}", last.json);
        assert!(
            events
                .iter()
                .all(|e| e.image.is_none() && e.kind != EventKind::Completed),
            "{task}: a cancelled job delivers no output"
        );
        handle.release();
    }
}
