//! Adobe-fixture-only observations. These owners never reserve the measured
//! MemoryBudget, dequeue protocol output, or change worker failure priority.
use super::protocol::Guard;
use anyhow::{Context as _, Result, ensure};
use std::{
    fmt::{self, Write as _},
    io::Read,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const STDERR_BYTES: usize = 16 * 1024;
const EVENTS: usize = 128;
const DETAIL_BYTES: usize = 1024;
const CHILDREN: usize = 16;
const ROLES: [&str; 3] = [
    "--lightroom-migration-worker",
    "--lightroom-source-reader-sql",
    "--lightroom-source-reader-raw",
];

struct Text {
    bytes: [u8; DETAIL_BYTES],
    length: usize,
    truncated: bool,
}
impl Text {
    fn new() -> Self {
        Self {
            bytes: [0; DETAIL_BYTES],
            length: 0,
            truncated: false,
        }
    }
    fn value(&self) -> String {
        String::from_utf8_lossy(&self.bytes[..self.length]).into_owned()
    }
}
impl fmt::Write for Text {
    fn write_str(&mut self, value: &str) -> fmt::Result {
        let n = (DETAIL_BYTES - self.length).min(value.len());
        self.bytes[self.length..self.length + n].copy_from_slice(&value.as_bytes()[..n]);
        self.length += n;
        self.truncated |= n != value.len();
        Ok(())
    }
}
struct Event {
    sequence: usize,
    elapsed_ns: u128,
    detail: Text,
}
struct Stderr {
    bytes: [u8; STDERR_BYTES],
    length: usize,
    discarded: u64,
}
impl Stderr {
    fn new() -> Self {
        Self {
            bytes: [0; STDERR_BYTES],
            length: 0,
            discarded: 0,
        }
    }
}
struct State {
    events: Vec<Event>,
    dropped_events: u64,
    stderr: [Stderr; 3],
    pids: Vec<(u32, usize)>,
}
struct Capture {
    executable: PathBuf,
    directory: PathBuf,
    started: Instant,
    state: Mutex<State>,
    readers: Mutex<Vec<JoinHandle<()>>>,
    stop: AtomicBool,
}
static ACTIVE: OnceLock<Mutex<Option<Arc<Capture>>>> = OnceLock::new();
fn active() -> Option<Arc<Capture>> {
    ACTIVE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}
impl Capture {
    fn stderr_bytes(&self, role: usize, bytes: &[u8]) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let stream = &mut state.stderr[role];
        let kept = (STDERR_BYTES - stream.length).min(bytes.len());
        stream.bytes[stream.length..stream.length + kept].copy_from_slice(&bytes[..kept]);
        stream.length += kept;
        stream.discarded = stream.discarded.saturating_add((bytes.len() - kept) as u64);
    }
    fn record(&self, detail: fmt::Arguments<'_>) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.events.len() == EVENTS {
            state.dropped_events = state.dropped_events.saturating_add(1);
            return;
        }
        let mut text = Text::new();
        let _ = text.write_fmt(detail);
        let sequence = state.events.len();
        state.events.push(Event {
            sequence,
            elapsed_ns: self.started.elapsed().as_nanos(),
            detail: text,
        });
    }
}
/// Exact guard whitelist excludes unrelated fixtures even under parallel libtest.
pub(crate) fn guard_event(guard: &Guard, detail: fmt::Arguments<'_>) {
    if (guard.session == "adobe-pressure" && guard.generation == "deny" && guard.operation == "run")
        || (guard.session == "batch3"
            && guard.generation == "adobe_retry"
            && guard.operation == "adobe_retry")
    {
        if let Some(c) = active() {
            c.record(format_args!(
                "guard={}/{}/{} {detail}",
                guard.session, guard.generation, guard.operation
            ));
        }
    }
}
pub(crate) struct Context {
    capture: Arc<Capture>,
    guard: &'static str,
}
impl Context {
    pub(crate) fn record(&self, detail: fmt::Arguments<'_>) {
        self.capture
            .record(format_args!("guard={} {detail}", self.guard));
    }
}
pub(crate) fn guard_context(guard: &Guard) -> Option<Context> {
    let label = if guard.session == "adobe-pressure"
        && guard.generation == "deny"
        && guard.operation == "run"
    {
        "adobe-pressure/deny/run"
    } else if guard.session == "batch3"
        && guard.generation == "adobe_retry"
        && guard.operation == "adobe_retry"
    {
        "batch3/adobe_retry/adobe_retry"
    } else {
        return None;
    };
    active().map(|capture| Context {
        capture,
        guard: label,
    })
}
pub(crate) fn event(detail: fmt::Arguments<'_>) {
    if let Some(c) = active() {
        c.record(detail);
    }
}
pub(crate) fn pid_event(pid: u32, detail: fmt::Arguments<'_>) {
    if let Some(c) = active() {
        let role = c
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pids
            .iter()
            .find(|v| v.0 == pid)
            .map(|v| v.1);
        if let Some(role) = role {
            c.record(format_args!("pid={pid} role={} {detail}", ROLES[role]));
        }
    }
}
pub(crate) fn matches(command: &Command) -> bool {
    active().is_some_and(|c| command.get_program() == c.executable.as_os_str())
}
/// Only normal stdout-protocol children call this. The separate stderr-protocol
/// test helpers never enter this path. Establish Process custody before calling.
pub(crate) fn attach(command: &Command, child: &mut Child) -> Result<()> {
    let Some(c) = active().filter(|c| command.get_program() == c.executable.as_os_str()) else {
        return Ok(());
    };
    let role = command
        .get_args()
        .next()
        .and_then(|v| v.to_str())
        .and_then(|v| ROLES.iter().position(|r| *r == v))
        .context("diagnostic role outside exact Adobe roster")?;
    let pid = child.id();
    let pipe = child
        .stderr
        .take()
        .context("Adobe diagnostic stderr pipe")?;
    let fd = pipe.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
        "Adobe diagnostic stderr nonblocking admission failed"
    );
    let mut readers = c.readers.lock().unwrap_or_else(|e| e.into_inner());
    ensure!(
        !c.stop.load(Ordering::Acquire),
        "Adobe diagnostic admission already closed"
    );
    ensure!(readers.len() < CHILDREN, "Adobe diagnostic reader limit");
    {
        let mut state = c.state.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(state.pids.len() < CHILDREN, "Adobe diagnostic PID limit");
        state.pids.push((pid, role));
    }
    c.record(format_args!("process.spawn pid={pid} role={}", ROLES[role]));
    let reader = spawn_stderr_reader(c.clone(), role, pid, pipe)?;
    readers.push(reader);
    Ok(())
}

// Both callers establish O_NONBLOCK before admission; only stderr bytes enter
// this owner. No protocol receiver or writer is available to it.
fn spawn_stderr_reader(
    c: Arc<Capture>,
    role: usize,
    pid: u32,
    mut pipe: impl Read + Send + 'static,
) -> Result<JoinHandle<()>> {
    let captured = c;
    let reader = thread::Builder::new()
        .name("adobe-stderr-prefix".into())
        .spawn(move || {
            let mut bytes = [0u8; 4096];
            // A reader is independently draining/discarding, never waiting on the
            // protocol pipe. Scope cleanup signals Stop and observes checked
            // join for at most five seconds; it never closes stderr on a timer
            // while the primary child still owns its admitted operation.
            loop {
                for _ in 0..16 {
                    match pipe.read(&mut bytes) {
                        Ok(0) => {
                            captured.record(format_args!("stderr.eof pid={pid}"));
                            return;
                        }
                        Ok(n) => {
                            captured.stderr_bytes(role, &bytes[..n]);
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            captured.record(format_args!("stderr.read_error pid={pid} error={e}"));
                            return;
                        }
                    }
                }
                if captured.stop.load(Ordering::Acquire) {
                    captured.record(format_args!(
                        "stderr.observation_stopped pid={pid} EOF_NOT_PROVEN"
                    ));
                    return;
                }
                thread::sleep(Duration::from_millis(2));
            }
        })
        .context("Adobe diagnostic reader spawn")?;
    Ok(reader)
}

pub(crate) struct Scope {
    capture: Arc<Capture>,
    finished: bool,
}
impl Scope {
    pub(crate) fn start(executable: &Path, directory: &Path) -> Result<Self> {
        let mut current = ACTIVE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        ensure!(current.is_none(), "Adobe diagnostic owner already retained");
        let capture = Arc::new(Capture {
            executable: executable.into(),
            directory: directory.into(),
            started: Instant::now(),
            state: Mutex::new(State {
                events: Vec::with_capacity(EVENTS),
                dropped_events: 0,
                stderr: std::array::from_fn(|_| Stderr::new()),
                pids: Vec::with_capacity(CHILDREN),
            }),
            readers: Mutex::new(Vec::with_capacity(CHILDREN)),
            stop: AtomicBool::new(false),
        });
        *current = Some(capture.clone());
        Ok(Self {
            capture,
            finished: false,
        })
    }
    pub(crate) fn finish(&mut self) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        self.capture.stop.store(true, Ordering::Release);
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            if self
                .capture
                .readers
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .all(|h| h.is_finished())
            {
                break;
            }
            if Instant::now() >= until {
                self.capture
                    .record(format_args!("diagnostic.cleanup_timeout OWNERS_RETAINED"));
                self.persist(false, "adobe-diagnostics.json")?;
                anyhow::bail!("Adobe diagnostic readers still owned after finite cleanup");
            }
            thread::sleep(Duration::from_millis(2));
        }
        let readers = std::mem::take(
            &mut *self
                .capture
                .readers
                .lock()
                .unwrap_or_else(|e| e.into_inner()),
        );
        let mut panic = false;
        for reader in readers {
            panic |= reader.join().is_err();
        }
        self.capture
            .record(format_args!("diagnostic.readers_joined panicked={panic}"));
        // Clear admission only after checked join. Publication errors remain
        // fixture errors; all physical diagnostic readers are already gone.
        *ACTIVE
            .get()
            .unwrap()
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
        self.finished = true;
        self.persist(true, "adobe-diagnostics.json")?;
        ensure!(!panic, "Adobe diagnostic reader panicked");
        Ok(())
    }
    pub(crate) fn before_assert(&self) -> Result<()> {
        self.persist(false, "adobe-before-assert.json")
    }
    fn persist(&self, joined: bool, leaf: &str) -> Result<()> {
        let state = self.capture.state.lock().unwrap_or_else(|e| e.into_inner());
        let events: Vec<_> = state.events.iter().map(|e| serde_json::json!({"sequence":e.sequence,"elapsed_ns":e.elapsed_ns.to_string(),"detail":e.detail.value(),"detail_truncated":e.detail.truncated})).collect();
        let stderr: Vec<_> = state.stderr.iter().enumerate().map(|(i,s)| serde_json::json!({"role":ROLES[i],"prefix_bytes":s.length,"discarded_bytes":s.discarded,"prefix_hex":s.bytes[..s.length].iter().map(|b|format!("{b:02x}")).collect::<String>()})).collect();
        let report = serde_json::json!({"schema":1,"scope":"ADOBE_TEST_ONLY_OBSERVATIONS_NOT_CAUSAL_PROOF","stderr_bytes_per_role":STDERR_BYTES,"event_limit":EVENTS,"event_detail_bytes":DETAIL_BYTES,"reader_limit":CHILDREN,"events":events,"dropped_events":state.dropped_events,"stderr":stderr,"role_pids":state.pids,"diagnostic_readers_checked_joined":joined});
        let bytes = serde_json::to_vec_pretty(&report)?;
        ensure!(
            bytes.len() <= 512 * 1024,
            "Adobe diagnostic publication cap"
        );
        let path = self.capture.directory.join(leaf);
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)?;
        std::io::Write::write_all(&mut file, &bytes)?;
        eprintln!(
            "Adobe diagnostic evidence: {} readers_joined={joined}",
            path.display()
        );
        Ok(())
    }
}
impl Drop for Scope {
    fn drop(&mut self) {
        if let Err(error) = self.finish() {
            eprintln!("Adobe diagnostic cleanup failed (no semantic success): {error}");
        }
    }
}

#[test]
fn adobe_diagnostic_caps_preserve_prefix_discard_overflow_and_leave_pool_unchanged() -> Result<()> {
    let budget = super::memory::MemoryBudget::new(64)?;
    let root = tempfile::tempdir()?;
    // No global observer, child process or protocol owner is admitted here.
    let capture = Capture {
        executable: root.path().join("unused"),
        directory: root.path().into(),
        started: Instant::now(),
        state: Mutex::new(State {
            events: Vec::with_capacity(EVENTS),
            dropped_events: 0,
            stderr: std::array::from_fn(|_| Stderr::new()),
            pids: Vec::with_capacity(CHILDREN),
        }),
        readers: Mutex::new(Vec::with_capacity(CHILDREN)),
        stop: AtomicBool::new(false),
    };
    let long = "a".repeat(DETAIL_BYTES + 19);
    for _ in 0..EVENTS + 7 {
        capture.record(format_args!("{long}"));
    }
    for role in 0..ROLES.len() {
        capture.stderr_bytes(role, &[42; STDERR_BYTES]);
        capture.stderr_bytes(role, &[7; 31]);
        capture.stderr_bytes(role, &[8; 13]);
    }
    let state = capture.state.lock().unwrap();
    assert_eq!(state.events.len(), EVENTS);
    assert_eq!(state.dropped_events, 7);
    assert!(
        state
            .events
            .iter()
            .all(|e| e.detail.length == DETAIL_BYTES && e.detail.truncated)
    );
    for stream in &state.stderr {
        assert_eq!(stream.length, STDERR_BYTES);
        assert_eq!(stream.discarded, 44);
        assert_eq!(stream.bytes, [42; STDERR_BYTES]);
    }
    assert_eq!(budget.used(), 0);
    Ok(())
}

#[test]
fn adobe_stderr_overflow_drains_and_reader_has_finite_checked_cleanup() -> Result<()> {
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    let budget = super::memory::MemoryBudget::new(64)?;
    let root = tempfile::tempdir()?;
    let mut scope = Scope::start(&root.path().join("not-a-child-executable"), root.path())?;
    let (reader, mut writer) = UnixStream::pair()?;
    reader.set_nonblocking(true)?;
    writer.set_write_timeout(Some(Duration::from_secs(2)))?;
    let handle = spawn_stderr_reader(scope.capture.clone(), 0, std::process::id(), reader)?;
    scope.capture.readers.lock().unwrap().push(handle);
    // Writing four times the retained prefix must finish while the independent
    // reader discards the overflow. No protocol, child or measured charge exists.
    writer.write_all(&[42; STDERR_BYTES * 4])?;
    drop(writer);
    let until = Instant::now() + Duration::from_secs(2);
    while !scope.capture.readers.lock().unwrap()[0].is_finished() {
        ensure!(
            Instant::now() < until,
            "diagnostic stderr did not observe EOF"
        );
        thread::sleep(Duration::from_millis(2));
    }
    scope.finish()?;
    let state = scope.capture.state.lock().unwrap();
    assert_eq!(state.stderr[0].length, STDERR_BYTES);
    assert_eq!(state.stderr[0].discarded, (STDERR_BYTES * 3) as u64);
    assert_eq!(state.stderr[0].bytes, [42; STDERR_BYTES]);
    assert!(scope.capture.readers.lock().unwrap().is_empty());
    assert_eq!(budget.used(), 0);
    Ok(())
}
