//! Admission-only service fixtures: no helper or image decoder is launched.
use super::*;
#[test]
fn synchronous_read_preflight_rejects_pause_external_permit_and_older_queued_render() -> Result<()>
{
    let directory = tempfile::tempdir()?;
    let (mut catalog, mut service, asset, _) = super::recovery_tests::setup(directory.path());
    assert!(service.synchronous_read_available());
    service.ensure_synchronous_read_available()?;
    let pause = service.pause_native_launches()?;
    assert!(!service.synchronous_read_available());
    let error = service.ensure_synchronous_read_available().unwrap_err();
    assert!(
        error
            .downcast_ref::<super::super::stage_io::Busy>()
            .is_some()
    );
    assert_eq!(service.encoded.used(), 0);
    let permit = service.native_launch_permit(&catalog, pause)?;
    assert!(!service.synchronous_read_available());
    assert!(
        service
            .ensure_synchronous_read_available()
            .unwrap_err()
            .downcast_ref::<super::super::stage_io::Busy>()
            .is_some()
    );
    drop(permit);
    assert!(service.synchronous_read_available());
    service.ensure_synchronous_read_available()?;
    let consumer = service.request(&mut catalog, &asset, Tier::Thumbnail, Priority::Foreground)?;
    assert_eq!(service.scheduler.usage().active, 0);
    assert!(service.scheduler.usage().queued > 0);
    assert!(!service.synchronous_read_available());
    let error = service.ensure_synchronous_read_available().unwrap_err();
    assert!(
        error
            .downcast_ref::<super::super::stage_io::Busy>()
            .is_some()
    );
    assert!(
        error
            .downcast_ref::<crate::catalog_session::store::ResourceLimit>()
            .is_none()
    );
    assert!(service.active_worker_pids().is_empty());
    assert_eq!(service.encoded.used(), 0);
    service.cancel(consumer)?;
    assert!(service.synchronous_read_available());
    service.ensure_synchronous_read_available()?;
    service.try_shutdown()?;
    Ok(())
}

#[test]
fn synchronous_admission_observes_owned_scheduler_active_and_queued_leases() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let (mut catalog, mut service, asset, _) = super::recovery_tests::setup(directory.path());
    let consumer = service.request(&mut catalog, &asset, Tier::Thumbnail, Priority::Foreground)?;
    assert!(!service.synchronous_read_available());
    let lease = service
        .scheduler
        .next_ready()?
        .context("actual scheduler lease")?;
    assert_eq!(service.scheduler.usage().active, 1);
    assert_eq!(service.scheduler.usage().queued, 0);
    assert!(!service.synchronous_read_available());
    assert!(
        service
            .ensure_synchronous_read_available()
            .unwrap_err()
            .is::<super::super::stage_io::Busy>()
    );
    service
        .scheduler
        .finished(lease.id, WorkerOutcome::Stopped)?;
    service.cancel(consumer)?;
    assert_eq!(service.scheduler.usage().active, 0);
    assert!(service.synchronous_read_available());
    service.try_shutdown()?;
    Ok(())
}
