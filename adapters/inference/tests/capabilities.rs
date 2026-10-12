//! Every provider the pinned runtime registers has an explicit adapter route, and the
//! reported per-control support is exactly what request gating enforces.

use std::collections::BTreeSet;

use lensworks_inference::capabilities::{self, check_generate};
use lensworks_inference::request::{
    ConditioningParam, ControlKindParam, GenerateParams, QuantChoice,
};
use serde_json::Value;

fn document() -> Value {
    let doc = lensworks_inference::capabilities_document();
    assert_eq!(doc["ok"], true, "{doc}");
    doc["result"].clone()
}

fn ids(entries: &Value) -> BTreeSet<String> {
    entries
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn every_registered_provider_has_an_explicit_route() {
    let doc = document();
    let catalog = runtime_macos::catalog().unwrap();
    let snapshot = catalog.snapshot();
    let routes = &doc["routes"];
    let set = |v: &[String]| v.iter().cloned().collect::<BTreeSet<_>>();
    assert_eq!(ids(&routes["generate"]), set(&snapshot.generator_ids));
    assert_eq!(ids(&routes["transform"]), set(&snapshot.transform_ids));
    assert_eq!(ids(&routes["caption"]), set(&snapshot.captioner_ids));
    assert_eq!(
        ids(&routes["embed_image"]),
        set(&snapshot.image_embedder_ids)
    );
    assert_eq!(ids(&routes["embed_text"]), set(&snapshot.text_embedder_ids));
    assert!(!snapshot.generator_ids.is_empty() && !snapshot.captioner_ids.is_empty());
    assert!(!snapshot.image_embedder_ids.is_empty() && !snapshot.text_embedder_ids.is_empty());
    assert_eq!(doc["inference_revision"], capabilities::INFERENCE_REVISION);
    assert_eq!(doc["platform"], "macos");
    assert_eq!(doc["backend"], "mlx");

    for kind in [
        "generate",
        "transform",
        "caption",
        "embed_image",
        "embed_text",
        "segment",
    ] {
        for entry in routes[kind].as_array().unwrap() {
            let route = entry["route"].as_str().unwrap();
            assert!(route == "supported" || route == "unsupported", "{entry}");
            if route == "unsupported" {
                assert!(
                    entry["reason"].as_str().is_some_and(|r| !r.is_empty()),
                    "{entry}"
                );
            }
        }
    }
    // Still-image generators are routed; video/audio ones are reported, not faked.
    let generators = routes["generate"].as_array().unwrap();
    let by_id = |id: &str| generators.iter().find(|g| g["id"] == id).unwrap().clone();
    assert_eq!(by_id("sana_sprint_1600m")["route"], "supported");
    assert_eq!(by_id("flux1_schnell")["route"], "supported");
    for g in generators {
        let video_or_audio = g["modality"] == "video" || g["modality"] == "audio";
        assert_eq!(g["route"] == "unsupported", video_or_audio, "{}", g["id"]);
    }
    // Embedding spaces pair up for semantic search.
    assert_eq!(
        routes["embed_image"][0]["space"],
        routes["embed_text"][0]["space"]
    );
    assert_eq!(
        routes["embed_image"][0]["embedding_dim"],
        routes["embed_text"][0]["embedding_dim"]
    );
    // Segmentation utilities are explicit routes.
    let tasks: BTreeSet<&str> = routes["segment"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["task"].as_str().unwrap())
        .collect();
    assert_eq!(
        tasks,
        BTreeSet::from([
            "segment_sam2_box",
            "segment_sam3_concept",
            "segment_sam3_box"
        ])
    );
    // Everything else the runtime ships is listed as not routed with a reason.
    let not_routed = doc["not_routed"].as_array().unwrap();
    let trainers = not_routed
        .iter()
        .find(|n| n["surface"] == "trainers")
        .unwrap();
    assert_eq!(
        trainers["ids"].as_array().unwrap().len(),
        snapshot.trainer_ids.len()
    );
    let llms = not_routed
        .iter()
        .find(|n| n["surface"] == "text_llm")
        .unwrap();
    assert_eq!(
        llms["ids"].as_array().unwrap().len(),
        snapshot.text_llm_ids.len()
    );
    assert!(
        not_routed
            .iter()
            .all(|n| n["reason"].as_str().is_some_and(|r| !r.is_empty()))
    );
}

#[test]
fn every_control_report_carries_support_and_a_reason_when_unsupported() {
    let doc = document();
    for kind in ["generate", "transform", "caption", "segment"] {
        for entry in doc["routes"][kind].as_array().unwrap() {
            for (name, control) in entry["controls"].as_object().unwrap() {
                let supported = control["supported"]
                    .as_bool()
                    .unwrap_or_else(|| panic!("{} {name}", entry["id"]));
                if !supported && kind != "caption" {
                    assert!(
                        control["reason"].as_str().is_some_and(|r| !r.is_empty()),
                        "{} {name}",
                        entry["id"]
                    );
                }
            }
        }
    }
}

/// For every routed generator, a request carrying a control is rejected exactly when the
/// capability document says that control is unsupported.
#[test]
fn generate_gating_matches_the_reported_capabilities_for_every_generator() {
    let catalog = runtime_macos::catalog().unwrap();
    let mut checked = 0;
    for registration in catalog.media().generators() {
        let d = (registration.descriptor)();
        let entry = capabilities::generator_entry(&d);
        if entry["route"] == "unsupported" {
            let flagged = check_generate(&d, &GenerateParams::default(), None);
            assert_eq!(flagged.len(), 1, "{}", d.id);
            assert_eq!(flagged[0].control, "route");
            continue;
        }
        let controls = &entry["controls"];
        let supported = |name: &str| controls[name]["supported"].as_bool().unwrap();
        let base = GenerateParams {
            prompt: "p".into(),
            width: 512,
            height: 512,
            ..Default::default()
        };
        assert!(
            check_generate(&d, &base, None).is_empty(),
            "{}: a plain request is accepted",
            d.id
        );
        let first = |name: &str| {
            controls[name]["values"]
                .as_array()
                .and_then(|v| v.first())
                .and_then(Value::as_str)
                .map(String::from)
        };
        let probes: Vec<(&str, GenerateParams)> = vec![
            (
                "negative_prompt",
                GenerateParams {
                    negative_prompt: Some("n".into()),
                    ..base.clone()
                },
            ),
            (
                "guidance",
                GenerateParams {
                    guidance: Some(3.0),
                    ..base.clone()
                },
            ),
            (
                "true_cfg",
                GenerateParams {
                    true_cfg: Some(3.0),
                    ..base.clone()
                },
            ),
            (
                "strength",
                GenerateParams {
                    strength: Some(0.5),
                    ..base.clone()
                },
            ),
            (
                "control_scale",
                GenerateParams {
                    control_scale: Some(0.5),
                    ..base.clone()
                },
            ),
            (
                "alpha_output",
                GenerateParams {
                    alpha_output: true,
                    ..base.clone()
                },
            ),
            (
                "sampler",
                GenerateParams {
                    sampler: Some(first("sampler").unwrap_or_else(|| "euler".into())),
                    ..base.clone()
                },
            ),
            (
                "scheduler",
                GenerateParams {
                    scheduler: Some(first("scheduler").unwrap_or_else(|| "karras".into())),
                    ..base.clone()
                },
            ),
            (
                "guidance_method",
                GenerateParams {
                    guidance_method: Some(first("guidance_method").unwrap_or_else(|| "cfg".into())),
                    ..base.clone()
                },
            ),
        ];
        for (name, params) in probes {
            let flagged = check_generate(&d, &params, None);
            assert_eq!(
                flagged.iter().any(|u| u.control == name),
                !supported(name),
                "{}: {name}",
                d.id
            );
        }
        for q in [QuantChoice::Q4, QuantChoice::Q8] {
            let label = format!("{q:?}").to_lowercase();
            let reported = controls["quantize"]["values"]
                .as_array()
                .is_some_and(|v| v.iter().any(|x| x == &Value::String(label.clone())));
            let flagged = check_generate(&d, &base, Some(q))
                .iter()
                .any(|u| u.control == "quantize");
            assert_eq!(flagged, !reported, "{}: quantize {label}", d.id);
        }
        let reported: BTreeSet<String> = entry["conditioning"]["supported"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        let conditionings = [
            ConditioningParam::Reference {
                input: 0,
                strength: None,
            },
            ConditioningParam::ReferenceRgba {
                input: 0,
                strength: None,
            },
            ConditioningParam::MultiReference { inputs: vec![0] },
            ConditioningParam::ReduxRefs {
                inputs: vec![0],
                weights: vec![1.0],
            },
            ConditioningParam::Control {
                input: 0,
                control: ControlKindParam::Canny,
                other: None,
                scale: None,
            },
            ConditioningParam::Depth { input: 0 },
            ConditioningParam::Mask { input: 0 },
        ];
        for cond in conditionings {
            let name = cond.name().to_string();
            let params = GenerateParams {
                conditioning: vec![cond],
                ..base.clone()
            };
            let flagged = check_generate(&d, &params, None)
                .iter()
                .any(|u| u.control == format!("conditioning.{name}"));
            assert_eq!(
                flagged,
                !reported.contains(&name),
                "{}: conditioning {name}",
                d.id
            );
        }
        checked += 1;
    }
    assert!(checked > 30, "checked {checked} routed generators");
}

#[test]
fn caption_and_embedder_capabilities_reflect_the_descriptors() {
    let catalog = runtime_macos::catalog().unwrap();
    let registry = catalog.media();
    for r in registry.captioners() {
        let d = (r.descriptor)();
        let entry = capabilities::captioner_entry(&d);
        assert_eq!(
            entry["controls"]["custom_prompt"]["supported"],
            d.capabilities.supports_custom_prompt
        );
        let bogus = lensworks_inference::request::CaptionParams {
            input: 0,
            caption_type: Some("NotARealType".into()),
            caption_length: None,
            extra_options: vec![],
            name_input: None,
            custom_prompt: None,
            low_vram: false,
            temperature: None,
            top_p: None,
            max_new_tokens: Some(u32::MAX),
            seed: None,
            repetition_penalty: None,
        };
        let flagged: Vec<String> = capabilities::check_caption(&d, &bogus)
            .into_iter()
            .map(|u| u.control)
            .collect();
        assert!(
            flagged.contains(&"caption_type".to_string())
                && flagged.contains(&"max_new_tokens".to_string()),
            "{flagged:?}"
        );
    }
    for r in registry.image_embedders() {
        let d = (r.descriptor)();
        assert_eq!(
            capabilities::image_embedder_entry(&d)["embedding_dim"],
            d.embedding_dim
        );
    }
}

/// The capability document carries the pinned runtime's checkpoint licence table, which the
/// native model store uses to validate and show every model component's terms.
#[test]
fn capabilities_carry_the_runtime_licence_table() {
    let doc = document();
    let table = &doc["model_licenses"];
    assert_eq!(table["kind"], "model-weight-licenses");
    let components = table["components"].as_array().unwrap();
    let row = |key: &str| {
        components
            .iter()
            .find(|c| c["component"] == key)
            .unwrap_or_else(|| panic!("no licence row for {key}"))
            .clone()
    };
    assert_eq!(row("sam3")["declared"], "SAM License");
    assert_eq!(row("sam3")["gated"], true);
    assert_eq!(row("sam2_1_hiera_large")["family"], "apache-2-0");
    let families = table["families"].as_array().unwrap();
    for key in [
        "sam3",
        "sam2_1_hiera_large",
        "sana_sprint_1_6b_1024px_diffusers",
        "gemma_2_2b_it",
    ] {
        let family = row(key)["family"].clone();
        let family = families
            .iter()
            .find(|f| f["id"] == family)
            .expect("family resolves");
        assert!(family["name"].as_str().is_some_and(|n| !n.is_empty()));
        assert!(
            family["text_url"]
                .as_str()
                .is_some_and(|n| n.starts_with("https://"))
        );
    }
    assert!(table.get("providers").is_none());
}
