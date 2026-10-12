//! Versioned JSON job request contract. Parsing and structural validation happen on the
//! submitting thread so malformed requests fail synchronously; capability checks that need
//! the provider registry happen on the executor before any weights are touched.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::pixels::HostImage;

pub const REQUEST_VERSION: u32 = 1;
const MAX_REQUEST_BYTES: usize = 1 << 20;
const MAX_TEXT_CHARS: usize = 16_384;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Task {
    Generate,
    Transform,
    Caption,
    EmbedImage,
    EmbedText,
    SegmentSam2Box,
    SegmentSam3Concept,
    SegmentSam3Box,
}

impl Task {
    pub fn name(self) -> &'static str {
        match self {
            Task::Generate => "generate",
            Task::Transform => "transform",
            Task::Caption => "caption",
            Task::EmbedImage => "embed_image",
            Task::EmbedText => "embed_text",
            Task::SegmentSam2Box => "segment_sam2_box",
            Task::SegmentSam3Concept => "segment_sam3_concept",
            Task::SegmentSam3Box => "segment_sam3_box",
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum WeightsRef {
    Dir(PathBuf),
    File(PathBuf),
}

impl WeightsRef {
    pub fn path(&self) -> &Path {
        match self {
            WeightsRef::Dir(p) | WeightsRef::File(p) => p,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Residency {
    /// Drop the model (and return MLX cached buffers) when the job ends. Default: inference
    /// shares unified memory with Metal rendering, so nothing stays resident implicitly.
    #[default]
    UnloadAfter,
    /// Keep the model loaded for the next job with the same provider/weights/quantization,
    /// until a different model is needed or `lw_inference_release_models` is called.
    KeepLoaded,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QuantChoice {
    Q4,
    Q8,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct LoadOptions {
    #[serde(default)]
    pub quantize: Option<QuantChoice>,
    #[serde(default)]
    pub residency: Residency,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    task: Task,
    provider: String,
    #[serde(default)]
    weights: Option<WeightsRef>,
    #[serde(default)]
    tokenizer: Option<PathBuf>,
    #[serde(default)]
    load: LoadOptions,
    #[serde(default)]
    params: Option<Value>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ControlKindParam {
    Pose,
    Canny,
    Depth,
    Other,
}

/// Image conditioning the adapter routes. Inputs are referenced by index into the input
/// buffer array passed alongside the JSON.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ConditioningParam {
    Reference {
        input: usize,
        #[serde(default)]
        strength: Option<f32>,
    },
    ReferenceRgba {
        input: usize,
        #[serde(default)]
        strength: Option<f32>,
    },
    MultiReference {
        inputs: Vec<usize>,
    },
    ReduxRefs {
        inputs: Vec<usize>,
        weights: Vec<f32>,
    },
    Control {
        input: usize,
        control: ControlKindParam,
        #[serde(default)]
        other: Option<String>,
        #[serde(default)]
        scale: Option<f32>,
    },
    Depth {
        input: usize,
    },
    Mask {
        input: usize,
    },
}

impl ConditioningParam {
    pub fn name(&self) -> &'static str {
        match self {
            ConditioningParam::Reference { .. } => "reference",
            ConditioningParam::ReferenceRgba { .. } => "reference_rgba",
            ConditioningParam::MultiReference { .. } => "multi_reference",
            ConditioningParam::ReduxRefs { .. } => "redux_refs",
            ConditioningParam::Control { .. } => "control",
            ConditioningParam::Depth { .. } => "depth",
            ConditioningParam::Mask { .. } => "mask",
        }
    }

    fn inputs(&self) -> Vec<usize> {
        match self {
            ConditioningParam::Reference { input, .. }
            | ConditioningParam::ReferenceRgba { input, .. }
            | ConditioningParam::Control { input, .. }
            | ConditioningParam::Depth { input }
            | ConditioningParam::Mask { input } => vec![*input],
            ConditioningParam::MultiReference { inputs }
            | ConditioningParam::ReduxRefs { inputs, .. } => inputs.clone(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct GenerateParams {
    pub prompt: String,
    #[serde(default)]
    pub negative_prompt: Option<String>,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub count: Option<u32>,
    #[serde(default)]
    pub seed: Option<u64>,
    #[serde(default)]
    pub steps: Option<u32>,
    #[serde(default)]
    pub guidance: Option<f32>,
    #[serde(default)]
    pub true_cfg: Option<f32>,
    #[serde(default)]
    pub sampler: Option<String>,
    #[serde(default)]
    pub scheduler: Option<String>,
    #[serde(default)]
    pub guidance_method: Option<String>,
    #[serde(default)]
    pub strength: Option<f32>,
    #[serde(default)]
    pub control_scale: Option<f32>,
    #[serde(default)]
    pub alpha_output: bool,
    #[serde(default)]
    pub conditioning: Vec<ConditioningParam>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "mode", rename_all = "snake_case", deny_unknown_fields)]
pub enum TargetParam {
    Scale { factor: f32 },
    MinEdge { edge: u32 },
    Resolution { width: u32, height: u32 },
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TransformParams {
    pub input: usize,
    pub target: TargetParam,
    #[serde(default)]
    pub seed: Option<u64>,
    #[serde(default)]
    pub strength: Option<f32>,
    #[serde(default)]
    pub steps: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CaptionParams {
    pub input: usize,
    #[serde(default)]
    pub caption_type: Option<String>,
    #[serde(default)]
    pub caption_length: Option<String>,
    #[serde(default)]
    pub extra_options: Vec<String>,
    #[serde(default)]
    pub name_input: Option<String>,
    #[serde(default)]
    pub custom_prompt: Option<String>,
    #[serde(default)]
    pub low_vram: bool,
    #[serde(default)]
    pub temperature: Option<f32>,
    #[serde(default)]
    pub top_p: Option<f32>,
    #[serde(default)]
    pub max_new_tokens: Option<u32>,
    #[serde(default)]
    pub seed: Option<u64>,
    #[serde(default)]
    pub repetition_penalty: Option<f32>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EmbedImageParams {
    pub inputs: Vec<usize>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EmbedTextParams {
    pub texts: Vec<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Sam2Size {
    Tiny,
    Small,
    BasePlus,
    Large,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Sam2BoxParams {
    pub input: usize,
    /// `[x1, y1, x2, y2]` in source pixel coordinates (top-left origin).
    pub box_xyxy: [f32; 4],
    pub model_size: Sam2Size,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Sam3ConceptParams {
    pub input: usize,
    pub concept: String,
    #[serde(default)]
    pub threshold: Option<f32>,
    #[serde(default)]
    pub mask_threshold: Option<f32>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Sam3BoxParams {
    pub input: usize,
    pub box_xyxy: [f32; 4],
    #[serde(default)]
    pub concept: Option<String>,
    #[serde(default)]
    pub threshold: Option<f32>,
    #[serde(default)]
    pub mask_threshold: Option<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Params {
    Generate(GenerateParams),
    Transform(TransformParams),
    Caption(CaptionParams),
    EmbedImage(EmbedImageParams),
    EmbedText(EmbedTextParams),
    Sam2Box(Sam2BoxParams),
    Sam3Concept(Sam3ConceptParams),
    Sam3Box(Sam3BoxParams),
}

/// A fully owned, structurally valid job request.
#[derive(Clone, Debug)]
pub struct Request {
    pub task: Task,
    pub provider: String,
    pub weights: Option<WeightsRef>,
    pub tokenizer: Option<PathBuf>,
    pub load: LoadOptions,
    pub params: Params,
    pub inputs: Vec<HostImage>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RequestError(pub String);

fn err<T>(message: impl Into<String>) -> Result<T, RequestError> {
    Err(RequestError(message.into()))
}

fn typed<T: serde::de::DeserializeOwned>(
    params: Option<Value>,
    task: Task,
) -> Result<T, RequestError> {
    let value = params.unwrap_or(Value::Object(Default::default()));
    serde_json::from_value(value).map_err(|e| RequestError(format!("{} params: {e}", task.name())))
}

fn check_path(label: &str, path: &Path) -> Result<(), RequestError> {
    if !path.is_absolute() {
        return err(format!("{label} must be an absolute path"));
    }
    if path
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return err(format!("{label} must not contain '..'"));
    }
    Ok(())
}

fn check_text(label: &str, text: &str) -> Result<(), RequestError> {
    if text.chars().count() > MAX_TEXT_CHARS {
        return err(format!("{label} exceeds {MAX_TEXT_CHARS} characters"));
    }
    Ok(())
}

fn check_box(b: &[f32; 4], image: &HostImage) -> Result<(), RequestError> {
    if b.iter().any(|v| !v.is_finite()) || b[2] <= b[0] || b[3] <= b[1] {
        return err("box_xyxy must be finite with x2 > x1 and y2 > y1");
    }
    if b[2] <= 0.0 || b[3] <= 0.0 || b[0] >= image.width as f32 || b[1] >= image.height as f32 {
        return err("box_xyxy does not overlap the input image");
    }
    Ok(())
}

impl Request {
    pub fn parse(json: &[u8], inputs: Vec<HostImage>) -> Result<Self, RequestError> {
        if json.len() > MAX_REQUEST_BYTES {
            return err("request exceeds 1 MiB");
        }
        let envelope: Envelope = serde_json::from_slice(json)
            .map_err(|e| RequestError(format!("invalid request: {e}")))?;
        if envelope.version != REQUEST_VERSION {
            return err(format!(
                "unsupported request version {}; expected {REQUEST_VERSION}",
                envelope.version
            ));
        }
        if envelope.provider.is_empty() || envelope.provider.len() > 256 {
            return err("provider must be a non-empty id of at most 256 bytes");
        }
        if let Some(weights) = &envelope.weights {
            check_path("weights", weights.path())?;
        }
        if let Some(tokenizer) = &envelope.tokenizer {
            check_path("tokenizer", tokenizer)?;
        }
        let task = envelope.task;
        let params = match task {
            Task::Generate => Params::Generate(typed(envelope.params, task)?),
            Task::Transform => Params::Transform(typed(envelope.params, task)?),
            Task::Caption => Params::Caption(typed(envelope.params, task)?),
            Task::EmbedImage => Params::EmbedImage(typed(envelope.params, task)?),
            Task::EmbedText => Params::EmbedText(typed(envelope.params, task)?),
            Task::SegmentSam2Box => Params::Sam2Box(typed(envelope.params, task)?),
            Task::SegmentSam3Concept => Params::Sam3Concept(typed(envelope.params, task)?),
            Task::SegmentSam3Box => Params::Sam3Box(typed(envelope.params, task)?),
        };
        if envelope.weights.is_none() {
            return err(format!("{} requires weights", task.name()));
        }
        let needs_tokenizer = matches!(task, Task::SegmentSam3Concept | Task::SegmentSam3Box);
        if needs_tokenizer && envelope.tokenizer.is_none() {
            return err(format!("{} requires a tokenizer path", task.name()));
        }
        if !needs_tokenizer && envelope.tokenizer.is_some() {
            return err(format!("{} does not take a tokenizer", task.name()));
        }
        let request = Request {
            task,
            provider: envelope.provider,
            weights: envelope.weights,
            tokenizer: envelope.tokenizer,
            load: envelope.load,
            params,
            inputs,
        };
        request.validate_inputs()?;
        Ok(request)
    }

    pub fn input(&self, index: usize) -> &HostImage {
        &self.inputs[index]
    }

    fn validate_inputs(&self) -> Result<(), RequestError> {
        let mut referenced: Vec<usize> = Vec::new();
        match &self.params {
            Params::Generate(p) => {
                check_text("prompt", &p.prompt)?;
                if let Some(n) = &p.negative_prompt {
                    check_text("negative_prompt", n)?;
                }
                for c in &p.conditioning {
                    if let ConditioningParam::ReduxRefs { inputs, weights } = c
                        && inputs.len() != weights.len()
                    {
                        return err("redux_refs needs one weight per input");
                    }
                    if let ConditioningParam::Control { control, other, .. } = c
                        && (*control == ControlKindParam::Other) != other.is_some()
                    {
                        return err("control kind 'other' requires (only it) a name in 'other'");
                    }
                    if c.inputs().is_empty() {
                        return err(format!(
                            "{} conditioning needs at least one input",
                            c.name()
                        ));
                    }
                    referenced.extend(c.inputs());
                }
            }
            Params::Transform(p) => referenced.push(p.input),
            Params::Caption(p) => {
                for t in [&p.custom_prompt, &p.name_input].into_iter().flatten() {
                    check_text("caption text", t)?;
                }
                referenced.push(p.input)
            }
            Params::EmbedImage(p) => {
                if p.inputs.is_empty() {
                    return err("embed_image needs at least one input");
                }
                referenced.extend(&p.inputs);
            }
            Params::EmbedText(p) => {
                if p.texts.is_empty() {
                    return err("embed_text needs at least one text");
                }
                for t in &p.texts {
                    check_text("text", t)?;
                }
            }
            Params::Sam2Box(p) => referenced.push(p.input),
            Params::Sam3Concept(p) => {
                if p.concept.trim().is_empty() {
                    return err("concept must not be empty");
                }
                check_text("concept", &p.concept)?;
                referenced.push(p.input)
            }
            Params::Sam3Box(p) => referenced.push(p.input),
        }
        for &index in &referenced {
            if index >= self.inputs.len() {
                return err(format!(
                    "input index {index} is out of range ({} inputs)",
                    self.inputs.len()
                ));
            }
        }
        for index in 0..self.inputs.len() {
            if !referenced.contains(&index) {
                return err(format!("input {index} is not referenced by the request"));
            }
        }
        match &self.params {
            Params::Sam2Box(p) => check_box(&p.box_xyxy, self.input(p.input))?,
            Params::Sam3Box(p) => check_box(&p.box_xyxy, self.input(p.input))?,
            _ => {}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb(w: u32, h: u32) -> HostImage {
        HostImage {
            width: w,
            height: h,
            channels: 3,
            pixels: vec![0; (w * h * 3) as usize],
        }
    }

    #[test]
    fn parses_a_generate_request() {
        let json = br#"{"version":1,"task":"generate","provider":"sana_sprint_1600m","weights":{"dir":"/m/q4"},
            "load":{"residency":"keep_loaded"},
            "params":{"prompt":"a fox","width":512,"height":512,"steps":2,"seed":7,
                      "conditioning":[{"kind":"mask","input":0}]}}"#;
        let request = Request::parse(json, vec![rgb(4, 4)]).unwrap();
        assert_eq!(request.task, Task::Generate);
        assert_eq!(request.load.residency, Residency::KeepLoaded);
        let Params::Generate(p) = &request.params else {
            panic!()
        };
        assert_eq!((p.width, p.steps, p.seed), (512, Some(2), Some(7)));
    }

    #[test]
    fn rejects_unknown_fields_versions_and_relative_paths() {
        let cases: &[&[u8]] = &[
            br#"{"version":2,"task":"generate","provider":"x","weights":{"dir":"/m"},"params":{"prompt":"","width":1,"height":1}}"#,
            br#"{"version":1,"task":"generate","provider":"x","weights":{"dir":"m"},"params":{"prompt":"","width":1,"height":1}}"#,
            br#"{"version":1,"task":"generate","provider":"x","weights":{"dir":"/a/../b"},"params":{"prompt":"","width":1,"height":1}}"#,
            br#"{"version":1,"task":"generate","provider":"x","weights":{"dir":"/m"},"params":{"prompt":"","width":1,"height":1,"lora":"x"}}"#,
            br#"{"version":1,"task":"generate","provider":"x","weights":{"dir":"/m"},"extra":1,"params":{"prompt":"","width":1,"height":1}}"#,
            br#"{"version":1,"task":"paint","provider":"x","weights":{"dir":"/m"}}"#,
            br#"{"version":1,"task":"generate","provider":"x","params":{"prompt":"","width":1,"height":1}}"#,
            br#"{"version":1,"task":"segment_sam3_concept","provider":"sam3","weights":{"file":"/m/a"},"params":{"input":0,"concept":"dog"}}"#,
            b"not json",
        ];
        for case in cases {
            assert!(
                Request::parse(case, vec![rgb(2, 2)]).is_err()
                    || Request::parse(case, vec![]).is_err(),
                "{}",
                String::from_utf8_lossy(case)
            );
        }
    }

    #[test]
    fn input_indices_must_match_exactly() {
        let json = br#"{"version":1,"task":"caption","provider":"c","weights":{"dir":"/m"},"params":{"input":1}}"#;
        assert!(
            Request::parse(json, vec![rgb(2, 2)])
                .unwrap_err()
                .0
                .contains("out of range")
        );
        let json = br#"{"version":1,"task":"caption","provider":"c","weights":{"dir":"/m"},"params":{"input":0}}"#;
        assert!(
            Request::parse(json, vec![rgb(2, 2), rgb(2, 2)])
                .unwrap_err()
                .0
                .contains("not referenced")
        );
        assert!(Request::parse(json, vec![rgb(2, 2)]).is_ok());
    }

    #[test]
    fn boxes_are_validated_against_the_input() {
        let ok = br#"{"version":1,"task":"segment_sam2_box","provider":"sam2","weights":{"file":"/m/s.safetensors"},"params":{"input":0,"box_xyxy":[1,1,3,3],"model_size":"large"}}"#;
        assert!(Request::parse(ok, vec![rgb(4, 4)]).is_ok());
        let inverted = br#"{"version":1,"task":"segment_sam2_box","provider":"sam2","weights":{"file":"/m/s.safetensors"},"params":{"input":0,"box_xyxy":[3,1,1,3],"model_size":"large"}}"#;
        assert!(Request::parse(inverted, vec![rgb(4, 4)]).is_err());
        let outside = br#"{"version":1,"task":"segment_sam2_box","provider":"sam2","weights":{"file":"/m/s.safetensors"},"params":{"input":0,"box_xyxy":[10,10,20,20],"model_size":"large"}}"#;
        assert!(Request::parse(outside, vec![rgb(4, 4)]).is_err());
    }
}
