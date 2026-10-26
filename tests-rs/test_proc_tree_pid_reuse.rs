// A recycled parent pid must never make a stranger part of a pane.
//
// Observed in the 2026-10-02 sweep on master e36bd85
// (test_issue657_wheel_copy_mode_nonshell, Layer 4):
//
//   [FAIL] the Alacritty pane's foreground is 'vctip'; this layer would prove nothing
//
// The pane was running the suite's own `psmux_i657_log_child`.  `vctip.exe` is
// the MSVC toolchain's telemetry helper: link.exe starts it and exits, and it
// lingers with a ParentProcessId naming the dead linker.  Other agents were
// compiling with MSVC on the same machine at the time.  Windows reuses pids, so
// when the pane process was created with the linker's old pid, the still
// living vctip.exe looked like the pane process's child, and the walk behind
// `#{pane_current_command}` (highest pid child at every level, no identity
// check) reported it.
//
// tmux cannot be fooled this way: `pane_current_command` comes from
// `osdep_get_name(fd, tty)` (format.c), which asks the tty for its foreground
// process group (`tcgetpgrp`, osdep-linux.c / osdep-darwin.c /
// osdep-freebsd.c).  Windows has no such answer for a console, so psmux walks
// Toolhelp parent links, and the ordering of creation times is the guard: a
// genuine child is created at or after its parent; the survivor of a recycled
// pid is older than the process that recycled it.
//
// Every walk site gets the same six questions, on synthetic tables with an
// injected clock:
//   (a) a "child" OLDER than its claimed parent is not followed (vctip),
//   (b) a genuine child created after its parent is followed,
//   (c) equal creation stamps are followed,
//   (d) an unknown creation time is not followed (per site decision, see
//       the doc comments in platform.rs: a pane descendant runs under the
//       server's token, so "unknown" means exited or not ours),
//   (e) the highest pid heuristic still picks the same process among the
//       genuine children,
//   (f) a cycle still ends.
// Each test also carries a stale edge that only the creation time guard can
// reject, so every test fails when the guard is removed.

use super::*;
use crate::platform::proc_tree;
use std::collections::HashMap;

fn row(pid: u32, ppid: u32, name: &str) -> ProcRowT {
    (pid, ppid, name.to_string())
}

/// A clock that knows exactly the pids it was given; everything else is
/// "unknown" (unqueryable or gone).
fn clock(times: &[(u32, u64)]) -> impl FnMut(u32) -> Option<u64> {
    let map: HashMap<u32, u64> = times.iter().copied().collect();
    move |pid| map.get(&pid).copied()
}

// Pane shell P created at t=1000.  The pane's real program (log_child) is its
// child, created later.  vctip.exe was started by a linker whose pid P now
// carries; vctip is far OLDER than P.  It also has the higher pid, so the
// highest pid heuristic alone picks it.
const P: u32 = 5000;
const LOG_CHILD: u32 = 5004;
const VCTIP: u32 = 7000;

fn vctip_sibling_table() -> Vec<ProcRowT> {
    vec![
        row(4, 0, "system"),
        row(P, 1200, "pwsh.exe"),
        row(LOG_CHILD, P, "psmux_i657_log_child.exe"),
        row(VCTIP, P, "vctip.exe"),
    ]
}

fn vctip_times() -> Vec<(u32, u64)> {
    vec![(P, 1000), (LOG_CHILD, 1100), (VCTIP, 50)]
}

// ---------------------------------------------------------------------------
// deepest_descendant: #{pane_current_command}, foreground_is_shell (Ctrl+C
// routing, wheel gating #657/#598, mouse protocol attribution #613),
// foreground_is_vt_bridge, foreground_leaf_pid (wheel latch owner).
// ---------------------------------------------------------------------------

#[test]
fn deepest_a_older_sibling_with_a_recycled_parent_pid_is_not_the_foreground() {
    let t = vctip_sibling_table();
    let got = deepest_descendant(&t, P, &mut clock(&vctip_times()));
    assert_eq!(
        got.map(|(p, _)| p),
        Some(LOG_CHILD),
        "vctip.exe (created at t=50) claims pane shell {P} (created at t=1000) as its \
         parent; that is a recycled pid, not a child, and must not be the foreground"
    );
}

#[test]
fn deepest_a_older_grandchild_under_the_real_program_is_not_followed() {
    // The other shape of the same sweep failure: the pane PROGRAM got the
    // linker's old pid, so vctip hangs one level further down.
    let t = vec![
        row(P, 1200, "pwsh.exe"),
        row(LOG_CHILD, P, "psmux_i657_log_child.exe"),
        row(VCTIP, LOG_CHILD, "vctip.exe"),
    ];
    let got = deepest_descendant(&t, P, &mut clock(&vctip_times()));
    assert_eq!(got.map(|(_, n)| n), Some("psmux_i657_log_child.exe".to_string()));
}

#[test]
fn deepest_b_genuine_chain_is_followed_past_a_stale_sibling() {
    // pwsh -> bash -> cat, all genuine, with an older stranger hanging off bash
    // under a higher pid.
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "bash.exe"),
        row(6001, 6000, "cat.exe"),
        row(9000, 6000, "explorer.exe"),
    ];
    let mut c = clock(&[(P, 1000), (6000, 1500), (6001, 1600), (9000, 10)]);
    assert_eq!(deepest_descendant(&t, P, &mut c), Some((6001, "cat.exe".to_string())));
}

#[test]
fn deepest_c_equal_creation_stamps_are_genuine() {
    // A shell and the command it starts often share one clock tick.
    let t = vec![
        row(P, 1, "cmd.exe"),
        row(6000, P, "ping.exe"),
        row(9000, P, "vctip.exe"),
    ];
    let mut c = clock(&[(P, 1000), (6000, 1000), (9000, 999)]);
    assert_eq!(deepest_descendant(&t, P, &mut c).map(|(p, _)| p), Some(6000));
}

#[test]
fn deepest_d_unknown_creation_time_is_not_followed() {
    // Per site decision: not followed.  The leaf a stale render table still
    // lists but that has since exited is the usual "unknown"; the parent is the
    // honest answer then.  A stranger whose time cannot be read is not adopted.
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "node.exe"),
        row(6001, 6000, "gone.exe"),
    ];
    let mut c = clock(&[(P, 1000), (6000, 1100)]); // 6001 unknown
    assert_eq!(deepest_descendant(&t, P, &mut c).map(|(p, _)| p), Some(6000));
    // An unknown ROOT has no genuine children at all.
    let mut c = clock(&[(6000, 1100), (6001, 1200)]);
    assert_eq!(deepest_descendant(&t, P, &mut c), None);
}

#[test]
fn deepest_e_highest_pid_still_wins_among_genuine_children() {
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(200, P, "a.exe"),
        row(300, P, "b.exe"),
        row(250, P, "c.exe"),
        row(900, P, "stranger.exe"),
        row(950, P, "conhost.exe"), // system exe: skipped as before
    ];
    let mut c = clock(&[(P, 100), (200, 110), (300, 120), (250, 130), (900, 5), (950, 101)]);
    assert_eq!(
        deepest_descendant(&t, P, &mut c).map(|(p, _)| p),
        Some(300),
        "among the genuine children the highest pid (300) is still the pick"
    );
}

#[test]
fn deepest_f_a_cycle_ends() {
    // 10 -> 11 -> 10 ...  The edge 11 -> 10 is stale (10 is older than 11), so
    // the guarded walk stops at 11; an unguarded one bounces 64 times and ends
    // on 10.  With equal stamps every edge is "genuine" and MAX_CHAIN alone
    // must end it.
    let t = vec![row(10, 11, "a.exe"), row(11, 10, "b.exe")];
    let mut c = clock(&[(10, 100), (11, 200)]);
    assert_eq!(deepest_descendant(&t, 10, &mut c).map(|(p, _)| p), Some(11));
    let mut flat = clock(&[(10, 100), (11, 100)]);
    assert!(deepest_descendant(&t, 10, &mut flat).is_some(), "bounded by MAX_CHAIN");
}

// ---------------------------------------------------------------------------
// foreground_child_in: automatic-rename, get_foreground_cwd (the PEB reading
// behind #{pane_current_path} and the rehome stale reading), the wheel's
// legacy pager name check.
// ---------------------------------------------------------------------------

#[test]
fn fgchild_a_stale_sibling_is_not_the_window_name() {
    let t = vctip_sibling_table();
    assert_eq!(foreground_child_in(&t, P, &mut clock(&vctip_times())), Some(LOG_CHILD));
}

#[test]
fn fgchild_a_stale_grandchild_under_a_wrapper_is_not_picked() {
    // pwsh -> cmd (wrapper) -> {node genuine, vctip stale with higher pid}
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "cmd.exe"),
        row(6100, 6000, "node.exe"),
        row(9000, 6000, "vctip.exe"),
    ];
    let mut c = clock(&[(P, 1000), (6000, 1100), (6100, 1200), (9000, 7)]);
    assert_eq!(foreground_child_in(&t, P, &mut c), Some(6100));
}

#[test]
fn fgchild_b_c_e_genuine_and_equal_children_keep_the_highest_pid_rule() {
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "vim.exe"),
        row(6500, P, "git.exe"),
        row(9000, P, "explorer.exe"),
    ];
    // 6500 shares the parent's tick (c); 9000 is a stranger (a).
    let mut c = clock(&[(P, 1000), (6000, 1300), (6500, 1000), (9000, 3)]);
    assert_eq!(foreground_child_in(&t, P, &mut c), Some(6500));
}

#[test]
fn fgchild_d_unknown_child_is_not_the_foreground() {
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "gone.exe")];
    assert_eq!(foreground_child_in(&t, P, &mut clock(&[(P, 1000)])), None);
    // ...and a stranger next to it is not adopted in its place.
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "gone.exe"), row(9000, P, "vctip.exe")];
    assert_eq!(foreground_child_in(&t, P, &mut clock(&[(P, 1000), (9000, 1)])), None);
}

// ---------------------------------------------------------------------------
// tree_has_vt_bridge: #{pane_current_path} trusting OSC 7 (#615, render path),
// has_vt_bridge_descendant (Ctrl+C #491/#579, mouse transport).
// ---------------------------------------------------------------------------

/// explorer.exe always carries the pid of the long dead userinit as its parent.
/// A pane shell handed that pid would adopt the whole desktop, including a wsl
/// the user has open in some other terminal.
fn explorer_adopted_table() -> Vec<ProcRowT> {
    vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "git.exe"),
        row(3000, P, "explorer.exe"),
        row(3100, 3000, "windowsterminal.exe"),
        row(3200, 3100, "wsl.exe"),
    ]
}

#[test]
fn bridge_a_a_wsl_under_an_adopted_explorer_is_not_in_the_pane() {
    let t = explorer_adopted_table();
    let mut c = clock(&[(P, 1000), (6000, 1100), (3000, 20), (3100, 30), (3200, 40)]);
    assert!(!tree_has_vt_bridge(&t, P, &mut c));
}

#[test]
fn bridge_b_a_genuine_wsl_is_found_and_a_stale_one_is_not() {
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(6000, P, "bash.exe"),
        row(6100, 6000, "ssh.exe"),
    ];
    let mut genuine = clock(&[(P, 1000), (6000, 1100), (6100, 1200)]);
    assert!(tree_has_vt_bridge(&t, P, &mut genuine));
    let mut stale = clock(&[(P, 1000), (6000, 1100), (6100, 1050)]);
    assert!(!tree_has_vt_bridge(&t, P, &mut stale), "ssh older than its claimed parent bash");
}

#[test]
fn bridge_c_equal_stamps_are_followed() {
    let t = vec![row(P, 1, "cmd.exe"), row(6000, P, "wsl.exe"), row(9000, P, "x.exe"), row(9100, 9000, "wsl.exe")];
    let mut c = clock(&[(P, 1000), (6000, 1000), (9000, 2), (9100, 3)]);
    assert!(tree_has_vt_bridge(&t, P, &mut c));
    let t2 = vec![row(P, 1, "cmd.exe"), row(9000, P, "x.exe"), row(9100, 9000, "wsl.exe")];
    assert!(!tree_has_vt_bridge(&t2, P, &mut c), "the bridge reachable only through the stale x.exe");
}

#[test]
fn bridge_d_unknown_bridge_is_not_counted() {
    // Per site decision: not counted.  A bridge the pane started runs under the
    // server's token and is always queryable; an unknown one has exited (it can
    // no longer be killed by a broadcast) or is not this pane's.
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "wsl.exe")];
    assert!(!tree_has_vt_bridge(&t, P, &mut clock(&[(P, 1000)])));
}

#[test]
fn bridge_f_a_cycle_ends_and_a_stale_bridge_in_it_is_not_reached() {
    let t = vec![
        row(P, 1, "pwsh.exe"),
        row(10, P, "a.exe"),
        row(11, 10, "b.exe"),
        row(10, 11, "a.exe"), // the same pid listed again under a cycle
        row(12, 11, "wsl.exe"),
    ];
    let mut c = clock(&[(P, 1000), (10, 1100), (11, 1200), (12, 900)]);
    assert!(!tree_has_vt_bridge(&t, P, &mut c), "wsl (t=900) is older than b.exe (t=1200)");
    let mut flat = clock(&[(P, 1000), (10, 1000), (11, 1000), (12, 1000)]);
    assert!(tree_has_vt_bridge(&t, P, &mut flat), "terminates, and a genuine bridge is still found");
}

// ---------------------------------------------------------------------------
// pid_in_pane_tree (proc_tree::is_genuine_descendant): the #613 wheel latch
// liveness check.
// ---------------------------------------------------------------------------

#[test]
fn latch_a_an_owner_older_than_the_pane_is_not_in_the_pane() {
    let t = vctip_sibling_table();
    let mut c = clock(&vctip_times());
    assert!(!proc_tree::is_genuine_descendant(&t, P, VCTIP, &mut c));
    assert!(proc_tree::is_genuine_descendant(&t, P, LOG_CHILD, &mut c));
}

#[test]
fn latch_a_a_stale_edge_one_level_up_is_caught_too() {
    // owner 8000 is a genuine child of 7000, but 7000 is a stranger that only
    // claims the pane shell through a recycled pid.
    let t = vec![row(P, 1, "pwsh.exe"), row(7000, P, "x.exe"), row(8000, 7000, "y.exe")];
    let mut c = clock(&[(P, 1000), (7000, 40), (8000, 60)]);
    assert!(!proc_tree::is_genuine_descendant(&t, P, 8000, &mut c));
}

#[test]
fn latch_b_c_genuine_and_equal_ancestry_holds() {
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "node.exe"), row(6100, 6000, "claude.exe"), row(9000, P, "vctip.exe")];
    let mut c = clock(&[(P, 1000), (6000, 1000), (6100, 1300), (9000, 2)]);
    assert!(proc_tree::is_genuine_descendant(&t, P, 6100, &mut c));
    assert!(!proc_tree::is_genuine_descendant(&t, P, 9000, &mut c));
}

#[test]
fn latch_d_unknown_owner_is_not_in_the_pane() {
    // Per site decision: not in the tree.  The owner having exited is exactly
    // when the latch must expire.
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "node.exe")];
    assert!(!proc_tree::is_genuine_descendant(&t, P, 6000, &mut clock(&[(P, 1000)])));
}

#[test]
fn latch_f_a_cycle_ends() {
    // 20 -> 21 -> 20 never reaches the root: MAX_CHAIN must end it even with
    // equal stamps, and a stale edge must end it straight away.
    let t = vec![row(20, 21, "a.exe"), row(21, 20, "b.exe"), row(30, P, "c.exe"), row(P, 1, "pwsh.exe")];
    let mut flat = clock(&[(20, 5), (21, 5), (30, 5), (P, 1000)]);
    assert!(!proc_tree::is_genuine_descendant(&t, P, 20, &mut flat));
    assert!(!proc_tree::is_genuine_descendant(&t, P, 30, &mut flat), "30 (t=5) is older than the pane");
}

// ---------------------------------------------------------------------------
// fell_back_to_root_in: the #579 boot window guard's precondition.
// ---------------------------------------------------------------------------

#[test]
fn fellback_a_a_shell_whose_only_child_is_a_stranger_is_childless() {
    let t = vec![row(P, 1, "pwsh.exe"), row(VCTIP, P, "vctip.exe")];
    assert!(fell_back_to_root_in(&t, P, &mut clock(&vctip_times())));
}

#[test]
fn fellback_b_c_genuine_or_equal_child_is_a_child() {
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "ping.exe"), row(VCTIP, P, "vctip.exe")];
    let mut c = clock(&[(P, 1000), (6000, 1000), (VCTIP, 50)]);
    assert!(!fell_back_to_root_in(&t, P, &mut c));
    let t2 = vec![row(P, 1, "pwsh.exe"), row(VCTIP, P, "vctip.exe")];
    assert!(fell_back_to_root_in(&t2, P, &mut c));
}

#[test]
fn fellback_d_unknown_child_leaves_the_shell_childless() {
    // Per site decision: not a child.  Childless is the state in which the
    // boot window guard runs; an exited child must not switch it off.
    let t = vec![row(P, 1, "pwsh.exe"), row(6000, P, "gone.exe"), row(VCTIP, P, "vctip.exe")];
    assert!(fell_back_to_root_in(&t, P, &mut clock(&[(P, 1000), (VCTIP, 50)])));
}

// ---------------------------------------------------------------------------
// proc_tree::genuine_descendants: the tree kill (collect_descendants*) and
// the bridge walks above share it.  test_bsod_kill_guard pins (a); these pin
// the rest.
// ---------------------------------------------------------------------------

#[test]
fn kill_bfs_c_d_f_equal_unknown_and_cycle() {
    let t: Vec<(u32, u32)> = vec![
        (P, 1),
        (6000, P),   // equal stamp: genuine
        (6001, P),   // unknown: not swept
        (10, 6000),  // cycle 10 <-> 11 under a genuine child
        (11, 10),
        (10, 11),
        (9000, P),   // stranger: older than P
        (9001, 9000),
    ];
    let mut c = clock(&[(P, 1000), (6000, 1000), (10, 1100), (11, 1200), (9000, 4), (9001, 5)]);
    let got = proc_tree::genuine_descendants(&t, P, &mut c, &mut |_| false);
    assert_eq!(got, vec![6000, 10, 11], "equal followed, unknown and stranger not, cycle ends");
}

// ---------------------------------------------------------------------------
// The memo: creation times live and die with one table.
// ---------------------------------------------------------------------------

#[test]
fn snapshot_memoises_creation_times_for_its_own_lifetime_only() {
    let me = std::process::id();
    let snap = ProcSnapshot::from(vec![(me, 0u32, "psmux.exe".to_string())]);
    assert_eq!(snap.memo_len(), 0);
    let first = snap.creation_of(me);
    assert!(first.is_some(), "the test process can read its own creation time");
    assert_eq!(first, crate::platform::process_kill::process_creation_time(me));
    let _ = snap.creation_of(me);
    let _ = snap.creation_of(u32::MAX - 2); // no such pid: memoised as unknown
    assert_eq!(snap.memo_len(), 2, "one entry per pid, repeat lookups are hits");
    let fresh = ProcSnapshot::from(vec![(me, 0u32, "psmux.exe".to_string())]);
    assert_eq!(fresh.memo_len(), 0, "a new table starts with an empty memo");
}

// ---------------------------------------------------------------------------
// Real processes, real creation times, one forged parent link: the vctip shape
// built from live processes.  A long lived "orphan" started BEFORE the pane
// root is re-parented (in a copy of the live table) onto the pane root, which
// is exactly what a recycled pid makes Toolhelp report.
// ---------------------------------------------------------------------------

#[test]
fn live_an_older_process_forged_onto_the_pane_root_is_not_adopted() {
    use std::process::{Command, Stdio};
    use std::time::Duration;
    let spawn = || {
        Command::new("cmd.exe")
            .args(["/c", "ping.exe", "-n", "30", "127.0.0.1"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn cmd")
    };
    let mut orphan = spawn();
    std::thread::sleep(Duration::from_millis(50)); // a different clock tick
    let mut root = spawn();
    let (orphan_pid, root_pid) = (orphan.id(), root.id());

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut rows = Vec::new();
    while std::time::Instant::now() < deadline {
        let t = process_table(std::time::Duration::ZERO).expect("snapshot");
        if t.iter().any(|(_, pp, n)| *pp == root_pid && n.starts_with("ping")) {
            rows = t.to_vec();
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!rows.is_empty(), "the pane root never got its ping child");
    let real_child = rows.iter().find(|(_, pp, n)| *pp == root_pid && n.starts_with("ping")).unwrap().0;
    // The forgery: the orphan "claims" the pane root, with a pid higher than
    // the real child so the highest pid rule alone would choose it.
    for r in rows.iter_mut() {
        if r.0 == orphan_pid {
            r.1 = root_pid;
        }
    }
    let forged_pid = u32::MAX - 7;
    rows.push((forged_pid, root_pid, "vctip.exe".to_string()));
    let snap = ProcSnapshot::from(rows);
    let orphan_created = crate::platform::process_kill::process_creation_time(orphan_pid);
    let root_created = crate::platform::process_kill::process_creation_time(root_pid);
    let mut c = |p: u32| if p == forged_pid { orphan_created } else { snap.creation_of(p) };
    let got = deepest_descendant(&snap, root_pid, &mut c).map(|(p, _)| p);

    let _ = orphan.kill();
    let _ = orphan.wait();
    let _ = root.kill();
    let _ = root.wait();

    assert!(orphan_created < root_created, "the orphan really is the older process");
    assert_eq!(
        got,
        Some(real_child),
        "the live walk adopted a process older than the pane root (orphan {orphan_pid}, \
         forged {forged_pid}); the real child is {real_child}"
    );
}

// ---------------------------------------------------------------------------
// Micro benchmark (ignored by default).  Run with
//   cargo test --release --bin psmux bench_proc_tree_render_walk -- --ignored --nocapture
// ---------------------------------------------------------------------------

/// The walk exactly as master e36bd85 had it, for an apples to apples baseline.
fn master_deepest_descendant(entries: &[ProcRowT], root_pid: u32) -> Option<(u32, String)> {
    let mut cur = root_pid;
    let mut leaf: Option<(u32, String)> = None;
    for _ in 0..64 {
        let next = entries
            .iter()
            .filter(|(pid, ppid, name)| *ppid == cur && *pid != cur && !is_system_exe(name))
            .max_by_key(|(pid, _, _)| *pid);
        match next {
            Some((pid, _, name)) => {
                cur = *pid;
                leaf = Some((*pid, name.clone()));
            }
            None => break,
        }
    }
    leaf
}

fn master_tree_has_vt_bridge(entries: &[ProcRowT], root_pid: u32) -> bool {
    let mut queue: Vec<u32> = vec![root_pid];
    let mut head = 0;
    while head < queue.len() {
        let parent = queue[head];
        head += 1;
        for (pid, ppid, name) in entries.iter() {
            if *ppid == parent && *pid != root_pid && !queue.contains(pid) {
                if is_vt_bridge_exe(name) {
                    return true;
                }
                queue.push(*pid);
            }
        }
    }
    false
}

#[test]
#[ignore]
fn bench_proc_tree_render_walk() {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    const N: u32 = 10_000;

    // A pane like tree: cmd (pane root) -> cmd (wrapper) -> ping.
    let mut root = Command::new("cmd.exe")
        .args(["/c", "cmd.exe", "/c", "ping.exe", "-n", "60", "127.0.0.1"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn");
    let root_pid = root.id();
    let deadline = Instant::now() + Duration::from_secs(10);
    let table = loop {
        let t = process_table(Duration::ZERO).expect("snapshot");
        let depth_ok = master_deepest_descendant(&t, root_pid)
            .is_some_and(|(_, n)| n.starts_with("ping"));
        if depth_ok || Instant::now() > deadline {
            break t;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    eprintln!("table rows: {}", table.len());

    let time = |label: &str, f: &mut dyn FnMut() -> bool| {
        let start = Instant::now();
        let mut hits = 0u32;
        for _ in 0..N {
            if f() {
                hits += 1;
            }
        }
        let el = start.elapsed();
        eprintln!(
            "{label:<44} {N} calls {:>9.3} ms  {:>8.3} us/call  (true {hits})",
            el.as_secs_f64() * 1e3,
            el.as_secs_f64() * 1e6 / N as f64
        );
    };

    time("deepest  master (unguarded)", &mut || {
        master_deepest_descendant(&table, root_pid).is_some()
    });
    time("deepest  guarded, memo warm (render path)", &mut || {
        deepest_descendant(&table, root_pid, &mut |p| table.creation_of(p)).is_some()
    });
    time("deepest  guarded, no memo (OpenProcess per edge)", &mut || {
        deepest_descendant(&table, root_pid, &mut |p| {
            crate::platform::process_kill::process_creation_time(p)
        })
        .is_some()
    });
    time("bridge   master (unguarded)", &mut || master_tree_has_vt_bridge(&table, root_pid));
    time("bridge   guarded, memo warm (render path)", &mut || {
        tree_has_vt_bridge(&table, root_pid, &mut |p| table.creation_of(p))
    });
    // The full #{pane_current_command} resolver already pays one OpenProcess
    // per call for the leaf's real name; this is the number a frame sees.
    time("resolver master walk + get_process_name", &mut || {
        master_deepest_descendant(&table, root_pid)
            .and_then(|(p, _)| get_process_name(p))
            .is_some()
    });
    time("resolver guarded (resolve_deepest_foreground)", &mut || {
        resolve_deepest_foreground(root_pid, std::sync::Arc::clone(&table)).is_some()
    });
    eprintln!("memo entries after the run: {}", table.memo_len());

    let _ = root.kill();
    let _ = root.wait();
}
