//! Opt-in controlled-fixture diagnostics. Never writes framed protocol streams.
//! The feature is off by default; the environment alone cannot enable it.
use crate::application::ImportStatus;

#[derive(Clone, Copy)]
#[repr(usize)]
pub(crate) enum Stage {
    ActorWait, ActorMaintain, ServiceTick, ImportEvent, BindStorage,
    HeaderReserve, MetadataApply, FileFinish, SendHeader, SendSource, SendEnd,
    FNext, FInspect, FRead, FFinishInspection, FValidateInspection,
    FReleaseInspection, FValidateFile, FReleaseFile, FOther,
    NativeAdmit, NativeSpawn, NativeStart, NativeStatus, NativeEncode,
    NativeRetire, NativePoll, NativeRead, RenderTransport,
    PublishBatch, CacheWrite, MetadataIndex, OrganizationIndex,
}
const NAMES: [&str; 33] = [
    "actor_wait", "actor_maintain", "service_tick", "import_event", "bind_storage",
    "header_reserve", "metadata_apply", "file_finish", "send_header", "send_source", "send_end",
    "f_next", "f_inspect", "f_read", "f_finish_inspection", "f_validate_inspection",
    "f_release_inspection", "f_validate_file", "f_release_file", "f_other",
    "native_admit", "native_spawn", "native_start", "native_status", "native_encode",
    "native_retire", "native_poll", "native_read", "render_transport",
    "publish_batch", "cache_write", "metadata_index", "organization_index",
];
#[cfg(not(feature = "import-timing-fixture"))]
pub(crate) struct Span;
#[cfg(not(feature = "import-timing-fixture"))]
impl Span {
    #[inline(always)]
    pub(crate) fn start(_: Stage) -> Self { Self }
}
#[cfg(not(feature = "import-timing-fixture"))]
#[inline(always)]
pub(crate) fn begin_attempt(_: &str, _: &[&std::path::Path]) {}
#[cfg(not(feature = "import-timing-fixture"))]
#[inline(always)]
pub(crate) fn snapshot(_: &ImportStatus) -> std::io::Result<()> { Ok(()) }
#[cfg(not(feature = "import-timing-fixture"))]
pub(crate) fn current_fixture_epoch() -> u64 { 0 }

#[cfg(feature = "import-timing-fixture")]
mod enabled {
    use super::*;
    use std::io::Write;
    use std::path::{PathBuf, Component};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;
    use std::time::Instant;

    // Fixed 33*9*u64 counters; no per-file paths, event log or source-sized data.
    // All durations are inclusive spans. Concurrent and nested sums are NOT wall time.
    struct Counter { count: u64, ns: u64, max: u64, buckets: [u64; 6], saturated: bool }
    impl Counter {
        const fn new() -> Self { Self { count: 0, ns: 0, max: 0, buckets: [0; 6], saturated: false } }
    }
    static COUNTERS: [Mutex<Counter>; 33] = [const { Mutex::new(Counter::new()) }; 33];
    static EPOCH: AtomicU64 = AtomicU64::new(0);
    static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
    // One bounded ID/path per process, not one record per file.
    static ATTEMPT: Mutex<Option<(String, PathBuf, std::fs::File, Instant, bool)>> = Mutex::new(None);
    const LIMITS: [u64; 6] = [100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, u64::MAX];
    pub(crate) struct Span {
        start: Option<(u64, Instant, Stage)>,
        #[cfg(test)]
        elapsed_ns: Option<u64>,
    }
    impl Span {
        pub(crate) fn start(stage: Stage) -> Self {
            let epoch = EPOCH.load(Ordering::Acquire);
            Self {
                start: (epoch != 0).then(|| (epoch, Instant::now(), stage)),
                #[cfg(test)]
                elapsed_ns: None,
            }
        }
    }
    impl Drop for Span {
        fn drop(&mut self) {
            let Some((epoch, start, stage)) = self.start else { return };
            if EPOCH.load(Ordering::Acquire) != epoch { return }
            let ns = u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX);
            #[cfg(test)]
            let ns = self.elapsed_ns.unwrap_or(ns);
            let mut counter = COUNTERS[stage as usize].lock().unwrap_or_else(|p| p.into_inner());
            if EPOCH.load(Ordering::Acquire) != epoch { return }
            counter.saturated |= counter.count == u64::MAX || counter.ns.checked_add(ns).is_none();
            counter.count = counter.count.saturating_add(1);
            counter.ns = counter.ns.saturating_add(ns);
            counter.max = counter.max.max(ns);
            let bucket = LIMITS.iter().position(|limit| ns <= *limit).unwrap();
            counter.saturated |= counter.buckets[bucket] == u64::MAX;
            counter.buckets[bucket] = counter.buckets[bucket].saturating_add(1);
        }
    }
    // Hold each no-follow directory component; no symlink/path alias is followed.
    fn directory(path: &std::path::Path) -> std::io::Result<std::fs::File> {
        let fd = unsafe { libc::open(c"/".as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        if fd < 0 { return Err(std::io::Error::last_os_error()) }
        let mut current = unsafe { std::fs::File::from_raw_fd(fd) };
        for component in path.components() {
            let Component::Normal(name) = component else { continue };
            let name = std::ffi::CString::new(name.as_bytes()).map_err(std::io::Error::other)?;
            let fd = unsafe { libc::openat(current.as_raw_fd(), name.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
            if fd < 0 { return Err(std::io::Error::last_os_error()) }
            current = unsafe { std::fs::File::from_raw_fd(fd) };
        }
        Ok(current)
    }
    pub(crate) fn begin_attempt(id: &str, protected: &[&std::path::Path]) {
        // Caller is the single actor after prior import terminal/drained admission.
        // Enable only a feature-built fixture helper with an explicitly supplied
        // existing physical diagnostic directory. This never selects a source root.
        if std::env::var("LW_CATALOG_IMPORT_TIMING_FIXTURE").as_deref() != Ok("1") { return }
        let Some(raw) = std::env::var_os("LW_CATALOG_IMPORT_TIMING_DIRECTORY") else { return };
        let dir = PathBuf::from(raw);
        if id.len() > 64 || uuid::Uuid::parse_str(id).is_err() || !dir.is_absolute()
            || dir.to_string_lossy().len() > 4096 || dir.canonicalize().ok().as_ref() != Some(&dir)
            || !dir.is_dir() { return }
        // Never write diagnostics in or above originals/catalog/cache authority.
        // An unavailable physical root disables diagnostics, never changes import.
        for root in protected {
            let Ok(root) = root.canonicalize() else { return };
            if dir.starts_with(&root) || root.starts_with(&dir) { return }
        }
        let Ok(held) = directory(&dir) else { return };
        EPOCH.store(0, Ordering::Release);
        for counter in &COUNTERS { *counter.lock().unwrap_or_else(|p| p.into_inner()) = Counter::new() }
        *ATTEMPT.lock().unwrap_or_else(|p| p.into_inner()) = Some((id.to_owned(), dir, held, Instant::now(), false));
        EPOCH.store(NEXT_EPOCH.fetch_add(1, Ordering::Relaxed), Ordering::Release);
    }
    pub(crate) fn current_fixture_epoch() -> u64 { EPOCH.load(Ordering::Acquire) }
    pub(crate) fn snapshot(status: &ImportStatus) -> std::io::Result<()> {
        let mut attempt = ATTEMPT.lock().unwrap_or_else(|p| p.into_inner());
        let Some((id, dir, held, start, published)) = attempt.as_mut() else { return Ok(()) };
        if *published || id != &status.id { return Ok(()) }
        // Captured immediately before checked Close. The separate public Close
        // receipt establishes retirement; this diagnostic snapshot never does.
        let rows: Vec<_> = NAMES.iter().zip(&COUNTERS).map(|(name, counter)| {
            let c = counter.lock().unwrap_or_else(|p| p.into_inner());
            serde_json::json!({"stage": name, "count": c.count, "sum_ns": c.ns,
                "max_ns": c.max, "buckets": c.buckets, "saturated": c.saturated})
        }).collect();
        let report = serde_json::json!({"schema":1,"scope":"fixture_only_inclusive_stage_timings_before_close",
            "pid":std::process::id(),"attempt":id,"import_status":status,
            "elapsed_ns":u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX),
            "bucket_upper_ns":LIMITS,"stages":rows,
            "readiness_observation":crate::import_readiness::snapshot(),
            "gate_diagnostics":crate::import_gate_diagnostics::snapshot(),
            "limits":"Inclusive/nested/concurrent sums are not additive; each row is coherent; snapshot can intersect an active span. No source contents/paths outside existing bounded ImportStatus; no Close/reap acceptance."});
        let bytes = serde_json::to_vec(&report).map_err(std::io::Error::other)?;
        if bytes.len() > 16 * 1024 { return Err(std::io::Error::other("fixture timing report cap")) }
        if dir.canonicalize()? != *dir { return Err(std::io::Error::other("fixture timing directory alias")) }
        let before = held.metadata()?;
        let current = std::fs::symlink_metadata(&*dir)?;
        if !current.is_dir() || (current.dev(), current.ino()) != (before.dev(), before.ino()) {
            return Err(std::io::Error::other("fixture timing directory changed"))
        }
        let leaf = std::ffi::CString::new(format!("import-timing-{}-{}.json", std::process::id(), id)).map_err(std::io::Error::other)?;
        let fd = unsafe { libc::openat(held.as_raw_fd(), leaf.as_ptr(), libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC, 0o600) };
        if fd < 0 { return Err(std::io::Error::last_os_error()) }
        let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
        #[cfg(test)]
        tests::boundary(tests::Point::Created, &mut file, dir, &leaf)?;
        let created = file.metadata()?;
        if !created.is_file() || created.nlink() != 1 || created.len() != 0 {
            return Err(std::io::Error::other("fixture timing created leaf invalid"))
        }
        #[cfg(test)]
        tests::boundary(tests::Point::Write, &mut file, dir, &leaf)?;
        file.write_all(&bytes)?;
        #[cfg(test)]
        tests::boundary(tests::Point::AfterWrite, &mut file, dir, &leaf)?;
        let metadata = file.metadata()?;
        let current = std::fs::symlink_metadata(&*dir)?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != bytes.len() as u64
            || !current.is_dir() || (current.dev(), current.ino()) != (before.dev(), before.ino()) {
            return Err(std::io::Error::other("fixture timing publication changed"))
        }
        // Readers consume this name, so attest it relative to the retained
        // parent without following or reopening any possible replacement.
        #[cfg(test)]
        tests::boundary(tests::Point::Named, &mut file, dir, &leaf)?;
        let mut named = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstatat(held.as_raw_fd(), leaf.as_ptr(), named.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) } < 0 {
            return Err(std::io::Error::last_os_error())
        }
        #[allow(unused_mut)]
        let mut named = unsafe { named.assume_init() };
        #[cfg(test)]
        tests::named_record(&mut named);
        if (metadata.dev(), metadata.ino()) != (created.dev(), created.ino())
            || (named.st_mode & libc::S_IFMT) != libc::S_IFREG || named.st_nlink != 1
            || named.st_size < 0 || named.st_size as u64 != metadata.len()
            || (named.st_dev as u64, named.st_ino as u64) != (metadata.dev(), metadata.ino()) {
            return Err(std::io::Error::other("fixture timing named leaf changed"))
        }
        *published = true;
        Ok(())
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::ffi::CStr;
        use std::fs::File;
        use std::path::Path;
        use crate::application::{ImportPhase, U64};
        use crate::storage_volume::NativePath;

        #[derive(Clone, Copy, PartialEq, Eq)]
        pub(super) enum Point { Created, Write, AfterWrite, Named }
        type Boundary = Box<dyn FnOnce(&mut File, &Path, &CStr) -> std::io::Result<()> + Send>;
        type Named = Box<dyn FnOnce(&mut libc::stat) + Send>;
        static SERIAL: Mutex<()> = Mutex::new(());
        static BOUNDARY: Mutex<Option<(Point, Boundary)>> = Mutex::new(None);
        static NAMED: Mutex<Option<Named>> = Mutex::new(None);
        pub(super) fn boundary(point: Point, file: &mut File, dir: &Path, name: &CStr) -> std::io::Result<()> {
            let hook = {
                let mut slot = BOUNDARY.lock().unwrap();
                if slot.as_ref().is_some_and(|(at, _)| *at == point) { slot.take() } else { None }
            };
            if let Some((_, hook)) = hook { hook(file, dir, name)? }
            Ok(())
        }
        pub(super) fn named_record(record: &mut libc::stat) {
            let hook = NAMED.lock().unwrap().take();
            if let Some(hook) = hook { hook(record) }
        }
        fn leaf(dir: &Path, name: &CStr) -> PathBuf {
            dir.join(std::ffi::OsStr::from_bytes(name.to_bytes()))
        }
        struct Fixture {
            _serial: std::sync::MutexGuard<'static, ()>,
            _root: tempfile::TempDir,
            dir: PathBuf,
            protected: PathBuf,
            id: String,
            old_flag: Option<std::ffi::OsString>,
            old_dir: Option<std::ffi::OsString>,
        }
        impl Fixture {
            fn new() -> Self {
                let serial = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
                EPOCH.store(0, Ordering::Release);
                *ATTEMPT.lock().unwrap_or_else(|p| p.into_inner()) = None;
                *BOUNDARY.lock().unwrap_or_else(|p| p.into_inner()) = None;
                *NAMED.lock().unwrap_or_else(|p| p.into_inner()) = None;
                let root = tempfile::tempdir().unwrap();
                let physical = root.path().canonicalize().unwrap();
                let dir = physical.join("timing");
                let protected = physical.join("originals");
                std::fs::create_dir(&dir).unwrap();
                std::fs::create_dir(&protected).unwrap();
                let old_flag = std::env::var_os("LW_CATALOG_IMPORT_TIMING_FIXTURE");
                let old_dir = std::env::var_os("LW_CATALOG_IMPORT_TIMING_DIRECTORY");
                // These exact tests are run alone, --test-threads=1. The mutex
                // serializes their process-global fixture environment/state.
                unsafe {
                    std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE", "1");
                    std::env::set_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY", &dir);
                }
                Self { _serial: serial, _root: root, dir, protected,
                    id: uuid::Uuid::new_v4().to_string(), old_flag, old_dir }
            }
            fn begin(&self) { begin_attempt(&self.id, &[self.protected.as_path()]); }
            fn status(&self) -> ImportStatus {
                ImportStatus { id: self.id.clone(), source: NativePath::from_path(&self.protected),
                    phase: ImportPhase::Discovering, imported: U64(0), unchanged: U64(0),
                    failed: U64(0), skipped: U64(0), metadata_updated: U64(0),
                    metadata_warnings: U64(0), awaiting_resources: U64(0),
                    pending_previews: 0, error: None, error_source: None }
            }
            fn output(&self) -> PathBuf {
                self.dir.join(format!("import-timing-{}-{}.json", std::process::id(), self.id))
            }
            fn hook(&self, point: Point, hook: impl FnOnce(&mut File, &Path, &CStr) -> std::io::Result<()> + Send + 'static) {
                assert!(BOUNDARY.lock().unwrap().replace((point, Box::new(hook))).is_none());
            }
            fn named(&self, hook: impl FnOnce(&mut libc::stat) + Send + 'static) {
                assert!(NAMED.lock().unwrap().replace(Box::new(hook)).is_none());
            }
            fn failed(&self, expected: &str) {
                let error = snapshot(&self.status()).expect_err("injected publication must fail");
                assert!(error.to_string().contains(expected), "wrong failure: {error}");
                assert!(BOUNDARY.lock().unwrap().is_none(), "boundary hook was not reached");
                assert!(NAMED.lock().unwrap().is_none(), "named-stat hook was not reached");
                assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4, "failed publication marked published");
            }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                EPOCH.store(0, Ordering::Release);
                *ATTEMPT.lock().unwrap_or_else(|p| p.into_inner()) = None;
                *BOUNDARY.lock().unwrap_or_else(|p| p.into_inner()) = None;
                *NAMED.lock().unwrap_or_else(|p| p.into_inner()) = None;
                unsafe {
                    match &self.old_flag { Some(value) => std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE", value), None => std::env::remove_var("LW_CATALOG_IMPORT_TIMING_FIXTURE") }
                    match &self.old_dir { Some(value) => std::env::set_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY", value), None => std::env::remove_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY") }
                }
            }
        }
        struct ReadinessFlag(Option<std::ffi::OsString>);
        impl ReadinessFlag {
            fn enable() -> Self {
                let old = std::env::var_os("LW_CATALOG_IMPORT_READINESS_OBSERVATION");
                unsafe { std::env::set_var("LW_CATALOG_IMPORT_READINESS_OBSERVATION", "1") };
                Self(old)
            }
        }
        impl Drop for ReadinessFlag {
            fn drop(&mut self) {
                unsafe {
                    match &self.0 {
                        Some(value) => std::env::set_var("LW_CATALOG_IMPORT_READINESS_OBSERVATION", value),
                        None => std::env::remove_var("LW_CATALOG_IMPORT_READINESS_OBSERVATION"),
                    }
                }
            }
        }
        fn maximum_width_report_fixture(f: &Fixture) -> ImportStatus {
            for counter in &COUNTERS {
                *counter.lock().unwrap() = Counter { count: u64::MAX, ns: u64::MAX,
                    max: u64::MAX, buckets: [u64::MAX; 6], saturated: true };
            }
            assert!(crate::import_readiness::maximal_serialization_fixture());
            let mut status = f.status();
            status.imported = U64(u64::MAX); status.unchanged = U64(u64::MAX);
            status.failed = U64(u64::MAX); status.skipped = U64(u64::MAX);
            status.metadata_updated = U64(u64::MAX); status.metadata_warnings = U64(u64::MAX);
            status.awaiting_resources = U64(u64::MAX); status.pending_previews = u32::MAX;
            status.error = Some("fixture serialization width only".repeat(4));
            status.error_source = Some(status.source.clone());
            status
        }
        #[test]
        fn maximum_width_nested_readiness_report_uses_actual_publisher_under_fixed_cap() {
            let f = Fixture::new(); let _flag = ReadinessFlag::enable();
            let original = f.protected.join("unchanged-original");
            std::fs::write(&original, b"UNCHANGED-ORIGINAL").unwrap();
            f.begin(); let status = maximum_width_report_fixture(&f);
            snapshot(&status).unwrap();
            let bytes = std::fs::read(f.output()).unwrap(); assert!(bytes.len() <= 16 * 1024);
            let report: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(report["schema"], 1); assert_eq!(report["attempt"], f.id);
            let timing = report["stages"].as_array().unwrap(); assert_eq!(timing.len(), 33);
            let observation = &report["readiness_observation"];
            assert_eq!(observation["epoch"].as_u64(), Some(current_fixture_epoch()));
            assert_eq!(observation["actor_wait_active"], true);
            assert_eq!(observation["pending_finalized_event"]["sequence"].as_u64(), Some(u64::MAX));
            let readiness = observation["rows"].as_array().unwrap(); assert_eq!(readiness.len(), 18);
            for row in timing.iter().chain(readiness.iter()) {
                assert_eq!(row["count"].as_u64(), Some(u64::MAX));
                assert_eq!(row["sum_ns"].as_u64(), Some(u64::MAX));
                assert_eq!(row["max_ns"].as_u64(), Some(u64::MAX));
                assert_eq!(row["saturated"], true);
                assert_eq!(row["buckets"].as_array().unwrap().len(), 6);
                assert!(row["buckets"].as_array().unwrap().iter().all(|b| b.as_u64() == Some(u64::MAX)));
            }
            let named = std::fs::symlink_metadata(f.output()).unwrap();
            assert!(named.is_file()); assert_eq!(named.nlink(), 1); assert_eq!(named.len(), bytes.len() as u64);
            assert!(ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            snapshot(&status).unwrap();
            assert_eq!(std::fs::metadata(f.output()).unwrap().ino(), named.ino());
            assert_eq!(std::fs::read(f.output()).unwrap(), bytes);
            assert_eq!(std::fs::read(original).unwrap(), b"UNCHANGED-ORIGINAL");
        }
        #[test]
        fn oversized_nested_readiness_report_fails_before_publication_without_mutating_originals() {
            let f = Fixture::new(); let _flag = ReadinessFlag::enable();
            let original = f.protected.join("unchanged-original");
            std::fs::write(&original, b"UNCHANGED-ORIGINAL").unwrap();
            f.begin(); let mut status = maximum_width_report_fixture(&f);
            status.error = Some("X".repeat(16 * 1024 + 1));
            let error = snapshot(&status).expect_err("oversize report must fail before publication");
            assert!(error.to_string().contains("fixture timing report cap"), "wrong failure: {error}");
            assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            assert!(!f.output().exists()); assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 0);
            assert_eq!(std::fs::read(original).unwrap(), b"UNCHANGED-ORIGINAL");
        }
        #[test]
        fn gate_discriminator_real_stamp_requires_same_enabled_epoch_and_checked_collection() {
            let f = Fixture::new(); let _flag = ReadinessFlag::enable(); f.begin();
            let stale = crate::import_gate_diagnostics::RenderReady::start();
            assert!(crate::import_gate_diagnostics::snapshot().is_none());
            // Reset before collection: old result cannot contribute to this attempt.
            f.begin(); stale.collected();
            assert!(crate::import_gate_diagnostics::snapshot().is_none());
            let ready = crate::import_gate_diagnostics::RenderReady::start();
            assert!(crate::import_gate_diagnostics::snapshot().is_none());
            ready.collected();
            let value = crate::import_gate_diagnostics::snapshot().unwrap();
            assert_eq!(value["rows"][0]["values"][0].as_u64(),Some(1));
            // Feature alone cannot enable it: reuse the existing exact readiness flag.
            unsafe { std::env::set_var("LW_CATALOG_IMPORT_READINESS_OBSERVATION", "0"); }
            f.begin(); crate::import_gate_diagnostics::RenderReady::start().collected();
            assert!(crate::import_gate_diagnostics::snapshot().is_none());
        }
        #[test]
        fn gate_discriminator_max_width_observation_uses_same_real_publisher_and_fixed_cap() {
            let f = Fixture::new(); let _flag = ReadinessFlag::enable(); f.begin();
            assert!(crate::import_gate_diagnostics::maximal_serialization_fixture());
            snapshot(&f.status()).unwrap();
            let bytes = std::fs::read(f.output()).unwrap(); assert!(bytes.len() <= 16 * 1024);
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["stages"].as_array().unwrap().len(), 33);
            assert_eq!(value["readiness_observation"]["rows"].as_array().unwrap().len(), 18);
            let diagnostic = &value["gate_diagnostics"];
            assert_eq!(diagnostic["first_blocker_counts"].as_array().unwrap().len(), 7);
            assert_eq!(diagnostic["rows"].as_array().unwrap().len(), 2);
            for row in diagnostic["rows"].as_array().unwrap() {
                assert_eq!(row["values"][0].as_u64(), Some(u64::MAX));
                assert_eq!(row["values"][3].as_array().unwrap().len(), 6);
                assert_eq!(row["values"][4], true);
            }
        }
        #[test]
        fn gate_discriminator_combined_oversize_refuses_before_creation_without_dropping_fields() {
            let f = Fixture::new(); let _flag = ReadinessFlag::enable(); f.begin();
            let status = maximum_width_report_fixture(&f);
            assert!(crate::import_gate_diagnostics::maximal_serialization_fixture());
            let error = snapshot(&status).expect_err("combined maximum-width observations exceed the unchanged cap");
            assert!(error.to_string().contains("fixture timing report cap"));
            assert!(!f.output().exists()); assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(),0);
            assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
        }
        #[test]
        fn exact_fixture_environment_is_required() {
            let f = Fixture::new();
            for flag in [None, Some("0"), Some("true"), Some("01")] {
                unsafe { match flag { Some(v) => std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE", v), None => std::env::remove_var("LW_CATALOG_IMPORT_TIMING_FIXTURE") } }
                f.begin(); assert_eq!(EPOCH.load(Ordering::Acquire), 0);
                drop(Span::start(Stage::FRead)); snapshot(&f.status()).unwrap();
                assert!(!f.output().exists());
            }
            unsafe { std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE", "1"); std::env::remove_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY"); }
            f.begin(); assert_eq!(EPOCH.load(Ordering::Acquire), 0);
            assert!(!f.output().exists());
        }
        #[test]
        fn unavailable_alias_and_relative_directories_disable_profiling() {
            let f = Fixture::new();
            let alias = f.dir.parent().unwrap().join("alias");
            std::os::unix::fs::symlink(&f.dir, &alias).unwrap();
            for dir in [PathBuf::from("relative"), f.dir.join("missing"), alias] {
                unsafe { std::env::set_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY", dir); }
                f.begin(); assert_eq!(EPOCH.load(Ordering::Acquire), 0);
                assert!(!f.output().exists());
            }
        }
        #[test]
        fn originals_catalog_and_cache_related_roots_are_protected() {
            let f = Fixture::new();
            let child = f.dir.join("child"); std::fs::create_dir(&child).unwrap();
            for root in [f.dir.as_path(), f.dir.parent().unwrap(), child.as_path()] {
                begin_attempt(&f.id, &[root]);
                assert_eq!(EPOCH.load(Ordering::Acquire), 0);
                assert!(!f.output().exists());
            }
            begin_attempt(&f.id, &[f.protected.join("missing").as_path()]);
            assert_eq!(EPOCH.load(Ordering::Acquire), 0);
            f.begin(); assert_ne!(EPOCH.load(Ordering::Acquire), 0);
            assert!(std::fs::read_dir(&f.protected).unwrap().next().is_none());
        }
        #[test]
        fn invalid_attempt_is_not_enabled() {
            let f = Fixture::new();
            let overlong = "a".repeat(65);
            for id in ["", "not-a-uuid", overlong.as_str()] {
                begin_attempt(id, &[f.protected.as_path()]);
                assert_eq!(EPOCH.load(Ordering::Acquire), 0);
            }
        }
        #[test]
        fn reset_discards_a_span_from_the_old_attempt() {
            let f = Fixture::new(); f.begin();
            let old = Span::start(Stage::FRead);
            let next = uuid::Uuid::new_v4().to_string();
            begin_attempt(&next, &[f.protected.as_path()]);
            drop(old);
            assert_eq!(COUNTERS[Stage::FRead as usize].lock().unwrap().count, 0);
            drop(Span::start(Stage::FRead));
            assert_eq!(COUNTERS[Stage::FRead as usize].lock().unwrap().count, 1);
            snapshot(&f.status()).unwrap(); assert!(!f.output().exists());
        }
        #[test]
        fn exact_bucket_edges_sum_max_and_saturation_use_real_drop() {
            let f = Fixture::new(); f.begin();
            let values = [0, 100_000, 100_001, 1_000_000, 1_000_001, 10_000_000,
                10_000_001, 100_000_000, 100_000_001, 1_000_000_000, 1_000_000_001];
            for value in values { let mut span = Span::start(Stage::ActorWait); span.elapsed_ns = Some(value); drop(span); }
            { let c = COUNTERS[Stage::ActorWait as usize].lock().unwrap();
                assert_eq!(c.count, values.len() as u64); assert_eq!(c.ns, values.iter().sum::<u64>());
                assert_eq!(c.max, *values.iter().max().unwrap()); assert_eq!(c.buckets, [2,2,2,2,2,1]); assert!(!c.saturated); }
            { let mut c = COUNTERS[Stage::FRead as usize].lock().unwrap(); c.count=u64::MAX; c.ns=u64::MAX; c.buckets[0]=u64::MAX; }
            let mut span = Span::start(Stage::FRead); span.elapsed_ns=Some(1); drop(span);
            let c=COUNTERS[Stage::FRead as usize].lock().unwrap();
            assert_eq!(c.count,u64::MAX); assert_eq!(c.ns,u64::MAX); assert_eq!(c.buckets[0],u64::MAX); assert!(c.saturated);
        }
        #[test]
        fn concurrent_completed_spans_and_snapshot_rows_are_coherent() {
            let f=Fixture::new();f.begin();
            std::thread::scope(|scope| { for _ in 0..8 { scope.spawn(|| { for _ in 0..32 { drop(Span::start(Stage::NativeStatus)); } }); } });
            snapshot(&f.status()).unwrap();
            let bytes=std::fs::read(f.output()).unwrap(); assert!(bytes.len()<=16*1024);
            let report:serde_json::Value=serde_json::from_slice(&bytes).unwrap();
            let rows=report["stages"].as_array().unwrap(); assert_eq!(rows.len(),33);
            let row=rows.iter().find(|row|row["stage"]=="native_status").unwrap();
            assert_eq!(row["count"],256); assert_eq!(row["buckets"].as_array().unwrap().iter().map(|v|v.as_u64().unwrap()).sum::<u64>(),256);
            assert!(row["max_ns"].as_u64().unwrap()<=row["sum_ns"].as_u64().unwrap());
            assert_eq!(row["saturated"],false);
            assert_eq!(report["attempt"],f.id);
        }
        #[test]
        fn named_leaf_matches_created_inode_and_duplicate_snapshot_is_noop() {
            let f=Fixture::new();f.begin(); drop(Span::start(Stage::CacheWrite));
            snapshot(&f.status()).unwrap();
            let original=std::fs::read(f.output()).unwrap();let inode=std::fs::metadata(f.output()).unwrap().ino();
            assert!(ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            snapshot(&f.status()).unwrap();assert_eq!(std::fs::read(f.output()).unwrap(),original);
            assert_eq!(std::fs::metadata(f.output()).unwrap().ino(),inode);
        }
        #[test]
        fn renamed_held_inode_and_same_size_replacement_are_rejected() {
            let f=Fixture::new(); f.begin();
            f.hook(Point::AfterWrite, |file,dir,name| { let path=leaf(dir,name);std::fs::rename(&path,dir.join("held-moved"))?;
                std::fs::write(path,vec![b'R';file.metadata()?.len() as usize])?; Ok(()) });
            f.failed("named leaf changed");
            let moved=std::fs::read(f.dir.join("held-moved")).unwrap();let replaced=std::fs::read(f.output()).unwrap();
            assert_eq!(moved.len(),replaced.len()); assert!(replaced.iter().all(|b|*b==b'R'));
            assert_eq!(serde_json::from_slice::<serde_json::Value>(&moved).unwrap()["attempt"],f.id);
        }
        #[test]
        fn renamed_missing_leaf_preserves_moved_inode() {
            let f=Fixture::new(); f.begin();
            f.hook(Point::AfterWrite, |_,dir,name| std::fs::rename(leaf(dir,name),dir.join("held-moved")));
            let error=snapshot(&f.status()).unwrap_err();assert_eq!(error.raw_os_error(),Some(libc::ENOENT));
            assert!(BOUNDARY.lock().unwrap().is_none());assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            assert!(!f.output().exists()); assert!(f.dir.join("held-moved").is_file());
        }
        #[test]
        fn symlink_replacement_never_follows_or_modifies_target() {
            let f=Fixture::new(); f.begin();let target=f.protected.join("original");std::fs::write(&target,b"immutable").unwrap();
            let capture=target.clone();f.hook(Point::AfterWrite,move |_,dir,name| {let path=leaf(dir,name);std::fs::rename(&path,dir.join("held-moved"))?;std::os::unix::fs::symlink(&capture,path)});
            f.failed("named leaf changed");assert_eq!(std::fs::read(&target).unwrap(),b"immutable");
            assert!(std::fs::symlink_metadata(f.output()).unwrap().file_type().is_symlink());assert!(f.dir.join("held-moved").is_file());
        }
        #[test]
        fn fifo_replacement_is_not_opened_or_removed() {
            let f=Fixture::new(); f.begin();
            f.hook(Point::AfterWrite, |_,dir,name| {let path=leaf(dir,name);std::fs::rename(&path,dir.join("held-moved"))?;
                let path=std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
                if unsafe {libc::mkfifo(path.as_ptr(),0o600)}!=0{return Err(std::io::Error::last_os_error())}Ok(())});
            f.failed("named leaf changed");
            use std::os::unix::fs::FileTypeExt;
            assert!(std::fs::symlink_metadata(f.output()).unwrap().file_type().is_fifo());assert!(f.dir.join("held-moved").is_file());
        }
        #[test]
        fn named_size_and_negative_size_are_rejected() {
            let f=Fixture::new(); f.begin();f.named(|stat|stat.st_size+=1);f.failed("named leaf changed");
            f.begin();std::fs::remove_file(f.output()).unwrap();f.named(|stat|stat.st_size=-1);f.failed("named leaf changed");
        }
        #[test]
        fn named_multiple_links_are_rejected() {
            let f=Fixture::new();f.begin();f.named(|stat|stat.st_nlink=2);f.failed("named leaf changed");
        }
        #[test]
        fn created_nonregular_held_descriptor_is_rejected_before_write() {
            let f=Fixture::new();f.begin();
            f.hook(Point::Created, |file,dir,_| {let replacement=File::open(dir)?;
                if unsafe {libc::dup2(replacement.as_raw_fd(),file.as_raw_fd())}<0{return Err(std::io::Error::last_os_error())}Ok(())});
            f.failed("created leaf invalid"); assert_eq!(std::fs::metadata(f.output()).unwrap().len(),0);
        }
        #[test]
        fn created_multiple_links_are_rejected_before_write() {
            let f=Fixture::new();f.begin();
            f.hook(Point::Created, |_,dir,name|std::fs::hard_link(leaf(dir,name),dir.join("second-link")));
            f.failed("created leaf invalid"); assert_eq!(std::fs::metadata(f.output()).unwrap().len(),0);
            assert_eq!(std::fs::metadata(f.output()).unwrap().nlink(),2);
        }
        #[test]
        fn created_nonempty_leaf_is_rejected_before_report_write() {
            let f=Fixture::new();f.begin();f.hook(Point::Created, |file,_,_|file.write_all(b"held-prefix"));
            f.failed("created leaf invalid");assert_eq!(std::fs::read(f.output()).unwrap(),b"held-prefix");
        }
        #[test]
        fn existing_leaf_and_existing_symlink_are_not_modified() {
            let f=Fixture::new();f.begin();std::fs::write(f.output(),b"existing").unwrap();
            let error=snapshot(&f.status()).unwrap_err();assert_eq!(error.raw_os_error(),Some(libc::EEXIST));assert_eq!(std::fs::read(f.output()).unwrap(),b"existing");
            std::fs::remove_file(f.output()).unwrap();let target=f.protected.join("original");std::fs::write(&target,b"original").unwrap();std::os::unix::fs::symlink(&target,f.output()).unwrap();
            let error=snapshot(&f.status()).unwrap_err();assert_eq!(error.raw_os_error(),Some(libc::EEXIST));assert_eq!(std::fs::read(target).unwrap(),b"original");
            assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
        }
        #[test]
        fn partial_write_error_preserves_failed_artifact_and_original_error() {
            let f=Fixture::new();f.begin();f.hook(Point::Write,|file,_,_|{file.write_all(b"partial")?;Err(std::io::Error::from_raw_os_error(libc::EIO))});
            let error=snapshot(&f.status()).unwrap_err();assert_eq!(error.raw_os_error(),Some(libc::EIO));
            assert!(BOUNDARY.lock().unwrap().is_none());assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            assert_eq!(std::fs::read(f.output()).unwrap(),b"partial");
        }
        #[test]
        fn replaced_parent_rejects_publication_without_modifying_new_directory() {
            let f=Fixture::new();f.begin();f.hook(Point::AfterWrite,|_,dir,_|{std::fs::rename(dir,dir.with_file_name("held-directory"))?;std::fs::create_dir(dir)});
            f.failed("publication changed");assert!(std::fs::read_dir(&f.dir).unwrap().next().is_none());
            let moved=f.dir.with_file_name("held-directory");assert_eq!(std::fs::read_dir(moved).unwrap().count(),1);
        }
        #[test]
        fn named_boundary_io_failure_preserves_error_and_complete_failed_artifact() {
            let f=Fixture::new();f.begin();f.hook(Point::Named,|_,_,_|Err(std::io::Error::from_raw_os_error(libc::EIO)));
            let error=snapshot(&f.status()).unwrap_err();assert_eq!(error.raw_os_error(),Some(libc::EIO));
            assert!(BOUNDARY.lock().unwrap().is_none());assert!(!ATTEMPT.lock().unwrap().as_ref().unwrap().4);
            assert!(serde_json::from_slice::<serde_json::Value>(&std::fs::read(f.output()).unwrap()).is_ok());
        }
    }
}
#[cfg(feature = "import-timing-fixture")]
pub(crate) use enabled::{Span, begin_attempt, snapshot, current_fixture_epoch};

#[cfg(all(test, not(feature = "import-timing-fixture")))]
mod disabled_tests {
    use super::*;
    #[test]
    fn default_build_cannot_enable_timing_or_write_a_report() {
        let root=tempfile::tempdir().unwrap();let physical=root.path().canonicalize().unwrap();
        let old_flag=std::env::var_os("LW_CATALOG_IMPORT_TIMING_FIXTURE");
        let old_dir=std::env::var_os("LW_CATALOG_IMPORT_TIMING_DIRECTORY");
        struct Restore(Option<std::ffi::OsString>,Option<std::ffi::OsString>);
        impl Drop for Restore {fn drop(&mut self){unsafe{
            match &self.0 {Some(v)=>std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE",v),None=>std::env::remove_var("LW_CATALOG_IMPORT_TIMING_FIXTURE")}
            match &self.1 {Some(v)=>std::env::set_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY",v),None=>std::env::remove_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY")}
        }}}
        let _restore=Restore(old_flag,old_dir);
        unsafe{std::env::set_var("LW_CATALOG_IMPORT_TIMING_FIXTURE","1");std::env::set_var("LW_CATALOG_IMPORT_TIMING_DIRECTORY",&physical);}
        assert_eq!(std::mem::size_of::<Span>(),0);begin_attempt("00000000-0000-4000-8000-000000000001",&[]);
        drop(Span::start(Stage::ActorWait));
        let status = ImportStatus {
            id: "00000000-0000-4000-8000-000000000001".to_owned(),
            source: crate::storage_volume::NativePath::from_path(&physical),
            phase: crate::application::ImportPhase::Discovering,
            imported: crate::application::U64(0), unchanged: crate::application::U64(0),
            failed: crate::application::U64(0), skipped: crate::application::U64(0),
            metadata_updated: crate::application::U64(0), metadata_warnings: crate::application::U64(0),
            awaiting_resources: crate::application::U64(0), pending_previews: 0,
            error: None, error_source: None,
        };
        snapshot(&status).unwrap();assert!(std::fs::read_dir(&physical).unwrap().next().is_none());
    }
}

