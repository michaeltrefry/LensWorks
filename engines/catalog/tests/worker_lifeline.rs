//! Helper processes must not outlive their owner and must stop on SIGTERM.
#![cfg(unix)]
use std::{
    os::unix::process::ExitStatusExt,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

const WORKER: &str = env!("CARGO_BIN_EXE_photocatalog");
const MODES: [&str; 2] = ["--catalog-filesystem-worker", "--catalog-desktop-worker"];

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait_gone(pid: i32, within: Duration) -> bool {
    let until = Instant::now() + within;
    while Instant::now() < until {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    !alive(pid)
}

/// The owner dies while the worker's stdin pipe stays open (held here), so
/// only parent-death detection can end the worker; EOF never arrives.
#[test]
fn worker_exits_when_its_owner_dies_even_with_its_pipe_still_open() {
    for mode in MODES {
        let mut owner = Command::new("/bin/sh")
            .arg("-c")
            // fd 3 carries our pipe past sh's /dev/null stdin for `&` jobs.
            .arg(r#"exec 3<&0; "$0" "$1" <&3 3<&- & echo $!; exec sleep 60"#)
            .arg(WORKER)
            .arg(mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(owner.stdout.take().unwrap()),
            &mut line,
        )
        .unwrap();
        let worker: i32 = line.trim().parse().unwrap();
        // Hold the write end ourselves: Child::wait would otherwise close it.
        let pipe = owner.stdin.take().unwrap();
        // The worker is blocked reading its startup frame from our open pipe.
        std::thread::sleep(Duration::from_millis(500));
        assert!(alive(worker), "{mode} worker should wait for its owner");
        owner.kill().unwrap();
        owner.wait().unwrap();
        // Generous only for a slow exec on a loaded host; an orphan never exits.
        let gone = wait_gone(worker, Duration::from_secs(20));
        if !gone {
            unsafe { libc::kill(worker, libc::SIGKILL) };
        }
        assert!(gone, "{mode} worker outlived its owner");
        drop(pipe);
    }
}

/// An inherited ignored SIGTERM (as a launching shell or host can leave
/// behind) must not stop a plain `kill` from ending the worker promptly.
#[test]
fn worker_stops_promptly_on_sigterm_even_if_inherited_as_ignored() {
    for mode in MODES {
        let mut worker = Command::new("/bin/sh")
            .arg("-c")
            .arg(r#"trap '' TERM; exec "$0" "$1""#)
            .arg(WORKER)
            .arg(mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        std::thread::sleep(Duration::from_millis(500));
        let pid = worker.id() as i32;
        assert!(worker.try_wait().unwrap().is_none(), "{mode} worker should wait for startup");
        // Repeat the signal: one delivered before the helper reaches main
        // is still ignored by the inherited disposition. A helper that keeps
        // ignoring SIGTERM never exits, whatever the count.
        let until = Instant::now() + Duration::from_secs(20);
        let status = loop {
            if let Some(status) = worker.try_wait().unwrap() {
                break Some(status);
            }
            if Instant::now() >= until {
                break None;
            }
            unsafe { libc::kill(pid, libc::SIGTERM) };
            std::thread::sleep(Duration::from_millis(100));
        };
        let Some(status) = status else {
            worker.kill().unwrap();
            worker.wait().unwrap();
            panic!("{mode} worker ignored SIGTERM");
        };
        assert_eq!(status.signal(), Some(libc::SIGTERM), "{mode}: {status:?}");
    }
}
