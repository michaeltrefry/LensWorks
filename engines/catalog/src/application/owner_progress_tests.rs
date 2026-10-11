//! Actual mutex/predicate/notifier/retained-task controls; no native children.
use super::*;
use crate::preview::transport_task::Task;
use std::sync::atomic::AtomicBool;
const BOUND: Duration = Duration::from_secs(5);

fn fixture() -> (Bridge, Arc<OwnerProgress>) {
    let bridge = super::tests::disconnected();
    let token = uuid::Uuid::new_v4();
    {
        let mut queue = bridge.0.shared.queue.lock().unwrap();
        queue.status.catalog = Some(token.to_string());
        queue.status.phase = Phase::Indexing;
    }
    let progress = OwnerProgress::new(&bridge.0.shared, token);
    (bridge, progress)
}

#[test]
fn owner_progress_completion_before_wait_is_durable() {
    let (bridge, progress) = fixture();
    progress.notify();
    let mut queue = bridge.0.shared.queue.lock().unwrap();
    assert!(!queue.owner_wait_required());
    queue.consume_owner_progress();
    assert!(queue.owner_wait_required());
}

#[test]
fn owner_progress_waiter_first_uses_same_mutex_and_condition() {
    let (bridge, progress) = fixture();
    let shared = bridge.0.shared.clone();
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let waiter = thread::spawn(move || {
        let queue = shared.queue.lock().unwrap();
        assert!(queue.owner_wait_required());
        ready_tx.send(()).unwrap();
        // Test-only five-second bound. Production remains the original 10ms.
        let (queue, _) = shared.wake.wait_timeout_while(queue, BOUND,
            |queue| queue.owner_wait_required()).unwrap();
        assert!(!queue.owner_wait_required(), "durable progress hint missing");
    });
    ready_rx.recv_timeout(BOUND).unwrap();
    progress.notify();
    waiter.join().unwrap();
}

#[test]
fn owner_progress_coalesces_without_repeated_maintenance() {
    let (bridge, progress) = fixture();
    for _ in 0..128 { progress.notify(); }
    let mut queue = bridge.0.shared.queue.lock().unwrap();
    assert!(!queue.owner_wait_required());
    queue.consume_owner_progress();
    assert!(queue.owner_wait_required());
    queue.consume_owner_progress();
    assert!(queue.owner_wait_required());
}

#[test]
fn owner_progress_new_hint_after_consumption_is_durable() {
    let (bridge, progress) = fixture();
    progress.notify();
    bridge.0.shared.queue.lock().unwrap().consume_owner_progress();
    progress.notify();
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
}

#[test]
fn owner_progress_spurious_wake_does_not_create_progress() {
    let (bridge, _) = fixture();
    bridge.0.shared.wake.notify_one();
    let mut queue = bridge.0.shared.queue.lock().unwrap();
    assert!(queue.owner_wait_required());
    queue.consume_owner_progress();
    assert!(queue.owner_wait_required());
}

#[test]
fn owner_progress_old_catalog_does_not_wake_replacement() {
    let (bridge, progress) = fixture();
    let replacement = uuid::Uuid::new_v4().to_string();
    bridge.0.shared.queue.lock().unwrap().status.catalog = Some(replacement.clone());
    progress.notify();
    let queue = bridge.0.shared.queue.lock().unwrap();
    assert!(queue.owner_wait_required());
    assert_eq!(queue.status.catalog.as_deref(), Some(replacement.as_str()));
}

#[test]
fn owner_progress_closed_closing_and_stopping_hints_are_ignored() {
    let (bridge, progress) = fixture();
    for phase in [Phase::Closing, Phase::Closed] {
        bridge.0.shared.queue.lock().unwrap().status.phase = phase;
        progress.notify();
        assert!(bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    }
    {
        let mut queue = bridge.0.shared.queue.lock().unwrap();
        queue.status.phase = Phase::Indexing;
        queue.stopping = true;
    }
    progress.notify();
    assert!(bridge.0.shared.queue.lock().unwrap().owner_wait_required());
}

#[test]
fn owner_progress_weak_registration_does_not_retain_actor() {
    let (bridge, progress) = fixture();
    let weak = Arc::downgrade(&bridge.0.shared);
    drop(bridge);
    assert!(weak.upgrade().is_none());
    progress.notify();
    assert!(weak.upgrade().is_none());
}

#[test]
fn owner_progress_poisoned_mutex_notification_does_not_panic() {
    let (bridge, progress) = fixture();
    let shared = bridge.0.shared.clone();
    assert!(thread::spawn(move || {
        let _held = shared.queue.lock().unwrap();
        panic!("controlled queue poison");
    }).join().is_err());
    progress.notify();
    assert!(bridge.0.shared.queue.lock().unwrap_or_else(|e| e.into_inner()).owner_progress_pending);
}

#[test]
fn owner_progress_early_hint_keeps_running_task_and_cancel_result_owned() -> Result<()> {
    let (bridge, progress) = fixture();
    let cancel = Arc::new(AtomicBool::new(false));
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let early = progress.clone();
    let mut task = Task::spawn_notified("owner-progress-held", cancel.clone(), Some(progress), move |_| {
        early.notify();
        ready_tx.send(())?;
        release_rx.recv_timeout(BOUND)?;
        Ok(19u8)
    })?;
    ready_rx.recv_timeout(BOUND)?;
    assert!(task.running());
    assert!(task.poll()?.is_none());
    {
        let mut queue = bridge.0.shared.queue.lock().unwrap();
        assert!(!queue.owner_wait_required());
        queue.consume_owner_progress();
        assert!(queue.owner_wait_required(), "early hint must not spin until thread exit");
    }
    task.signal_cancel();
    assert!(cancel.load(std::sync::atomic::Ordering::Acquire));
    assert!(task.poll()?.is_none(), "cancel is not retirement");
    release_tx.send(())?;
    assert_eq!(task.shutdown()?, Some(19));
    assert!(task.poll().is_err(), "sole result cannot be replayed");
    Ok(())
}

#[test]
fn owner_progress_normal_exit_preserves_sole_result() -> Result<()> {
    let (bridge, progress) = fixture();
    let mut task = Task::spawn_notified("owner-progress-ok", Arc::new(AtomicBool::new(false)),
        Some(progress), |_| Ok(27u8))?;
    assert_eq!(task.shutdown()?, Some(27));
    assert!(task.poll().is_err());
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    Ok(())
}

#[test]
fn owner_progress_error_exit_preserves_typed_cause() -> Result<()> {
    use crate::filesystem_worker::wire::{Failure, FailureKind};
    let (bridge, progress) = fixture();
    let mut task = Task::<u8>::spawn_notified("owner-progress-error", Arc::new(AtomicBool::new(false)),
        Some(progress), |_| Err(Failure::new(FailureKind::Canceled, "controlled task cancellation").into()))?;
    let error = task.shutdown().unwrap_err();
    assert_eq!(error.downcast_ref::<Failure>().unwrap().kind, FailureKind::Canceled);
    assert!(task.poll().is_err());
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    Ok(())
}

#[test]
fn owner_progress_unwind_exit_preserves_failure_and_notifies() -> Result<()> {
    let (bridge, progress) = fixture();
    let mut task = Task::<u8>::spawn_notified("owner-progress-panic", Arc::new(AtomicBool::new(false)),
        Some(progress), |_| panic!("controlled task unwind"))?;
    assert!(task.shutdown().unwrap_err().to_string().contains("panicked"));
    assert!(task.poll().is_err());
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    Ok(())
}

#[test]
fn owner_progress_poison_recovery_during_task_unwind_preserves_failure() -> Result<()> {
    let (bridge, progress) = fixture();
    let shared = bridge.0.shared.clone();
    assert!(thread::spawn(move || {
        let _held = shared.queue.lock().unwrap();
        panic!("controlled queue poison before task");
    }).join().is_err());
    let mut task = Task::<u8>::spawn_notified("owner-progress-compound", Arc::new(AtomicBool::new(false)),
        Some(progress), |_| panic!("controlled task unwind"))?;
    assert!(task.shutdown().unwrap_err().to_string().contains("panicked"));
    assert!(bridge.0.shared.queue.lock().unwrap_or_else(|e| e.into_inner()).owner_progress_pending);
    Ok(())
}

#[test]
fn owner_progress_shutdown_releases_queue_before_join() -> Result<()> {
    let (bridge, progress) = fixture();
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let mut task = Task::spawn_notified("owner-progress-join", Arc::new(AtomicBool::new(false)),
        Some(progress), move |_| { release_rx.recv_timeout(BOUND)?; Ok(1u8) })?;
    let queue = bridge.0.shared.queue.lock().unwrap();
    release_tx.send(())?;
    // Matches Actor's scope: no queue guard survives checked task shutdown.
    drop(queue);
    assert_eq!(task.shutdown()?, Some(1));
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    Ok(())
}

#[test]
fn owner_progress_hint_does_not_mutate_public_cancel_or_status() {
    let (bridge, progress) = fixture();
    let cancel = Cancellation::default();
    {
        let mut queue = bridge.0.shared.queue.lock().unwrap();
        queue.active_cancel = Some(cancel.clone());
        queue.status.cancel_requested = true;
        queue.status.active_previews = 4;
    }
    progress.notify();
    let queue = bridge.0.shared.queue.lock().unwrap();
    assert!(!queue.active_cancel.as_ref().unwrap().is_canceled());
    assert!(queue.status.cancel_requested);
    assert_eq!(queue.status.active_previews, 4);
    assert!(queue.import_status.is_none());
    assert!(queue.import_cancel.is_none());
}

#[test]
fn owner_progress_hint_preserves_public_work_priority_and_reserved_shutdown() {
    let (bridge, progress) = fixture();
    let (tx, _rx) = mpsc::sync_channel(1);
    bridge.0.shared.queue.lock().unwrap().pending.push_back(Envelope {
        work: Work::Shutdown(tx), cancel: Cancellation::default(), created: Instant::now(),
    });
    progress.notify();
    let mut queue = bridge.0.shared.queue.lock().unwrap();
    assert!(!queue.owner_wait_required());
    queue.consume_owner_progress();
    assert_eq!(queue.pending.len(), 1);
    assert_eq!(queue.pending.front().unwrap().priority(), 0);
    assert!(!queue.owner_wait_required(), "public work still defeats waiting");
}

#[test]
fn owner_progress_post_tick_mark_requests_only_one_next_pass() {
    let (bridge, _) = fixture();
    let mut queue = bridge.0.shared.queue.lock().unwrap();
    // Exact method called after Event::End queues its consumer, not a service grant.
    queue.mark_owner_progress();
    assert!(!queue.owner_wait_required());
    queue.consume_owner_progress();
    assert!(queue.owner_wait_required());
    assert!(queue.pending.is_empty());
    assert_eq!(queue.status.active_previews, 0);
}

use crate::catalog_session::{CatalogBootstrap, CatalogFilesystem, ConfirmSqlAdmission, LeaseId, PhysicalObjectId, PrepareCatalog, RootCapability, SqlAdmissionConfirmed};
use crate::catalog_backup::RestoreStatus;
fn synthetic_root() -> RootCapability {
    // Synthetic identities only; these tests do not admit or open a catalog.
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
    let path = std::path::Path::new("/synthetic");
    #[cfg(windows)]
    let path = std::path::Path::new(r"C:\synthetic");
    RootCapability {
        epoch: LeaseId::new(),
        token: LeaseId::new(),
        session: LeaseId::new(),
        canonical_root: NativePath::from_path(path),
        root_physical: physical,
        catalog_physical: physical,
    }
}

struct NoIo;
impl CatalogFilesystem for NoIo {
    fn prepare_catalog(&self, _: &PrepareCatalog, _: &AtomicBool) -> Result<CatalogBootstrap> {
        anyhow::bail!("unexpected catalog admission")
    }
    fn abandon_prepare(&self, _: U64, _: &LeaseId) -> Result<()> {
        anyhow::bail!("unexpected abandon")
    }
    fn confirm_sql_admission(
        &self,
        _: &ConfirmSqlAdmission,
        _: &AtomicBool,
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

#[test]
fn owner_progress_calls_lanes_share_registration_and_replacement() -> Result<()> {
    let (bridge, progress) = fixture();
    let calls = crate::preview::stage_io::Calls::new(Arc::new(NoIo), synthetic_root(), false);
    let lane_before = calls.task_lane()?;
    assert!(lane_before.owner_progress().is_none());
    calls.set_owner_progress(Some(progress.clone()));
    let lane_after = calls.task_lane()?;
    for lane in [&calls, &lane_before, &lane_after] {
        assert!(Arc::ptr_eq(&lane.owner_progress().unwrap(), &progress));
    }
    lane_before.owner_progress().unwrap().notify();
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    calls.set_owner_progress(None);
    assert!(lane_before.owner_progress().is_none());
    assert!(lane_after.owner_progress().is_none());
    Ok(())
}

#[test]
fn owner_progress_unregistered_task_retains_previous_behavior() -> Result<()> {
    let (bridge, _) = fixture();
    let mut task = Task::spawn("owner-progress-unregistered", Arc::new(AtomicBool::new(false)),
        |_| Ok(31u8))?;
    assert_eq!(task.shutdown()?, Some(31));
    assert!(task.poll().is_err());
    assert!(bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    Ok(())
}

#[test]
fn owner_progress_result_hint_does_not_release_byte_reservation() -> Result<()> {
    let (bridge, progress) = fixture();
    let budget = crate::preview::ByteBudget::new(32)?;
    let reservation = budget.try_reserve(32).context("fixture full reservation")?;
    let mut task = Task::spawn_notified("owner-progress-charged-result", Arc::new(AtomicBool::new(false)),
        Some(progress), move |_| Ok(reservation))?;
    let result = task.shutdown()?.context("sole charged result")?;
    assert!(!bridge.0.shared.queue.lock().unwrap().owner_wait_required());
    assert_eq!(budget.used(), 32);
    assert!(budget.try_reserve(1).is_none(), "hint and join do not release retained payload allowance");
    assert!(task.poll().is_err());
    drop(result);
    assert_eq!(budget.used(), 0);
    assert!(budget.try_reserve(32).is_some());
    Ok(())
}
