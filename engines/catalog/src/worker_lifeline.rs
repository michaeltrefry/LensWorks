//! A dedicated helper process must never outlive the owner that spawned it.
//!
//! Helpers speak a framed protocol over pipes owned by their parent. When the
//! parent dies the pipes may stay open (a grandchild or test harness can hold
//! the other end), so EOF alone is not a reliable signal. Every helper mode
//! therefore watches its parent pid and exits when it is reparented. Helpers
//! are crash-consistent by design (owners already SIGKILL them on abnormal
//! shutdown), so leaving with `_exit` keeps the same on-disk guarantees.
//!
//! SIGTERM is reset to its default action and unblocked, overriding any
//! ignored disposition or blocked mask inherited across exec, so a plain
//! `kill` stops a helper promptly instead of requiring SIGKILL.

/// Exit status of a helper that observed its owner disappear.
pub const ORPHANED_EXIT_CODE: i32 = 125;

#[cfg(unix)]
pub fn install() {
    use std::time::Duration;
    // SAFETY: called once at helper startup before any other thread exists.
    unsafe {
        libc::signal(libc::SIGTERM, libc::SIG_DFL);
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut());
    }
    let parent = unsafe { libc::getppid() };
    let orphaned = move || {
        let current = unsafe { libc::getppid() };
        current != parent || current == 1
    };
    if orphaned() {
        unsafe { libc::_exit(ORPHANED_EXIT_CODE) };
    }
    let _ = std::thread::Builder::new()
        .name("owner-lifeline".into())
        .spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(200));
                if orphaned() {
                    // SAFETY: async-signal-safe immediate exit; no owner remains
                    // to receive replies, and helpers are crash-consistent.
                    unsafe { libc::_exit(ORPHANED_EXIT_CODE) };
                }
            }
        });
}

#[cfg(not(unix))]
pub fn install() {}
