//! Versioned ownership boundary. Public retained requests are forwarded without
//! projecting/narrowing their serde surface; receivers never block admission.
use photocatalog::{
    application as app,
    application::desktop::{DesktopBridge, StartupFailure},
    storage_volume::NativePath,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::c_void,
    sync::{
        Arc, Condvar, Mutex, OnceLock, Weak,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

const MAX_INPUT: usize = 4 * 1024 * 1024;
const MAX_SLOTS: usize = 1024;
const MAX_JOBS: usize = 128;
const MAX_SESSIONS: usize = 4;
const MAX_BUFFERS: usize = 256;
const MAX_HASHERS: usize = 16;
const MAX_BUFFER_BYTES: usize = 512 * 1024 * 1024;
const MAX_CONFIGURED_BYTES: usize = 8 * 1024 * 1024 * 1024;
static PAYLOAD_LIMIT: AtomicUsize = AtomicUsize::new(MAX_BUFFER_BYTES);
static OWNERS: AtomicUsize = AtomicUsize::new(0);
static PAYLOAD_BYTES: AtomicUsize = AtomicUsize::new(0);
static FLOAT_WORKERS: AtomicUsize = AtomicUsize::new(0);
static LIVE_JOBS: AtomicUsize = AtomicUsize::new(0);
static LIVE_HASHERS: AtomicUsize = AtomicUsize::new(0);
struct FloatWorkerLease;
impl FloatWorkerLease {
    fn reserve()->Result<Self>{
        FLOAT_WORKERS.compare_exchange(0,1,Ordering::AcqRel,Ordering::Acquire)
            .map_err(|_|error("resource_limit","one isolated float worker allowance"))?;
        Ok(Self)
    }
}
impl Drop for FloatWorkerLease { fn drop(&mut self){FLOAT_WORKERS.fetch_sub(1,Ordering::AcqRel);} }
struct Lease {
    bytes: usize,
}
impl Lease {
    fn reserve(bytes: usize) -> Result<Self> {
        PAYLOAD_BYTES
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes)
                    .filter(|n| *n <= PAYLOAD_LIMIT.load(Ordering::Acquire))
            })
            .map_err(|_| error("resource_limit", "shared pending/result byte allowance"))?;
        Ok(Self { bytes })
    }
    fn shrink(&mut self, bytes: usize) {
        assert!(bytes <= self.bytes);
        PAYLOAD_BYTES.fetch_sub(self.bytes - bytes, Ordering::AcqRel);
        self.bytes = bytes;
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        PAYLOAD_BYTES.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}
pub(super) fn has_managed_owner() -> bool {
    OWNERS.load(Ordering::Acquire) != 0
}
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
#[derive(Debug)]
struct Error {
    code: String,
    message: String,
}
type Result<T> = std::result::Result<T, Error>;
fn error(code: &str, message: impl ToString) -> Error {
    Error {
        code: code.into(),
        message: message.to_string(),
    }
}
fn native(e: impl ToString) -> Error {
    error("native", e)
}
fn retained(e: app::BridgeError) -> Error {
    Error {
        code: serde_json::to_value(e.code)
            .unwrap()
            .as_str()
            .unwrap()
            .into(),
        message: e.message,
    }
}
fn envelope(r: Result<Value>) -> Value {
    match r {
        Ok(v) => json!({"version":2,"ok":true,"result":v}),
        Err(e) => json!({"version":2,"ok":false,"error":{"code":e.code,"message":e.message}}),
    }
}
fn fenced<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
        .unwrap_or_else(|_| Err(error("panic", "Rust panic fenced")))
}

#[derive(Clone)]
enum Owner {
    Ready(DesktopBridge),
    Draining(DesktopBridge),
    Retained(Arc<anyhow::Error>),
    Closed,
}
#[derive(Default)]
struct ShutdownState {
    running: bool,
    result: Option<Result<()>>,
}
#[cfg(test)]
static SHUTDOWN_GATE: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);
#[cfg(test)]
#[derive(Default)]
struct StartupGate {
    handle: Mutex<Option<u64>>,
    resume: AtomicBool,
}
#[cfg(test)]
static STARTUP_GATE: Mutex<Option<Arc<StartupGate>>> = Mutex::new(None);
struct Session {
    // The reserved registry slot is not public authority until startup installs
    // its ready or retained owner. Guessed handles cannot retire that slot.
    published: AtomicBool,
    // Serializes publication with the shutdown admission fence.
    admission_closed: Mutex<bool>,
    catalog_roots: Mutex<std::collections::HashMap<String, std::path::PathBuf>>,
    worker_limit: u64,
    cache_root: Option<std::path::PathBuf>,
    owner: Mutex<Owner>,
    shutdown_state: Arc<Mutex<ShutdownState>>,
    live: AtomicBool,
    handle: Mutex<u64>,
    callbacks: Mutex<Vec<Weak<Subscription>>>,
    jobs: Mutex<Vec<Weak<Job>>>,
    decode_worker: std::path::PathBuf,
    original_roots: Vec<std::path::PathBuf>,
}
impl Session {
    fn document_source(&self, original: &NativePath) -> Result<std::path::PathBuf> {
        let selected = path(original.clone())?;
        let physical = std::fs::canonicalize(&selected).map_err(native)?;
        if physical != selected || !self.original_roots.iter().any(|root| physical.starts_with(root) && physical != *root) {
            return Err(error("invalid_request", "document source must be a physical file under an admitted originals root"));
        }
        let metadata = std::fs::symlink_metadata(&selected).map_err(native)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(error("invalid_request", "document source must be a regular original"));
        }
        Ok(selected)
    }
    fn preflight(&self, r: &app::Request) -> Result<()> {
        let (path, create) = match r {
            app::Request::OpenExisting { path } => (path, false),
            app::Request::Create { path } => (path, true),
            _ => {
                if matches!(r, app::Request::Close { .. }) {
                    return Ok(());
                }
                if let Some(catalog) =
                    serde_json::to_value(r).map_err(native)?["args"]["catalog"].as_str()
                {
                    return self.preflight_catalog(catalog);
                }
                return Ok(());
            }
        };
        let selected = self::path(path.clone())?;
        if selected
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
        {
            return Err(error("invalid_request", "catalog parent traversal"));
        }
        let root = if create {
            super::managed_entry(&selected, true).map_err(admission)?;
            prospective(&selected)?
        } else {
            super::existing_catalog(&selected).map_err(admission)?
        };
        self.preflight_root(&root)
    }
    fn preflight_catalog(&self, catalog: &str) -> Result<()> {
        let root = lock(&self.catalog_roots).get(catalog).cloned();
        if let Some(root) = root {
            self.preflight_root(&root)
        } else {
            Ok(())
        }
    }
    fn preflight_root(&self, root: &std::path::Path) -> Result<()> {
        super::validate_managed_catalog(root).map_err(admission)?;
        super::managed_entry(&root.join(".lightroom-import.lock"), false).map_err(admission)?;
        let cache = match &self.cache_root {
            Some(parent) => {
                let parent = prospective(parent)?;
                parent.join(
                    blake3::hash(
                        &serde_json::to_vec(&NativePath::from_path(&root)).map_err(native)?,
                    )
                    .to_hex()
                    .as_str(),
                )
            }
            None => root.join("application-previews"),
        };
        managed_cache(&cache)?;
        Ok(())
    }
    fn bridge(&self) -> Result<DesktopBridge> {
        match &*lock(&self.owner) {
            Owner::Ready(b) => Ok(b.clone()),
            Owner::Draining(_) => Err(error("busy", "session is draining")),
            Owner::Retained(e) => Err(error("retained_startup", e)),
            Owner::Closed => Err(error("closed", "session is closed")),
        }
    }
    fn status(&self) -> Value {
        if *lock(&self.admission_closed) {
            let pending=lock(&self.jobs).iter().filter_map(Weak::upgrade)
                .filter(|job|lock(&job.retained_decoder).as_ref().is_some_and(|owner|!owner.is_drained())).count();
            if pending!=0{return json!({"phase":"draining","pending":pending,"outcome_unknown":true,
                "message":"owned decoder exit remains unverified; retry checked Close","pid":0});}
        }

        let owner = lock(&self.owner);
        match &*owner {
            Owner::Ready(b) | Owner::Draining(b) => {
                let s = b.status();
                let phase = if matches!(&*owner, Owner::Draining(_)) {
                    "draining".to_string()
                } else {
                    format!("{:?}", s.phase).to_lowercase()
                };
                json!({"phase":phase,"pending":s.pending,"outcome_unknown":s.outcome_unknown,"message":s.message,"pid":s.pid})
            }
            Owner::Retained(e) => {
                let state = lock(&self.shutdown_state);
                let phase = if state.running || state.result.is_some() {
                    "draining"
                } else {
                    "retained_startup"
                };
                json!({"phase":phase,"pending":0,"outcome_unknown":true,"message":e.to_string(),"pid":0})
            }
            Owner::Closed => {
                json!({"phase":"closed","pending":0,"outcome_unknown":false,"message":null,"pid":0})
            }
        }
    }
    fn shutdown(&self) -> Result<Value> {
        // Admission publishes under this same mutex, so both owner lists
        // are final before cancellation and callback admission are closed.
        *lock(&self.admission_closed) = true;
        for cb in lock(&self.callbacks).iter().filter_map(Weak::upgrade) {
            cb.close();
        }
        for job in lock(&self.jobs).iter().filter_map(Weak::upgrade) {
            job.cancel();
        }
        let mut owner = lock(&self.owner);
        if matches!(&*owner, Owner::Closed) {
            if lock(&self.jobs).iter().filter_map(Weak::upgrade).any(|job|!job.done()) {
                return Err(error("draining","waiting for owned decoder drain/job completion"));
            }
            return Ok(json!({"phase":"closed"}));
        }
        let mut state = lock(&self.shutdown_state);
        if state.running {
            return Err(error(
                "draining",
                "checked shutdown remains owned by background receiver",
            ));
        }
        if state.result.as_ref().is_some_and(|r| r.is_err()) {
            let Some(Err(e)) = state.result.take() else {
                unreachable!()
            };
            return Err(error("draining", e.message));
        }
        if state.result.is_none() {
            let closing = owner.clone();
            if let Owner::Ready(b) = &*owner {
                *owner = Owner::Draining(b.clone());
            }
            state.running = true;
            let shared = self.shutdown_state.clone();
            #[cfg(test)]
            let gate = lock(&SHUTDOWN_GATE).take();
            if let Err(e) = std::thread::Builder::new()
                .name("LensWorks checked catalog shutdown".into())
                .spawn(move || {
                    #[cfg(test)]
                    if let Some(gate) = gate {
                        while !gate.load(Ordering::Acquire) {
                            std::thread::sleep(Duration::from_millis(2));
                        }
                    }
                    let result = fenced(|| match closing {
                        Owner::Ready(b) | Owner::Draining(b) => b.try_shutdown().map_err(native),
                        Owner::Retained(e) => {
                            if let Some(s) = e.downcast_ref::<StartupFailure>() {
                                s.try_shutdown().map_err(native)
                            } else if let Some(s) =
                                e.downcast_ref::<app::desktop::RetainedStartup>()
                            {
                                s.try_shutdown().map_err(native)
                            } else {
                                Ok(())
                            }
                        }
                        Owner::Closed => Ok(()),
                    });
                    let mut state = lock(&shared);
                    state.result = Some(result);
                    state.running = false;
                })
            {
                state.running = false;
                return Err(error(
                    "draining",
                    format!("shutdown receiver admission failed: {e}"),
                ));
            }
            return Err(error(
                "draining",
                "checked shutdown admitted; poll until closed",
            ));
        }
        // Decoder jobs are independent child owners; don't release admission until
        // cancellation has actually reaped them and completed receivers.
        if lock(&self.jobs)
            .iter()
            .filter_map(Weak::upgrade)
            .any(|j| !j.done())
        {
            return Err(error(
                "draining",
                "waiting for job receivers/decoder children",
            ));
        }
        *owner = Owner::Closed;
        if self.live.swap(false, Ordering::AcqRel) {
            OWNERS.fetch_sub(1, Ordering::AcqRel);
        }
        Ok(json!({"phase":"closed"}))
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if self.live.load(Ordering::Acquire) {
            let _ = self.shutdown();
        }
    }
}
enum Bytes {
    Owned(Vec<u8>),
    Preview(app::PreviewBytes),
    SourcePlane { plane: crate::full_decode::SourcePlane, session: u64 },
}
impl Bytes {
    fn bytes(&self) -> &[u8] {
        match self {
            Self::Owned(b) => b,
            Self::Preview(b) => b.bytes(),
            Self::SourcePlane { .. } => &[],
        }
    }
}
struct Buffer {
    bytes: Bytes,
    descriptor: Value,
    _lease: Lease,
}
struct Hasher {
    state: Mutex<Option<blake3::Hasher>>,
}
impl Hasher {
    fn reserve() -> Result<Arc<Self>> {
        LIVE_HASHERS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < MAX_HASHERS).then_some(n + 1)
            })
            .map_err(|_| error("resource_limit", "sixteen live hasher allowance"))?;
        Ok(Arc::new(Self {
            state: Mutex::new(Some(blake3::Hasher::new())),
        }))
    }
}
impl Drop for Hasher {
    fn drop(&mut self) {
        LIVE_HASHERS.fetch_sub(1, Ordering::AcqRel);
    }
}
struct JobState {
    result: Option<Result<Buffer>>,
    taken: bool,
}
struct Job {
    session: Arc<Session>,
    state: Mutex<JobState>,
    cancel: Mutex<Option<app::Cancellation>>,
    local_cancel: Arc<AtomicBool>,
    handle: Mutex<u64>,
    lease: Mutex<Option<Lease>>,
    worker: Mutex<Option<FloatWorkerLease>>,
    retained_decoder: Mutex<Option<Arc<crate::full_decode::RetainedDecoder>>>,
}
impl Drop for Job {
    fn drop(&mut self) {
        LIVE_JOBS.fetch_sub(1, Ordering::AcqRel);
    }
}
impl Job {
    fn cancel(&self) {
        self.local_cancel.store(true, Ordering::Release);
        if let Some(c) = &*lock(&self.cancel) {
            c.cancel();
        }
    }
    fn done(&self) -> bool {
        { let s=lock(&self.state); if s.result.is_none() && !s.taken {return false;} }
        let mut retained=lock(&self.retained_decoder);
        if let Some(owner)=retained.as_ref() {
            if owner.try_drain().is_err(){return false;}
            retained.take();
        }
        lock(&self.worker).take();true
    }
    fn register_decoder(&self, owner:Arc<crate::full_decode::RetainedDecoder>) {
        // Published immediately after spawn, before polling/allocation can fail
        // or unwind. One admitted worker has exactly one retained child owner.
        *lock(&self.retained_decoder)=Some(owner);
    }
    fn decode_failure(&self, failure:anyhow::Error)->Error {
        // Forward the complete context chain: the outer refusal alone hides the
        // worker cause (exit status, stderr diagnostic, frame or admission error).
        let message=format!("{failure:#}");
        if let Some(retained)=failure.downcast_ref::<crate::full_decode::RetainedDecodeFailure>() {
            *lock(&self.retained_decoder)=Some(retained.owner.clone());
            return error("draining",message);
        }
        if self.local_cancel.load(Ordering::Acquire){error("canceled",message)}else{native(message)}
    }
    fn finish(&self, result: Result<Buffer>) {
        *lock(&self.cancel) = None;
        lock(&self.lease).take();
        lock(&self.state).result = Some(result);
        // Receiver completion alone is not child drain. Preserve the worker slot
        // on unverified termination until a checked Close/JobRelease retry.
        let _ = self.done();
        let callbacks: Vec<_> = lock(&self.session.callbacks)
            .iter()
            .filter_map(Weak::upgrade)
            .collect();
        for cb in callbacks {
            let session = *lock(&self.session.handle);
            let job = *lock(&self.handle);
            cb.fire(session, job);
        }
    }
}
pub type Completion = unsafe extern "C" fn(*mut c_void, u64, u64);
struct CallbackState {
    closed: bool,
    inflight: usize,
}
struct Subscription {
    callback: Completion,
    context: usize,
    state: Mutex<CallbackState>,
    drained: Condvar,
    handle: Mutex<u64>,
}
thread_local! {static IN_CALLBACK:std::cell::Cell<u64>=const{std::cell::Cell::new(0)};}
impl Subscription {
    fn close(&self) {
        lock(&self.state).closed = true;
    }
    fn fire(&self, session: u64, job: u64) {
        {
            let mut s = lock(&self.state);
            if s.closed {
                return;
            }
            s.inflight += 1;
        }
        let id = *lock(&self.handle);
        IN_CALLBACK.with(|v| {
            let old = v.replace(id);
            unsafe { (self.callback)(self.context as *mut c_void, session, job) };
            v.set(old);
        });
        let mut s = lock(&self.state);
        s.inflight -= 1;
        self.drained.notify_all();
    }
    fn drain(&self, timeout: Duration) -> Result<()> {
        self.close();
        if IN_CALLBACK.with(|v| v.get() == *lock(&self.handle)) {
            return Err(error("busy", "callback cannot drain itself"));
        }
        let until = Instant::now() + timeout;
        let mut s = lock(&self.state);
        while s.inflight != 0 {
            let now = Instant::now();
            if now >= until {
                return Err(error("busy", "callback drain timed out"));
            }
            let (next, _) = self
                .drained
                .wait_timeout(s, until - now)
                .unwrap_or_else(|e| e.into_inner());
            s = next;
        }
        Ok(())
    }
}
#[derive(Clone)]
enum Entry {
    Session(Arc<Session>),
    Job(Arc<Job>),
    Buffer(Arc<Buffer>),
    ReservedResponse(Arc<Buffer>),
    Subscription(Arc<Subscription>),
    Hasher(Arc<Hasher>),
}
impl Entry {
    fn kind(&self) -> u64 {
        match self {
            Self::Session(_) => 1,
            Self::Job(_) => 2,
            Self::Buffer(_) | Self::ReservedResponse(_) => 3,
            Self::Subscription(_) => 4,
            Self::Hasher(_) => 5,
        }
    }
}
struct Slot {
    generation: u32,
    entry: Option<Entry>,
}
#[derive(Default)]
struct Registry {
    slots: Vec<Slot>,
}
impl Registry {
    fn insert(&mut self, e: Entry) -> Result<u64> {
        if matches!(&e, Entry::Job(_))
            && self
                .slots
                .iter()
                .filter(|s| matches!(s.entry, Some(Entry::Job(_))))
                .count()
                >= MAX_JOBS
        {
            return Err(error("resource_limit", "job handle allowance"));
        }
        if matches!(&e, Entry::Buffer(_) | Entry::ReservedResponse(_))
            && self
                .slots
                .iter()
                .filter(|s| {
                    matches!(
                        &s.entry,
                        Some(Entry::Buffer(_) | Entry::ReservedResponse(_))
                    )
                })
                .count()
                >= MAX_BUFFERS
        {
            return Err(error("resource_limit", "buffer handle allowance"));
        }
        let i = if let Some(i) = self
            .slots
            .iter()
            .position(|s| s.entry.is_none() && s.generation < u32::MAX)
        {
            i
        } else {
            if self.slots.len() >= MAX_SLOTS {
                return Err(error("resource_limit", "handle allowance"));
            }
            self.slots.push(Slot {
                generation: 0,
                entry: None,
            });
            self.slots.len() - 1
        };
        let slot = &mut self.slots[i];
        slot.generation += 1;
        let id = (u64::from(slot.generation) << 32) | (e.kind() << 24) | (i as u64 + 1);
        slot.entry = Some(e);
        Ok(id)
    }
    fn get(&self, h: u64, kind: u64) -> Result<Entry> {
        let index = (h & 0xffffff)
            .checked_sub(1)
            .ok_or_else(|| error("invalid_handle", "zero handle"))? as usize;
        let slot = self
            .slots
            .get(index)
            .ok_or_else(|| error("invalid_handle", "unknown handle"))?;
        if u64::from(slot.generation) != h >> 32 || (h >> 24) & 255 != kind {
            return Err(error("invalid_handle", "stale or wrong-kind handle"));
        }
        if matches!(&slot.entry, Some(Entry::ReservedResponse(_))) {
            return Err(error("invalid_handle", "response handle is not published"));
        }
        slot.entry
            .clone()
            .filter(|e| e.kind() == kind)
            .ok_or_else(|| error("invalid_handle", "released handle"))
    }
    fn remove(&mut self, h: u64, kind: u64) -> Result<Entry> {
        let e = self.get(h, kind)?;
        self.slots[((h & 0xffffff) - 1) as usize].entry = None;
        Ok(e)
    }
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
fn session(h: u64) -> Result<Arc<Session>> {
    if let Entry::Session(s) = lock(registry()).get(h, 1)? {
        if !s.published.load(Ordering::Acquire) {
            return Err(error("invalid_handle", "session handle is not published"));
        }
        Ok(s)
    } else {
        unreachable!()
    }
}
fn job(h: u64) -> Result<Arc<Job>> {
    if let Entry::Job(j) = lock(registry()).get(h, 2)? {
        Ok(j)
    } else {
        unreachable!()
    }
}
fn source_plane_buffer(handle: u64, session_handle: u64) -> Result<Arc<Buffer>> {
    let Entry::Buffer(buffer) = lock(registry()).get(handle, 3)? else { unreachable!() };
    let Bytes::SourcePlane { session: owner, .. } = &buffer.bytes else {
        return Err(error("invalid_handle", "expected source plane buffer"));
    };
    if *owner != session_handle {
        return Err(error("invalid_handle", "source plane belongs to a different session"));
    }
    Ok(buffer)
}
fn decimal(s: &str) -> Result<u64> {
    let n = s
        .parse::<u64>()
        .map_err(|_| error("invalid_request", "handle requires decimal string"))?;
    if n.to_string() != s {
        return Err(error("invalid_request", "noncanonical decimal handle"));
    }
    Ok(n)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    payload_bytes: Option<app::U64>,
    worker_bytes: Option<app::U64>,
    worker_executable: NativePath,
    decode_worker_executable: Option<NativePath>,
    cache_root: Option<NativePath>,
    #[serde(default)]
    original_roots: Vec<NativePath>,
    #[serde(default)]
    limits: app::Limits,
    #[serde(default)]
    preview_policy: photocatalog::preview::PreviewPolicy,
    #[serde(default)]
    preview_limits: photocatalog::preview::ServiceLimits,
}
fn path(p: NativePath) -> Result<std::path::PathBuf> {
    if match &p {
        NativePath::UnixBytes(v) => v.len() > 32768,
        NativePath::WindowsWide(v) => v.len() > 16384,
    } {
        return Err(error("invalid_request", "native path exceeds 32768 bytes"));
    }
    let p = p.to_path().map_err(native)?;
    if !p.is_absolute()
        || p.components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
    {
        return Err(error(
            "invalid_request",
            "absolute native path without parent traversal required",
        ));
    }
    Ok(p)
}
fn admission(e: super::Failure) -> Error {
    error(e.code, e.message)
}
fn prospective(p: &std::path::Path) -> Result<std::path::PathBuf> {
    let mut probe = p.to_path_buf();
    let mut suffix = Vec::new();
    loop {
        match std::fs::canonicalize(&probe) {
            Ok(mut root) => {
                for leaf in suffix.into_iter().rev() {
                    root = root.join(leaf);
                }
                return Ok(root);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let leaf = probe
                    .file_name()
                    .ok_or_else(|| {
                        error("invalid_request", "native path has no existing ancestor")
                    })?
                    .to_os_string();
                suffix.push(leaf);
                if !probe.pop() {
                    return Err(error("invalid_request", "native path has no parent"));
                }
            }
            Err(e) => return Err(native(e)),
        }
    }
}
fn managed_cache(cache: &std::path::Path) -> Result<()> {
    for directory in [
        cache.to_path_buf(),
        cache.join("manifest"),
        cache.join("thumbnail"),
        cache.join("large"),
        cache.join("manifest/workers"),
        cache.join("manifest/prepared"),
    ] {
        super::managed_entry(&directory, true).map_err(admission)?;
    }
    for file in [
        "previews.sqlite3",
        "previews.sqlite3-wal",
        "previews.sqlite3-shm",
        "previews.sqlite3-journal",
        "preview.lock",
    ] {
        super::managed_entry(&cache.join("manifest").join(file), false).map_err(admission)?;
    }
    for tier in ["thumbnail", "large"] {
        for prefix in 0..256 {
            super::managed_entry(&cache.join(tier).join(format!("{prefix:02x}")), true)
                .map_err(admission)?;
        }
    }
    Ok(())
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    SessionCreate {
        config: Box<Config>,
    },
    SessionStatus {
        session: String,
    },
    SessionShutdown {
        session: String,
    },
    SessionRelease {
        session: String,
    },
    Submit {
        session: String,
        request: Box<app::Request>,
    },
    PreviewBytes {
        session: String,
        catalog: String,
        ticket: String,
        foreground: bool,
    },
    JobStatus {
        job: String,
    },
    JobCancel {
        job: String,
    },
    JobResult {
        job: String,
    },
    JobRelease {
        job: String,
    },
    SourceIdentity {
        session: String,
        catalog: String,
        export_job: String,
        sequence: app::I64,
    },
    DocumentSourceRevision {
        session: String,
        original: NativePath,
        max_encoded_bytes: app::U64,
    },
    DevelopDocumentSource {
        session: String,
        source: crate::full_decode::SourceDevelopment,
        tile: Option<crate::full_decode::SourceTileRect>,
        limits: app::exports::DecodeLimits,
        worker_bytes: app::U64,
        max_output_bytes: app::U64,
    },
    OpenDocumentSourcePlane {
        session: String,
        source: crate::full_decode::SourceDevelopment,
        limits: app::exports::DecodeLimits,
        worker_bytes: app::U64,
    },
    DocumentSourcePlaneTile {
        session: String,
        plane: String,
        tile: crate::full_decode::SourceTileRect,
        max_output_bytes: app::U64,
    },
    DecodeFull {
        session: String,
        catalog: String,
        export_job: String,
        sequence: app::I64,
        limits: app::exports::DecodeLimits,
        worker_bytes: app::U64,
        max_output_bytes: app::U64,
    },
}
#[derive(Deserialize)]
struct Envelope {
    version: u32,
    #[serde(flatten)]
    command: Command,
}
fn new_job(s: Arc<Session>, bytes: usize) -> Result<(u64, Arc<Job>)> {
    let admission = lock(&s.admission_closed);
    if *admission {
        return Err(error("closed", "session admission is closed"));
    }
    let lease = Lease::reserve(bytes)?;
    LIVE_JOBS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < MAX_JOBS).then_some(n + 1)
        })
        .map_err(|_| error("resource_limit", "live receiver/job allowance"))?;
    let j = Arc::new(Job {
        session: s.clone(),
        state: Mutex::new(JobState {
            result: None,
            taken: false,
        }),
        cancel: Mutex::new(None),
        local_cancel: Arc::new(AtomicBool::new(false)),
        handle: Mutex::new(0),
        lease: Mutex::new(Some(lease)),
        worker: Mutex::new(None),
        retained_decoder: Mutex::new(None),
    });
    let h = lock(registry()).insert(Entry::Job(j.clone()))?;
    *lock(&j.handle) = h;
    {
        let mut jobs = lock(&s.jobs);
        jobs.retain(|w| w.strong_count() != 0);
        jobs.push(Arc::downgrade(&j));
    }
    drop(admission);
    Ok((h, j))
}
type Operation = Box<dyn FnOnce(&Arc<Job>) -> Result<Buffer> + Send>;
#[cfg(test)]
static FAIL_SPAWN: AtomicBool = AtomicBool::new(false);
fn prepare_receiver(j: Arc<Job>) -> Option<std::sync::mpsc::SyncSender<Operation>> {
    #[cfg(test)]
    if FAIL_SPAWN.swap(false, Ordering::AcqRel) {
        j.finish(Err(error(
            "resource_limit",
            "injected receiver admission failure before effects",
        )));
        return None;
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel::<Operation>(1);
    let owner = j.clone();
    if let Err(e) = std::thread::Builder::new()
        .name("LensWorks catalog receiver".into())
        .spawn(move || {
            let result = match receiver.recv() {
                Ok(f) => fenced(|| f(&owner)),
                Err(_) => Err(error(
                    "canceled",
                    "receiver admission abandoned before submission",
                )),
            };
            owner.finish(result);
        })
    {
        j.finish(Err(error(
            "resource_limit",
            format!("receiver admission failed before effects: {e}"),
        )));
        return None;
    }
    Some(sender)
}
fn dispatch_receiver(
    j: Arc<Job>,
    sender: std::sync::mpsc::SyncSender<Operation>,
    f: impl FnOnce(&Arc<Job>) -> Result<Buffer> + Send + 'static,
) {
    if sender.send(Box::new(f)).is_err() {
        j.cancel();
        j.finish(Err(error("outcome_unknown","receiver stopped after admission; cancellation requested; inspect retained durable operation status")));
    }
}
fn spawn_job(
    j: Arc<Job>,
    f: impl FnOnce(&Arc<Job>) -> Result<Buffer> + Send + 'static,
) -> Result<()> {
    if let Some(sender) = prepare_receiver(j.clone()) {
        dispatch_receiver(j, sender, f);
    }
    Ok(())
}
fn json_buffer(v: impl serde::Serialize, mut lease: Lease) -> Result<Buffer> {
    let bytes = serde_json::to_vec(&v).map_err(native)?;
    if bytes.len() > MAX_INPUT || bytes.len() > lease.bytes {
        return Err(error("resource_limit", "JSON result exceeds reservation"));
    }
    lease.shrink(bytes.len());
    Ok(Buffer {
        bytes: Bytes::Owned(bytes),
        descriptor: json!({"kind":"json","mime":"application/json"}),
        _lease: lease,
    })
}
fn plan(
    s: &Arc<Session>,
    j: &Arc<Job>,
    catalog: String,
    export_job: String,
    sequence: app::I64,
) -> Result<app::exports::Plan> {
    s.preflight_catalog(&catalog)?;
    let pending = s
        .bridge()?
        .submit(app::Request::Export {
            catalog,
            request: Box::new(app::exports::Request::Plan {
                job: export_job,
                sequence,
            }),
        })
        .map_err(retained)?;
    *lock(&j.cancel) = Some(pending.cancellation());
    if j.local_cancel.load(Ordering::Acquire) {
        pending.cancel();
    }
    match pending.recv() {
        app::Reply::Ok {
            value: app::Response::Export(v),
        } => {
            if let app::exports::Response::Plan(p) = *v {
                Ok(*p)
            } else {
                Err(error("native", "expected retained export plan"))
            }
        }
        app::Reply::Error { error: e } => Err(retained(e)),
        _ => Err(error("native", "unexpected retained plan response")),
    }
}
fn execute(bytes: &[u8]) -> Result<Value> {
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|e| error("invalid_request", e))?;
    if envelope.version != 2 {
        return Err(error("invalid_request", "expected managed ABI version 2"));
    }
    match envelope.command {
        Command::SessionCreate { config } => {
            let payload = config
                .payload_bytes
                .map_or(MAX_BUFFER_BYTES as u64, |v| v.0);
            let worker_limit = config.worker_bytes.map_or(4 * 1024 * 1024 * 1024, |v| v.0);
            if payload < MAX_INPUT as u64 * 2
                || payload > MAX_CONFIGURED_BYTES as u64
                || worker_limit == 0
                || worker_limit > MAX_CONFIGURED_BYTES as u64
            {
                return Err(error(
                    "resource_limit",
                    "finite session owner budgets outside platform envelope",
                ));
            }
            let worker = path(config.worker_executable)?;
            let decode = path(
                config
                    .decode_worker_executable
                    .unwrap_or_else(|| NativePath::from_path(&worker)),
            )?;
            let config = app::Config {
                worker_executable: worker,
                cache_root: config.cache_root.map(path).transpose()?,
                original_roots: config
                    .original_roots
                    .into_iter()
                    .map(path)
                    .collect::<Result<_>>()?,
                preview_policy: config.preview_policy,
                preview_limits: config.preview_limits,
                limits: config.limits,
            };
            if let Some(root) = &config.cache_root {
                super::managed_entry(root, true).map_err(admission)?;
            }
            let s = Arc::new(Session {
                published: AtomicBool::new(false),
                admission_closed: Mutex::new(false),
                catalog_roots: Mutex::new(std::collections::HashMap::new()),
                worker_limit,
                cache_root: config.cache_root.clone(),
                owner: Mutex::new(Owner::Closed),
                shutdown_state: Arc::default(),
                live: AtomicBool::new(false),
                handle: Mutex::new(0),
                callbacks: Mutex::new(Vec::new()),
                jobs: Mutex::new(Vec::new()),
                decode_worker: decode,
                original_roots: config.original_roots.iter().map(|root| std::fs::canonicalize(root).map_err(native)).collect::<Result<Vec<_>>>()?,
            });
            let h = lock(registry()).insert(Entry::Session(s.clone()))?;
            *lock(&s.handle) = h;
            {
                let _legacy = lock(&super::REQUEST_LOCK);
                if payload as usize != PAYLOAD_LIMIT.load(Ordering::Acquire) {
                    if OWNERS.load(Ordering::Acquire) != 0
                        || PAYLOAD_BYTES.load(Ordering::Acquire) > MAX_INPUT
                    {
                        lock(registry()).remove(h, 1)?;
                        return Err(error(
                            "busy",
                            "changing process payload pool requires all previous owners/buffers released",
                        ));
                    }
                    PAYLOAD_LIMIT.store(payload as usize, Ordering::Release);
                }
                if OWNERS
                    .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                        (n < MAX_SESSIONS).then_some(n + 1)
                    })
                    .is_err()
                {
                    lock(registry()).remove(h, 1)?;
                    return Err(error(
                        "resource_limit",
                        "four retained session owner allowance",
                    ));
                }
                s.live.store(true, Ordering::Release);
            }
            #[cfg(test)]
            if let Some(gate) = lock(&STARTUP_GATE).take() {
                *lock(&gate.handle) = Some(h);
                while !gate.resume.load(Ordering::Acquire) {
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
            *lock(&s.owner) = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                DesktopBridge::spawn(config)
            })) {
                Ok(Ok(b)) => Owner::Ready(b),
                Ok(Err(e)) => Owner::Retained(Arc::new(e)),
                Err(_) => Owner::Retained(Arc::new(anyhow::anyhow!(
                    "managed startup panic fenced; cleanup state requires shutdown"
                ))),
            };
            s.published.store(true, Ordering::Release);
            Ok(
                json!({"session":h.to_string(),"phase":s.status()["phase"],"source_revision":super::SOURCE_REVISION}),
            )
        }
        Command::SessionStatus { session: h } => Ok(session(decimal(&h)?)?.status()),
        Command::SessionShutdown { session: h } => session(decimal(&h)?)?.shutdown(),
        Command::SessionRelease { session: h } => {
            let h = decimal(&h)?;
            let s = session(h)?;
            if !matches!(*lock(&s.owner), Owner::Closed) ||
                lock(&s.jobs).iter().filter_map(Weak::upgrade).any(|job|!job.done()) {
                return Err(error("busy", "checked shutdown and every owned decoder drain must finish before release"));
            }
            lock(registry()).remove(h, 1)?;
            Ok(json!({"released":true}))
        }
        Command::Submit {
            session: h,
            request,
        } => {
            let s = session(decimal(&h)?)?;
            let bridge = s.bridge()?;
            s.preflight(&request)?;
            let opened = match &*request {
                app::Request::Create { path } | app::Request::OpenExisting { path } => {
                    Some(prospective(&path.to_path().map_err(native)?)?)
                }
                _ => None,
            };
            let closing = matches!(&*request, app::Request::Close { .. });
            let (h, j) = new_job(s, MAX_INPUT)?;
            let Some(receiver) = prepare_receiver(j.clone()) else {
                return Ok(json!({"job":h.to_string()}));
            };
            let p = match bridge.submit(*request) {
                Ok(p) => p,
                Err(e) => {
                    lock(registry()).remove(h, 2)?;
                    return Err(retained(e));
                }
            };
            *lock(&j.cancel) = Some(p.cancellation());
            dispatch_receiver(j, receiver, move |j| {
                let reply = p.recv();
                if let app::Reply::Ok {
                    value: app::Response::Status(status),
                } = &reply
                {
                    if let (Some(root), Some(catalog)) = (opened, status.catalog.as_ref()) {
                        let mut roots = lock(&j.session.catalog_roots);
                        roots.clear();
                        roots.insert(catalog.clone(), root);
                    } else if closing && status.catalog.is_none() {
                        lock(&j.session.catalog_roots).clear();
                    }
                }
                json_buffer(reply, lock(&j.lease).take().unwrap())
            });
            Ok(json!({"job":h.to_string()}))
        }
        Command::PreviewBytes {
            session: h,
            catalog,
            ticket,
            foreground,
        } => {
            let s = session(decimal(&h)?)?;
            s.preflight_catalog(&catalog)?;
            let bridge = s.bridge()?;
            let (h, j) = new_job(s, 32 * 1024 * 1024)?;
            let Some(receiver) = prepare_receiver(j.clone()) else {
                return Ok(json!({"job":h.to_string()}));
            };
            let p = match bridge.preview_bytes(catalog, ticket, foreground) {
                Ok(p) => p,
                Err(e) => {
                    lock(registry()).remove(h, 2)?;
                    return Err(retained(e));
                }
            };
            *lock(&j.cancel) = Some(p.cancellation());
            dispatch_receiver(j, receiver, move |j| {
                let b = p.recv().map_err(retained)?;
                let descriptor = json!({"kind":"preview","mime":b.mime});
                let mut lease = lock(&j.lease).take().unwrap();
                if b.bytes().len() > lease.bytes {
                    return Err(error("resource_limit", "preview result reservation"));
                }
                lease.shrink(b.bytes().len());
                Ok(Buffer {
                    bytes: Bytes::Preview(b),
                    descriptor,
                    _lease: lease,
                })
            });
            Ok(json!({"job":h.to_string()}))
        }
        Command::JobStatus { job: h } => {
            let j = job(decimal(&h)?)?;
            let s = lock(&j.state);
            Ok(
                json!({"phase":if s.taken{"taken"}else if s.result.is_some(){"complete"}else{"pending"},"cancel_requested":j.local_cancel.load(Ordering::Acquire),"failed":s.result.as_ref().is_some_and(|r|r.is_err())}),
            )
        }
        Command::JobCancel { job: h } => {
            job(decimal(&h)?)?.cancel();
            Ok(json!({"cancel_requested":true}))
        }
        Command::JobResult { job: h } => {
            let j = job(decimal(&h)?)?;
            let mut s = lock(&j.state);
            if s.taken {
                return Err(error("already_taken", "job result already taken"));
            }
            let value = s
                .result
                .take()
                .ok_or_else(|| error("busy", "job is pending"))?;
            match value {
                Err(e) => {
                    s.taken = true;
                    Err(e)
                }
                Ok(b) => {
                    let length = b.bytes.bytes().len();
                    let descriptor = b.descriptor.clone();
                    let b = Arc::new(b);
                    match lock(registry()).insert(Entry::Buffer(b.clone())) {
                        Ok(h) => {
                            s.taken = true;
                            Ok(
                                json!({"buffer":h.to_string(),"length":length.to_string(),"descriptor":descriptor}),
                            )
                        }
                        Err(e) => {
                            s.result = Some(Ok(Arc::try_unwrap(b).ok().unwrap()));
                            Err(e)
                        }
                    }
                }
            }
        }
        Command::JobRelease { job: h } => {
            let h = decimal(&h)?;
            let j = job(h)?;
            if !j.done() {
                return Err(error("busy", "cancel and await completion before release"));
            }
            lock(registry()).remove(h, 2)?;
            Ok(json!({"released":true}))
        }
        Command::SourceIdentity {
            session: h,
            catalog,
            export_job,
            sequence,
        } => {
            let s = session(decimal(&h)?)?;
            s.bridge()?;
            let (h, j) = new_job(s.clone(), MAX_INPUT)?;
            spawn_job(j, move |j| {
                json_buffer(
                    plan(&s, j, catalog, export_job, sequence)?,
                    lock(&j.lease).take().unwrap(),
                )
            })?;
            Ok(json!({"job":h.to_string()}))
        }
        Command::DocumentSourceRevision { session: h, original, max_encoded_bytes } => {
            let s = session(decimal(&h)?)?;
            s.bridge()?;
            if max_encoded_bytes.0 == 0 || max_encoded_bytes.0 == u64::MAX || max_encoded_bytes.0 > s.worker_limit {
                return Err(error("resource_limit", "explicit original read allowance required"));
            }
            let source = s.document_source(&original)?;
            let (h, j) = new_job(s.clone(), MAX_INPUT)?;
            spawn_job(j, move |j| {
                if j.local_cancel.load(Ordering::Acquire) { return Err(error("canceled", "original inspection canceled")); }
                let revision: app::exports::FileRevision = photocatalog::metadata_export::inspect_file_revision_with_checkpoint(&source, max_encoded_bytes.0, &mut |_| {
                    if j.local_cancel.load(Ordering::Acquire) {
                        return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "original inspection canceled"));
                    }
                    Ok(())
                }).map_err(native)?.into();
                if j.local_cancel.load(Ordering::Acquire) { return Err(error("canceled", "original inspection canceled")); }
                s.document_source(&original)?;
                json_buffer(json!({"original":original,"original_revision":revision,"source_revision":super::SOURCE_REVISION,"protocol":2}), lock(&j.lease).take().unwrap())
            })?;
            Ok(json!({"job":h.to_string()}))
        }
        Command::DevelopDocumentSource { session: h, source, tile, limits, worker_bytes, max_output_bytes } => {
            let s = session(decimal(&h)?)?;
            s.bridge()?;
            s.document_source(&source.original)?;
            if worker_bytes.0 == 0 || worker_bytes.0 > s.worker_limit || max_output_bytes.0 == 0
                || max_output_bytes.0 > PAYLOAD_LIMIT.load(Ordering::Acquire) as u64 {
                return Err(error("resource_limit", "document decode outside worker/result allowance"));
            }
            if let Some(rect) = tile { rect.validate(None, max_output_bytes.0).map_err(native)?; }
            let (h, j) = new_job(s.clone(), max_output_bytes.0 as usize)?;
            spawn_job(j, move |j| {
                *lock(&j.worker)=Some(FloatWorkerLease::reserve()?);
                s.document_source(&source.original)?;
                let decoded = match tile {
                    Some(tile) => crate::full_decode::run_source_tile(&s.decode_worker, source.clone(), tile, limits, worker_bytes.0, max_output_bytes.0, &j.local_cancel, &|owner|j.register_decoder(owner)),
                    None => crate::full_decode::run_source(&s.decode_worker, source.clone(), limits, worker_bytes.0, max_output_bytes.0, &j.local_cancel, &|owner|j.register_decoder(owner)),
                };
                let (bytes, descriptor) = decoded.map_err(|e|j.decode_failure(e))?;
                if j.local_cancel.load(Ordering::Acquire) { return Err(error("canceled", "document decode canceled after worker drain")); }
                s.document_source(&source.original)?;
                let mut lease = lock(&j.lease).take().unwrap(); lease.shrink(bytes.len());
                Ok(Buffer { bytes: Bytes::Owned(bytes), descriptor, _lease:lease })
            })?;
            Ok(json!({"job":h.to_string()}))
        }
        Command::OpenDocumentSourcePlane { session: h, source, limits, worker_bytes } => {
            let session_handle = decimal(&h)?;
            let s = session(session_handle)?; s.bridge()?; s.document_source(&source.original)?;
            if worker_bytes.0 == 0 || worker_bytes.0 > s.worker_limit {
                return Err(error("resource_limit", "source plane decode outside worker allowance"));
            }
            // Only bounded descriptor/validation scratch occupies this managed result.
            // The complete immutable payload is held by an unlinked file, not a Vec.
            let (h, j) = new_job(s.clone(), MAX_INPUT)?;
            spawn_job(j, move |j| {
                *lock(&j.worker)=Some(FloatWorkerLease::reserve()?);
                s.document_source(&source.original)?;
                let plane = crate::full_decode::run_source_plane(&s.decode_worker, source.clone(), limits,
                    worker_bytes.0, &j.local_cancel, &|owner|j.register_decoder(owner)).map_err(|e|j.decode_failure(e))?;
                if j.local_cancel.load(Ordering::Acquire) { return Err(error("canceled", "source plane canceled after worker drain")); }
                s.document_source(&source.original)?;
                let mut descriptor = plane.descriptor.clone();
                descriptor["payload_digest"] = plane.payload_digest.clone().into();
                Ok(Buffer { bytes: Bytes::SourcePlane { plane, session: session_handle }, descriptor,
                    _lease: lock(&j.lease).take().unwrap() })
            })?;
            Ok(json!({"job":h.to_string()}))
        }
        Command::DocumentSourcePlaneTile { session: h, plane: p, tile, max_output_bytes } => {
            let session_handle = decimal(&h)?;
            let s = session(session_handle)?; s.bridge()?;
            let buffer = source_plane_buffer(decimal(&p)?, session_handle)?;
            if max_output_bytes.0 == 0 || max_output_bytes.0 > PAYLOAD_LIMIT.load(Ordering::Acquire) as u64 {
                return Err(error("resource_limit", "source tile outside result allowance"));
            }
            let required = tile.validate(None, max_output_bytes.0).map_err(native)?;
            let (h, j) = new_job(s, usize::try_from(required).map_err(native)?)?;
            spawn_job(j, move |j| {
                let Bytes::SourcePlane { plane, .. } = &buffer.bytes else { unreachable!() };
                let (bytes, descriptor) = plane.read_tile(tile, max_output_bytes.0, &j.local_cancel).map_err(|e|
                    if j.local_cancel.load(Ordering::Acquire) { error("canceled", e) } else { native(e) })?;
                if j.local_cancel.load(Ordering::Acquire) { return Err(error("canceled", "source tile canceled before publication")); }
                let mut lease = lock(&j.lease).take().unwrap(); lease.shrink(bytes.len());
                Ok(Buffer { bytes: Bytes::Owned(bytes), descriptor, _lease: lease })
            })?;
            Ok(json!({"job":h.to_string()}))
        }
        Command::DecodeFull {
            session: h,
            catalog,
            export_job,
            sequence,
            limits,
            worker_bytes,
            max_output_bytes,
        } => {
            let s = session(decimal(&h)?)?;
            s.bridge()?;
            if worker_bytes.0 == 0
                || max_output_bytes.0 == 0
                || max_output_bytes.0 > PAYLOAD_LIMIT.load(Ordering::Acquire) as u64
                || worker_bytes.0 > s.worker_limit
            {
                return Err(error(
                    "resource_limit",
                    "decode worker/output budget outside allowance",
                ));
            }
            let (h, j) = new_job(s.clone(), max_output_bytes.0 as usize)?;
            spawn_job(j, move |j| {
                *lock(&j.worker)=Some(FloatWorkerLease::reserve()?);
                let prepared = plan(&s, j, catalog.clone(), export_job.clone(), sequence)?;
                let (bytes, descriptor) = crate::full_decode::run(
                    &s.decode_worker,
                    prepared.clone(),
                    limits,
                    worker_bytes.0,
                    max_output_bytes.0,
                    &j.local_cancel,
                    &|owner|j.register_decoder(owner),
                )
                .map_err(|e|j.decode_failure(e))?;
                if j.local_cancel.load(Ordering::Acquire) {
                    return Err(error("canceled", "decode canceled after worker drain"));
                }
                let current = plan(&s, j, catalog, export_job, sequence)?;
                if serde_json::to_value(&current.identity).map_err(native)?
                    != serde_json::to_value(&prepared.identity).map_err(native)?
                    || current.authority != prepared.authority
                {
                    return Err(error(
                        "stale_session",
                        "plan authority changed during decode",
                    ));
                }
                let mut lease = lock(&j.lease).take().unwrap();
                lease.shrink(bytes.len());
                Ok(Buffer {
                    bytes: Bytes::Owned(bytes),
                    descriptor,
                    _lease: lease,
                })
            })?;
            Ok(json!({"job":h.to_string()}))
        }
    }
}
fn status(e: &Error) -> i32 {
    match e.code.as_str() {
        "invalid_handle" => 4,
        "range" => 5,
        "busy" => 6,
        "resource_limit" => 2,
        "panic" => 3,
        _ => 1,
    }
}
// Reserve both the response slot and its byte lease BEFORE executing any
// mutation. Taking a job result/session admission can never succeed silently
// and then lose its only public handle to response-allocation saturation.
struct ResponseReservation {
    handle: u64,
    published: bool,
}
impl ResponseReservation {
    fn reserve() -> Result<Self> {
        let lease = Lease::reserve(MAX_INPUT)?;
        let b = Arc::new(Buffer {
            bytes: Bytes::Owned(Vec::new()),
            descriptor: json!({"kind":"json"}),
            _lease: lease,
        });
        let handle = lock(registry()).insert(Entry::ReservedResponse(b))?;
        Ok(Self {
            handle,
            published: false,
        })
    }
    fn publish(mut self, value: Value) -> Result<u64> {
        let bytes = serde_json::to_vec(&value).map_err(native)?;
        // Mutating results contain only bounded handle/status fields or the float
        // descriptor (worker header <=1MiB). Oversize errors come from input parsing
        // before effects; replace only those errors with a bounded diagnostic.
        let bytes = if bytes.len() > MAX_INPUT {
            serde_json::to_vec(&envelope(Err(error(
                "resource_limit",
                "response error text exceeded allowance",
            ))))
            .unwrap()
        } else {
            bytes
        };
        let mut r = lock(registry());
        let index = ((self.handle & 0xffffff) - 1) as usize;
        let Some(Entry::ReservedResponse(b)) = r.slots[index].entry.take() else {
            return Err(error("invalid_handle", "response reservation lost"));
        };
        let mut b = Arc::try_unwrap(b).ok().unwrap();
        b._lease.shrink(bytes.len());
        b.bytes = Bytes::Owned(bytes);
        r.slots[index].entry = Some(Entry::Buffer(Arc::new(b)));
        self.published = true;
        Ok(self.handle)
    }
}
impl Drop for ResponseReservation {
    fn drop(&mut self) {
        if !self.published {
            let mut r = lock(registry());
            let index = ((self.handle & 0xffffff) - 1) as usize;
            if r.slots[index].generation as u64 == self.handle >> 32 {
                r.slots[index].entry = None;
            }
        }
    }
}
/// Caller must supply valid length-delimited input and writable output pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_blake3(
    bytes: *const u8,
    length: usize,
    out_digest: *mut u8,
) -> i32 {
    if out_digest.is_null() || (bytes.is_null() && length != 0) {
        return 1;
    }
    if length > MAX_INPUT {
        return 5;
    }
    match fenced(|| {
        let input = if length == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
        Ok(blake3::hash(input))
    }) {
        Ok(digest) => {
            unsafe { std::ptr::copy_nonoverlapping(digest.as_bytes().as_ptr(), out_digest, 32) };
            0
        }
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_blake3_init(out_hasher: *mut u64) -> i32 {
    if out_hasher.is_null() {
        return 1;
    }
    unsafe { *out_hasher = 0 };
    match fenced(|| lock(registry()).insert(Entry::Hasher(Hasher::reserve()?))) {
        Ok(h) => {
            unsafe { *out_hasher = h };
            0
        }
        Err(e) => status(&e),
    }
}
fn hasher(h: u64) -> Result<Arc<Hasher>> {
    match lock(registry()).get(h, 5)? {
        Entry::Hasher(owner) => Ok(owner),
        _ => unreachable!(),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_blake3_update(h: u64, bytes: *const u8, length: usize) -> i32 {
    if bytes.is_null() && length != 0 {
        return 1;
    }
    if length > MAX_INPUT {
        return 5;
    }
    match fenced(|| {
        let owner = hasher(h)?;
        let mut state = lock(&owner.state);
        let active = state
            .as_mut()
            .ok_or_else(|| error("busy", "hasher is finalized"))?;
        let input = if length == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
        active.update(input);
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_blake3_finalize(h: u64, out_digest: *mut u8) -> i32 {
    if out_digest.is_null() {
        return 1;
    }
    match fenced(|| {
        let owner = hasher(h)?;
        let active = lock(&owner.state)
            .take()
            .ok_or_else(|| error("busy", "hasher is finalized"))?;
        let digest = active.finalize();
        unsafe { std::ptr::copy_nonoverlapping(digest.as_bytes().as_ptr(), out_digest, 32) };
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn lw_catalog_blake3_release(h: u64) -> i32 {
    match fenced(|| {
        lock(registry()).remove(h, 5)?;
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}
/// Caller must supply valid length-delimited input and writable output pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_managed_request(
    request: *const u8,
    length: usize,
    out: *mut u64,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    unsafe {
        *out = 0;
    }
    if length > MAX_INPUT {
        return 2;
    }
    if request.is_null() && length != 0 {
        return 1;
    }
    let result = fenced(|| {
        let reservation = ResponseReservation::reserve()?;
        let bytes = if length == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(request, length) }
        };
        reservation.publish(envelope(fenced(|| execute(bytes))))
    });
    match result {
        Ok(h) => {
            unsafe { *out = h };
            0
        }
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_buffer_copy(
    h: u64,
    offset: usize,
    dst: *mut u8,
    capacity: usize,
    out: *mut usize,
) -> i32 {
    if out.is_null() || (dst.is_null() && capacity != 0) {
        return 1;
    }
    unsafe {
        *out = 0;
    }
    match fenced(|| {
        let Entry::Buffer(b) = lock(registry()).get(h, 3)? else {
            unreachable!()
        };
        if matches!(&b.bytes, Bytes::SourcePlane { .. }) { return Err(error("invalid_request", "source planes require an admitted bounded range job")); }
        let bytes = b.bytes.bytes();
        if offset > bytes.len() {
            return Err(error("range", "buffer offset"));
        }
        let n = capacity.min(bytes.len() - offset);
        if n != 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr().add(offset), dst, n);
            }
        }
        unsafe {
            *out = n;
        }
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn lw_catalog_buffer_release(h: u64) -> i32 {
    match fenced(|| {
        lock(registry()).remove(h, 3)?;
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}
fn admit_subscription(s: &Session, cb: Arc<Subscription>) -> Result<u64> {
    let admission = lock(&s.admission_closed);
    if *admission {
        return Err(error("closed", "session admission is closed"));
    }
    let id = lock(registry()).insert(Entry::Subscription(cb.clone()))?;
    *lock(&cb.handle) = id;
    let mut callbacks = lock(&s.callbacks);
    callbacks.retain(|w| w.strong_count() != 0);
    callbacks.push(Arc::downgrade(&cb));
    Ok(id)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_catalog_subscribe(
    h: u64,
    callback: Option<Completion>,
    context: *mut c_void,
    out: *mut u64,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    unsafe {
        *out = 0;
    }
    let Some(callback) = callback else {
        return 1;
    };
    match fenced(|| {
        let s = session(h)?;
        s.bridge()?;
        let cb = Arc::new(Subscription {
            callback,
            context: context as usize,
            state: Mutex::new(CallbackState {
                closed: false,
                inflight: 0,
            }),
            drained: Condvar::new(),
            handle: Mutex::new(0),
        });
        admit_subscription(&s, cb)
    }) {
        Ok(id) => {
            unsafe {
                *out = id;
            }
            0
        }
        Err(e) => status(&e),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn lw_catalog_unsubscribe_and_drain(h: u64, timeout_ms: u32) -> i32 {
    if timeout_ms > 60000 {
        return 1;
    }
    match fenced(|| {
        let Entry::Subscription(cb) = lock(registry()).get(h, 4)? else {
            unreachable!()
        };
        cb.drain(Duration::from_millis(timeout_ms.into()))?;
        lock(registry()).remove(h, 4)?;
        Ok(())
    }) {
        Ok(()) => 0,
        Err(e) => status(&e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_decoder_refuses_job_session_release_and_worker_readmission_until_checked_exit() {
        let _serial = crate::test_serial();
        let request=|value:Value|execute(&serde_json::to_vec(&value).unwrap());
        for unwind in [false,true] {
        let session=empty_session();
        let sh=lock(registry()).insert(Entry::Session(session.clone())).unwrap();
        *lock(&session.handle)=sh;
        let (handle,job)=new_job(session.clone(),128).unwrap();
        *lock(&job.worker)=Some(FloatWorkerLease::reserve().unwrap());
        let owner=crate::full_decode::source_tile_tests::retirement_owner();
        owner.refuse(true);
        job.register_decoder(owner.clone());
        let terminal = if unwind { fenced(||->Result<Buffer>{panic!("controlled receiver unwind after child registration")}) }
            else { Err(error("draining","injected drain uncertainty after actual child admission")) };
        job.finish(terminal);
        assert!(!job.done());assert_eq!(FLOAT_WORKERS.load(Ordering::Acquire),1);
        assert!(FloatWorkerLease::reserve().is_err());
        let refused=request(json!({"version":2,"op":"job_release","job":handle.to_string()})).unwrap_err();
        assert_eq!(refused.code,"busy");
        assert_eq!(session.shutdown().unwrap_err().code,"draining");
        assert_eq!(session.status()["phase"],"draining");assert_eq!(session.status()["outcome_unknown"],true);
        assert_eq!(request(json!({"version":2,"op":"session_release","session":sh.to_string()})).unwrap_err().code,"busy");
        assert!(matches!(lock(registry()).get(handle,2),Ok(Entry::Job(_))));
        owner.refuse(false);
        let deadline=Instant::now()+Duration::from_secs(5);
        while !job.done(){assert!(Instant::now()<deadline);std::thread::sleep(Duration::from_millis(2));}
        assert_eq!(FLOAT_WORKERS.load(Ordering::Acquire),0);
        assert!(lock(&job.retained_decoder).is_none());
        session.shutdown().unwrap();
        request(json!({"version":2,"op":"job_release","job":handle.to_string()})).unwrap();
        assert_eq!(request(json!({"version":2,"op":"job_release","job":handle.to_string()})).unwrap_err().code,"invalid_handle");
        request(json!({"version":2,"op":"session_release","session":sh.to_string()})).unwrap();
        let replacement=FloatWorkerLease::reserve().unwrap();drop(replacement);
        }
    }
    #[test]
    fn managed_source_plane_handle_binds_owner_and_retains_inflight_file() {
        let _serial = crate::test_serial();
        let initial = PAYLOAD_BYTES.load(Ordering::Acquire);
        let buffer = Buffer {
            bytes: Bytes::SourcePlane { plane: crate::full_decode::source_tile_tests::held_plane(), session: 123 },
            descriptor: json!({"kind":"source_float_plane"}),
            _lease: Lease::reserve(128).unwrap(),
        };
        let handle = lock(registry()).insert(Entry::Buffer(Arc::new(buffer))).unwrap();
        assert!(matches!(source_plane_buffer(handle,124),Err(e) if e.code=="invalid_handle"));
        let inflight = source_plane_buffer(handle,123).unwrap();
        let mut count = 99;
        let mut byte = 0;
        assert_ne!(unsafe { lw_catalog_buffer_copy(handle,0,&mut byte,1,&mut count) },0);
        assert_eq!(count,0);
        assert_eq!(lw_catalog_buffer_release(handle),0);
        assert!(matches!(source_plane_buffer(handle,123),Err(e) if e.code=="invalid_handle"));
        let Bytes::SourcePlane { plane, .. } = &inflight.bytes else { panic!() };
        let (bytes,_) = plane.read_tile(crate::full_decode::SourceTileRect{x:1,y:0,width:1,height:1},16,&AtomicBool::new(false)).unwrap();
        assert_eq!(f32::from_le_bytes(bytes[..4].try_into().unwrap()),-1.0);
        assert_eq!(PAYLOAD_BYTES.load(Ordering::Acquire),initial+128);
        drop(inflight);
        assert_eq!(PAYLOAD_BYTES.load(Ordering::Acquire),initial);
        let ordinary = json_buffer(json!({}),Lease::reserve(128).unwrap()).unwrap();
        let handle = lock(registry()).insert(Entry::Buffer(Arc::new(ordinary))).unwrap();
        assert!(matches!(source_plane_buffer(handle,123),Err(e) if e.code=="invalid_handle"));
        assert_eq!(lw_catalog_buffer_release(handle),0);
    }
    fn empty_session() -> Arc<Session> {
        Arc::new(Session {
            published: AtomicBool::new(true),
            admission_closed: Mutex::new(false),
            catalog_roots: Mutex::new(std::collections::HashMap::new()),
            worker_limit: 1024,
            cache_root: None,
            owner: Mutex::new(Owner::Closed),
            shutdown_state: Arc::default(),
            live: AtomicBool::new(false),
            handle: Mutex::new(0),
            callbacks: Mutex::new(Vec::new()),
            jobs: Mutex::new(Vec::new()),
            decode_worker: "/missing-worker".into(),
            original_roots: Vec::new(),
        })
    }
    fn close_session(s: &Session) {
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            match s.shutdown() {
                Ok(_) => return,
                Err(e) => {
                    assert_eq!(e.code, "draining");
                    assert!(Instant::now() < until, "{}", e.message);
                }
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    fn raw(value: Value) -> (i32, u64) {
        let bytes = serde_json::to_vec(&value).unwrap();
        let mut h = 0;
        let code = unsafe { lw_catalog_managed_request(bytes.as_ptr(), bytes.len(), &mut h) };
        (code, h)
    }
    fn response(h: u64) -> Value {
        let Entry::Buffer(b) = lock(registry()).get(h, 3).unwrap() else {
            panic!()
        };
        serde_json::from_slice(b.bytes.bytes()).unwrap()
    }
    fn fill_buffers(n: usize) -> Vec<u64> {
        (0..n)
            .map(|_| {
                let (code, h) = raw(json!({"version":0,"op":"session_status","session":"0"}));
                assert_eq!(code, 0);
                h
            })
            .collect()
    }
    #[test]
    fn managed_blake3_known_vectors_and_argument_limits() {
        let _serial = crate::test_serial();
        for (input, expected) in [
            (
                &b""[..],
                "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
            ),
            (
                &b"abc"[..],
                "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
            ),
        ] {
            let mut digest = [0u8; 32];
            let pointer = if input.is_empty() {
                std::ptr::null()
            } else {
                input.as_ptr()
            };
            assert_eq!(
                unsafe { lw_catalog_blake3(pointer, input.len(), digest.as_mut_ptr()) },
                0
            );
            assert_eq!(blake3::Hash::from(digest).to_hex().as_str(), expected);
        }
        let mut untouched = [0x55; 32];
        assert_eq!(
            unsafe { lw_catalog_blake3(std::ptr::null(), 1, untouched.as_mut_ptr()) },
            1
        );
        assert_eq!(
            unsafe { lw_catalog_blake3(b"x".as_ptr(), MAX_INPUT + 1, untouched.as_mut_ptr()) },
            5
        );
        assert_eq!(
            unsafe { lw_catalog_blake3(std::ptr::null(), 0, std::ptr::null_mut()) },
            1
        );
        assert_eq!(untouched, [0x55; 32]);
        let input = vec![0x80; MAX_INPUT];
        assert_eq!(
            unsafe { lw_catalog_blake3(input.as_ptr(), input.len(), untouched.as_mut_ptr()) },
            0
        );
        assert_eq!(untouched, *blake3::hash(&input).as_bytes());
        assert!(input.iter().all(|b| *b == 0x80));
    }
    #[test]
    fn managed_streaming_blake3_large_input_final_once_and_handle_faults() {
        let _serial = crate::test_serial();
        struct Owned(u64);
        impl Drop for Owned {
            fn drop(&mut self) {
                if self.0 != 0 {
                    assert_eq!(lw_catalog_blake3_release(self.0), 0);
                }
            }
        }
        let mut h = 0;
        assert_eq!(unsafe { lw_catalog_blake3_init(std::ptr::null_mut()) }, 1);
        assert_eq!(unsafe { lw_catalog_blake3_init(&mut h) }, 0);
        let mut owner = Owned(h);
        assert_eq!(
            unsafe { lw_catalog_blake3_update(h, std::ptr::null(), 0) },
            0
        );
        assert_eq!(
            unsafe { lw_catalog_blake3_update(h, std::ptr::null(), 1) },
            1
        );
        assert_eq!(
            unsafe { lw_catalog_blake3_update(h, b"x".as_ptr(), MAX_INPUT + 1) },
            5
        );
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(h, std::ptr::null_mut()) },
            1
        );
        let input = vec![0; MAX_INPUT + 1];
        for chunk in input.chunks(MAX_INPUT) {
            assert_eq!(
                unsafe { lw_catalog_blake3_update(h, chunk.as_ptr(), chunk.len()) },
                0
            );
        }
        let mut digest = [0u8; 32];
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(h, digest.as_mut_ptr()) },
            0
        );
        assert_eq!(digest, *blake3::hash(&input).as_bytes());
        println!(
            "BLAKE3 zero-vector bytes={} digest={}",
            input.len(),
            blake3::Hash::from(digest).to_hex()
        );
        let mut untouched = [0x55; 32];
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(h, untouched.as_mut_ptr()) },
            6
        );
        assert_eq!(unsafe { lw_catalog_blake3_update(h, b"x".as_ptr(), 1) }, 6);
        assert_eq!(untouched, [0x55; 32]);
        assert_eq!(lw_catalog_blake3_release(h), 0);
        owner.0 = 0;
        assert_eq!(lw_catalog_blake3_release(h), 4);
        assert_eq!(
            unsafe { lw_catalog_blake3_update(h, std::ptr::null(), 0) },
            4
        );
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(h, untouched.as_mut_ptr()) },
            4
        );
        assert_eq!(untouched, [0x55; 32]);
        let (code, buffer) = raw(json!({"version":0,"op":"session_status","session":"0"}));
        assert_eq!(code, 0);
        assert_eq!(
            unsafe { lw_catalog_blake3_update(buffer, std::ptr::null(), 0) },
            4
        );
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(buffer, untouched.as_mut_ptr()) },
            4
        );
        assert_eq!(lw_catalog_blake3_release(buffer), 4);
        assert_eq!(lw_catalog_buffer_release(buffer), 0);
        let mut replacement = 0;
        assert_eq!(unsafe { lw_catalog_blake3_init(&mut replacement) }, 0);
        let _replacement = Owned(replacement);
        assert_ne!(replacement, h);
        assert_eq!(
            unsafe { lw_catalog_blake3_update(h, std::ptr::null(), 0) },
            4
        );
        for byte in b"abc" {
            assert_eq!(unsafe { lw_catalog_blake3_update(replacement, byte, 1) }, 0);
        }
        assert_eq!(
            unsafe { lw_catalog_blake3_finalize(replacement, digest.as_mut_ptr()) },
            0
        );
        assert_eq!(
            blake3::Hash::from(digest).to_hex().as_str(),
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        );
    }
    #[test]
    fn managed_streaming_blake3_owner_allowance_survives_release_during_call() {
        let _serial = crate::test_serial();
        struct Owners(Vec<u64>);
        impl Drop for Owners {
            fn drop(&mut self) {
                for h in self.0.drain(..) {
                    assert_eq!(lw_catalog_blake3_release(h), 0);
                }
            }
        }
        assert_eq!(LIVE_HASHERS.load(Ordering::Acquire), 0);
        let mut owners = Owners(Vec::new());
        for _ in 0..MAX_HASHERS {
            let mut h = 0;
            assert_eq!(unsafe { lw_catalog_blake3_init(&mut h) }, 0);
            owners.0.push(h);
        }
        let mut denied = 99;
        assert_eq!(unsafe { lw_catalog_blake3_init(&mut denied) }, 2);
        assert_eq!(denied, 0);
        let h = owners.0.pop().unwrap();
        let active_call_owner = hasher(h).unwrap();
        assert_eq!(lw_catalog_blake3_release(h), 0);
        assert_eq!(LIVE_HASHERS.load(Ordering::Acquire), MAX_HASHERS);
        assert_eq!(unsafe { lw_catalog_blake3_init(&mut denied) }, 2);
        drop(active_call_owner);
        assert_eq!(LIVE_HASHERS.load(Ordering::Acquire), MAX_HASHERS - 1);
        assert_eq!(unsafe { lw_catalog_blake3_init(&mut denied) }, 0);
        owners.0.push(denied);
        drop(owners);
        assert_eq!(LIVE_HASHERS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn managed_initializing_session_rejects_guessed_authority_until_published() {
        let _serial = crate::test_serial();
        extern "C" fn noop_callback(_: *mut c_void, _: u64, _: u64) {}
        struct Resume(Arc<StartupGate>);
        impl Drop for Resume {
            fn drop(&mut self) {
                self.0.resume.store(true, Ordering::Release);
            }
        }
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
        let gate = Arc::new(StartupGate::default());
        let _resume = Resume(gate.clone());
        *lock(&STARTUP_GATE) = Some(gate.clone());
        let startup = std::thread::spawn(|| {
            raw(
                json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
            )
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let sh = loop {
            if let Some(h) = *lock(&gate.handle) {
                break h;
            }
            assert!(
                Instant::now() < deadline,
                "startup did not reach admission gate"
            );
            std::thread::sleep(Duration::from_millis(2));
        };
        assert_eq!(OWNERS.load(Ordering::Acquire), 1);
        for op in ["session_status", "session_shutdown", "session_release"] {
            let (code, h) = raw(json!({"version":2,"op":op,"session":sh.to_string()}));
            assert_eq!(code, 0);
            assert_eq!(response(h)["error"]["code"], "invalid_handle");
            lw_catalog_buffer_release(h);
        }
        let (code, h) = raw(
            json!({"version":2,"op":"submit","session":sh.to_string(),"request":{"command":"status"}}),
        );
        assert_eq!(code, 0);
        assert_eq!(response(h)["error"]["code"], "invalid_handle");
        lw_catalog_buffer_release(h);
        let mut subscription = 99;
        assert_eq!(
            unsafe {
                lw_catalog_subscribe(
                    sh,
                    Some(noop_callback),
                    std::ptr::null_mut(),
                    &mut subscription,
                )
            },
            4
        );
        assert_eq!(subscription, 0);
        gate.resume.store(true, Ordering::Release);
        let (code, h) = startup.join().unwrap();
        assert_eq!(code, 0);
        assert_eq!(response(h)["result"]["session"], sh.to_string());
        assert_eq!(response(h)["result"]["phase"], "retained_startup");
        lw_catalog_buffer_release(h);
        close_session(&session(sh).unwrap());
        lock(registry()).remove(sh, 1).unwrap();
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn managed_receiver_failure_retains_visible_job_before_any_effect() {
        let _serial = crate::test_serial();
        let initial = LIVE_JOBS.load(Ordering::Acquire);
        let (h, j) = new_job(empty_session(), 128).unwrap();
        let effects = Arc::new(AtomicUsize::new(0));
        FAIL_SPAWN.store(true, Ordering::Release);
        let count = effects.clone();
        spawn_job(j.clone(), move |j| {
            count.fetch_add(1, Ordering::AcqRel);
            json_buffer(json!({"effect":true}), lock(&j.lease).take().unwrap())
        })
        .unwrap();
        assert!(j.done());
        assert_eq!(effects.load(Ordering::Acquire), 0);
        assert!(matches!(lock(registry()).get(h, 2), Ok(Entry::Job(_))));
        let (code, response_handle) =
            raw(json!({"version":2,"op":"job_result","job":h.to_string()}));
        assert_eq!(code, 0);
        assert_eq!(response(response_handle)["error"]["code"], "resource_limit");
        lw_catalog_buffer_release(response_handle);
        lock(registry()).remove(h, 2).unwrap();
        drop(j);
        assert_eq!(LIVE_JOBS.load(Ordering::Acquire), initial);
    }
    #[test]
    fn managed_blocked_checked_shutdown_retains_owner_and_keeps_polling_finite() {
        let _serial = crate::test_serial();
        let (code, h) = raw(
            json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
        );
        assert_eq!(code, 0);
        let sh = response(h)["result"]["session"]
            .as_str()
            .unwrap()
            .parse::<u64>()
            .unwrap();
        lw_catalog_buffer_release(h);
        let gate = Arc::new(AtomicBool::new(false));
        *lock(&SHUTDOWN_GATE) = Some(gate.clone());
        for _ in 0..3 {
            let start = Instant::now();
            let (code, h) =
                raw(json!({"version":2,"op":"session_shutdown","session":sh.to_string()}));
            assert_eq!(code, 0);
            assert_eq!(response(h)["error"]["code"], "draining");
            assert!(start.elapsed() < Duration::from_millis(250));
            lw_catalog_buffer_release(h);
        }
        assert_eq!(session(sh).unwrap().status()["phase"], "draining");
        assert_eq!(OWNERS.load(Ordering::Acquire), 1);
        assert!(matches!(new_job(session(sh).unwrap(),128),Err(e)if e.code=="closed"));
        let (code, h) = raw(json!({"version":2,"op":"session_release","session":sh.to_string()}));
        assert_eq!(code, 0);
        assert_eq!(response(h)["error"]["code"], "busy");
        lw_catalog_buffer_release(h);
        gate.store(true, Ordering::Release);
        close_session(&session(sh).unwrap());
        lock(registry()).remove(sh, 1).unwrap();
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn managed_retained_startup_owners_are_bounded_until_checked_shutdown() {
        let _serial = crate::test_serial();
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
        let mut owners = Vec::new();
        for _ in 0..MAX_SESSIONS {
            let (code, h) = raw(
                json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
            );
            assert_eq!(code, 0);
            let reply = response(h);
            assert_eq!(reply["result"]["phase"], "retained_startup");
            owners.push(
                reply["result"]["session"]
                    .as_str()
                    .unwrap()
                    .parse::<u64>()
                    .unwrap(),
            );
            lw_catalog_buffer_release(h);
        }
        let (code, h) = raw(
            json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
        );
        assert_eq!(code, 0);
        assert_eq!(response(h)["error"]["code"], "resource_limit");
        lw_catalog_buffer_release(h);
        assert_eq!(OWNERS.load(Ordering::Acquire), MAX_SESSIONS);
        for h in owners {
            close_session(&session(h).unwrap());
            lock(registry()).remove(h, 1).unwrap();
        }
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn managed_shutdown_fences_concurrent_job_and_callback_publication() {
        let _serial = crate::test_serial();
        let s = empty_session();
        let gate = Arc::new(std::sync::Barrier::new(33));
        let callbacks = Box::new(AtomicUsize::new(0));
        unsafe extern "C" fn count(ctx: *mut c_void, _: u64, _: u64) {
            unsafe { &*(ctx as *const AtomicUsize) }.fetch_add(1, Ordering::AcqRel);
        }
        let context = (&*callbacks as *const AtomicUsize) as usize;
        let mut threads = Vec::new();
        for n in 0..32 {
            let s = s.clone();
            let gate = gate.clone();
            threads.push(std::thread::spawn(move || {
                gate.wait();
                if n % 2 == 0 {
                    match new_job(s, 128) {
                        Ok((h, j)) => Some((h, Some(j))),
                        Err(e) => {
                            assert_eq!(e.code, "closed");
                            None
                        }
                    }
                } else {
                    let cb = Arc::new(Subscription {
                        callback: count,
                        context,
                        state: Mutex::new(CallbackState {
                            closed: false,
                            inflight: 0,
                        }),
                        drained: Condvar::new(),
                        handle: Mutex::new(0),
                    });
                    match admit_subscription(&s, cb) {
                        Ok(h) => Some((h, None)),
                        Err(e) => {
                            assert_eq!(e.code, "closed");
                            None
                        }
                    }
                }
            }));
        }
        gate.wait();
        let _ = s.shutdown();
        for thread in threads {
            if let Some((h, job)) = thread.join().unwrap() {
                if let Some(j) = job {
                    assert!(j.local_cancel.load(Ordering::Acquire));
                    let lease = lock(&j.lease).take().unwrap();
                    j.finish(json_buffer(json!({"done":true}), lease));
                    lock(registry()).remove(h, 2).unwrap();
                } else {
                    let Entry::Subscription(cb) = lock(registry()).get(h, 4).unwrap() else {
                        panic!()
                    };
                    assert!(lock(&cb.state).closed);
                    cb.fire(0, 0);
                    assert_eq!(lw_catalog_unsubscribe_and_drain(h, 0), 0);
                }
            }
        }
        assert!(matches!(new_job(s.clone(),128),Err(e) if e.code=="closed"));
        assert_eq!(callbacks.load(Ordering::Acquire), 0);
        close_session(&s);
        assert_eq!(LIVE_JOBS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn managed_response_and_payload_saturation_never_orphan_effects() {
        let _serial = crate::test_serial();
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
        let initial = PAYLOAD_BYTES.load(Ordering::Acquire);
        let reservation = ResponseReservation::reserve().unwrap();
        let mut count = 123;
        assert_eq!(
            unsafe {
                lw_catalog_buffer_copy(reservation.handle, 0, std::ptr::null_mut(), 0, &mut count)
            },
            4
        );
        assert_eq!(count, 0);
        assert_eq!(lw_catalog_buffer_release(reservation.handle), 4);
        let published = reservation.publish(json!({"visible":true})).unwrap();
        assert_eq!(response(published)["visible"], true);
        lw_catalog_buffer_release(published);
        let buffers = fill_buffers(MAX_BUFFERS);
        let (code, h) = raw(
            json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
        );
        assert_eq!(code, 2);
        assert_eq!(h, 0);
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
        for h in buffers {
            assert_eq!(lw_catalog_buffer_release(h), 0);
        }
        let s = empty_session();
        let (jh, j) = new_job(s, MAX_INPUT).unwrap();
        let lease = lock(&j.lease).take().unwrap();
        j.finish(json_buffer(json!({"durable":"unchanged"}), lease));
        let buffers = fill_buffers(MAX_BUFFERS - 1);
        let (code, h) = raw(json!({"version":2,"op":"job_result","job":jh.to_string()}));
        assert_eq!(code, 0);
        assert_eq!(response(h)["error"]["code"], "resource_limit");
        assert!(!lock(&j.state).taken);
        assert_eq!(lw_catalog_buffer_release(h), 0);
        for h in buffers {
            lw_catalog_buffer_release(h);
        }
        let (code, h) = raw(json!({"version":2,"op":"job_result","job":jh.to_string()}));
        assert_eq!(code, 0);
        let result = response(h);
        let payload = result["result"]["buffer"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(response(payload)["durable"], "unchanged");
        lw_catalog_buffer_release(h);
        lw_catalog_buffer_release(payload);
        lock(registry()).remove(jh, 2).unwrap();
        drop(j);
        // Completed-but-unreceived payloads and released response handles share the
        // same lease pool. Admission is rejected until its actual owner releases it.
        let available =
            PAYLOAD_LIMIT.load(Ordering::Acquire) - PAYLOAD_BYTES.load(Ordering::Acquire);
        let lease = Lease::reserve(available).unwrap();
        let (code, h) = raw(
            json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
        );
        assert_eq!((code, h), (2, 0));
        assert_eq!(OWNERS.load(Ordering::Acquire), 0);
        drop(lease);
        let (code, h) = raw(
            json!({"version":2,"op":"session_create","config":{"worker_executable":{"encoding":"UnixBytes","units":[47,120]}}}),
        );
        assert_eq!(code, 0);
        let sh = response(h)["result"]["session"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        lw_catalog_buffer_release(h);
        close_session(&session(sh).unwrap());
        lock(registry()).remove(sh, 1).unwrap();
        assert_eq!(PAYLOAD_BYTES.load(Ordering::Acquire), initial);
    }
    struct Gate {
        entered: AtomicUsize,
        release: AtomicBool,
    }
    unsafe extern "C" fn blocked(ctx: *mut c_void, _: u64, _: u64) {
        let g = unsafe { &*(ctx as *const Gate) };
        g.entered.fetch_add(1, Ordering::AcqRel);
        while !g.release.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn managed_released_jobs_cannot_bypass_blocked_callback_receiver_cap() {
        let _serial = crate::test_serial();
        let initial = LIVE_JOBS.load(Ordering::Acquire);
        assert_eq!(initial, 0);
        let s = empty_session();
        let gate = Box::new(Gate {
            entered: AtomicUsize::new(0),
            release: AtomicBool::new(false),
        });
        let cb = Arc::new(Subscription {
            callback: blocked,
            context: (&*gate as *const Gate) as usize,
            state: Mutex::new(CallbackState {
                closed: false,
                inflight: 0,
            }),
            drained: Condvar::new(),
            handle: Mutex::new(1),
        });
        lock(&s.callbacks).push(Arc::downgrade(&cb));
        for _ in 0..MAX_JOBS {
            let (h, j) = new_job(s.clone(), 128).unwrap();
            spawn_job(j.clone(), |j| {
                json_buffer(json!({"done":true}), lock(&j.lease).take().unwrap())
            })
            .unwrap();
            let until = Instant::now() + Duration::from_secs(5);
            while !j.done() {
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(1));
            }
            lock(registry()).remove(h, 2).unwrap();
            drop(j);
        }
        assert_eq!(LIVE_JOBS.load(Ordering::Acquire), MAX_JOBS);
        assert!(matches!(new_job(s.clone(),128),Err(e)if e.code=="resource_limit"));
        assert!(matches!(cb.drain(Duration::ZERO),Err(e)if e.code=="busy"));
        gate.release.store(true, Ordering::Release);
        cb.drain(Duration::from_secs(5)).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while LIVE_JOBS.load(Ordering::Acquire) != 0 {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        let (h, j) = new_job(s.clone(), 128).unwrap();
        lock(registry()).remove(h, 2).unwrap();
        drop(j);
        assert!(lock(&s.jobs).len() <= 1);
        drop(gate);
    }
}
