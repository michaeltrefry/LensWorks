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
    fn init(self) -> Result<Self::State, String>;
    fn run(state: &mut Self::State, request: Request, job: &Shared);
    /// Drop resident models; returns how many were released.
    fn release_models(state: &mut Self::State) -> usize;
    /// Called after a panic escaped `run`: drop anything that may be inconsistent.
    fn after_panic(state: &mut Self::State);
}

enum Command {
    Run(Box<Request>, Arc<Shared>),
    ReleaseModels(mpsc::SyncSender<usize>),
}

pub struct Executor {
    tx: Mutex<mpsc::Sender<Command>>,
}

pub fn failed_json(kind: &str, message: &str) -> Value {
    serde_json::json!({ "kind": kind, "message": message })
}

impl Executor {
    pub fn spawn<R: Runner>(runner: R) -> Self {
        let (tx, rx) = mpsc::channel::<Command>();
        thread::Builder::new()
            .name("lensworks-inference-executor".into())
            .spawn(move || {
                let mut state = match catch_unwind(AssertUnwindSafe(|| runner.init())) {
                    Ok(Ok(state)) => Some(state),
                    Ok(Err(message)) => {
                        Self::drain_failed(rx, &message);
                        return;
                    }
                    Err(_) => {
                        Self::drain_failed(rx, "inference runtime initialisation panicked");
                        return;
                    }
                };
                for command in rx {
                    let state = state.as_mut().expect("state");
                    match command {
                        Command::Run(request, job) => {
                            if job.is_cancelled() {
                                job.emit_json(
                                    EventKind::Cancelled,
                                    &serde_json::json!({ "stage": "queued" }),
                                );
                                continue;
                            }
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
                            let released =
                                catch_unwind(AssertUnwindSafe(|| R::release_models(state)))
                                    .unwrap_or(0);
                            let _ = reply.send(released);
                        }
                    }
                }
            })
            .expect("spawn inference executor");
        Self { tx: Mutex::new(tx) }
    }

    fn drain_failed(rx: mpsc::Receiver<Command>, message: &str) {
        for command in rx {
            match command {
                Command::Run(_, job) => job.emit_json(
                    EventKind::Failed,
                    &failed_json("runtime_unavailable", message),
                ),
                Command::ReleaseModels(reply) => {
                    let _ = reply.send(0);
                }
            }
        }
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
