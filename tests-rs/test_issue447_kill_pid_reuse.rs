// Issue #447: kill_process_tree can terminate an unrelated process (PID reuse)
// and misses children spawned after its snapshot.
//
// These tests are registered INSIDE `platform::process_kill` (see the
// `#[path]` registration at the bottom of that module) so they can reach the
// private helpers `terminate_pid`, `collect_descendants`, and
// `collect_descendants_from_table`.
//
// A real PID-reuse collision cannot be forced deterministically (the OS picks
// which PID to reuse). But the DANGEROUS PRIMITIVE the race depends on can be
// proven deterministically: `terminate_pid` kills whatever process currently
// holds a PID, with ZERO identity verification. If that PID has been reused by
// an unrelated process, that innocent process dies. The tests below prove the
// primitive is unguarded, then (after the fix) prove the guard rejects a PID
// whose identity no longer matches.

use super::*;

/// Spawn an innocent "bystander" process that is NOT a descendant of anything
/// psmux-related. Returns (Child, pid). We use ping -n <big> 127.0.0.1 which
/// idles for a long time without consuming CPU.
fn spawn_bystander() -> (std::process::Child, u32) {
    let child = std::process::Command::new("ping")
        .args(["-n", "600", "127.0.0.1"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("failed to spawn bystander ping process");
    let pid = child.id();
    (child, pid)
}

/// Poll whether a PID is still alive by trying to OpenProcess for SYNCHRONIZE.
fn pid_alive(pid: u32) -> bool {
    const SYNCHRONIZE: u32 = 0x0010_0000;
    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(desired_access: u32, inherit_handle: i32, process_id: u32) -> isize;
        fn CloseHandle(handle: isize) -> i32;
        fn GetExitCodeProcess(h: isize, code: *mut u32) -> i32;
    }
    const STILL_ACTIVE: u32 = 259;
    unsafe {
        let h = OpenProcess(SYNCHRONIZE | 0x0400 /*QUERY_INFORMATION*/, 0, pid);
        if h == 0 || h == INVALID_HANDLE {
            return false;
        }
        let mut code: u32 = 0;
        let ok = GetExitCodeProcess(h, &mut code);
        CloseHandle(h);
        ok != 0 && code == STILL_ACTIVE
    }
}

fn wait_until_dead(pid: u32, timeout_ms: u64) -> bool {
    let step = 50u64;
    let mut waited = 0u64;
    while waited < timeout_ms {
        if !pid_alive(pid) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(step));
        waited += step;
    }
    !pid_alive(pid)
}

/// The raw primitive (guard DISABLED via None) kills an unrelated process
/// purely by PID. This documents the underlying capability the PID-reuse race
/// weaponizes, and is the exact mode used by detach-client -P (kill_parent).
#[test]
fn terminate_pid_unguarded_kills_by_raw_pid() {
    let (mut bystander, pid) = spawn_bystander();
    assert!(pid_alive(pid), "bystander should be alive right after spawn");

    // None disables the reuse guard -> unconditional kill.
    terminate_pid(pid, None);

    assert!(
        wait_until_dead(pid, 3000),
        "unguarded terminate_pid failed to kill bystander PID {}",
        pid
    );
    let _ = bystander.wait();
}

/// FIX PROOF (race #1): a PID whose process was created AFTER the snapshot
/// cutoff is treated as a reused PID and NOT terminated. This is the precise
/// scenario the issue describes: a descendant exits, its PID is reused by an
/// unrelated process, and the sweep must not kill that innocent process.
///
/// We simulate reuse deterministically: capture a cutoff, wait past the system
/// timer granularity, THEN spawn the "innocent reuser". Its creation time is
/// strictly later than the cutoff, so the guard must refuse to kill it.
#[test]
fn guarded_terminate_rejects_pid_reused_after_cutoff() {
    // Cutoff captured BEFORE the innocent process exists.
    let cutoff = now_filetime();
    // Sleep well past GetSystemTimeAsFileTime granularity (~15ms) so the
    // innocent process's creation time is unambiguously after the cutoff.
    std::thread::sleep(std::time::Duration::from_millis(200));

    let (mut innocent, pid) = spawn_bystander();
    assert!(pid_alive(pid), "innocent process should be alive after spawn");

    // The sweep asks to kill this PID believing it was a descendant, but the
    // real process was created after the cutoff -> guard must skip it.
    terminate_pid(pid, Some(cutoff));

    // Give any (erroneous) termination time to take effect, then assert SURVIVAL.
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert!(
        pid_alive(pid),
        "REGRESSION: guarded terminate_pid killed an innocent PID reused after the cutoff"
    );

    // Cleanup: kill it for real with the guard disabled.
    terminate_pid(pid, None);
    let _ = wait_until_dead(pid, 3000);
    let _ = innocent.wait();
}

/// FIX PROOF (no over-blocking): a genuine descendant (created BEFORE the
/// cutoff) is still terminated. Proves the guard does not break the normal
/// teardown path.
#[test]
fn guarded_terminate_still_kills_genuine_descendant() {
    let (mut child, pid) = spawn_bystander();
    assert!(pid_alive(pid), "process should be alive after spawn");
    // Wait past timer granularity, THEN capture the cutoff so the process's
    // creation time is unambiguously <= cutoff (a legitimate descendant).
    std::thread::sleep(std::time::Duration::from_millis(200));
    let cutoff = now_filetime();

    terminate_pid(pid, Some(cutoff));

    assert!(
        wait_until_dead(pid, 3000),
        "guarded terminate_pid failed to kill a genuine (pre-cutoff) descendant PID {}",
        pid
    );
    let _ = child.wait();
}

/// FIX PROOF: process_creation_filetime returns an increasing value for a
/// later-spawned process, and now_filetime brackets it correctly. This is the
/// identity signal the guard relies on.
#[test]
fn creation_filetime_ordering_is_monotonic() {
    let before = now_filetime();
    std::thread::sleep(std::time::Duration::from_millis(200));
    let (mut child, pid) = spawn_bystander();
    let created = process_creation_filetime(pid).expect("should read creation time of live pid");
    std::thread::sleep(std::time::Duration::from_millis(200));
    let after = now_filetime();

    assert!(created > before, "creation time must be after a pre-spawn cutoff");
    assert!(created <= after, "creation time must be at/before a post-spawn instant");

    terminate_pid(pid, None);
    let _ = wait_until_dead(pid, 3000);
    let _ = child.wait();
}

/// REPRODUCTION (pre-fix): the descendant sweep is captured from a ONE-SHOT
/// snapshot, so a child spawned AFTER the snapshot is invisible to the sweep.
/// We prove this by building the descendant set from a snapshot taken before a
/// child is "spawned", then showing that a later-appearing (pid, ppid) edge is
/// absent from the pre-snapshot descendant set.
#[test]
fn collect_descendants_misses_children_spawned_after_snapshot() {
    // Synthetic PIDs have no live process to query creation times from, so use
    // the injectable variant with a synthetic clock where every edge is
    // genuine (each child created after its parent). Without this, the
    // BSOD-guard edge validation would (correctly) refuse to traverse
    // unverifiable PIDs and mask what this test is actually about: one-shot
    // snapshot timing.
    let mut clock = |pid: u32| -> Option<u64> {
        match pid {
            1000 => Some(100),
            1001 => Some(200),
            1002 => Some(300),
            _ => None,
        }
    };
    // Simulated process table AT snapshot time: root 1000 has one child 1001.
    let root = 1000u32;
    let table_at_snapshot: Vec<(u32, u32)> = vec![(root, 1), (1001, root)];
    let descs_before = collect_descendants_from_table_with(&table_at_snapshot, root, &mut clock);
    assert!(
        descs_before.contains(&1001),
        "existing child must be found in the snapshot"
    );
    assert!(
        !descs_before.contains(&1002),
        "a child not yet spawned cannot appear in the snapshot set"
    );

    // Later, root spawns grandchild 1002 (child of 1001). The kill loop only
    // ever iterates descs_before, so 1002 is NEVER swept -> orphan leak.
    let table_later: Vec<(u32, u32)> = vec![(root, 1), (1001, root), (1002, 1001)];
    let descs_after = collect_descendants_from_table_with(&table_later, root, &mut clock);
    assert!(
        descs_after.contains(&1002),
        "a fresh snapshot WOULD have found 1002"
    );
    assert!(
        !descs_before.contains(&1002),
        "REPRODUCED: the original one-shot snapshot missed the late child 1002",
    );
}
