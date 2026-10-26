// kill-server must end the namespace's warm standby too.
//
// `psmux -L ns new-session -d -s x` followed at once by `psmux -L ns
// kill-server` left the `__warm__` standby of that namespace running 10 times
// out of 10 on the unfixed build. The session server spawns its standby a
// moment after it registers, and the standby registers a few hundred
// milliseconds after that; kill-server enumerated the registry in between,
// found only the session server, ended it and returned. Nothing ever ended the
// standby, and one of them later rebuilt its data directory after it had been
// deleted.
//
// The fix: kill-server stamps a per namespace kill marker before and after it
// enumerates, and an unclaimed standby ends itself when a marker covers it.
// These tests pin the marker files and the decision; the end to end proof is
// tests/test_kill_server_reaps_warm.ps1.

use super::*;
use std::fs;
use std::path::PathBuf;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "psmux_killwarm_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn facts() -> WarmStandbyFacts {
    WarmStandbyFacts {
        own_creation: Some(1_000),
        spawner_creation: Some(500),
        spawner_alive: true,
        kill_marker: None,
        data_dir_present: true,
    }
}

#[test]
fn no_marker_keeps_the_standby() {
    assert_eq!(warm_standby_verdict(&facts()), WarmStandbyVerdict::Keep);
    let mut f = facts();
    f.spawner_alive = false; // spawner gone by kill-session: the pool stays
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::Keep);
}

#[test]
fn a_kill_after_the_standby_was_created_ends_it() {
    // The standby existed when the kill began but registered after the
    // enumeration, so the kill never reached it directly.
    let mut f = facts();
    f.kill_marker = Some(1_500);
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::NamespaceKilled);
    // Same tick counts: never let clock granularity save a standby the kill
    // was aimed at.
    f.kill_marker = Some(1_000);
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::NamespaceKilled);
}

#[test]
fn a_standby_spawned_after_the_kill_by_a_server_the_kill_ended_is_ended() {
    // Spawner created at 500, kill stamped at 800, standby created at 1000 by
    // the doomed spawner before it processed the kill.
    let mut f = facts();
    f.kill_marker = Some(800);
    f.spawner_alive = true;
    assert_eq!(
        warm_standby_verdict(&f),
        WarmStandbyVerdict::Keep,
        "while the spawner still runs the standby must wait"
    );
    f.spawner_alive = false;
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::SpawnerKilled);
}

#[test]
fn an_old_kill_does_not_touch_a_later_namespace() {
    // kill-server at 100, then a new session (spawner at 500) and its standby
    // at 1000: neither existed when the kill ran.
    let mut f = facts();
    f.kill_marker = Some(100);
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::Keep);
    // Even once that new spawner is gone (kill-session), the old kill does not
    // cover it.
    f.spawner_alive = false;
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::Keep);
}

#[test]
fn unknown_times_never_end_a_standby() {
    let f = WarmStandbyFacts {
        own_creation: None,
        spawner_creation: None,
        spawner_alive: false,
        kill_marker: Some(u64::MAX),
        data_dir_present: true,
    };
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::Keep);
}

#[test]
fn a_deleted_data_dir_ends_the_standby() {
    let mut f = facts();
    f.data_dir_present = false;
    assert_eq!(warm_standby_verdict(&f), WarmStandbyVerdict::DataDirGone);
}

#[test]
fn marker_files_are_distinct_per_scope() {
    let dir = temp_dir("paths");
    let a = kill_marker_path(&dir, KillScope::Namespace(Some("alpha")));
    let b = kill_marker_path(&dir, KillScope::Namespace(Some("beta")));
    let d = kill_marker_path(&dir, KillScope::Namespace(None));
    let all = kill_marker_path(&dir, KillScope::All);
    let set: std::collections::HashSet<_> = [&a, &b, &d, &all].into_iter().collect();
    assert_eq!(set.len(), 4, "{a:?} {b:?} {d:?} {all:?}");
    for p in [&a, &b, &d, &all] {
        assert_eq!(p.parent().unwrap(), dir.join("killed"));
        // Never a registry extension: nothing that scans `.port`/`.pid` may
        // mistake a marker for a session.
        assert!(p.extension().is_none(), "{p:?}");
    }
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn marker_reads_its_namespace_or_the_all_sweep_whichever_is_newer() {
    let dir = temp_dir("rw");
    assert_eq!(read_kill_marker(&dir, Some("ns")), None);
    write_kill_marker(&dir, KillScope::Namespace(Some("other")), 900);
    assert_eq!(read_kill_marker(&dir, Some("ns")), None, "another namespace's kill is not ours");
    write_kill_marker(&dir, KillScope::Namespace(Some("ns")), 300);
    assert_eq!(read_kill_marker(&dir, Some("ns")), Some(300));
    write_kill_marker(&dir, KillScope::All, 700);
    assert_eq!(read_kill_marker(&dir, Some("ns")), Some(700));
    assert_eq!(read_kill_marker(&dir, None), Some(700), "-a covers the default namespace");
    write_kill_marker(&dir, KillScope::Namespace(Some("ns")), 1_200);
    assert_eq!(read_kill_marker(&dir, Some("ns")), Some(1_200));
    // Rewriting leaves no temporary files behind.
    let leftovers: Vec<_> = fs::read_dir(dir.join("killed"))
        .unwrap()
        .flatten()
        .filter(|e| e.path().extension().is_some())
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn kill_server_stamps_the_marker_even_with_nothing_registered() {
    // The standby may be the only server of the namespace and not registered
    // yet: an empty registry is exactly the case the marker exists for.
    let dir = temp_dir("stamp");
    let before = crate::platform::process_kill::now_process_filetime();
    let n = kill_servers_in_scope(&dir, KillScope::Namespace(Some("wo_stamp")), None);
    assert_eq!(n, 0);
    let m = read_kill_marker(&dir, Some("wo_stamp")).expect("marker written");
    assert!(m >= before, "marker {m} older than the kill ({before})");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn force_killed_sets_are_swept_and_nothing_else() {
    // A pid that cannot be running: its set is the dead standby's.
    let dir = temp_dir("sweep");
    let dead = PidTarget { pid: 0xFFFF_FFF0, creation_time: 42 };
    let write_set = |base: &str, body: &str| {
        for ext in ["port", "key", "sid", "act"] {
            fs::write(dir.join(format!("{base}.{ext}")), "1").unwrap();
        }
        fs::write(dir.join(format!("{base}.pid")), body).unwrap();
    };
    write_set("wo_ns____warm__", "4294967280:42");
    // Same pid, different creation: a set rewritten by somebody else.
    write_set("wo_ns__other", "4294967280:43");
    // Matching identity but another namespace: outside the kill's scope.
    write_set("wo_zz____warm__", "4294967280:42");
    sweep_registry_sets_of(&dir, KillScope::Namespace(Some("wo_ns")), &[dead]);
    for ext in ["port", "key", "sid", "act", "pid"] {
        assert!(!dir.join(format!("wo_ns____warm__.{ext}")).exists(), "{ext} left");
        assert!(dir.join(format!("wo_ns__other.{ext}")).exists(), "{ext} of other removed");
        assert!(dir.join(format!("wo_zz____warm__.{ext}")).exists(), "{ext} out of scope removed");
    }
    let _ = fs::remove_dir_all(&dir);
}
