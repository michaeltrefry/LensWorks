//! Weights-free capability and unsupported-control reporting.
//!
//! Every provider registered by the pinned runtime bundle appears with an explicit adapter
//! route (`supported` or `unsupported` with a reason). Each control the adapter exposes is
//! reported as supported (with its constraints) or unsupported (with a reason) per provider;
//! the same rules gate requests on the executor, so a request never silently drops a control
//! the engine cannot honour.

use runtime_macos::gen_core::{
    CaptionerDescriptor, ConditioningKind, ImageEmbedderDescriptor, Modality, ModelDescriptor,
    ProviderRegistry, Quant, StepSupport, TextEmbedderDescriptor, TransformDescriptor,
};
use serde_json::{Map, Value, json};

use crate::request::{
    CaptionParams, ConditioningParam, GenerateParams, QuantChoice, TargetParam, TransformParams,
};

pub const INFERENCE_REVISION: &str = "25bd55cdb6a56c78b07584a12150c9f5d46be439";
pub const ABI_VERSION: u32 = 1;

/// Conditioning kinds this adapter can carry (still-image inputs).
const ROUTED_CONDITIONING: &[&str] = &[
    "reference",
    "reference_rgba",
    "multi_reference",
    "redux_refs",
    "control",
    "depth",
    "mask",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Unsupported {
    pub control: String,
    pub reason: String,
}

impl Unsupported {
    fn new(control: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            control: control.into(),
            reason: reason.into(),
        }
    }
}

pub fn unsupported_json(provider: &str, items: &[Unsupported]) -> Value {
    json!({
        "kind": "unsupported",
        "message": format!("{provider} cannot honour: {}", items.iter().map(|u| u.control.as_str()).collect::<Vec<_>>().join(", ")),
        "unsupported": items.iter().map(|u| json!({"control": u.control, "reason": u.reason})).collect::<Vec<_>>(),
    })
}

fn snake(name: &str) -> String {
    let mut out = String::new();
    for (i, ch) in name.chars().enumerate() {
        if ch.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn conditioning_name(kind: ConditioningKind) -> String {
    snake(&format!("{kind:?}"))
}

fn modality_name(m: Modality) -> &'static str {
    match m {
        Modality::Image => "image",
        Modality::Video => "video",
        Modality::Both => "image_and_video",
        Modality::Audio => "audio",
    }
}

fn quant_name(q: Quant) -> String {
    snake(&format!("{q:?}"))
}

fn quant_supported(d: &ModelDescriptor, q: QuantChoice) -> bool {
    let want = match q {
        QuantChoice::Q4 => Quant::Q4,
        QuantChoice::Q8 => Quant::Q8,
    };
    d.capabilities.supported_quants.contains(&want)
}

/// `Some(reason)` when the adapter has no route for this generator at all.
pub fn generator_route_unsupported(d: &ModelDescriptor) -> Option<String> {
    match d.modality {
        Modality::Image | Modality::Both => None,
        Modality::Video => Some("video output is not a LensWorks still-image route".into()),
        Modality::Audio => Some("audio output is not a LensWorks still-image route".into()),
    }
}

fn model_conditioning(d: &ModelDescriptor) -> Vec<String> {
    d.capabilities
        .conditioning
        .iter()
        .map(|k| conditioning_name(*k))
        .collect()
}

fn has_reference(d: &ModelDescriptor) -> bool {
    let kinds = model_conditioning(d);
    kinds
        .iter()
        .any(|k| k == "reference" || k == "reference_rgba")
}

fn support(ok: bool, constraints: Value, reason: &str) -> Value {
    if ok {
        let mut m = Map::new();
        m.insert("supported".into(), Value::Bool(true));
        if let Value::Object(c) = constraints {
            m.extend(c);
        }
        Value::Object(m)
    } else {
        json!({"supported": false, "reason": reason})
    }
}

pub fn generator_entry(d: &ModelDescriptor) -> Value {
    let c = &d.capabilities;
    let route = generator_route_unsupported(d);
    let steps = match &c.supported_steps {
        StepSupport::Unconstrained => json!({}),
        StepSupport::Exact(v) => json!({"exact": v}),
        StepSupport::Range { min, max } => json!({"min": min, "max": max}),
    };
    let kinds = model_conditioning(d);
    let mut controls = Map::new();
    controls.insert("prompt".into(), json!({"supported": true}));
    controls.insert(
        "size".into(),
        json!({"supported": true, "min": c.min_size, "max": c.max_size, "rule": format!("{:?}", c.size_floor)}),
    );
    controls.insert(
        "count".into(),
        json!({"supported": true, "max": c.max_count}),
    );
    controls.insert("seed".into(), json!({"supported": true}));
    controls.insert("steps".into(), support(true, steps, ""));
    controls.insert(
        "negative_prompt".into(),
        support(
            c.supports_negative_prompt,
            json!({}),
            "the model has no negative prompt",
        ),
    );
    controls.insert(
        "guidance".into(),
        support(
            c.supports_guidance,
            json!({}),
            "the model takes no guidance scale",
        ),
    );
    controls.insert(
        "true_cfg".into(),
        support(
            c.supports_true_cfg,
            json!({}),
            "the model has no true-CFG path",
        ),
    );
    controls.insert(
        "sampler".into(),
        support(
            !c.samplers.is_empty(),
            json!({"values": c.samplers}),
            "the model has a fixed sampler",
        ),
    );
    controls.insert(
        "scheduler".into(),
        support(
            !c.schedulers.is_empty(),
            json!({"values": c.schedulers}),
            "the model has a fixed scheduler",
        ),
    );
    controls.insert(
        "guidance_method".into(),
        support(
            !c.supported_guidance_methods.is_empty(),
            json!({"values": c.supported_guidance_methods}),
            "the model has a fixed guidance method",
        ),
    );
    controls.insert(
        "strength".into(),
        support(
            has_reference(d),
            json!({}),
            "the model has no reference-image (image-to-image) conditioning",
        ),
    );
    controls.insert(
        "control_scale".into(),
        support(
            kinds.iter().any(|k| k == "control"),
            json!({}),
            "the model has no control-image conditioning",
        ),
    );
    controls.insert(
        "alpha_output".into(),
        support(
            c.supports_alpha_output,
            json!({}),
            "the model emits RGB only",
        ),
    );
    let quants: Vec<String> = c
        .supported_quants
        .iter()
        .copied()
        .filter(|q| matches!(q, Quant::Q4 | Quant::Q8))
        .map(quant_name)
        .collect();
    controls.insert(
        "quantize".into(),
        support(
            !quants.is_empty(),
            json!({"values": quants}),
            "the model offers no load-time quantization",
        ),
    );
    // Engine features the adapter deliberately does not carry across this ABI.
    for (name, engine_has) in [
        ("lora", c.supports_lora || c.supports_lokr),
        ("preview", c.supports_preview),
        ("hdr", c.supports_hdr),
        ("prompt_enhancement", c.supports_prompt_enhancement),
    ] {
        let reason = if engine_has {
            "supported by the engine but not routed by this adapter version"
        } else {
            "not supported by the model"
        };
        controls.insert(name.into(), json!({"supported": false, "reason": reason}));
    }
    let conditioning_supported: Vec<&String> = kinds
        .iter()
        .filter(|k| ROUTED_CONDITIONING.contains(&k.as_str()))
        .collect();
    let conditioning_unsupported: Vec<Value> = kinds
        .iter()
        .filter(|k| !ROUTED_CONDITIONING.contains(&k.as_str()))
        .map(|k| json!({"kind": k, "reason": "non-still-image conditioning is not routed by this adapter"}))
        .collect();
    json!({
        "id": d.id,
        "family": d.family,
        "backend": d.backend,
        "modality": modality_name(d.modality),
        "route": if route.is_some() { "unsupported" } else { "supported" },
        "reason": route,
        "outputs": if c.supports_alpha_output { json!(["rgb8", "rgba8_straight"]) } else { json!(["rgb8"]) },
        "color_space": "srgb",
        "required_components": d.required_components,
        "mac_only": c.mac_only,
        "controls": controls,
        "conditioning": {"supported": conditioning_supported, "unsupported": conditioning_unsupported},
    })
}

/// Unsupported controls/values in a generate request. Empty means the adapter will pass the
/// request to the provider (whose own `validate` still applies).
pub fn check_generate(
    d: &ModelDescriptor,
    p: &GenerateParams,
    quantize: Option<QuantChoice>,
) -> Vec<Unsupported> {
    let c = &d.capabilities;
    let mut out = Vec::new();
    if let Some(reason) = generator_route_unsupported(d) {
        out.push(Unsupported::new("route", reason));
        return out;
    }
    let mut flag = |present: bool, ok: bool, name: &str, reason: &str| {
        if present && !ok {
            out.push(Unsupported::new(name, reason));
        }
    };
    flag(
        p.negative_prompt.is_some(),
        c.supports_negative_prompt,
        "negative_prompt",
        "the model has no negative prompt",
    );
    flag(
        p.guidance.is_some(),
        c.supports_guidance,
        "guidance",
        "the model takes no guidance scale",
    );
    flag(
        p.true_cfg.is_some(),
        c.supports_true_cfg,
        "true_cfg",
        "the model has no true-CFG path",
    );
    flag(
        p.strength.is_some(),
        has_reference(d),
        "strength",
        "the model has no reference-image conditioning",
    );
    let kinds = model_conditioning(d);
    flag(
        p.control_scale.is_some(),
        kinds.iter().any(|k| k == "control"),
        "control_scale",
        "the model has no control-image conditioning",
    );
    flag(
        p.alpha_output,
        c.supports_alpha_output,
        "alpha_output",
        "the model emits RGB only",
    );
    for (name, value, allowed) in [
        ("sampler", &p.sampler, &c.samplers),
        ("scheduler", &p.scheduler, &c.schedulers),
        (
            "guidance_method",
            &p.guidance_method,
            &c.supported_guidance_methods,
        ),
    ] {
        if let Some(v) = value {
            if allowed.is_empty() {
                out.push(Unsupported::new(
                    name,
                    format!("the model has a fixed {name}"),
                ));
            } else if !allowed.contains(&v.as_str()) {
                out.push(Unsupported::new(
                    name,
                    format!("'{v}' is not one of {allowed:?}"),
                ));
            }
        }
    }
    if let Some(steps) = p.steps
        && !c.supported_steps.admits(steps)
    {
        out.push(Unsupported::new(
            "steps",
            format!("{steps} steps are not admitted ({:?})", c.supported_steps),
        ));
    }
    if let Some(count) = p.count
        && (count == 0 || count > c.max_count)
    {
        out.push(Unsupported::new(
            "count",
            format!("count must be 1..={}", c.max_count),
        ));
    }
    for cond in &p.conditioning {
        let name = cond.name();
        if !kinds.iter().any(|k| k == name) {
            out.push(Unsupported::new(
                format!("conditioning.{name}"),
                "the model does not accept this conditioning",
            ));
        }
        if let ConditioningParam::Reference {
            strength: Some(_), ..
        }
        | ConditioningParam::ReferenceRgba {
            strength: Some(_), ..
        } = cond
            && !has_reference(d)
        {
            out.push(Unsupported::new(
                format!("conditioning.{name}.strength"),
                "the model has no reference conditioning",
            ));
        }
    }
    if let Some(q) = quantize
        && !quant_supported(d, q)
    {
        out.push(Unsupported::new(
            "quantize",
            "the model offers no such load-time quantization",
        ));
    }
    out
}

pub fn transform_entry(d: &TransformDescriptor) -> Value {
    let c = &d.capabilities;
    json!({
        "id": d.id, "family": d.family, "backend": d.backend, "route": "supported",
        "outputs": ["rgb8"], "color_space": "srgb", "mac_only": c.mac_only,
        "controls": {
            "target.scale": support(c.scale, json!({"max": c.max_scale}), "the transform has no scale-factor target"),
            "target.min_edge": support(c.min_edge, json!({}), "the transform has no min-edge target"),
            "target.resolution": support(c.resolution, json!({}), "the transform has no explicit-resolution target"),
            "seed": support(c.is_diffusion, json!({}), "the transform is deterministic"),
            "steps": support(c.is_diffusion, json!({}), "the transform is deterministic"),
            "strength": support(c.supports_strength, json!({}), "the transform has no strength knob"),
        }
    })
}

pub fn check_transform(d: &TransformDescriptor, p: &TransformParams) -> Vec<Unsupported> {
    let c = &d.capabilities;
    let mut out = Vec::new();
    match p.target {
        TargetParam::Scale { factor } if !c.scale || factor > c.max_scale => {
            out.push(Unsupported::new(
                "target.scale",
                format!("scale targets up to {} only", c.max_scale),
            ))
        }
        TargetParam::MinEdge { .. } if !c.min_edge => {
            out.push(Unsupported::new("target.min_edge", "no min-edge target"))
        }
        TargetParam::Resolution { .. } if !c.resolution => out.push(Unsupported::new(
            "target.resolution",
            "no explicit-resolution target",
        )),
        _ => {}
    }
    if (p.seed.is_some() || p.steps.is_some()) && !c.is_diffusion {
        out.push(Unsupported::new(
            "seed/steps",
            "the transform is deterministic",
        ));
    }
    if p.strength.is_some() && !c.supports_strength {
        out.push(Unsupported::new(
            "strength",
            "the transform has no strength knob",
        ));
    }
    out
}

pub fn captioner_entry(d: &CaptionerDescriptor) -> Value {
    let c = &d.capabilities;
    json!({
        "id": d.id, "family": d.family, "backend": d.backend, "route": "supported",
        "input": "rgb8 (RGBA is composited over white)", "mac_only": c.mac_only,
        "controls": {
            "caption_type": {"supported": !c.caption_types.is_empty(), "values": c.caption_types},
            "caption_length": {"supported": !c.caption_lengths.is_empty(), "values": c.caption_lengths},
            "custom_prompt": support(c.supports_custom_prompt, json!({"max_chars": c.max_prompt_chars}), "the captioner has no custom prompt"),
            "low_vram": support(c.supports_low_vram, json!({}), "the captioner has no low-memory mode"),
            "extra_options": {"supported": c.max_extra_options > 0, "max": c.max_extra_options, "max_chars": c.max_extra_option_chars},
            "name_input": {"supported": c.max_name_chars > 0, "max_chars": c.max_name_chars},
            "image_size": {"supported": true, "min": c.min_image_size, "max": c.max_image_size},
            "max_new_tokens": {"supported": true, "max": c.max_new_tokens},
            "sampling": {"supported": true, "fields": ["temperature", "top_p", "seed", "repetition_penalty"]},
            "trigger_words": {"supported": false, "reason": "raw captions only; trigger words are a dataset concern"},
        }
    })
}

pub fn check_caption(d: &CaptionerDescriptor, p: &CaptionParams) -> Vec<Unsupported> {
    let c = &d.capabilities;
    let mut out = Vec::new();
    if let Some(t) = &p.caption_type
        && !c.caption_types.contains(&t.as_str())
    {
        out.push(Unsupported::new(
            "caption_type",
            format!("'{t}' is not one of {:?}", c.caption_types),
        ));
    }
    if let Some(l) = &p.caption_length
        && !c.caption_lengths.contains(&l.as_str())
    {
        out.push(Unsupported::new(
            "caption_length",
            format!("'{l}' is not one of {:?}", c.caption_lengths),
        ));
    }
    if p.custom_prompt.is_some() && !c.supports_custom_prompt {
        out.push(Unsupported::new(
            "custom_prompt",
            "the captioner has no custom prompt",
        ));
    }
    if p.low_vram && !c.supports_low_vram {
        out.push(Unsupported::new(
            "low_vram",
            "the captioner has no low-memory mode",
        ));
    }
    if p.extra_options.len() > c.max_extra_options {
        out.push(Unsupported::new(
            "extra_options",
            format!("at most {} extra options", c.max_extra_options),
        ));
    }
    if let Some(n) = p.max_new_tokens
        && n > c.max_new_tokens
    {
        out.push(Unsupported::new(
            "max_new_tokens",
            format!("at most {}", c.max_new_tokens),
        ));
    }
    out
}

pub fn image_embedder_entry(d: &ImageEmbedderDescriptor) -> Value {
    json!({"id": d.id, "family": d.family, "backend": d.backend, "route": "supported", "embedding_dim": d.embedding_dim,
           "space": d.space, "normalized": false, "input": "rgb8 (RGBA is composited over white)", "batch": true, "mac_only": d.mac_only})
}

pub fn text_embedder_entry(d: &TextEmbedderDescriptor) -> Value {
    json!({"id": d.id, "family": d.family, "backend": d.backend, "route": "supported", "embedding_dim": d.embedding_dim,
           "space": d.space, "normalized": false, "batch": true, "mac_only": d.mac_only})
}

/// Bespoke segmentation utilities the adapter routes (they are not registry providers).
pub fn segmentation_entries() -> Value {
    json!([
        {
            "id": "sam2", "task": "segment_sam2_box", "utility": "mlx-gen-sam2 Sam2Segmenter", "route": "supported",
            "weights": "file: a SAM 2.1 hiera safetensors checkpoint", "prompt": "one box in source pixels",
            "controls": {"box_xyxy": {"supported": true}, "model_size": {"supported": true, "values": ["tiny", "small", "base_plus", "large"]},
                         "points": {"supported": false, "reason": "the SAM2 still-image utility exposes box prompts only"}},
            "output": "one mask8 (0/255) at the source size", "cancellation": "before load, before and after the forward pass"
        },
        {
            "id": "sam3", "task": "segment_sam3_concept", "utility": "mlx-gen-sam3 Sam3ImageSegmenter::segment", "route": "supported",
            "weights": "file: facebook/sam3 model.safetensors, plus tokenizer.json", "prompt": "open-vocabulary text concept",
            "controls": {"concept": {"supported": true}, "threshold": {"supported": true, "default": 0.5}, "mask_threshold": {"supported": true, "default": 0.5}},
            "output": "every detected instance as mask8 at the source size with score and box", "cancellation": "before load, before and after the forward pass"
        },
        {
            "id": "sam3", "task": "segment_sam3_box", "utility": "mlx-gen-sam3 Sam3ImageSegmenter::segment_with_boxes", "route": "supported",
            "weights": "file: facebook/sam3 model.safetensors, plus tokenizer.json", "prompt": "one positive box, optional text concept",
            "controls": {"box_xyxy": {"supported": true}, "concept": {"supported": true}, "threshold": {"supported": true, "default": 0.5}, "mask_threshold": {"supported": true, "default": 0.5},
                         "points": {"supported": false, "reason": "point prompts need the SAM3 tracker, which this adapter version does not route"}},
            "output": "the instance with most mask area inside the box, as mask8 at the source size", "cancellation": "before load, before and after the forward pass"
        }
    ])
}

/// The runtime's own checkpoint licence table (families and component rows, the shared
/// `gen_core` surface every media catalog reads), so the native model store validates and shows
/// licence terms from the pinned runtime instead of a hand-maintained copy. Provider mappings are
/// not re-exported by the bundle, so model components name their licence rows explicitly.
pub fn model_licenses() -> Value {
    let manifest = runtime_macos::gen_core::component_licenses_manifest_json(
        runtime_macos::gen_core::LICENSE_FAMILIES,
        runtime_macos::gen_core::MEDIA_COMPONENT_LICENSES,
        &[],
    );
    let mut value: Value = serde_json::from_str(&manifest).expect("licence manifest is JSON");
    let object = value
        .as_object_mut()
        .expect("licence manifest is an object");
    object.remove("providers");
    value
}

/// The full weights-free capability document.
pub fn capabilities(
    registry: &ProviderRegistry,
    platform: &str,
    backend: &str,
    trainer_ids: &[String],
    text_llm_ids: &[String],
) -> Value {
    let generators: Vec<Value> = registry
        .generators()
        .map(|r| generator_entry(&(r.descriptor)()))
        .collect();
    let transforms: Vec<Value> = registry
        .transforms()
        .map(|r| transform_entry(&(r.descriptor)()))
        .collect();
    let captioners: Vec<Value> = registry
        .captioners()
        .map(|r| captioner_entry(&(r.descriptor)()))
        .collect();
    let image_embedders: Vec<Value> = registry
        .image_embedders()
        .map(|r| image_embedder_entry(&(r.descriptor)()))
        .collect();
    let text_embedders: Vec<Value> = registry
        .text_embedders()
        .map(|r| text_embedder_entry(&(r.descriptor)()))
        .collect();
    let ids = |it: Vec<&'static str>| it.into_iter().map(String::from).collect::<Vec<_>>();
    json!({
        "abi_version": ABI_VERSION,
        "request_version": crate::request::REQUEST_VERSION,
        "inference_revision": INFERENCE_REVISION,
        "platform": platform,
        "backend": backend,
        "execution": {
            "concurrency": "serialized on one executor thread",
            "cancellation": "cooperative: providers stop at step boundaries; queued jobs cancel immediately; a cancelled job never delivers output",
            "residency": ["unload_after", "keep_loaded"],
            "buffers": "8-bit sRGB; inputs may be strided, straight or premultiplied; outputs are tightly packed straight alpha",
        },
        "routes": {
            "generate": generators,
            "transform": transforms,
            "caption": captioners,
            "embed_image": image_embedders,
            "embed_text": text_embedders,
            "segment": segmentation_entries(),
        },
        "model_licenses": model_licenses(),
        "not_routed": [
            {"surface": "trainers", "ids": trainer_ids, "reason": "fine-tuning is not a LensWorks task"},
            {"surface": "text_llm", "ids": text_llm_ids, "reason": "general chat models are not a LensWorks task; captions use the captioner route"},
            {"surface": "transcribers", "ids": ids(registry.transcribers().map(|r| (r.descriptor)().id).collect()), "reason": "audio input is not a LensWorks task"},
            {"surface": "audio_lane", "ids": [], "reason": "the Candle audio lane is not composed into this build"},
            {"surface": "bespoke", "ids": ["depth", "face", "instantid", "pid", "sam2_video", "sam3_video", "sam3_points"],
             "reason": "bespoke utilities without a LensWorks route in this adapter version"},
        ],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snake_case_conversion() {
        assert_eq!(snake("ReferenceRgba"), "reference_rgba");
        assert_eq!(snake("Mask"), "mask");
        assert_eq!(
            conditioning_name(ConditioningKind::MultiReference),
            "multi_reference"
        );
    }
}
