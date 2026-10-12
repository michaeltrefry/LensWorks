//! Executor-side task routes: registry providers (generators, transforms, captioners,
//! embedders) and the SAM2/SAM3 bespoke segmentation utilities.

use std::path::{Path, PathBuf};

use mlx_rs::{Array, Dtype};
use runtime_macos::gen_core::{
    self, CaptionOptions, CaptionRequest, CaptionSampling, Captioner, Conditioning, ControlKind,
    GenerationOutput, GenerationRequest, Generator, ImageEmbedder, LoadPhase, LoadSpec,
    OutputChannels, Progress, ProviderRegistry, Quant, TargetSize, TextEmbedder, Transform,
    TransformRequest, WeightsSource,
};
use runtime_macos::media::weights::Weights;
use runtime_macos::providers::sam2::{Sam2ModelSize, Sam2Segmenter};
use runtime_macos::providers::sam3::{Sam3ImageSegmenter, Sam3TextConfig, Sam3Tokenizer};
use serde_json::{Value, json};

use crate::capabilities::{self, INFERENCE_REVISION, Unsupported, unsupported_json};
use crate::job::{EventKind, Runner, Shared, failed_json};
use crate::pixels::{self, HostImage};
use crate::request::{
    ConditioningParam, ControlKindParam, Params, QuantChoice, Request, Residency, Sam2Size,
    TargetParam, WeightsRef,
};

/// A box-prompted still-image segmentation utility (SAM2). Host data in and out, so the
/// route's input conversion and output mapping do not depend on the MLX implementation.
pub trait Sam2Utility {
    /// The mask for `box_xyxy` (source pixels) over `image` (RGB at the source size): row-major
    /// `width * height` bytes.
    fn segment(&self, image: &gen_core::Image, box_xyxy: [f32; 4]) -> gen_core::Result<Vec<u8>>;
}

/// One SAM3 instance read back to the host: a mask-logit grid with its score and box.
#[derive(Clone, Debug, PartialEq)]
pub struct Sam3Instance {
    pub score: f32,
    pub box_xyxy: [f32; 4],
    /// Row-major `grid_width * grid_height` mask values; `> 0` is inside.
    pub grid: Vec<f32>,
    pub grid_width: usize,
    pub grid_height: usize,
}

/// The SAM3 open-vocabulary image segmenter with its tokenizer.
pub trait Sam3Utility {
    /// Every instance matching `concept` over `image` (RGB at the source size), optionally
    /// constrained by one positive box in source pixels.
    fn segment(
        &self,
        image: &gen_core::Image,
        concept: &str,
        prompt_box: Option<[f32; 4]>,
        threshold: f32,
        mask_threshold: f32,
    ) -> gen_core::Result<Vec<Sam3Instance>>;
}

/// Where providers come from. Production uses the validated runtime catalog and the bespoke
/// SAM utilities; tests substitute any loader while keeping the real registry descriptors.
pub trait ProviderSource {
    fn registry(&self) -> &ProviderRegistry;
    fn load_generator(&self, id: &str, spec: &LoadSpec) -> gen_core::Result<Box<dyn Generator>> {
        self.registry().load(id, spec)
    }
    fn load_transform(&self, id: &str, spec: &LoadSpec) -> gen_core::Result<Box<dyn Transform>> {
        self.registry().load_transform(id, spec)
    }
    fn load_captioner(&self, id: &str, spec: &LoadSpec) -> gen_core::Result<Box<dyn Captioner>> {
        self.registry().load_captioner(id, spec)
    }
    fn load_image_embedder(
        &self,
        id: &str,
        spec: &LoadSpec,
    ) -> gen_core::Result<Box<dyn ImageEmbedder>> {
        self.registry().load_image_embedder(id, spec)
    }
    fn load_text_embedder(
        &self,
        id: &str,
        spec: &LoadSpec,
    ) -> gen_core::Result<Box<dyn TextEmbedder>> {
        self.registry().load_text_embedder(id, spec)
    }
    fn load_sam2(&self, weights: &Path, size: Sam2Size) -> gen_core::Result<Box<dyn Sam2Utility>> {
        let size = match size {
            Sam2Size::Tiny => Sam2ModelSize::Tiny,
            Sam2Size::Small => Sam2ModelSize::Small,
            Sam2Size::BasePlus => Sam2ModelSize::BasePlus,
            Sam2Size::Large => Sam2ModelSize::Large,
        };
        let weights = read_weights(weights)?;
        Ok(Box::new(Sam2Segmenter::from_weights_for_size(
            &weights, size,
        )?))
    }
    fn load_sam3(
        &self,
        weights: &Path,
        tokenizer: &Path,
        quantize_bits: Option<i32>,
    ) -> gen_core::Result<Box<dyn Sam3Utility>> {
        let weights = read_weights(weights)?;
        let mut model = Sam3ImageSegmenter::from_weights(&weights)?;
        if let Some(bits) = quantize_bits {
            model.quantize(bits)?;
        }
        let tokenizer = Sam3Tokenizer::from_file(tokenizer, &Sam3TextConfig::sam3())?;
        Ok(Box::new(Sam3 { model, tokenizer }))
    }
}

pub struct CatalogProviders {
    catalog: runtime_macos::RuntimeCatalog,
}

impl CatalogProviders {
    pub fn new() -> Result<Self, String> {
        runtime_macos::catalog()
            .map(|catalog| Self { catalog })
            .map_err(|e| format!("the pinned inference runtime catalog failed validation: {e}"))
    }
}

impl ProviderSource for CatalogProviders {
    fn registry(&self) -> &ProviderRegistry {
        self.catalog.media()
    }
}

fn read_weights(path: &Path) -> gen_core::Result<Weights> {
    Weights::from_file(path)
        .and_then(|w| w.materialize().map(|()| w))
        .map_err(|e| gen_core::Error::Msg(format!("weights {}: {e}", path.display())))
}

fn readback(stage: &str, e: impl std::fmt::Display) -> gen_core::Error {
    gen_core::Error::Msg(format!("{stage}: {e}"))
}

impl Sam2Utility for Sam2Segmenter {
    fn segment(&self, image: &gen_core::Image, box_xyxy: [f32; 4]) -> gen_core::Result<Vec<u8>> {
        let mask =
            Sam2Segmenter::segment(self, &image.pixels, image.height, image.width, box_xyxy)?;
        let bytes = mask
            .as_dtype(Dtype::Uint8)
            .map_err(|e| readback("mask readback", e))?;
        Ok(bytes.as_slice::<u8>().to_vec())
    }
}

struct Sam3 {
    model: Sam3ImageSegmenter,
    tokenizer: Sam3Tokenizer,
}

const SAM3_INPUT: u32 = 1008;

fn sam3_pixels(image: &gen_core::Image) -> gen_core::Result<Array> {
    let buffer = image::RgbImage::from_raw(image.width, image.height, image.pixels.clone())
        .ok_or_else(|| gen_core::Error::Msg("sam3 input buffer".into()))?;
    let resized = image::imageops::resize(
        &buffer,
        SAM3_INPUT,
        SAM3_INPUT,
        image::imageops::FilterType::Triangle,
    );
    let plane = (SAM3_INPUT * SAM3_INPUT) as usize;
    let mut chw = vec![0f32; 3 * plane];
    for (i, px) in resized.as_raw().chunks_exact(3).enumerate() {
        for c in 0..3 {
            chw[c * plane + i] = f32::from(px[c]) / 127.5 - 1.0;
        }
    }
    Ok(Array::from_slice(
        &chw,
        &[1, 3, SAM3_INPUT as i32, SAM3_INPUT as i32],
    ))
}

impl Sam3Utility for Sam3 {
    fn segment(
        &self,
        image: &gen_core::Image,
        concept: &str,
        prompt_box: Option<[f32; 4]>,
        threshold: f32,
        mask_threshold: f32,
    ) -> gen_core::Result<Vec<Sam3Instance>> {
        let pixels = sam3_pixels(image)?;
        let (input_ids, text_mask) = self.tokenizer.encode(concept)?;
        let (fw, fh) = (image.width as f32, image.height as f32);
        let instances = match prompt_box {
            None => self.model.segment(
                &pixels,
                &input_ids,
                &text_mask,
                (fw, fh),
                threshold,
                mask_threshold,
            ),
            Some(b) => {
                let (x1, y1) = (b[0].clamp(0.0, fw), b[1].clamp(0.0, fh));
                let (x2, y2) = (b[2].clamp(0.0, fw), b[3].clamp(0.0, fh));
                let cxcywh = [
                    (x1 + x2) * 0.5 / fw,
                    (y1 + y2) * 0.5 / fh,
                    (x2 - x1) / fw,
                    (y2 - y1) / fh,
                ];
                let boxes = Array::from_slice(&cxcywh, &[1, 1, 4]);
                self.model.segment_with_boxes(
                    &pixels,
                    &input_ids,
                    &text_mask,
                    &boxes,
                    &[1],
                    (fw, fh),
                    threshold,
                    mask_threshold,
                )
            }
        }?;
        instances
            .iter()
            .map(|inst| {
                let shape = inst.mask.shape().to_vec();
                if shape.len() != 2 {
                    return Err(gen_core::Error::Msg(format!(
                        "sam3 mask has shape {shape:?}"
                    )));
                }
                let grid = inst
                    .mask
                    .as_dtype(Dtype::Float32)
                    .map_err(|e| readback("mask readback", e))?;
                Ok(Sam3Instance {
                    score: inst.score,
                    box_xyxy: inst.box_xyxy,
                    grid: grid.as_slice::<f32>().to_vec(),
                    grid_width: shape[1] as usize,
                    grid_height: shape[0] as usize,
                })
            })
            .collect()
    }
}

enum Loaded {
    Generator(Box<dyn Generator>),
    Transform(Box<dyn Transform>),
    Captioner(Box<dyn Captioner>),
    ImageEmbedder(Box<dyn ImageEmbedder>),
    TextEmbedder(Box<dyn TextEmbedder>),
    Sam2(Box<dyn Sam2Utility>),
    Sam3(Box<dyn Sam3Utility>),
}

pub struct State {
    providers: Box<dyn ProviderSource>,
    resident: Option<(String, Loaded)>,
}

pub struct InferenceRunner<F> {
    make: F,
}

impl<F> InferenceRunner<F>
where
    F: FnMut() -> Result<Box<dyn ProviderSource>, String> + Send + 'static,
{
    pub fn new(make: F) -> Self {
        Self { make }
    }
}

/// A typed job failure, mapped onto the `Failed` / `Cancelled` terminal events.
enum JobError {
    Cancelled,
    /// The request was refused before execution (unknown provider, unsupported control,
    /// out-of-range value). The resident model, if any, is untouched and stays loaded.
    Rejected(Value),
    /// Loading or execution failed; the provider may be inconsistent and is dropped.
    Failed(Value),
}

impl JobError {
    fn new(kind: &str, message: impl AsRef<str>) -> Self {
        JobError::Failed(failed_json(kind, message.as_ref()))
    }

    fn rejected(kind: &str, message: impl AsRef<str>) -> Self {
        JobError::Rejected(failed_json(kind, message.as_ref()))
    }

    fn unsupported(provider: &str, items: &[Unsupported]) -> Self {
        JobError::Rejected(unsupported_json(provider, items))
    }
}

/// A request-validation error from a capability floor or a provider's `validate`.
fn validation_error(error: gen_core::Error) -> JobError {
    match error {
        gen_core::Error::Canceled => JobError::Cancelled,
        gen_core::Error::Unsupported(m) => JobError::rejected("unsupported", m),
        other => JobError::rejected("invalid_request", other.to_string()),
    }
}

fn unknown_provider(kind: &str, id: &str) -> JobError {
    JobError::rejected(
        "unknown_provider",
        format!("no {kind} '{id}' is registered"),
    )
}

fn engine_error(stage: &str, error: impl Into<gen_core::Error>) -> JobError {
    match error.into() {
        gen_core::Error::Canceled => JobError::Cancelled,
        gen_core::Error::Unsupported(m) => JobError::new("unsupported", format!("{stage}: {m}")),
        gen_core::Error::GeometryRefused {
            reason,
            requested_width,
            requested_height,
            alternative,
        } => JobError::Failed(json!({
            "kind": "geometry_refused",
            "message": reason,
            "requested": [requested_width, requested_height],
            "alternative": alternative.map(|(w, h)| vec![w, h]),
        })),
        gen_core::Error::Io(e) => JobError::new(
            if stage == "load" { "load" } else { "io" },
            format!("{stage}: {e}"),
        ),
        gen_core::Error::MissingTensor(t) => {
            JobError::new("load", format!("{stage}: missing tensor {t}"))
        }
        other => JobError::new(
            if stage == "load" { "load" } else { "engine" },
            format!("{stage}: {other}"),
        ),
    }
}

fn check_cancel(job: &Shared) -> Result<(), JobError> {
    if job.is_cancelled() {
        Err(JobError::Cancelled)
    } else {
        Ok(())
    }
}

fn progress_json(p: Progress) -> Value {
    match p {
        Progress::Step { current, total } => {
            json!({"phase": "step", "current": current, "total": total})
        }
        Progress::Decoding => json!({"phase": "decoding"}),
        Progress::Loading(LoadPhase::TextEncoder) => {
            json!({"phase": "loading", "component": "text_encoder"})
        }
        Progress::Loading(LoadPhase::Renderer) => {
            json!({"phase": "loading", "component": "renderer"})
        }
    }
}

fn quant(q: Option<QuantChoice>) -> Option<Quant> {
    q.map(|q| match q {
        QuantChoice::Q4 => Quant::Q4,
        QuantChoice::Q8 => Quant::Q8,
    })
}

fn load_spec(request: &Request) -> LoadSpec {
    let weights = match request.weights.as_ref().expect("validated") {
        WeightsRef::Dir(p) => WeightsSource::Dir(p.clone()),
        WeightsRef::File(p) => WeightsSource::File(p.clone()),
    };
    let mut spec = LoadSpec::new(weights);
    if let Some(q) = quant(request.load.quantize) {
        spec = spec.with_quant(q);
    }
    spec
}

fn cache_key(request: &Request, kind: &str) -> String {
    format!(
        "{kind}\u{0}{}\u{0}{}\u{0}{:?}\u{0}{}",
        request.provider,
        request
            .weights
            .as_ref()
            .map(|w| w.path().display().to_string())
            .unwrap_or_default(),
        request.load.quantize,
        request
            .tokenizer
            .as_ref()
            .map(|t| t.display().to_string())
            .unwrap_or_default(),
    )
}

fn require_existing(path: &Path, label: &str) -> Result<(), JobError> {
    if path.exists() {
        Ok(())
    } else {
        Err(JobError::rejected(
            "load",
            format!("{label} {} does not exist", path.display()),
        ))
    }
}

impl State {
    /// Return the resident model for `key`, loading it (after dropping any other resident
    /// model) when absent. Returns whether the model was reused.
    fn ensure(
        &mut self,
        key: String,
        job: &Shared,
        load: impl FnOnce(&dyn ProviderSource) -> Result<Loaded, JobError>,
    ) -> Result<(bool, &Loaded), JobError> {
        let reused = matches!(&self.resident, Some((k, _)) if *k == key);
        if !reused {
            if self.resident.take().is_some() {
                mlx_rs::memory::clear_cache();
            }
            check_cancel(job)?;
            job.emit_json(EventKind::Progress, &json!({"phase": "load_model"}));
            let loaded = load(self.providers.as_ref())?;
            self.resident = Some((key, loaded));
        }
        Ok((reused, &self.resident.as_ref().expect("resident").1))
    }

    fn drop_resident(&mut self) -> usize {
        let had = self.resident.take().is_some();
        mlx_rs::memory::clear_cache();
        usize::from(had)
    }
}

impl<F> Runner for InferenceRunner<F>
where
    F: FnMut() -> Result<Box<dyn ProviderSource>, String> + Send + 'static,
{
    type State = State;

    fn init(&mut self) -> Result<State, String> {
        Ok(State {
            providers: (self.make)()?,
            resident: None,
        })
    }

    fn run(state: &mut State, request: Request, job: &Shared) {
        let residency = request.load.residency;
        let outcome = route(state, &request, job);
        // A load/execution failure may leave a provider inconsistent, so it is dropped; a
        // rejected request or a cooperative cancel leaves a healthy model that `keep_loaded` keeps.
        if residency == Residency::UnloadAfter || matches!(outcome, Err(JobError::Failed(_))) {
            state.drop_resident();
        }
        match outcome {
            // A cancel that arrives after the provider returned still wins: cancelled jobs
            // never deliver output.
            Ok(_) if job.is_cancelled() => {
                job.emit_json(EventKind::Cancelled, &json!({"stage": "after_run"}))
            }
            Ok((outputs, result)) => {
                for (kind, image, meta) in &outputs {
                    job.emit(*kind, &meta.to_string(), Some(image));
                }
                job.emit_json(EventKind::Completed, &result);
            }
            Err(JobError::Cancelled) => {
                job.emit_json(EventKind::Cancelled, &json!({"stage": "run"}))
            }
            Err(JobError::Failed(value) | JobError::Rejected(value)) => {
                job.emit_json(EventKind::Failed, &value)
            }
        }
    }

    fn release_models(state: &mut State) -> usize {
        state.drop_resident()
    }

    fn after_panic(state: &mut State) {
        state.drop_resident();
    }
}

type Outputs = Vec<(EventKind, HostImage, Value)>;

fn image_meta(index: usize, image: &HostImage) -> Value {
    json!({
        "index": index, "width": image.width, "height": image.height, "channels": image.channels,
        "row_bytes": image.row_bytes(), "alpha": if image.channels == 4 { "straight" } else { "none" }, "color_space": "srgb",
    })
}

fn provenance(request: &Request, reused: bool, conversions: Vec<String>) -> Value {
    json!({
        "task": request.task.name(),
        "provider": request.provider,
        "inference_revision": INFERENCE_REVISION,
        "weights": request.weights.as_ref().map(|w| w.path().display().to_string()),
        "quantize": request.load.quantize.map(|q| format!("{q:?}").to_lowercase()),
        "model_reused": reused,
        "input_conversions": conversions,
        "metallib": crate::metallib::resolve_once().describe(),
    })
}

/// Records how each input was converted for the provider, for result provenance.
fn rgb_input(image: &HostImage, label: String, conversions: &mut Vec<String>) -> gen_core::Image {
    match image.channels {
        4 => conversions.push(format!(
            "{label}: rgba8 straight composited over white to rgb8"
        )),
        1 => conversions.push(format!("{label}: gray8 replicated to rgb8")),
        _ => {}
    }
    image.to_rgb()
}

fn route(state: &mut State, request: &Request, job: &Shared) -> Result<(Outputs, Value), JobError> {
    check_cancel(job)?;
    match &request.params {
        Params::Generate(_) => generate(state, request, job),
        Params::Transform(_) => transform(state, request, job),
        Params::Caption(_) => caption(state, request, job),
        Params::EmbedImage(_) | Params::EmbedText(_) => embed(state, request, job),
        Params::Sam2Box(_) => sam2_box(state, request, job),
        Params::Sam3Concept(_) | Params::Sam3Box(_) => sam3(state, request, job),
    }
}

fn generate(
    state: &mut State,
    request: &Request,
    job: &Shared,
) -> Result<(Outputs, Value), JobError> {
    let Params::Generate(p) = &request.params else {
        unreachable!()
    };
    let descriptor = state
        .providers
        .registry()
        .generators()
        .map(|r| (r.descriptor)())
        .find(|d| d.id == request.provider)
        .ok_or_else(|| unknown_provider("generator", &request.provider))?;
    let unsupported = capabilities::check_generate(&descriptor, p, request.load.quantize);
    if !unsupported.is_empty() {
        return Err(JobError::unsupported(&request.provider, &unsupported));
    }
    let mut conversions = Vec::new();
    let mut conditioning = Vec::with_capacity(p.conditioning.len());
    for (n, cond) in p.conditioning.iter().enumerate() {
        let label = |i: usize| format!("conditioning[{n}] input {i}");
        conditioning.push(match cond {
            ConditioningParam::Reference { input, strength } => Conditioning::Reference {
                image: rgb_input(request.input(*input), label(*input), &mut conversions),
                strength: *strength,
            },
            ConditioningParam::ReferenceRgba { input, strength } => Conditioning::ReferenceRgba {
                image: request.input(*input).to_rgba(),
                strength: *strength,
            },
            ConditioningParam::MultiReference { inputs } => Conditioning::MultiReference {
                images: inputs
                    .iter()
                    .map(|i| rgb_input(request.input(*i), label(*i), &mut conversions))
                    .collect(),
            },
            ConditioningParam::ReduxRefs { inputs, weights } => Conditioning::ReduxRefs {
                refs: inputs
                    .iter()
                    .zip(weights)
                    .map(|(i, w)| {
                        (
                            rgb_input(request.input(*i), label(*i), &mut conversions),
                            *w,
                        )
                    })
                    .collect(),
            },
            ConditioningParam::Control {
                input,
                control,
                other,
                scale,
            } => Conditioning::Control {
                image: rgb_input(request.input(*input), label(*input), &mut conversions),
                kind: match control {
                    ControlKindParam::Pose => ControlKind::Pose,
                    ControlKindParam::Canny => ControlKind::Canny,
                    ControlKindParam::Depth => ControlKind::Depth,
                    ControlKindParam::Other => {
                        ControlKind::Other(other.clone().unwrap_or_default())
                    }
                },
                scale: *scale,
            },
            ConditioningParam::Depth { input } => Conditioning::Depth {
                image: rgb_input(request.input(*input), label(*input), &mut conversions),
            },
            ConditioningParam::Mask { input } => Conditioning::Mask {
                image: rgb_input(request.input(*input), label(*input), &mut conversions),
            },
        });
    }
    let req = GenerationRequest {
        prompt: p.prompt.clone(),
        negative_prompt: p.negative_prompt.clone(),
        width: p.width,
        height: p.height,
        count: p.count.unwrap_or(1),
        seed: p.seed,
        steps: p.steps,
        guidance: p.guidance,
        true_cfg: p.true_cfg,
        sampler: p.sampler.clone(),
        scheduler: p.scheduler.clone(),
        guidance_method: p.guidance_method.clone(),
        strength: p.strength,
        control_scale: p.control_scale,
        conditioning,
        output_channels: if p.alpha_output {
            OutputChannels::Rgba
        } else {
            OutputChannels::Rgb
        },
        cancel: job.cancel.clone(),
        ..Default::default()
    };
    // The advertised shared floor (size range and grid, counts, steps, finiteness, sampler /
    // scheduler membership, conditioning allowlist) is weights-free: refuse here, before any
    // weights load and without disturbing a resident model.
    descriptor
        .capabilities
        .validate_request(descriptor.id, &req)
        .map_err(validation_error)?;
    let spec = load_spec(request);
    let key = cache_key(request, "generate");
    let provider = request.provider.clone();
    let (reused, loaded) = state.ensure(key, job, |providers| {
        providers
            .load_generator(&provider, &spec)
            .map(Loaded::Generator)
            .map_err(|e| engine_error("load", e))
    })?;
    let Loaded::Generator(generator) = loaded else {
        unreachable!()
    };
    job.emit_json(
        EventKind::Started,
        &json!({"task": "generate", "provider": request.provider, "model_reused": reused}),
    );
    // The provider's own checks (anything beyond the shared floor).
    generator.validate(&req).map_err(validation_error)?;
    check_cancel(job)?;
    let output = generator
        .generate(&req, &mut |progress| {
            job.emit_json(EventKind::Progress, &progress_json(progress))
        })
        .map_err(|e| engine_error("generate", e))?;
    let images = match output {
        GenerationOutput::Images(images) => images
            .into_iter()
            .map(HostImage::from_rgb)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobError::new("engine", e))?,
        GenerationOutput::ImagesRgba(images) => images
            .into_iter()
            .map(HostImage::from_rgba)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| JobError::new("engine", e))?,
        GenerationOutput::Video { .. } => {
            return Err(JobError::new(
                "unsupported_output",
                "the provider returned video; LensWorks routes still images only",
            ));
        }
        GenerationOutput::Audio(_) => {
            return Err(JobError::new(
                "unsupported_output",
                "the provider returned audio; LensWorks routes still images only",
            ));
        }
    };
    let outputs: Outputs = images
        .into_iter()
        .enumerate()
        .map(|(i, image)| {
            let meta = image_meta(i, &image);
            (EventKind::Image, image, meta)
        })
        .collect();
    let mut result = provenance(request, reused, conversions);
    result["images"] = json!(outputs.len());
    result["params"] = json!({"prompt": p.prompt, "negative_prompt": p.negative_prompt, "width": p.width, "height": p.height,
        "count": req.count, "seed": p.seed, "steps": p.steps, "guidance": p.guidance, "strength": p.strength});
    Ok((outputs, result))
}

fn transform(
    state: &mut State,
    request: &Request,
    job: &Shared,
) -> Result<(Outputs, Value), JobError> {
    let Params::Transform(p) = &request.params else {
        unreachable!()
    };
    let descriptor = state
        .providers
        .registry()
        .transforms()
        .map(|r| (r.descriptor)())
        .find(|d| d.id == request.provider)
        .ok_or_else(|| unknown_provider("transform", &request.provider))?;
    // The transform contract advertises its targets and knobs only (no shared request floor),
    // so this capability check is the whole weights-free validation.
    let unsupported = capabilities::check_transform(&descriptor, p);
    if !unsupported.is_empty() {
        return Err(JobError::unsupported(&request.provider, &unsupported));
    }
    let mut conversions = Vec::new();
    let req = TransformRequest {
        image: rgb_input(
            request.input(p.input),
            format!("input {}", p.input),
            &mut conversions,
        ),
        target: match p.target {
            TargetParam::Scale { factor } => TargetSize::Scale(factor),
            TargetParam::MinEdge { edge } => TargetSize::MinEdge(edge),
            TargetParam::Resolution { width, height } => TargetSize::Resolution { width, height },
        },
        seed: p.seed,
        strength: p.strength,
        steps: p.steps,
        cancel: job.cancel.clone(),
    };
    let spec = load_spec(request);
    let provider = request.provider.clone();
    let (reused, loaded) = state.ensure(cache_key(request, "transform"), job, |providers| {
        providers
            .load_transform(&provider, &spec)
            .map(Loaded::Transform)
            .map_err(|e| engine_error("load", e))
    })?;
    let Loaded::Transform(t) = loaded else {
        unreachable!()
    };
    job.emit_json(
        EventKind::Started,
        &json!({"task": "transform", "provider": request.provider, "model_reused": reused}),
    );
    t.validate(&req).map_err(validation_error)?;
    check_cancel(job)?;
    let image = t
        .apply(&req, &mut |progress| {
            job.emit_json(EventKind::Progress, &progress_json(progress))
        })
        .map_err(|e| engine_error("transform", e))?;
    let image = HostImage::from_rgb(image).map_err(|e| JobError::new("engine", e))?;
    let meta = image_meta(0, &image);
    let mut result = provenance(request, reused, conversions);
    result["images"] = json!(1);
    Ok((vec![(EventKind::Image, image, meta)], result))
}

/// Stand-in for a provider-rendered caption prompt in the weights-free floor check: the
/// provider renders its template (from type/length/options) only after it loads.
const RENDERED_PROMPT_PROBE: &str = "caption";

fn caption(
    state: &mut State,
    request: &Request,
    job: &Shared,
) -> Result<(Outputs, Value), JobError> {
    let Params::Caption(p) = &request.params else {
        unreachable!()
    };
    let descriptor = state
        .providers
        .registry()
        .captioners()
        .map(|r| (r.descriptor)())
        .find(|d| d.id == request.provider)
        .ok_or_else(|| unknown_provider("captioner", &request.provider))?;
    let unsupported = capabilities::check_caption(&descriptor, p);
    if !unsupported.is_empty() {
        return Err(JobError::unsupported(&request.provider, &unsupported));
    }
    let defaults = CaptionOptions::default();
    let sampling_defaults = CaptionSampling::default();
    let input = request.input(p.input);
    let options = CaptionOptions {
        caption_type: p.caption_type.clone().unwrap_or(defaults.caption_type),
        caption_length: p.caption_length.clone().unwrap_or(defaults.caption_length),
        extra_options: p.extra_options.clone(),
        name_input: p.name_input.clone().unwrap_or_default(),
        custom_prompt: p.custom_prompt.clone().unwrap_or_default(),
        low_vram: p.low_vram,
    };
    let sampling = CaptionSampling {
        temperature: p.temperature.unwrap_or(sampling_defaults.temperature),
        top_p: p.top_p.unwrap_or(sampling_defaults.top_p),
        max_new_tokens: p.max_new_tokens.unwrap_or(sampling_defaults.max_new_tokens),
        seed: p.seed,
        repetition_penalty: p
            .repetition_penalty
            .unwrap_or(sampling_defaults.repetition_penalty),
        repetition_context: sampling_defaults.repetition_context,
    };
    // Empty: the provider renders its own template from the options (or the custom prompt).
    let prompt = p.custom_prompt.clone().unwrap_or_default();
    // The shared captioner floor reads only the image size, prompt, options and sampling, so a
    // pixel-free probe validates it before any weights load. The rendered template's length is
    // checked by the provider's own `validate` after loading.
    let probe = CaptionRequest {
        image: gen_core::Image {
            width: input.width,
            height: input.height,
            pixels: Vec::new(),
        },
        prompt: if prompt.trim().is_empty() {
            RENDERED_PROMPT_PROBE.into()
        } else {
            prompt.clone()
        },
        options: options.clone(),
        sampling,
        trigger_words: Vec::new(),
        cancel: job.cancel.clone(),
    };
    descriptor
        .capabilities
        .validate_request(descriptor.id, &probe)
        .map_err(validation_error)?;
    let mut conversions = Vec::new();
    let req = CaptionRequest {
        image: rgb_input(input, format!("input {}", p.input), &mut conversions),
        prompt,
        options,
        sampling,
        trigger_words: Vec::new(),
        cancel: job.cancel.clone(),
    };
    let spec = load_spec(request);
    let provider = request.provider.clone();
    let (reused, loaded) = state.ensure(cache_key(request, "caption"), job, |providers| {
        providers
            .load_captioner(&provider, &spec)
            .map(Loaded::Captioner)
            .map_err(|e| engine_error("load", e))
    })?;
    let Loaded::Captioner(c) = loaded else {
        unreachable!()
    };
    job.emit_json(
        EventKind::Started,
        &json!({"task": "caption", "provider": request.provider, "model_reused": reused}),
    );
    c.validate(&req).map_err(validation_error)?;
    check_cancel(job)?;
    let out = c
        .caption(&req, &mut |progress| {
            job.emit_json(EventKind::Progress, &progress_json(progress))
        })
        .map_err(|e| engine_error("caption", e))?;
    let mut result = provenance(request, reused, conversions);
    result["caption"] = json!(out.text);
    result["generated_tokens"] = json!(out.generated_tokens);
    result["finish_reason"] = json!(out.finish_reason.map(|r| format!("{r:?}").to_lowercase()));
    Ok((Vec::new(), result))
}

fn dense_only(request: &Request) -> Result<(), JobError> {
    if request.load.quantize.is_some() {
        return Err(JobError::unsupported(
            &request.provider,
            &[Unsupported {
                control: "quantize".into(),
                reason: "embedders load dense".into(),
            }],
        ));
    }
    Ok(())
}

fn embed(state: &mut State, request: &Request, job: &Shared) -> Result<(Outputs, Value), JobError> {
    let spec = load_spec(request);
    let provider = request.provider.clone();
    let registry = state.providers.registry();
    let (vectors, dim, space, conversions, reused) = match &request.params {
        Params::EmbedImage(p) => {
            let d = registry
                .image_embedders()
                .map(|r| (r.descriptor)())
                .find(|d| d.id == request.provider)
                .ok_or_else(|| unknown_provider("image embedder", &request.provider))?;
            dense_only(request)?;
            let mut conversions = Vec::new();
            let images: Vec<_> = p
                .inputs
                .iter()
                .map(|i| rgb_input(request.input(*i), format!("input {i}"), &mut conversions))
                .collect();
            let (reused, loaded) =
                state.ensure(cache_key(request, "embed_image"), job, |providers| {
                    providers
                        .load_image_embedder(&provider, &spec)
                        .map(Loaded::ImageEmbedder)
                        .map_err(|e| engine_error("load", e))
                })?;
            let Loaded::ImageEmbedder(e) = loaded else {
                unreachable!()
            };
            job.emit_json(
                EventKind::Started,
                &json!({"task": "embed_image", "provider": provider, "model_reused": reused}),
            );
            check_cancel(job)?;
            (
                e.embed_batch(&images)
                    .map_err(|e| engine_error("embed", e))?,
                d.embedding_dim,
                d.space,
                conversions,
                reused,
            )
        }
        Params::EmbedText(p) => {
            let d = registry
                .text_embedders()
                .map(|r| (r.descriptor)())
                .find(|d| d.id == request.provider)
                .ok_or_else(|| unknown_provider("text embedder", &request.provider))?;
            dense_only(request)?;
            let (reused, loaded) =
                state.ensure(cache_key(request, "embed_text"), job, |providers| {
                    providers
                        .load_text_embedder(&provider, &spec)
                        .map(Loaded::TextEmbedder)
                        .map_err(|e| engine_error("load", e))
                })?;
            let Loaded::TextEmbedder(e) = loaded else {
                unreachable!()
            };
            job.emit_json(
                EventKind::Started,
                &json!({"task": "embed_text", "provider": provider, "model_reused": reused}),
            );
            check_cancel(job)?;
            let texts: Vec<&str> = p.texts.iter().map(String::as_str).collect();
            (
                e.embed_text_batch(&texts)
                    .map_err(|e| engine_error("embed", e))?,
                d.embedding_dim,
                d.space,
                Vec::new(),
                reused,
            )
        }
        _ => unreachable!(),
    };
    let expected = match &request.params {
        Params::EmbedImage(p) => p.inputs.len(),
        Params::EmbedText(p) => p.texts.len(),
        _ => unreachable!(),
    };
    if vectors.len() != expected
        || vectors
            .iter()
            .any(|v| v.len() != dim || v.iter().any(|x| !x.is_finite()))
    {
        return Err(JobError::new(
            "engine",
            format!("embedder returned vectors that are not {expected} finite {dim}-d vectors"),
        ));
    }
    let mut result = provenance(request, reused, conversions);
    result["space"] = json!(space);
    result["embedding_dim"] = json!(dim);
    result["normalized"] = json!(false);
    result["embeddings"] = json!(vectors);
    Ok((Vec::new(), result))
}

fn weights_file(request: &Request) -> Result<PathBuf, JobError> {
    match request.weights.as_ref().expect("validated") {
        WeightsRef::File(p) => {
            require_existing(p, "weights")?;
            Ok(p.clone())
        }
        WeightsRef::Dir(_) => Err(JobError::rejected(
            "invalid_request",
            format!("{} takes a single weights file", request.task.name()),
        )),
    }
}

fn sam2_box(
    state: &mut State,
    request: &Request,
    job: &Shared,
) -> Result<(Outputs, Value), JobError> {
    let Params::Sam2Box(p) = &request.params else {
        unreachable!()
    };
    if request.provider != "sam2" {
        return Err(JobError::rejected(
            "unknown_provider",
            "segment_sam2_box uses provider 'sam2'",
        ));
    }
    if request.load.quantize.is_some() {
        return Err(JobError::unsupported(
            "sam2",
            &[Unsupported {
                control: "quantize".into(),
                reason: "the SAM2 utility loads dense".into(),
            }],
        ));
    }
    let file = weights_file(request)?;
    let key = format!("{}\u{0}{:?}", cache_key(request, "sam2"), p.model_size);
    let size = p.model_size;
    let (reused, loaded) = state.ensure(key, job, |providers| {
        providers
            .load_sam2(&file, size)
            .map(Loaded::Sam2)
            .map_err(|e| engine_error("load", e))
    })?;
    let Loaded::Sam2(segmenter) = loaded else {
        unreachable!()
    };
    job.emit_json(
        EventKind::Started,
        &json!({"task": "segment_sam2_box", "provider": "sam2", "model_reused": reused}),
    );
    check_cancel(job)?;
    let image = request.input(p.input);
    let mut conversions = Vec::new();
    let rgb = rgb_input(image, format!("input {}", p.input), &mut conversions);
    let bytes = segmenter
        .segment(&rgb, p.box_xyxy)
        .map_err(|e| engine_error("segment", e))?;
    check_cancel(job)?;
    let mask = HostImage::mask(image.width, image.height, bytes)
        .map_err(|e| JobError::new("engine", e))?;
    let meta = json!({"index": 0, "width": mask.width, "height": mask.height, "channels": 1, "row_bytes": mask.row_bytes(),
                      "values": "0 or 255", "coordinates": "source pixels", "box_xyxy": p.box_xyxy});
    let mut result = provenance(request, reused, conversions);
    result["masks"] = json!(1);
    Ok((vec![(EventKind::Mask, mask, meta)], result))
}

/// Number of grid cells of `m` that are inside the mask and inside the normalised box.
fn mask_area_in_box(m: &Sam3Instance, b: [f32; 4], w: u32, h: u32) -> usize {
    let (nx1, ny1, nx2, ny2) = (
        b[0] / w as f32,
        b[1] / h as f32,
        b[2] / w as f32,
        b[3] / h as f32,
    );
    let (gw, gh) = (m.grid_width, m.grid_height);
    (0..gw * gh)
        .filter(|&i| {
            let (cx, cy) = (
                ((i % gw) as f32 + 0.5) / gw as f32,
                ((i / gw) as f32 + 0.5) / gh as f32,
            );
            m.grid[i] > 0.0 && cx >= nx1 && cx < nx2 && cy >= ny1 && cy < ny2
        })
        .count()
}

fn sam3(state: &mut State, request: &Request, job: &Shared) -> Result<(Outputs, Value), JobError> {
    if request.provider != "sam3" {
        return Err(JobError::rejected(
            "unknown_provider",
            format!("{} uses provider 'sam3'", request.task.name()),
        ));
    }
    let file = weights_file(request)?;
    let tokenizer_path = request.tokenizer.clone().expect("validated");
    require_existing(&tokenizer_path, "tokenizer")?;
    let bits = request
        .load
        .quantize
        .map(|q| if q == QuantChoice::Q4 { 4 } else { 8 });
    let (reused, loaded) = state.ensure(cache_key(request, "sam3"), job, |providers| {
        providers
            .load_sam3(&file, &tokenizer_path, bits)
            .map(Loaded::Sam3)
            .map_err(|e| engine_error("load", e))
    })?;
    let Loaded::Sam3(model) = loaded else {
        unreachable!()
    };
    job.emit_json(
        EventKind::Started,
        &json!({"task": request.task.name(), "provider": "sam3", "model_reused": reused}),
    );
    let (input_index, concept, threshold, mask_threshold, prompt_box) = match &request.params {
        Params::Sam3Concept(p) => (
            p.input,
            p.concept.clone(),
            p.threshold,
            p.mask_threshold,
            None,
        ),
        Params::Sam3Box(p) => (
            p.input,
            p.concept.clone().unwrap_or_default(),
            p.threshold,
            p.mask_threshold,
            Some(p.box_xyxy),
        ),
        _ => unreachable!(),
    };
    let image = request.input(input_index);
    let (w, h) = (image.width, image.height);
    let mut conversions = Vec::new();
    let rgb = rgb_input(image, format!("input {input_index}"), &mut conversions);
    check_cancel(job)?;
    let instances = model
        .segment(
            &rgb,
            &concept,
            prompt_box,
            threshold.unwrap_or(0.5),
            mask_threshold.unwrap_or(0.5),
        )
        .map_err(|e| engine_error("segment", e))?;
    check_cancel(job)?;
    if let Some(bad) = instances.iter().find(|m| {
        m.grid_width == 0 || m.grid_height == 0 || m.grid.len() != m.grid_width * m.grid_height
    }) {
        return Err(JobError::new(
            "engine",
            format!(
                "sam3 returned a {}x{} mask grid with {} values",
                bad.grid_width,
                bad.grid_height,
                bad.grid.len()
            ),
        ));
    }
    let selected: Vec<Sam3Instance> = match prompt_box {
        None => instances,
        Some(b) => {
            // As SceneWorks' smart select: the instance with the most mask area inside the box.
            let best = instances
                .into_iter()
                .map(|m| (mask_area_in_box(&m, b, w, h), m))
                .filter(|(n, _)| *n > 0)
                .max_by_key(|(n, _)| *n);
            match best {
                Some((_, m)) => vec![m],
                None => {
                    return Err(JobError::new(
                        "no_result",
                        "SAM3 found no object in the selection box",
                    ));
                }
            }
        }
    };
    let outputs: Outputs = selected
        .into_iter()
        .enumerate()
        .map(|(i, m)| {
            let mask = HostImage { width: w, height: h, channels: 1, pixels: pixels::resize_binary_mask(&m.grid, m.grid_width, m.grid_height, w, h) };
            let meta = json!({"index": i, "width": w, "height": h, "channels": 1, "row_bytes": w, "values": "0 or 255",
                              "coordinates": "source pixels", "score": m.score, "box_xyxy": m.box_xyxy});
            (EventKind::Mask, mask, meta)
        })
        .collect();
    let mut result = provenance(request, reused, conversions);
    result["masks"] = json!(outputs.len());
    result["concept"] = json!(concept);
    Ok((outputs, result))
}
