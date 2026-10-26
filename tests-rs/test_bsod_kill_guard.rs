// BSOD guard: kernel dumps (bugcheck 0xEF) proved psmux.exe TerminateProcess'd
// a critical session-0 svchost.exe. Root cause: the pane-tree-kill BFS
// followed a STALE Toolhelp32 ParentPid link -- a pane descendant exited, its
// PID was recycled by an unrelated process, and the BFS (which only tracks
// pid/ppid numbers, not process *identity*) walked that stale edge straight
// into the OS process hierarchy (services.exe -> svchost.exe) and killed it.
//
// This module is registered INSIDE `platform::process_kill` (see the
// `#[path]` registration at the bottom of that module, alongside the sibling
// `tests_issue447_kill_pid_reuse` registration) so `use super::*` resolves the
// guard's private/pub(crate) helpers directly:
//
//   pub(crate) fn is_protected_image(name: &str) -> bool
//   pub(crate) fn edge_is_genuine(parent_creation: Option<u64>, child_creation: Option<u64>) -> bool
//   pub fn is_protected_system_process(pid: u32) -> bool
//
// Three independent layers are exercised:
//   1. is_protected_image      -- static denylist of critical image names.
//   2. edge_is_genuine         -- creation-time ordering check that rejects a
//                                 parent/child edge where the "parent" pid was
//                                 recycled by a process created AFTER the
//                                 "child" -- i.e. the edge is backwards in
//                                 time and therefore stale/impossible.
//   3. is_protected_system_process -- the live, end-to-end guard: pid 0/4,
//                                 denylisted images, and (per contract)
//                                 cross-session targets / unqueryable
//                                 identities are all refused.

use super::*;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Enumerate the live process table via Toolhelp32 (our OWN minimal binding,
/// deliberately independent of `process_kill`'s internal snapshot helpers) and
/// return the first PID whose image name matches `target_lower` (already
/// lowercase), case-insensitively. Returns None if no such process is running.
fn find_pid_by_image(target_lower: &str) -> Option<u32> {
    #[repr(C)]
    struct ProcessEntry32W {
        dw_size: u32,
        cnt_usage: u32,
        th32_process_id: u32,
        th32_default_heap_id: usize,
        th32_module_id: u32,
        cnt_threads: u32,
        th32_parent_process_id: u32,
        pc_pri_class_base: i32,
        dw_flags: u32,
        sz_exe_file: [u16; 260],
    }

    const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;
    const INVALID_HANDLE: isize = -1;

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateToolhelp32Snapshot(dw_flags: u32, th32_process_id: u32) -> isize;
        fn Process32FirstW(h_snapshot: isize, lppe: *mut ProcessEntry32W) -> i32;
        fn Process32NextW(h_snapshot: isize, lppe: *mut ProcessEntry32W) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }

    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE || snap == 0 {
            return None;
        }

        let mut pe: ProcessEntry32W = std::mem::zeroed();
        pe.dw_size = std::mem::size_of::<ProcessEntry32W>() as u32;
        let mut found: Option<u32> = None;

        if Process32FirstW(snap, &mut pe) != 0 {
            loop {
                let nul = pe
                    .sz_exe_file
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(pe.sz_exe_file.len());
                let name = String::from_utf16_lossy(&pe.sz_exe_file[..nul]);
                if name.to_lowercase() == target_lower {
                    found = Some(pe.th32_process_id);
                    break;
                }
                if Process32NextW(snap, &mut pe) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
        found
    }
}

// ---------------------------------------------------------------------------
// 1. is_protected_image -- static denylist
// ---------------------------------------------------------------------------

#[test]
fn is_protected_image_true_for_every_denylisted_name() {
    let denylist = [
        "csrss.exe",
        "smss.exe",
        "wininit.exe",
        "winlogon.exe",
        "services.exe",
        "lsass.exe",
        "lsaiso.exe",
        "svchost.exe",
        "dwm.exe",
        "fontdrvhost.exe",
    ];
    for name in denylist {
        assert!(is_protected_image(name), "{name} must be on the protected-image denylist");
    }
}

#[test]
fn is_protected_image_matches_case_insensitively() {
    assert!(is_protected_image("SvcHost.EXE"), "mixed-case svchost must still match");
    assert!(is_protected_image("CSRSS.EXE"), "all-upper csrss must still match");
    assert!(is_protected_image("WinInit.Exe"), "title-case wininit must still match");
}

#[test]
fn is_protected_image_false_for_ordinary_and_psmux_processes() {
    for name in ["pwsh.exe", "psmux.exe", "cmd.exe", "conhost.exe", "node.exe"] {
        assert!(!is_protected_image(name), "{name} must NOT be on the protected-image denylist");
    }
}

// ---------------------------------------------------------------------------
// 2. edge_is_genuine -- creation-time ordering guard
// ---------------------------------------------------------------------------

#[test]
fn edge_is_genuine_both_unknown_is_not_genuine() {
    assert!(!edge_is_genuine(None, None), "no identity evidence at all -> refuse");
}

#[test]
fn edge_is_genuine_unknown_parent_is_not_genuine() {
    assert!(!edge_is_genuine(None, Some(5)), "parent identity unqueryable -> refuse (fail safe)");
}

#[test]
fn edge_is_genuine_unknown_child_is_not_genuine() {
    assert!(!edge_is_genuine(Some(5), None), "child identity unqueryable -> refuse (fail safe)");
}

#[test]
fn edge_is_genuine_rejects_recycled_parent_pid() {
    // Parent creation time (10) is LATER than the child's (5): a real parent
    // cannot be created after its own child, so this "edge" only exists
    // because the original parent process at this PID exited and the PID
    // number was recycled by a newer, unrelated process. This is precisely
    // the stale-link shape the BFS must refuse to walk.
    assert!(!edge_is_genuine(Some(10), Some(5)), "child older than parent -> recycled-pid edge, reject");
}

#[test]
fn edge_is_genuine_accepts_child_created_after_parent() {
    assert!(edge_is_genuine(Some(5), Some(10)), "child created strictly after parent -> genuine lineage");
}

#[test]
fn edge_is_genuine_accepts_equal_creation_times() {
    assert!(edge_is_genuine(Some(5), Some(5)), "child creation == parent creation is accepted (>=)");
}

/// FIX PROOF: reconstructs the exact mechanism from the kernel dump. A pane's
/// process-tree BFS held a ParentPid edge whose "parent" slot was a psmux
/// pane pid that had long since exited and been recycled by Windows for an
/// unrelated process created very late (t=999_999) -- while the BFS's
/// "child" node at that edge was a genuine system process created at boot
/// (t=100, e.g. wininit.exe). Because the recycled "parent" is YOUNGER than
/// the "child" it supposedly spawned, the edge is backwards in time and must
/// be rejected. This is the guard that stops the BFS from ever reaching
/// services.exe -> svchost.exe through that stale link, which is what
/// TerminateProcess'd a session-0 svchost.exe and bugchecked the machine
/// with 0xEF.
#[test]
fn edge_is_genuine_rejects_the_exact_bsod_crash_shape() {
    assert!(
        !edge_is_genuine(Some(999_999), Some(100)),
        "recycled pane pid (t=999999) masquerading as parent of a boot-time system process (t=100) must be rejected"
    );
}

// ---------------------------------------------------------------------------
// 3. is_protected_system_process -- live end-to-end guard
// ---------------------------------------------------------------------------

#[test]
fn is_protected_system_process_false_for_current_process() {
    assert!(
        !is_protected_system_process(std::process::id()),
        "the test harness's own process must never be considered protected"
    );
}

#[test]
fn is_protected_system_process_true_for_system_idle_and_system_pids() {
    assert!(is_protected_system_process(0), "pid 0 (System Idle Process) must be protected");
    assert!(is_protected_system_process(4), "pid 4 (System) must be protected");
}

/// FIX PROOF: the exact process class that BSOD'd the machine. If no
/// svchost.exe happens to be enumerable (should never happen on a real
/// Windows box), skip rather than fail -- this test is about proving the
/// guard against a REAL instance, not asserting one always exists.
#[test]
fn is_protected_system_process_true_for_real_svchost() {
    match find_pid_by_image("svchost.exe") {
        Some(pid) => {
            assert!(
                is_protected_system_process(pid),
                "REGRESSION: a real, live svchost.exe pid {pid} was NOT recognized as protected"
            );
        }
        None => {
            eprintln!(
                "SKIP: no svchost.exe process found via Toolhelp32 enumeration on this machine; \
                 cannot exercise the live svchost guard path"
            );
        }
    }
}

#[test]
fn is_protected_system_process_false_for_ordinary_spawned_child() {
    match std::process::Command::new("cmd")
        .args(["/c", "timeout", "/t", "60"])
        .spawn()
    {
        Ok(mut child) => {
            let pid = child.id();
            assert!(
                !is_protected_system_process(pid),
                "an ordinary spawned cmd/timeout child (pid {pid}) must NOT be protected \
                 (this is exactly what a real pane descendant looks like)"
            );
            let _ = child.kill();
            let _ = child.wait();
        }
        Err(e) => {
            eprintln!("SKIP: could not spawn a cmd/timeout child process: {e}");
        }
    }
}

/// Traversal-level regression for the crash itself: a synthetic table shaped
/// exactly like the BSOD scenario. Pane 9000 (created recently) is listed as
/// the parent of "wininit" 300 (created at boot, i.e. long BEFORE the pane)
/// because the pane's PID recycled wininit's long-dead real parent. The BFS
/// must refuse that stale edge, so neither 300 nor anything below it
/// ("services" 400, "svchost" 500) may appear in the kill set — while the
/// pane's genuine child 9001 still does.
#[test]
fn descendant_walk_rejects_stale_edge_into_os_hierarchy() {
    let pane = 9000u32;
    let table: Vec<(u32, u32)> = vec![
        (pane, 1),      // pane shell (root of the kill)
        (9001, pane),   // genuine pane child
        (300, pane),    // "wininit": stale ppid — its real parent died, PID reused by pane
        (400, 300),     // "services.exe"
        (500, 400),     // critical "svchost.exe" — killing this bugchecks the machine
    ];
    let mut clock = |pid: u32| -> Option<u64> {
        match pid {
            9000 => Some(999_999), // pane created recently
            9001 => Some(1_000_000), // genuine child: created after pane
            300 => Some(100),      // boot-time system processes: created long
            400 => Some(101),      // before the pane that supposedly spawned them
            500 => Some(102),
            _ => None,
        }
    };
    let descs = collect_descendants_from_table_with(&table, pane, &mut clock);
    assert!(descs.contains(&9001), "genuine pane child must still be swept");
    assert!(
        !descs.contains(&300) && !descs.contains(&400) && !descs.contains(&500),
        "stale edge into the OS hierarchy must not be traversed (BSOD regression): got {:?}",
        descs
    );
}
