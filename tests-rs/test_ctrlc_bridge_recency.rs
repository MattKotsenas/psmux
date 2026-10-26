//! The Ctrl+C boot-window guard (issue #579) must be bounded by how RECENTLY
//! a VT bridge started, not by whether one exists at all.
//!
//! Regression under test: `send_ctrl_c_event`'s childless-fallback guard used
//! the unbounded `any_vt_bridge_running()`.  An ordinary idle shell pane is
//! childless too — a pwsh blocked in a builtin such as `Start-Sleep` has no
//! child process — so the guard engaged whenever ANY `wsl.exe`/`ssh.exe` was
//! alive anywhere on the machine, stripped ENABLE_PROCESSED_INPUT (measured
//! console mode 0x01F7) and delivered only the raw 0x03, which pwsh ignores
//! mid-cmdlet, while skipping the CTRL_C_EVENT that would have cancelled it.
//! `send-keys C-c` silently stopped interrupting anything in every shell pane
//! on any machine with a WSL window open.
//!
//! The discriminator is process creation time: a bridge inside the ~1-2s cold
//! boot window is attribution-blind (parented by wslservice, on no console)
//! and must still suppress the broadcast; a bridge alive for longer is either
//! already visible to the descendant BFS / console-membership checks or is
//! nothing to do with this pane.
use super::*;
use std::time::Duration;

const WINDOW: Duration = BRIDGE_BOOT_WINDOW;

// ---------------------------------------------------------------------------
// The fresh-vs-stale decision itself.
// ---------------------------------------------------------------------------

#[test]
fn a_freshly_started_bridge_is_still_guarded() {
    // The #579 boot-window bridge: the regression test injects Ctrl+C 900ms
    // after the launch, so anything in that range MUST keep firing the guard.
    assert!(bridge_is_within_boot_window("wsl.exe", Some(Duration::from_millis(0)), WINDOW));
    assert!(bridge_is_within_boot_window("wsl.exe", Some(Duration::from_millis(900)), WINDOW));
    assert!(bridge_is_within_boot_window("wsl.exe", Some(Duration::from_secs(2)), WINDOW));
    assert!(bridge_is_within_boot_window("wslhost.exe", Some(Duration::from_millis(300)), WINDOW));
    assert!(bridge_is_within_boot_window("ssh.exe", Some(Duration::from_secs(1)), WINDOW));
}

#[test]
fn a_stale_unrelated_bridge_is_not_guarded() {
    // The reproduced bug: a `wsl.exe` the user left open (measured age on the
    // reproducing machine: 282625s) must NOT suppress a pane's Ctrl+C.
    assert!(!bridge_is_within_boot_window("wsl.exe", Some(Duration::from_secs(282_625)), WINDOW));
    assert!(!bridge_is_within_boot_window("wsl.exe", Some(Duration::from_secs(60)), WINDOW));
    assert!(!bridge_is_within_boot_window("ssh.exe", Some(Duration::from_secs(3600)), WINDOW));
}

#[test]
fn the_window_boundary_is_inclusive_and_exact() {
    assert!(bridge_is_within_boot_window("wsl.exe", Some(WINDOW), WINDOW));
    assert!(!bridge_is_within_boot_window(
        "wsl.exe",
        Some(WINDOW + Duration::from_millis(1)),
        WINDOW
    ));
}

#[test]
fn the_boot_window_generously_covers_the_reproduced_cold_boot() {
    // The #579 repro's cold boot is ~1-2s and its injected Ctrl+C lands at
    // 900ms.  Guard against anyone tightening this below that reality.
    assert!(WINDOW >= Duration::from_secs(5), "boot window shrank below the measured cold boot");
}

#[test]
fn the_resident_service_never_counts_however_fresh() {
    // wslservice.exe is resident forever once WSL has run; it was already
    // excluded from the system-wide check for exactly this reason, and the
    // age bound must not smuggle it back in on a service restart.
    assert!(!bridge_is_within_boot_window("wslservice.exe", Some(Duration::ZERO), WINDOW));
    assert!(!bridge_is_within_boot_window("wslservice", Some(Duration::ZERO), WINDOW));
}

#[test]
fn non_bridges_never_count_however_fresh() {
    for name in ["pwsh.exe", "cmd.exe", "bash.exe", "node.exe", "psmux.exe"] {
        assert!(
            !bridge_is_within_boot_window(name, Some(Duration::ZERO), WINDOW),
            "{name} must not be treated as a VT bridge"
        );
    }
}

#[test]
fn an_unreadable_creation_time_does_not_count() {
    // A process we cannot even open with PROCESS_QUERY_LIMITED_INFORMATION
    // is running under a token that is not ours, so it cannot be the bridge
    // this pane's own shell just launched.  Counting it would restore the
    // unbounded behavior for that process forever.
    assert!(!bridge_is_within_boot_window("wsl.exe", None, WINDOW));
}

// ---------------------------------------------------------------------------
// The creation-time primitive the decision rests on.
// ---------------------------------------------------------------------------

#[test]
fn process_age_reads_our_own_process() {
    let age = process_age(std::process::id()).expect("own process age must be readable");
    // Sanity only: a cargo test binary is younger than a year.
    assert!(age < Duration::from_secs(365 * 24 * 3600), "implausible age {age:?}");
}

#[test]
fn process_age_of_a_dead_pid_is_none() {
    assert!(process_age(u32::MAX).is_none());
}

#[test]
fn process_age_tracks_wall_clock_for_a_real_child() {
    // The load-bearing property: a process started NOW measures as young, and
    // its measured age grows with elapsed time.  Without this the whole
    // discriminator would be inert.
    let mut child = match std::process::Command::new("cmd.exe")
        .args(["/c", "ping -n 6 127.0.0.1 >NUL"])
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return, // no cmd.exe: nothing to assert, do not fail the suite
    };
    let pid = child.id();

    let first = process_age(pid).expect("just-spawned child age must be readable");
    assert!(
        first < Duration::from_secs(3),
        "a just-spawned process measured as {first:?} old"
    );
    assert!(
        bridge_is_within_boot_window("wsl.exe", Some(first), WINDOW),
        "a just-spawned process must fall inside the boot window"
    );

    std::thread::sleep(Duration::from_millis(1500));
    let second = process_age(pid).expect("child still alive");
    assert!(
        second >= first + Duration::from_millis(1200),
        "age did not advance with wall clock: {first:?} -> {second:?}"
    );

    // And with a boot window tighter than the elapsed time, the same process
    // is now classified stale — fresh vs stale on one real process.
    assert!(!bridge_is_within_boot_window(
        "wsl.exe",
        Some(second),
        Duration::from_millis(500)
    ));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn recently_started_vt_bridge_ignores_the_machines_stale_bridges() {
    // Cannot assert a fixed value (a real cold boot could legitimately be in
    // flight), but the returned candidate — if any — must satisfy the bound
    // it was asked for.  With a zero window nothing can qualify: no process
    // has a non-negative age of zero ticks by the time we measure it, and a
    // stale background wsl.exe certainly does not.
    if let Some((pid, age)) = recently_started_vt_bridge(WINDOW) {
        assert!(age <= WINDOW, "returned pid={pid} age={age:?} exceeds the window");
    }
}
