//! A sidecar whose process is gone must be noticed even when its output pipe
//! is still open.
//!
//! The host used to learn that the sidecar had died from one signal only:
//! end-of-file on the sidecar's stdout. A pipe reports end-of-file when its
//! LAST writer closes it, and every program the sidecar starts with
//! inherited handles (a tool, a dev server a tool launched) holds a copy of
//! that same pipe. So a sidecar that crashed while one of them was running
//! stayed "alive" for as long as the survivor did: every call waited out its
//! full timeout, hours for a tool run, and nothing respawned.
//!
//! This drives a real PowerShell process through that exact sequence.
#![cfg(windows)]

use std::time::{Duration, Instant};

use devkit_host::{PsHost, SidecarSpec};

/// How long the stand-in child keeps the pipe open. Well beyond the window
/// the host is given to notice, so only the process-exit signal can explain
/// a pass.
const CHILD_SECONDS: u32 = 25;
const NOTICE_WITHIN: Duration = Duration::from_secs(10);

#[test]
fn an_exited_sidecar_is_noticed_while_a_child_still_holds_its_output() {
    // A runtime built by hand, because of how it has to end. Tokio reads a
    // child's pipes on its blocking threads, and a runtime that is simply
    // dropped waits for those reads - here, for the stand-in child to finish
    // its whole run. `shutdown_background` leaves without waiting.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");
    let (noticed, noticed_after, respawned) = runtime.block_on(exercise());
    runtime.shutdown_background();

    assert!(
        noticed,
        "the sidecar process exited but the host still reported it alive after {noticed_after:?}"
    );
    assert!(
        respawned,
        "a host that noticed the death must start a new sidecar on the next call"
    );
}

async fn exercise() -> (bool, Duration, bool) {
    let dir = std::env::temp_dir().join(format!("devkit-host-death-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp folder");
    let script = dir.join("exit-leaving-a-child.ps1");
    // -NoNewWindow is what makes the child share this process's handles,
    // the way a tool's own child processes do.
    let body = format!(
        "Start-Process -NoNewWindow -FilePath \"$env:SystemRoot\\System32\\ping.exe\" -ArgumentList '-n','{CHILD_SECONDS}','127.0.0.1'\r\nStart-Sleep -Milliseconds 500\r\nexit 0\r\n"
    );
    std::fs::write(&script, body).expect("script");

    let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
    let spec = SidecarSpec {
        // Windows PowerShell: present on every Windows machine, so the test
        // never depends on what else is installed.
        program: std::path::Path::new(&system_root)
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe"),
        script,
        cwd: dir.clone(),
        default_timeout: Duration::from_secs(5),
    };

    let host = PsHost::spawn(spec).await.expect("sidecar starts");
    assert!(host.is_alive(), "a freshly started sidecar counts as alive");

    let started = Instant::now();
    while host.is_alive() && started.elapsed() < NOTICE_WITHIN {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let noticed_after = started.elapsed();
    let noticed = !host.is_alive();

    // What noticing is for: the next call starts a fresh sidecar instead of
    // writing into a dead one. (This stand-in exits again straight away, so
    // the call itself fails; that it was started at all is the point.)
    let respawned = noticed && host.ensure_alive().await.is_ok() && host.is_alive();

    host.shutdown().await;
    let _ = std::fs::remove_dir_all(&dir);
    (noticed, noticed_after, respawned)
}
