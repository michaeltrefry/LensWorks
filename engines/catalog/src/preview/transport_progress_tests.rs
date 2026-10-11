//! Service-loop progress with actual transport tasks and synthetic F/N adapters.
//! No helper process or image codec is launched by these managed workers.
use super::*;
use crate::application::U64;
use crate::catalog_backup::RestoreStatus;
use crate::catalog_session::{
    CatalogBootstrap, CatalogFilesystem, ConfirmSqlAdmission, LeaseId, PhysicalObjectId,
    PrepareCatalog, RootCapability, SqlAdmissionConfirmed, native as n,
    preview_io::{Expected, Integrity},
    preview_stage as f,
};
use crate::filesystem_worker::wire::{Failure, FailureKind};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, AtomicUsize},
    mpsc,
};
use std::time::Duration;

struct LostAdmission {
    stage: LeaseId,
    first: Mutex<Option<f::Request>>,
    requests: Mutex<Vec<f::Request>>,
    held_abort: Mutex<Option<(mpsc::SyncSender<()>, mpsc::Receiver<()>)>>,
    held_spawn: Mutex<Option<(mpsc::SyncSender<()>, mpsc::Receiver<()>)>>,
    admit_ready: bool,
    native_calls: AtomicUsize,
    native_actions: Mutex<Vec<n::Action>>,
}
impl CatalogFilesystem for LostAdmission {
    fn native(&self) -> Option<&dyn n::CatalogNative> {
        Some(self)
    }
    fn preview_stage_call(
        &self,
        request: &f::Request,
        _: &std::sync::atomic::AtomicBool,
    ) -> Result<f::Reply> {
        self.requests.lock().unwrap().push(request.clone());
        let value = match &request.action {
            f::Action::Admit { .. } => {
                if self.admit_ready {
                    f::Value::Admitted {
                        stage: self.stage.clone(),
                        ready: true,
                        error: None,
                    }
                } else {
                    let mut first = self.first.lock().unwrap();
                    if first.is_none() {
                        *first = Some(request.clone());
                        return Err(
                            Failure::new(FailureKind::Unknown, "lost A stage receipt").into()
                        );
                    }
                    if first.as_ref().unwrap().operation == request.operation {
                        ensure!(
                            serde_json::to_vec(first.as_ref().unwrap())?
                                == serde_json::to_vec(request)?,
                            "changed origin A admission replay"
                        );
                        f::Value::Admitted {
                            stage: self.stage.clone(),
                            ready: true,
                            error: None,
                        }
                    } else {
                        return Err(Failure::new(
                            FailureKind::Canceled,
                            "B rejected before effects",
                        )
                        .into());
                    }
                }
            }
            f::Action::Upload { stage, .. } | f::Action::SealInput { stage, .. }
                if self.admit_ready =>
            {
                ensure!(stage == &self.stage, "unexpected fixture upload stage");
                f::Value::Unit
            }
            f::Action::AbortRead { stage } => {
                ensure!(stage == &self.stage, "unexpected fixture stage abort");
                if let Some((entered, release)) = self.held_abort.lock().unwrap().take() {
                    entered.send(())?;
                    release.recv()?;
                }
                f::Value::Unit
            }
            f::Action::Release { stage } => {
                ensure!(stage == &self.stage, "unexpected fixture stage release");
                f::Value::Unit
            }
            _ => anyhow::bail!("unexpected fixture stage operation"),
        };
        Ok(f::Reply {
            epoch: request.root.epoch.clone(),
            session: request.root.session.clone(),
            operation: request.operation,
            value,
        })
    }
    fn prepare_catalog(
        &self,
        _: &PrepareCatalog,
        _: &std::sync::atomic::AtomicBool,
    ) -> Result<CatalogBootstrap> {
        anyhow::bail!("unexpected catalog admission")
    }
    fn abandon_prepare(&self, _: U64, _: &LeaseId) -> Result<()> {
        anyhow::bail!("unexpected abandon")
    }
    fn confirm_sql_admission(
        &self,
        _: &ConfirmSqlAdmission,
        _: &std::sync::atomic::AtomicBool,
    ) -> Result<SqlAdmissionConfirmed> {
        anyhow::bail!("unexpected SQL admission")
    }
    fn restore_status(&self, _: &RootCapability) -> Result<Option<RestoreStatus>> {
        anyhow::bail!("unexpected restore")
    }
    fn resume_restored_jobs(&self, _: &RootCapability, _: &str, _: bool) -> Result<RestoreStatus> {
        anyhow::bail!("unexpected resume")
    }
    fn release_root(&self, _: &RootCapability) -> Result<()> {
        anyhow::bail!("unexpected root release")
    }
}
impl n::CatalogNative for LostAdmission {
    fn call(&self, request: &n::Request, _: &std::sync::atomic::AtomicBool) -> Result<n::Status> {
        self.native_calls
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        self.native_actions
            .lock()
            .unwrap()
            .push(request.action.clone());
        if matches!(request.action, n::Action::Spawn { .. })
            && let Some((entered, release)) = self.held_spawn.lock().unwrap().take()
        {
            entered.send(())?;
            release.recv()?;
            return Err(Failure::new(
                FailureKind::Canceled,
                "fixture rejects before native spawn effects",
            )
            .into());
        }
        anyhow::bail!("no native child may be admitted by this fixture")
    }
    fn status(&self, _: &RootCapability, _: U64) -> Result<n::Status> {
        anyhow::bail!("no native status exists in fixture")
    }
}
fn root() -> RootCapability {
    #[cfg(unix)]
    let physical = PhysicalObjectId::Unix {
        device: U64(1),
        inode: U64(2),
    };
    #[cfg(windows)]
    let physical = PhysicalObjectId::Windows {
        volume_serial: U64(1),
        file_index: U64(2),
    };
    #[cfg(unix)]
    let path = Path::new("/synthetic-transport-progress");
    #[cfg(windows)]
    let path = Path::new(r"C:\synthetic-transport-progress");
    RootCapability {
        epoch: LeaseId::new(),
        token: LeaseId::new(),
        session: LeaseId::new(),
        canonical_root: NativePath::from_path(path),
        root_physical: physical,
        catalog_physical: physical,
    }
}
fn admit_managed(
    previews: &mut PreviewService,
    calls: Arc<super::super::stage_io::Calls>,
) -> Result<u64> {
    let lease = previews
        .scheduler
        .next_ready()?
        .context("fixture native lease missing")?;
    let request = previews
        .jobs
        .get(&lease.key)
        .context("fixture saved job missing")?
        .request
        .clone();
    let guard = previews
        .encoded
        .try_reserve(previews.limits.per_worker_encoded_bytes)
        .context("fixture encoded reservation missing")?;
    let worker = WorkerProcess::spawn_managed(calls, request, &previews.limits)?;
    let id = lease.id;
    previews.active.insert(
        id,
        ActiveJob {
            lease,
            worker,
            _encoded: guard,
        },
    );
    previews.active.get_mut(&id).unwrap().worker.start()?;
    Ok(id)
}
#[test]
fn tick_reconciles_finished_unknown_origin_while_other_transport_waits() -> Result<()> {
    run(false)
}
#[test]
fn tick_retries_cleanup_thread_admission_without_latching_a_terminal_result() -> Result<()> {
    run(true)
}
fn run(fail_cleanup_spawn: bool) -> Result<()> {
    let directory = tempfile::tempdir()?;
    let (mut catalog, mut previews, asset, _) = super::recovery_tests::setup(directory.path());
    previews.limits.workers = 2;
    previews.limits.working_bytes = 8 * 1024 * 1024 * 1024;
    previews.scheduler = PreviewScheduler::new(super::super::scheduler::SchedulerLimits {
        requests: previews.limits.requests,
        workers: 2,
        working_bytes: previews.limits.working_bytes,
    })?;
    previews.request(&mut catalog, &asset, Tier::Thumbnail, Priority::Foreground)?;
    previews.request(&mut catalog, &asset, Tier::Large, Priority::Foreground)?;
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let fake = Arc::new(LostAdmission {
        stage: LeaseId::new(),
        first: Mutex::new(None),
        requests: Mutex::new(Vec::new()),
        held_abort: Mutex::new(Some((entered_tx, release_rx))),
        held_spawn: Mutex::new(None),
        admit_ready: false,
        native_calls: AtomicUsize::new(0),
        native_actions: Mutex::new(Vec::new()),
    });
    let calls = super::super::stage_io::Calls::new(fake.clone(), root(), false);
    let a = admit_managed(&mut previews, calls.clone())?;
    if fail_cleanup_spawn {
        previews
            .active
            .get_mut(&a)
            .unwrap()
            .worker
            .fail_next_cleanup_spawn();
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    while previews.active[&a].worker.transport_busy() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(2));
    }
    let a_finished_before_b = !previews.active[&a].worker.transport_busy();
    let b = admit_managed(&mut previews, calls)?;
    // B's task has been started and remains unable to dispatch over A's Unknown.
    std::thread::sleep(Duration::from_millis(20));
    let b_busy_before_tick = previews.active[&b].worker.transport_busy();
    let charged = previews.encoded.used();
    let scheduler_charged = previews.scheduler.usage().reserved_bytes;
    let start = Instant::now();
    let tick = previews.tick(&mut catalog);
    let tick_elapsed = start.elapsed();
    let first_cleanup_absent = !fail_cleanup_spawn
        || matches!(
            entered_rx.recv_timeout(Duration::from_millis(30)),
            Err(mpsc::RecvTimeoutError::Timeout)
        );
    let retry_tick = if fail_cleanup_spawn {
        previews.tick(&mut catalog)
    } else {
        Ok(())
    };
    let cleanup_started = entered_rx.recv_timeout(Duration::from_secs(2));
    let held_count = previews.active.len();
    let held_encoded = previews.encoded.used();
    let held_working = previews.scheduler.usage().reserved_bytes;
    // Always release F and explicitly drain before assertions, including the
    // old global-busy implementation which never started origin reconciliation.
    let _ = release_tx.send(());
    let deadline = Instant::now() + Duration::from_secs(3);
    let drained = loop {
        match previews.try_shutdown() {
            Ok(()) => break Ok(()),
            Err(error) if Instant::now() >= deadline => break Err(error),
            Err(_) => std::thread::sleep(Duration::from_millis(2)),
        }
    };
    tick?;
    retry_tick?;
    drained?;
    assert!(
        first_cleanup_absent,
        "injected thread failure unexpectedly launched cleanup"
    );
    assert!(a_finished_before_b);
    assert!(b_busy_before_tick);
    cleanup_started?;
    assert!(
        tick_elapsed < Duration::from_secs(1),
        "tick blocked: {tick_elapsed:?}"
    );
    assert_eq!(held_count, 2);
    assert_eq!(held_encoded, charged);
    assert_eq!(held_working, scheduler_charged);
    assert_eq!(previews.encoded.used(), 0);
    assert_eq!(previews.scheduler.usage().reserved_bytes, 0);
    assert_eq!(
        fake.native_calls.load(std::sync::atomic::Ordering::Acquire),
        0
    );
    let requests = fake.requests.lock().unwrap();
    let first = fake.first.lock().unwrap();
    let original = first.as_ref().unwrap();
    let exact: Vec<_> = requests
        .iter()
        .filter(|r| r.operation == original.operation)
        .collect();
    assert_eq!(exact.len(), 2);
    assert_eq!(serde_json::to_vec(exact[0])?, serde_json::to_vec(exact[1])?);
    assert!(
        requests
            .iter()
            .any(|r| matches!(r.action, f::Action::Release { .. }))
    );
    Ok(())
}

struct ManagedReadFiles {
    calls: Arc<super::super::stage_io::Calls>,
    encoded: Vec<u8>,
}
impl super::AdmittedStoreFiles for ManagedReadFiles {
    fn stage_calls(&self) -> Option<Arc<super::super::stage_io::Calls>> {
        Some(self.calls.clone())
    }
    fn cache_root(&self, _: &Path) -> Result<LeaseId> {
        Ok(LeaseId::new())
    }
    fn cache_read_cancel(
        &self,
        expected: Expected,
        allowance: u64,
        cancel: &AtomicBool,
    ) -> Result<(Integrity, Vec<u8>)> {
        ensure!(!cancel.load(std::sync::atomic::Ordering::Acquire));
        ensure!(expected.bytes.0 == self.encoded.len() as u64);
        ensure!(allowance >= expected.bytes.0);
        ensure!(expected.checksum == blake3::hash(&self.encoded).to_hex().as_str());
        Ok((Integrity::Intact, self.encoded.clone()))
    }
    fn lock_tiers(&self, _: &StoreConfig, _: &str) -> Result<Arc<dyn Send + Sync>> {
        anyhow::bail!("fixture does not acquire cache locks")
    }
}

#[test]
fn synchronous_read_admission_rejects_active_managed_read_lease_and_recovers_after_drain()
-> Result<()> {
    let directory = tempfile::tempdir()?;
    let (catalog, mut service, asset, source) = super::recovery_tests::setup(directory.path());
    let identity = catalog.edit_render_identity(&VariantKey::master(&asset))?;
    let key = service.variant_key(&identity, Tier::Thumbnail)?;
    let prepared = super::prepare(&crate::media::decode_full(&source)?, key.edge)?;
    let encoded = super::encode(&prepared, key.encoding, None)?;
    service.store.desire(&key, || Ok(true))?;
    service.store.publish(&key, &encoded, |attach| attach())?;

    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let fake = Arc::new(LostAdmission {
        stage: LeaseId::new(),
        first: Mutex::new(None),
        requests: Mutex::new(Vec::new()),
        held_abort: Mutex::new(None),
        held_spawn: Mutex::new(Some((entered_tx, release_rx))),
        admit_ready: true,
        native_calls: AtomicUsize::new(0),
        native_actions: Mutex::new(Vec::new()),
    });
    let calls = super::super::stage_io::Calls::new(fake.clone(), root(), true);
    service
        .store
        .set_admitted_files_for_test(Arc::new(ManagedReadFiles { calls, encoded }));

    let ticket = service.queue_read_variant(
        &catalog,
        &VariantKey::master(&asset),
        Tier::Thumbnail,
        false,
        Priority::Foreground,
        false,
    )?;
    assert!(service.tick_read(&catalog).is_none());

    let deadline = Instant::now() + Duration::from_secs(3);
    let reached_spawn = loop {
        let _ = service.tick_read(&catalog);
        match entered_rx.try_recv() {
            Ok(()) => break true,
            Err(mpsc::TryRecvError::Disconnected) => break false,
            Err(mpsc::TryRecvError::Empty) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(2));
            }
            Err(mpsc::TryRecvError::Empty) => break false,
        }
    };
    let active_read = service.reads.active();
    let active_usage = service.scheduler_usage();
    let active_queue_usage = service.read_queue_usage();
    let busy = service
        .ensure_synchronous_read_available()
        .unwrap_err()
        .is::<super::super::stage_io::Busy>();

    // The fake N adapter rejects Spawn before effects. Its release lets the
    // retained owner follow checked abort/release and return the scheduler lease.
    let _ = release_tx.send(());
    let drain_deadline = Instant::now() + Duration::from_secs(3);
    let drained = loop {
        match service.try_shutdown() {
            Ok(()) => break Ok(()),
            Err(error) if Instant::now() >= drain_deadline => break Err(error),
            Err(_) => std::thread::sleep(Duration::from_millis(2)),
        }
    };
    drained?;

    let retired_usage = service.scheduler_usage();
    let retired_read = service.reads.active();
    let admission_recovered = service.synchronous_read_available();
    let actions = fake.requests.lock().unwrap();
    let saw_admit = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::Admit { .. }));
    let saw_abort = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::AbortRead { .. }));
    let saw_release = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::Release { .. }));
    drop(actions);

    assert!(
        reached_spawn,
        "managed read never reached fake native Spawn"
    );
    assert!(active_read, "read queue did not retain the managed read");
    assert_eq!(active_usage.active, 1, "native read lease was not active");
    assert_eq!(active_usage.queued, 0);
    assert!(active_usage.reserved_bytes > 0);
    assert_eq!(active_queue_usage.queued, 1);
    assert_eq!(active_queue_usage.completed, 0);
    assert!(
        busy,
        "synchronous cache read admitted during active read lease"
    );
    assert!(ticket.0 > 0);
    assert!(saw_admit);
    assert!(
        saw_abort && saw_release,
        "managed stage did not drain normally"
    );
    let native_actions = fake.native_actions.lock().unwrap();
    assert_eq!(
        native_actions
            .iter()
            .filter(|action| matches!(action, n::Action::Spawn { .. }))
            .count(),
        1,
        "fixture must reject exactly one native Spawn before effects"
    );
    assert!(!retired_read);
    assert_eq!(retired_usage.active, 0);
    assert_eq!(retired_usage.queued, 0);
    assert_eq!(retired_usage.reserved_bytes, 0);
    assert!(admission_recovered);
    Ok(())
}

#[test]
fn preview_settings_status_stays_undrained_after_active_read_cancel_ack()
-> Result<()> {
    let directory = tempfile::tempdir()?;
    let (mut catalog, mut service, asset, source) = super::recovery_tests::setup(directory.path());
    let identity = catalog.edit_render_identity(&VariantKey::master(&asset))?;
    let key = service.variant_key(&identity, Tier::Thumbnail)?;
    let prepared = super::prepare(&crate::media::decode_full(&source)?, key.edge)?;
    let encoded = super::encode(&prepared, key.encoding, None)?;
    service.store.desire(&key, || Ok(true))?;
    service.store.publish(&key, &encoded, |attach| attach())?;

    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let fake = Arc::new(LostAdmission {
        stage: LeaseId::new(),
        first: Mutex::new(None),
        requests: Mutex::new(Vec::new()),
        held_abort: Mutex::new(None),
        held_spawn: Mutex::new(Some((entered_tx, release_rx))),
        admit_ready: true,
        native_calls: AtomicUsize::new(0),
        native_actions: Mutex::new(Vec::new()),
    });
    let calls = super::super::stage_io::Calls::new(fake.clone(), root(), true);
    service
        .store
        .set_admitted_files_for_test(Arc::new(ManagedReadFiles { calls, encoded }));

    let ticket = service.queue_read_variant(
        &catalog,
        &VariantKey::master(&asset),
        Tier::Thumbnail,
        false,
        Priority::Foreground,
        false,
    )?;
    let pending_status = crate::application::preview_settings::preview_drain_status_for_test(
        &mut catalog, &mut service,
    )?;
    assert!(service.tick_read(&catalog).is_none());

    let deadline = Instant::now() + Duration::from_secs(3);
    let reached_spawn = loop {
        let _ = service.tick_read(&catalog);
        match entered_rx.try_recv() {
            Ok(()) => break true,
            Err(mpsc::TryRecvError::Disconnected) => break false,
            Err(mpsc::TryRecvError::Empty) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(2));
            }
            Err(mpsc::TryRecvError::Empty) => break false,
        }
    };
    let active_read = service.reads.active();
    let active_usage = service.scheduler_usage();
    let active_queue_usage = service.read_queue_usage();
    let busy = service
        .ensure_synchronous_read_available()
        .unwrap_err()
        .is::<super::super::stage_io::Busy>();

    let active_status = crate::application::preview_settings::preview_drain_status_for_test(
        &mut catalog, &mut service,
    );
    let canceled = service.cancel_read(ticket);
    let canceled_status = crate::application::preview_settings::preview_drain_status_for_test(
        &mut catalog, &mut service,
    );
    let canceled_read_retained = service.reads.active();
    let canceled_usage = service.scheduler_usage();

    // The fake N adapter rejects Spawn before effects. Its release lets the
    // retained owner follow checked abort/release and return the scheduler lease.
    let _ = release_tx.send(());
    let drain_deadline = Instant::now() + Duration::from_secs(3);
    let drained = loop {
        match service.try_shutdown() {
            Ok(()) => break Ok(()),
            Err(error) if Instant::now() >= drain_deadline => break Err(error),
            Err(_) => std::thread::sleep(Duration::from_millis(2)),
        }
    };
    drained?;

    let retired_status = crate::application::preview_settings::preview_drain_status_for_test(
        &mut catalog, &mut service,
    )?;
    assert!(!pending_status.previews_drained);
    assert!(!active_status?.previews_drained);
    assert!(canceled, "active read cancellation acknowledgement missing");
    assert!(!canceled_status?.previews_drained,
            "cancel acknowledgement was falsely reported as native retirement");
    assert!(canceled_read_retained);
    assert_eq!(canceled_usage.active, active_usage.active);
    assert_eq!(canceled_usage.reserved_bytes, active_usage.reserved_bytes);
    assert!(retired_status.previews_drained);
    let retired_usage = service.scheduler_usage();
    let retired_read = service.reads.active();
    let admission_recovered = service.synchronous_read_available();
    let actions = fake.requests.lock().unwrap();
    let saw_admit = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::Admit { .. }));
    let saw_abort = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::AbortRead { .. }));
    let saw_release = actions
        .iter()
        .any(|request| matches!(request.action, f::Action::Release { .. }));
    drop(actions);

    assert!(
        reached_spawn,
        "managed read never reached fake native Spawn"
    );
    assert!(active_read, "read queue did not retain the managed read");
    assert_eq!(active_usage.active, 1, "native read lease was not active");
    assert_eq!(active_usage.queued, 0);
    assert!(active_usage.reserved_bytes > 0);
    assert_eq!(active_queue_usage.queued, 1);
    assert_eq!(active_queue_usage.completed, 0);
    assert!(
        busy,
        "synchronous cache read admitted during active read lease"
    );
    assert!(ticket.0 > 0);
    assert!(saw_admit);
    assert!(
        saw_abort && saw_release,
        "managed stage did not drain normally"
    );
    let native_actions = fake.native_actions.lock().unwrap();
    assert_eq!(
        native_actions
            .iter()
            .filter(|action| matches!(action, n::Action::Spawn { .. }))
            .count(),
        1,
        "fixture must reject exactly one native Spawn before effects"
    );
    assert!(!retired_read);
    assert_eq!(retired_usage.active, 0);
    assert_eq!(retired_usage.queued, 0);
    assert_eq!(retired_usage.reserved_bytes, 0);
    assert!(admission_recovered);
    Ok(())
}
