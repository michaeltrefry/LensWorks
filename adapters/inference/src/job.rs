//! Job lifecycle: one dedicated executor thread, FIFO-serialised jobs, a cooperative cancel
//! flag per job and a callback slot with a hard teardown guarantee.
//!
//! * MLX/Metal execution is effectively single-threaded per process and inference providers
//!   are `!Send`, so every load and run happens on the one executor thread, which also owns
//!   the (at most one) resident model.
//! * `JobHandle::release` guarantees that once it returns no callback for that job is running
//!   or will ever start. It may be called from inside that job's own callback.
//! * Every job that is not released first receives exactly one terminal event: `Completed`,
//!   `Failed` or `Cancelled`. After the terminal event the sink is dropped.

use std::cell::Cell;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use runtime_macos::gen_core::CancelFlag;
use serde_json::Value;

use crate::pixels::HostImage;
use crate::request::Request;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum EventKind {
    Started = 1,
    Progress = 2,
    Image = 3,
    Mask = 4,
    Completed = 5,
    Failed = 6,
    Cancelled = 7,
}

impl EventKind {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            EventKind::Completed | EventKind::Failed | EventKind::Cancelled
        )
    }
}

/// One event, borrowed for the duration of the callback only.
pub struct EventOut<'a> {
    pub kind: EventKind,
    pub json: &'a str,
    pub image: Option<&'a HostImage>,
}

pub type Sink = Box<dyn FnMut(&EventOut<'_>) + Send>;

thread_local! {
    /// The job whose callback is currently executing on this thread, so a re-entrant
    /// `release` from inside the callback does not deadlock on the slot lock.
    static ACTIVE: Cell<usize> = const { Cell::new(0) };
}

pub struct Shared {
    pub cancel: CancelFlag,
    slot: Mutex<Option<Sink>>,
    released: AtomicBool,
    terminal: AtomicBool,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl Shared {
    fn new(sink: Sink) -> Arc<Self> {
        Arc::new(Self {
            cancel: CancelFlag::new(),
            slot: Mutex::new(Some(sink)),
            released: AtomicBool::new(false),
            terminal: AtomicBool::new(false),
        })
    }

    fn id(&self) -> usize {
        self as *const Self as usize
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    /// Deliver one event. Ignored after release or after the terminal event.
    pub fn emit(&self, kind: EventKind, json: &str, image: Option<&HostImage>) {
        if self.released.load(Ordering::Acquire) || self.terminal.load(Ordering::Acquire) {
            return;
        }
        let mut slot = lock(&self.slot);
        if self.released.load(Ordering::Acquire) || self.terminal.load(Ordering::Acquire) {
            return;
        }
        if kind.is_terminal() {
            self.terminal.store(true, Ordering::Release);
        }
        if let Some(sink) = slot.as_mut() {
            let previous = ACTIVE.with(|a| a.replace(self.id()));
            let event = EventOut { kind, json, image };
            // A panicking sink must not take down the executor; the job continues to its
            // terminal state and the sink is dropped.
            let panicked = catch_unwind(AssertUnwindSafe(|| sink(&event))).is_err();
            ACTIVE.with(|a| a.set(previous));
            if panicked || kind.is_terminal() || self.released.load(Ordering::Acquire) {
                *slot = None;
            }
        }
    }

    pub fn emit_json(&self, kind: EventKind, value: &Value) {
        self.emit(kind, &value.to_string(), None);
    }

    fn release(&self) {
        self.cancel.cancel();
        if ACTIVE.with(|a| a.get()) == self.id() {
            // Inside this job's callback on this thread: the slot lock is held by `emit`,
            // which drops the sink as soon as the callback returns.
            self.released.store(true, Ordering::Release);
            return;
        }
        let mut slot = lock(&self.slot);
        self.released.store(true, Ordering::Release);
        *slot = None;
    }
}

/// Owner-side handle. Dropping it releases the job.
pub struct JobHandle {
    shared: Arc<Shared>,
}

impl JobHandle {
    pub fn cancel(&self) {
        self.shared.cancel.cancel();
    }

    pub fn release(self) {
        drop(self);
    }
}

impl Drop for JobHandle {
    fn drop(&mut self) {
        self.shared.release();
    }
}

/// What the executor runs. `run` executes on the executor thread with exclusive access to
/// `state` (the resident model and provider registry).
pub trait Runner: Send + 'static {
    type State;
    /// Build the executor state. Called on the executor thread; after a failure it is tried
    /// again for a later job (see [`RetryPolicy`]), so a transient failure is not permanent.
    fn init(&mut self) -> Result<Self::State, String>;
    fn run(state: &mut Self::State, request: Request, job: &Shared);
    /// Drop resident models; returns how many were released.
    fn release_models(state: &mut Self::State) -> usize;
    /// Called after a panic escaped `run`: drop anything that may be inconsistent.
    fn after_panic(state: &mut Self::State);
}

/// When runtime initialisation is retried after it failed: not before `initial` has passed,
/// doubling after each further failure up to `max`. Jobs arriving inside the backoff window
/// fail fast with `runtime_unavailable` and the remaining delay.
#[derive(Clone, Copy, Debug)]
pub struct RetryPolicy {
    pub initial: Duration,
    pub max: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            initial: Duration::from_secs(1),
            max: Duration::from_secs(60),
        }
    }
}

type Call = Box<dyn FnOnce() + Send>;

enum Command {
    Run(Box<Request>, Arc<Shared>),
    ReleaseModels(mpsc::SyncSender<usize>),
    /// Arbitrary work that must run on the executor (MLX) thread, e.g. the GPU self-test.
    Call(Call),
}

pub struct Executor {
    tx: Mutex<mpsc::Sender<Command>>,
}

pub fn failed_json(kind: &str, message: &str) -> Value {
    serde_json::json!({ "kind": kind, "message": message })
}

/// The executor thread's view of runtime initialisation.
struct Init<R: Runner> {
    runner: R,
    policy: RetryPolicy,
    state: Option<R::State>,
    error: String,
    delay: Duration,
    next_attempt: Instant,
    attempts: u32,
}

impl<R: Runner> Init<R> {
    fn new(runner: R, policy: RetryPolicy) -> Self {
        Self {
            runner,
            policy,
            state: None,
            error: String::new(),
            delay: policy.initial,
            next_attempt: Instant::now(),
            attempts: 0,
        }
    }

    /// The state, initialising it when absent and the backoff window has passed.
    fn state(&mut self) -> Result<&mut R::State, Value> {
        if self.state.is_none() {
            let now = Instant::now();
            if now < self.next_attempt {
                let mut value = failed_json("runtime_unavailable", &self.error);
                value["retry_after_ms"] =
                    serde_json::json!((self.next_attempt - now).as_millis() as u64);
                return Err(value);
            }
            self.attempts += 1;
            match catch_unwind(AssertUnwindSafe(|| self.runner.init())) {
                Ok(Ok(state)) => {
                    self.state = Some(state);
                    self.delay = self.policy.initial;
                }
                failure => {
                    self.error = match failure {
                        Ok(Err(message)) => message,
                        _ => "inference runtime initialisation panicked".into(),
                    };
                    self.next_attempt = Instant::now() + self.delay;
                    let mut value = failed_json("runtime_unavailable", &self.error);
                    value["retry_after_ms"] = serde_json::json!(self.delay.as_millis() as u64);
                    value["attempts"] = serde_json::json!(self.attempts);
                    self.delay = (self.delay * 2).min(self.policy.max);
                    return Err(value);
                }
            }
        }
        Ok(self.state.as_mut().expect("state"))
    }
}

impl Executor {
    pub fn spawn<R: Runner>(runner: R) -> Self {
        Self::spawn_with_retry(runner, RetryPolicy::default())
    }

    pub fn spawn_with_retry<R: Runner>(runner: R, policy: RetryPolicy) -> Self {
        let (tx, rx) = mpsc::channel::<Command>();
        thread::Builder::new()
            .name("lensworks-inference-executor".into())
            .spawn(move || {
                let mut init = Init::new(runner, policy);
                // Initialise eagerly so the first job does not pay for it; a failure here is
                // retried by a later job.
                let _ = init.state();
                for command in rx {
                    match command {
                        Command::Run(request, job) => {
                            if job.is_cancelled() {
                                job.emit_json(
                                    EventKind::Cancelled,
                                    &serde_json::json!({ "stage": "queued" }),
                                );
                                continue;
                            }
                            let state = match init.state() {
                                Ok(state) => state,
                                Err(failure) => {
                                    job.emit_json(EventKind::Failed, &failure);
                                    continue;
                                }
                            };
                            let outcome =
                                catch_unwind(AssertUnwindSafe(|| R::run(state, *request, &job)));
                            if outcome.is_err() {
                                R::after_panic(state);
                                job.emit_json(
                                    EventKind::Failed,
                                    &failed_json(
                                        "panic",
                                        "the inference job panicked; resident models were dropped",
                                    ),
                                );
                            }
                            // `run` must end every job; guarantee the terminal event regardless.
                            if job.is_cancelled() {
                                job.emit_json(
                                    EventKind::Cancelled,
                                    &serde_json::json!({ "stage": "finished" }),
                                );
                            } else {
                                job.emit_json(
                                    EventKind::Failed,
                                    &failed_json("internal", "the job ended without a result"),
                                );
                            }
                        }
                        Command::ReleaseModels(reply) => {
                            let released = init
                                .state
                                .as_mut()
                                .map(|state| {
                                    catch_unwind(AssertUnwindSafe(|| R::release_models(state)))
                                        .unwrap_or(0)
                                })
                                .unwrap_or(0);
                            let _ = reply.send(released);
                        }
                        Command::Call(call) => {
                            let _ = catch_unwind(AssertUnwindSafe(call));
                        }
                    }
                }
            })
            .expect("spawn inference executor");
        Self { tx: Mutex::new(tx) }
    }

    /// Run `f` on the executor thread after the jobs queued ahead of it and return its result
    /// (`None` if it panicked or the executor stopped).
    pub fn call<T: Send + 'static>(&self, f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
        let (reply, rx) = mpsc::sync_channel(1);
        let call: Call = Box::new(move || {
            let _ = reply.send(f());
        });
        lock(&self.tx).send(Command::Call(call)).ok()?;
        rx.recv().ok()
    }

    pub fn submit(&self, request: Request, sink: Sink) -> JobHandle {
        let shared = Shared::new(sink);
        let sent = lock(&self.tx).send(Command::Run(Box::new(request), shared.clone()));
        if sent.is_err() {
            shared.emit_json(
                EventKind::Failed,
                &failed_json("runtime_unavailable", "the inference executor has stopped"),
            );
        }
        JobHandle { shared }
    }

    /// Blocks until queued jobs ahead of it have finished and resident models are dropped.
    pub fn release_models(&self) -> usize {
        let (reply, rx) = mpsc::sync_channel(1);
        if lock(&self.tx).send(Command::ReleaseModels(reply)).is_err() {
            return 0;
        }
        rx.recv().unwrap_or(0)
    }
}
