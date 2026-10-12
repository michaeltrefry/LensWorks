//! Weights-free job lifecycle tests: typed progress/output/failure, cooperative cancellation,
//! panic fencing, model residency and callback teardown. A scripted generator stands in for
//! model execution while the real registry descriptor (sana_sprint_1600m) drives capability
//! checks, so these run on every machine.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lensworks_inference::job::{EventKind, EventOut, Executor, JobHandle};
use lensworks_inference::pixels::HostImage;
use lensworks_inference::request::Request;
use lensworks_inference::routes::{InferenceRunner, ProviderSource};
use runtime_macos::gen_core::{
    self, GenerationOutput, GenerationRequest, Generator, Image, LoadSpec, ModelDescriptor,
    Progress, ProviderRegistry,
};
use serde_json::Value;

const PROVIDER: &str = "sana_sprint_1600m";

struct Scripted {
    descriptor: ModelDescriptor,
    observed_cancel: Arc<AtomicUsize>,
}

impl Generator for Scripted {
    fn descriptor(&self) -> &ModelDescriptor {
        &self.descriptor
    }

    fn validate(&self, _req: &GenerationRequest) -> gen_core::Result<()> {
        Ok(())
    }

    fn generate(
        &self,
        req: &GenerationRequest,
        on_progress: &mut dyn FnMut(Progress),
    ) -> gen_core::Result<GenerationOutput> {
        if req.prompt.contains("panic") {
            panic!("scripted provider panic");
        }
        if req.prompt.contains("fail") {
            return Err(gen_core::Error::Msg("scripted engine failure".into()));
        }
        let steps = req.steps.unwrap_or(3);
        let delay = if req.prompt.contains("slow") {
            Duration::from_millis(40)
        } else {
            Duration::ZERO
        };
        for current in 1..=steps {
            if req.cancel.is_cancelled() {
                self.observed_cancel.fetch_add(1, Ordering::SeqCst);
                return Err(gen_core::Error::Canceled);
            }
            on_progress(Progress::Step {
                current,
                total: steps,
            });
            std::thread::sleep(delay);
        }
        on_progress(Progress::Decoding);
        let pixels = (0..req.width * req.height * 3)
            .map(|i| (i % 251) as u8)
            .collect();
        Ok(GenerationOutput::Images(vec![Image {
            width: req.width,
            height: req.height,
            pixels,
        }]))
    }
}

struct FakeProviders {
    catalog: runtime_macos::RuntimeCatalog,
    loads: Arc<AtomicUsize>,
    observed_cancel: Arc<AtomicUsize>,
}

impl ProviderSource for FakeProviders {
    fn registry(&self) -> &ProviderRegistry {
        self.catalog.media()
    }

    fn load_generator(&self, id: &str, spec: &LoadSpec) -> gen_core::Result<Box<dyn Generator>> {
        if format!("{:?}", spec.weights).contains("missing") {
            return Err(gen_core::Error::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no weights",
            )));
        }
        self.loads.fetch_add(1, Ordering::SeqCst);
        let descriptor = self
            .registry()
            .generators()
            .map(|r| (r.descriptor)())
            .find(|d| d.id == id)
            .expect("descriptor");
        Ok(Box::new(Scripted {
            descriptor,
            observed_cancel: self.observed_cancel.clone(),
        }))
    }
}

struct Harness {
    executor: Executor,
    loads: Arc<AtomicUsize>,
    observed_cancel: Arc<AtomicUsize>,
}

impl Harness {
    fn new() -> Self {
        let loads = Arc::new(AtomicUsize::new(0));
        let observed_cancel = Arc::new(AtomicUsize::new(0));
        let (l, c) = (loads.clone(), observed_cancel.clone());
        let executor = Executor::spawn(InferenceRunner::new(move || {
            let catalog = runtime_macos::catalog().map_err(|e| e.to_string())?;
            Ok(Box::new(FakeProviders {
                catalog,
                loads: l,
                observed_cancel: c,
            }) as Box<dyn ProviderSource>)
        }));
        Self {
            executor,
            loads,
            observed_cancel,
        }
    }
}

#[derive(Debug, Clone)]
struct Recorded {
    kind: EventKind,
    json: Value,
    image: Option<HostImage>,
}

type Log = Arc<Mutex<Vec<Recorded>>>;

/// A sink that records events, signals `tx` with each kind and keeps `alive` alive for as
/// long as the sink itself exists (to observe when the adapter drops it).
fn recording_sink(
    log: Log,
    tx: mpsc::Sender<EventKind>,
    alive: Arc<()>,
) -> Box<dyn FnMut(&EventOut<'_>) + Send> {
    Box::new(move |event: &EventOut<'_>| {
        let _keep = &alive;
        log.lock().unwrap().push(Recorded {
            kind: event.kind,
            json: serde_json::from_str(event.json).expect("event JSON"),
            image: event.image.cloned(),
        });
        let _ = tx.send(event.kind);
    })
}

fn generate(prompt: &str, steps: u32, extra: &str) -> Request {
    let json = format!(
        r#"{{"version":1,"task":"generate","provider":"{PROVIDER}","weights":{{"dir":"/models/sana/q4"}}{extra},
            "params":{{"prompt":"{prompt}","width":4,"height":2,"steps":{steps},"seed":11}}}}"#
    );
    Request::parse(json.as_bytes(), Vec::new()).expect("valid request")
}

fn wait_terminal(rx: &mpsc::Receiver<EventKind>) -> EventKind {
    loop {
        let kind = rx
            .recv_timeout(Duration::from_secs(60))
            .expect("event before timeout");
        if kind.is_terminal() {
            return kind;
        }
    }
}

fn submit(
    h: &Harness,
    request: Request,
) -> (
    JobHandle,
    Log,
    mpsc::Receiver<EventKind>,
    std::sync::Weak<()>,
) {
    let log: Log = Arc::default();
    let (tx, rx) = mpsc::channel();
    let alive = Arc::new(());
    let weak = Arc::downgrade(&alive);
    let handle = h
        .executor
        .submit(request, recording_sink(log.clone(), tx, alive));
    (handle, log, rx, weak)
}

fn kinds(log: &Log) -> Vec<EventKind> {
    log.lock().unwrap().iter().map(|r| r.kind).collect()
}

#[test]
fn successful_job_streams_typed_progress_then_output_then_one_terminal() {
    let h = Harness::new();
    let (handle, log, rx, weak) = submit(&h, generate("a fox", 3, ""));
    assert_eq!(wait_terminal(&rx), EventKind::Completed);
    let events = log.lock().unwrap().clone();
    let steps: Vec<_> = events
        .iter()
        .filter(|e| e.json["phase"] == "step")
        .map(|e| e.json["current"].as_u64().unwrap())
        .collect();
    assert_eq!(steps, vec![1, 2, 3]);
    assert!(
        events
            .iter()
            .any(|e| e.kind == EventKind::Progress && e.json["phase"] == "decoding")
    );
    let started = events
        .iter()
        .position(|e| e.kind == EventKind::Started)
        .unwrap();
    let image_at = events
        .iter()
        .position(|e| e.kind == EventKind::Image)
        .unwrap();
    assert!(started < image_at && image_at < events.len() - 1);
    let image = events[image_at].image.clone().unwrap();
    assert_eq!((image.width, image.height, image.channels), (4, 2, 3));
    assert_eq!(
        image.pixels,
        (0..24).map(|i| (i % 251) as u8).collect::<Vec<_>>()
    );
    assert_eq!(events[image_at].json["color_space"], "srgb");
    assert_eq!(events[image_at].json["alpha"], "none");
    let done = &events.last().unwrap().json;
    assert_eq!(done["provider"], PROVIDER);
    assert_eq!(
        done["inference_revision"],
        lensworks_inference::capabilities::INFERENCE_REVISION
    );
    assert_eq!(done["images"], 1);
    assert_eq!(events.iter().filter(|e| e.kind.is_terminal()).count(), 1);
    // The sink is dropped right after the terminal event, before release.
    std::thread::sleep(Duration::from_millis(20));
    assert!(weak.upgrade().is_none(), "sink freed after terminal");
    handle.release();
}

#[test]
fn cancel_mid_run_stops_at_a_step_boundary_and_delivers_no_output() {
    let h = Harness::new();
    let (handle, log, rx, _weak) = submit(&h, generate("slow", 50, ""));
    loop {
        let kind = rx.recv_timeout(Duration::from_secs(30)).unwrap();
        let steps = log
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.json["phase"] == "step")
            .count();
        if kind == EventKind::Progress && steps >= 3 {
            break;
        }
    }
    handle.cancel();
    assert_eq!(wait_terminal(&rx), EventKind::Cancelled);
    let events = kinds(&log);
    assert!(!events.contains(&EventKind::Image));
    assert!(!events.contains(&EventKind::Completed));
    assert_eq!(
        h.observed_cancel.load(Ordering::SeqCst),
        1,
        "provider observed the cooperative flag"
    );
    let steps = log
        .lock()
        .unwrap()
        .iter()
        .filter(|e| e.json["phase"] == "step")
        .count();
    assert!(steps < 50, "stopped early ({steps} steps)");
    handle.release();
}

#[test]
fn failures_are_typed_and_never_load_for_unsupported_controls() {
    let h = Harness::new();
    let cases: Vec<(Request, &str)> = vec![
        (generate("fail", 2, ""), "engine"),
        (
            Request::parse(
                format!(r#"{{"version":1,"task":"generate","provider":"{PROVIDER}","weights":{{"dir":"/models/missing"}},"params":{{"prompt":"x","width":4,"height":2}}}}"#).as_bytes(),
                vec![],
            )
            .unwrap(),
            "load",
        ),
        (
            Request::parse(br#"{"version":1,"task":"generate","provider":"no_such_model","weights":{"dir":"/m"},"params":{"prompt":"x","width":4,"height":2}}"#, vec![]).unwrap(),
            "unknown_provider",
        ),
    ];
    for (request, expected) in cases {
        let (handle, log, rx, _) = submit(&h, request);
        assert_eq!(wait_terminal(&rx), EventKind::Failed);
        let last = log.lock().unwrap().last().unwrap().json.clone();
        assert_eq!(last["kind"], expected, "{last}");
        assert!(last["message"].as_str().unwrap().len() > 3);
        handle.release();
    }
    let loads_before = h.loads.load(Ordering::SeqCst);
    // Sana Sprint is CFG-free, has no masks and no sampler choice: each is reported, not dropped.
    let request = Request::parse(
        format!(
            r#"{{"version":1,"task":"generate","provider":"{PROVIDER}","weights":{{"dir":"/m"}},
                "params":{{"prompt":"x","width":4,"height":2,"negative_prompt":"blur","sampler":"euler","alpha_output":true,
                           "conditioning":[{{"kind":"mask","input":0}}]}}}}"#
        )
        .as_bytes(),
        vec![HostImage { width: 4, height: 2, channels: 1, pixels: vec![255; 8] }],
    )
    .unwrap();
    let (handle, log, rx, _) = submit(&h, request);
    assert_eq!(wait_terminal(&rx), EventKind::Failed);
    let last = log.lock().unwrap().last().unwrap().json.clone();
    assert_eq!(last["kind"], "unsupported");
    let controls: Vec<&str> = last["unsupported"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["control"].as_str().unwrap())
        .collect();
    for expected in [
        "negative_prompt",
        "sampler",
        "alpha_output",
        "conditioning.mask",
    ] {
        assert!(
            controls.contains(&expected),
            "{expected} missing from {controls:?}"
        );
    }
    assert_eq!(
        h.loads.load(Ordering::SeqCst),
        loads_before,
        "no weights touched for an unsupported request"
    );
    handle.release();
}

#[test]
fn a_provider_panic_is_fenced_and_the_executor_keeps_serving() {
    let h = Harness::new();
    let (handle, log, rx, _) = submit(
        &h,
        generate("panic", 2, r#","load":{"residency":"keep_loaded"}"#),
    );
    assert_eq!(wait_terminal(&rx), EventKind::Failed);
    assert_eq!(log.lock().unwrap().last().unwrap().json["kind"], "panic");
    handle.release();
    // The panicked model was dropped even though it asked to stay loaded.
    let (handle, log, rx, _) = submit(
        &h,
        generate("after", 1, r#","load":{"residency":"keep_loaded"}"#),
    );
    assert_eq!(wait_terminal(&rx), EventKind::Completed);
    assert_eq!(
        log.lock().unwrap().last().unwrap().json["model_reused"],
        false
    );
    handle.release();
}

#[test]
fn release_during_a_run_stops_callbacks_immediately_and_frees_the_sink() {
    let h = Harness::new();
    let (handle, log, rx, weak) = submit(&h, generate("slow", 40, ""));
    while log
        .lock()
        .unwrap()
        .iter()
        .filter(|e| e.json["phase"] == "step")
        .count()
        < 2
    {
        rx.recv_timeout(Duration::from_secs(30)).unwrap();
    }
    handle.release();
    let frozen = log.lock().unwrap().len();
    assert!(
        weak.upgrade().is_none(),
        "release dropped the sink synchronously"
    );
    // The executor finishes the (now cancelled) job in the background and serves the next.
    let (next, next_log, next_rx, _) = submit(&h, generate("next", 1, ""));
    assert_eq!(wait_terminal(&next_rx), EventKind::Completed);
    assert_eq!(
        log.lock().unwrap().len(),
        frozen,
        "no callback after release returned"
    );
    assert!(
        h.observed_cancel.load(Ordering::SeqCst) >= 1,
        "release cancelled the running job"
    );
    assert!(
        next_log
            .lock()
            .unwrap()
            .iter()
            .any(|e| e.kind == EventKind::Image)
    );
    next.release();
}

#[test]
fn release_from_inside_the_callback_does_not_deadlock() {
    let h = Harness::new();
    let slot: Arc<Mutex<Option<JobHandle>>> = Arc::default();
    let count = Arc::new(AtomicUsize::new(0));
    let alive = Arc::new(());
    let weak = Arc::downgrade(&alive);
    let (tx, rx) = mpsc::channel();
    let (s, c) = (slot.clone(), count.clone());
    let handle = h.executor.submit(
        generate("slow", 30, ""),
        Box::new(move |event: &EventOut<'_>| {
            let _keep = &alive;
            let n = c.fetch_add(1, Ordering::SeqCst) + 1;
            if event.kind == EventKind::Progress
                && n >= 3
                && let Some(handle) = s.lock().unwrap().take()
            {
                handle.release();
                let _ = tx.send(());
            }
        }),
    );
    *slot.lock().unwrap() = Some(handle);
    rx.recv_timeout(Duration::from_secs(30))
        .expect("released from the callback");
    let at_release = count.load(Ordering::SeqCst);
    let (next, _, next_rx, _) = submit(&h, generate("next", 1, ""));
    assert_eq!(wait_terminal(&next_rx), EventKind::Completed);
    assert_eq!(
        count.load(Ordering::SeqCst),
        at_release,
        "no callback after the re-entrant release"
    );
    assert!(
        weak.upgrade().is_none(),
        "sink dropped once the releasing callback returned"
    );
    next.release();
}

#[test]
fn queued_jobs_cancel_without_loading_and_residency_is_explicit() {
    let h = Harness::new();
    let (first, _, first_rx, _) = submit(
        &h,
        generate("slow", 20, r#","load":{"residency":"keep_loaded"}"#),
    );
    let (queued, queued_log, queued_rx, _) = submit(&h, generate("never", 1, ""));
    queued.cancel();
    assert_eq!(wait_terminal(&first_rx), EventKind::Completed);
    assert_eq!(wait_terminal(&queued_rx), EventKind::Cancelled);
    assert_eq!(
        queued_log.lock().unwrap().last().unwrap().json["stage"],
        "queued"
    );
    assert_eq!(h.loads.load(Ordering::SeqCst), 1);
    // keep_loaded: the next identical job reuses the resident model.
    let (second, log, rx, _) = submit(
        &h,
        generate("again", 1, r#","load":{"residency":"keep_loaded"}"#),
    );
    assert_eq!(wait_terminal(&rx), EventKind::Completed);
    assert_eq!(
        log.lock().unwrap().last().unwrap().json["model_reused"],
        true
    );
    assert_eq!(h.loads.load(Ordering::SeqCst), 1);
    assert_eq!(h.executor.release_models(), 1);
    assert_eq!(h.executor.release_models(), 0);
    // unload_after (default) reloads and leaves nothing resident.
    let (third, log, rx, _) = submit(&h, generate("fresh", 1, ""));
    assert_eq!(wait_terminal(&rx), EventKind::Completed);
    assert_eq!(
        log.lock().unwrap().last().unwrap().json["model_reused"],
        false
    );
    assert_eq!(h.loads.load(Ordering::SeqCst), 2);
    assert_eq!(h.executor.release_models(), 0);
    for handle in [first, queued, second, third] {
        handle.release();
    }
}

#[test]
fn a_panicking_sink_is_dropped_without_killing_the_executor() {
    let h = Harness::new();
    let handle = h.executor.submit(
        generate("x", 2, ""),
        Box::new(|_: &EventOut<'_>| panic!("sink panic")),
    );
    let (next, _, rx, _) = submit(&h, generate("y", 1, ""));
    assert_eq!(wait_terminal(&rx), EventKind::Completed);
    handle.release();
    next.release();
}

#[test]
fn many_concurrent_submitters_each_get_exactly_one_terminal() {
    let h = Arc::new(Harness::new());
    let threads: Vec<_> = (0..8)
        .map(|i| {
            let h = h.clone();
            std::thread::spawn(move || {
                let (handle, log, rx, _) =
                    submit(&h, generate(if i % 3 == 0 { "fail" } else { "ok" }, 2, ""));
                if i % 4 == 1 {
                    handle.cancel();
                }
                let terminal = wait_terminal(&rx);
                std::thread::sleep(Duration::from_millis(10));
                let terminals = kinds(&log).iter().filter(|k| k.is_terminal()).count();
                handle.release();
                (terminal, terminals)
            })
        })
        .collect();
    for t in threads {
        let (_, terminals) = t.join().unwrap();
        assert_eq!(terminals, 1);
    }
}
