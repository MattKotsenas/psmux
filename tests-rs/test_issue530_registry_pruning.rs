//! Issue #530: `~/.psmux` grows without bound because orphaned registry files
//! are unreachable.
//!
//! Every registry sweep in `session.rs` enumerates `.port` files and deletes
//! the siblings it finds, which makes `.port` the sole entry point to a
//! session's registry set. Teardown paths that removed `.port`/`.key`/`.pid`
//! but not `.sid` therefore stranded one file per session permanently: no code
//! path looks at a `.sid` without first finding its `.port`, so nothing could
//! ever delete it again.
//!
//! Field state that prompted this: 6,570 files in one data dir, of which 6,060
//! were `.sid` orphans and only 17 were live `.port` entries — plus 161
//! `.spawnlock` files, which are only ever removed by a `Drop` that does not
//! run when the holder is killed. The oldest was three weeks old.
//!
//! The cost is not just disk: `resolve_session_by_id` scans every `.sid` in the
//! directory to map `$N` to a session name, so each leaked file is re-read on
//! every lookup.

use super::*;

/// Unique scratch directory per test, so cases can never observe each other.
fn scratch_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "psmux-530-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn write(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, body).expect("write registry file");
    p
}

fn exists(dir: &std::path::Path, name: &str) -> bool {
    dir.join(name).exists()
}

/// Nothing is alive, so every orphan is collectable.
fn all_dead(_pid: u32) -> bool {
    false
}

/// The core defect: a `.sid` whose `.port` is gone is removed.
#[test]
fn a_sid_orphaned_by_teardown_is_pruned() {
    let dir = scratch_dir("sid");
    write(&dir, "ns__work.sid", "3");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);

    assert_eq!(pruned, 1, "the orphaned .sid should have been removed");
    assert!(
        !exists(&dir, "ns__work.sid"),
        "orphaned .sid survived the sweep"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A live session's files must never be touched. This is the property that
/// makes the sweep safe to run on every CLI invocation.
#[test]
fn a_complete_registry_set_with_a_port_is_left_alone() {
    let dir = scratch_dir("live");
    write(&dir, "ns__work.port", "51234");
    write(&dir, "ns__work.key", "deadbeef");
    write(&dir, "ns__work.sid", "3");
    write(&dir, "ns__work.pid", "4242:134301758043996634");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);

    assert_eq!(pruned, 0, "a set with a .port must not be pruned");
    for f in ["ns__work.port", "ns__work.key", "ns__work.sid", "ns__work.pid"] {
        assert!(exists(&dir, f), "{f} was removed but its .port still exists");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A server that is still coming up has written `.sid`/`.key`/`.pid` but not
/// yet its `.port` beacon. The grace period is the only thing standing between
/// the sweep and a healthy startup, so assert it directly.
#[test]
fn a_freshly_written_orphan_is_kept_until_the_grace_period_elapses() {
    let dir = scratch_dir("young");
    write(&dir, "ns__starting.sid", "7");
    write(&dir, "ns__starting.key", "abc123");

    let pruned =
        prune_orphaned_registry_files_in_with(&dir, Duration::from_secs(3600), usize::MAX, all_dead);

    assert_eq!(pruned, 0, "files inside the grace window must be kept");
    assert!(exists(&dir, "ns__starting.sid"));
    assert!(exists(&dir, "ns__starting.key"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A wedged server that never published a port still owns its identity files;
/// deleting them would only make it harder for the #448 reaper to find.
#[test]
fn an_orphan_whose_pid_anchor_is_alive_is_kept() {
    let dir = scratch_dir("alive");
    write(&dir, "ns__wedged.pid", "4242:134301758043996634");
    write(&dir, "ns__wedged.sid", "9");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, |pid| pid == 4242);

    assert_eq!(pruned, 0, "a live PID anchor must protect the whole set");
    assert!(exists(&dir, "ns__wedged.pid"));
    assert!(
        exists(&dir, "ns__wedged.sid"),
        ".sid is anchored by its sibling .pid, not by its own contents"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Same set, dead owner: now the whole thing goes.
#[test]
fn an_orphan_whose_pid_anchor_is_dead_is_pruned() {
    let dir = scratch_dir("dead");
    write(&dir, "ns__gone.pid", "4242:134301758043996634");
    write(&dir, "ns__gone.sid", "9");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);

    assert_eq!(pruned, 2, "both satellites of a dead server should go");
    assert!(!exists(&dir, "ns__gone.pid"));
    assert!(!exists(&dir, "ns__gone.sid"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// `.spawnlock` records its holder's PID in the file body rather than in a
/// sibling, and its `Drop`-based cleanup never runs when the holder is killed.
#[test]
fn a_spawnlock_is_pruned_when_its_holder_is_dead_and_kept_while_alive() {
    let dir = scratch_dir("lock");
    write(&dir, "ns____warm__.spawnlock", "22532");

    let kept = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, |pid| pid == 22532);
    assert_eq!(kept, 0, "a lock held by a live process must be kept");
    assert!(exists(&dir, "ns____warm__.spawnlock"));

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);
    assert_eq!(pruned, 1, "a lock whose holder died must be reclaimed");
    assert!(!exists(&dir, "ns____warm__.spawnlock"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// The sweep must not wander outside the registry: the session-id counter, its
/// lock, and debug logs share the directory and are not `.port` satellites.
#[test]
fn non_registry_files_are_never_touched() {
    let dir = scratch_dir("bystanders");
    write(&dir, "next_session_id", "41");
    write(&dir, "next_session_id.lock", "1234");
    write(&dir, "session.log", "some debug output");
    let _ = std::fs::create_dir_all(dir.join("instances"));
    let _ = std::fs::create_dir_all(dir.join("servers"));

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);

    assert_eq!(pruned, 0, "no bystander file should have been removed");
    assert!(exists(&dir, "next_session_id"));
    assert!(exists(&dir, "next_session_id.lock"));
    assert!(exists(&dir, "session.log"));
    assert!(dir.join("instances").is_dir());
    assert!(dir.join("servers").is_dir());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Reproduces the observed field shape: many dead namespaces leaving only
/// `.sid` behind, alongside one genuinely live session.
#[test]
fn a_backlog_of_dead_namespaces_is_cleared_without_harming_the_live_one() {
    let dir = scratch_dir("backlog");
    for i in 0..50 {
        write(&dir, &format!("jefe-conformance-{i}-0__probe.sid"), "1");
    }
    write(&dir, "live__work.port", "51234");
    write(&dir, "live__work.sid", "2");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);

    assert_eq!(pruned, 50, "every orphaned namespace should be cleared");
    assert!(exists(&dir, "live__work.port"));
    assert!(exists(&dir, "live__work.sid"));
    let remaining = std::fs::read_dir(&dir).unwrap().count();
    assert_eq!(remaining, 2, "only the live session's files should remain");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `remove_session_registry_files` is what teardown paths must use; verify it
/// really takes the whole set, since a partial delete is what created #530.
#[test]
fn removing_a_registry_set_leaves_nothing_behind() {
    let dir = scratch_dir("removeall");
    let port = write(&dir, "ns__work.port", "51234");
    write(&dir, "ns__work.key", "deadbeef");
    write(&dir, "ns__work.sid", "3");
    write(&dir, "ns__work.pid", "4242:134301758043996634");

    remove_session_registry_files(&port);

    let remaining = std::fs::read_dir(&dir).unwrap().count();
    assert_eq!(
        remaining, 0,
        "teardown must not strand a satellite; leftovers are unreachable forever"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// instances/ — the same leak, one directory down.
//
// #509 left namespace identity tokens unpruned on the argument that they are
// bounded by distinct namespace names. Disposable `-L` namespaces make that set
// unbounded, which is what the reporter of #530 came back to correct.
// ---------------------------------------------------------------------------

fn token(dir: &std::path::Path, ns: Option<&str>, body: &str) -> std::path::PathBuf {
    let p = crate::paths::namespace_instance_file(dir, ns);
    std::fs::create_dir_all(p.parent().unwrap()).expect("create instances dir");
    std::fs::write(&p, body).expect("write token");
    p
}

/// A namespace with no `.port` anywhere has no server, so its token goes.
#[test]
fn a_token_for_a_dead_namespace_is_pruned() {
    let dir = scratch_dir("tok-dead");
    let t = token(&dir, Some("throwaway-42"), "a1b2c3d4e5f60718");

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX);

    assert_eq!(pruned, 1, "the dead namespace's token should be removed");
    assert!(!t.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A namespace that still has a live server keeps its identity: re-minting it
/// would look like a server restart to a supervisor watching #{server_instance}.
#[test]
fn a_token_for_a_live_namespace_is_kept() {
    let dir = scratch_dir("tok-live");
    let live = token(&dir, Some("alive"), "1111111111111111");
    let dead = token(&dir, Some("gone"), "2222222222222222");
    write(&dir, "alive__work.port", "51234");

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX);

    assert_eq!(pruned, 1, "only the namespace with no server should be pruned");
    assert!(live.exists(), "a live namespace must keep its token");
    assert!(!dead.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The namespace warm helper is `<ns>____warm__`, so the split that recovers
/// the namespace has to survive a run of underscores on both sides.
#[test]
fn a_namespace_known_only_by_its_warm_helper_is_kept() {
    let dir = scratch_dir("tok-warm");
    let live = token(&dir, Some("ns_a"), "3333333333333333");
    write(&dir, "ns_a____warm__.port", "51235");

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX);

    assert_eq!(pruned, 0);
    assert!(
        live.exists(),
        "a namespace whose only server is its warm helper is still live"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The default namespace cannot be recovered from a bare `<session>` base, so
/// it is kept whenever anything at all is running.
#[test]
fn the_default_token_is_kept_while_any_server_lives() {
    let dir = scratch_dir("tok-default");
    let def = token(&dir, None, "4444444444444444");
    write(&dir, "work.port", "51236");

    assert_eq!(prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX), 0);
    assert!(def.exists());

    // With nothing left running it is collectable like any other: the next
    // server to start re-mints, which is what a genuine restart should look like.
    std::fs::remove_file(dir.join("work.port")).unwrap();
    assert_eq!(prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX), 1);
    assert!(!def.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A token written seconds ago may belong to a namespace still coming up: its
/// server establishes identity before it publishes a `.port`.
#[test]
fn a_freshly_minted_token_is_inside_the_grace_window() {
    let dir = scratch_dir("tok-grace");
    let t = token(&dir, Some("starting"), "5555555555555555");

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::from_secs(3600), usize::MAX);

    assert_eq!(pruned, 0, "a young token must survive the grace window");
    assert!(t.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Disposable namespaces are the reported workload: N throwaway names must
/// collapse to only the ones still running.
#[test]
fn a_backlog_of_disposable_namespace_tokens_collapses_to_the_live_ones() {
    let dir = scratch_dir("tok-backlog");
    for i in 0..200 {
        token(&dir, Some(&format!("jefe-probe-{i}")), "6666666666666666");
    }
    let keep = token(&dir, Some("keeper"), "7777777777777777");
    write(&dir, "keeper__work.port", "51237");

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX);

    assert_eq!(pruned, 200);
    assert!(keep.exists());
    let left = std::fs::read_dir(crate::paths::instance_dir_in(&dir)).unwrap().count();
    assert_eq!(left, 1, "instances/ is bounded by LIVE namespaces, not by names ever used");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The sweep must not wander out of `instances/` into the registry itself.
#[test]
fn the_token_sweep_never_touches_session_files() {
    let dir = scratch_dir("tok-scope");
    write(&dir, "orphan.sid", "9");
    write(&dir, "next_session_id", "12");
    token(&dir, Some("dead"), "8888888888888888");

    prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, usize::MAX);

    assert!(exists(&dir, "orphan.sid"), "satellite sweep owns .sid, not this one");
    assert!(exists(&dir, "next_session_id"), "the id counter is not a registry satellite");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The token sweep is bounded the same way the satellite sweep is, and the two
/// share one budget so a single invocation cannot exceed it across both passes.
#[test]
fn the_token_sweep_respects_its_budget() {
    let dir = scratch_dir("tok-budget");
    for i in 0..40 {
        token(&dir, Some(&format!("dead-{i}")), "9999999999999999");
    }

    let pruned = prune_orphaned_instance_tokens_in_with(&dir, Duration::ZERO, 10);

    assert_eq!(pruned, 10, "the token sweep must stop once its budget is spent");
    let left = std::fs::read_dir(crate::paths::instance_dir_in(&dir)).unwrap().count();
    assert_eq!(left, 30, "the rest drains over the following sweeps");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A sweep must stay cheap. Every psmux invocation runs it, including trivial
/// ones like `psmux -V`, so a large backlog has to drain over several sweeps
/// instead of making one arbitrary command delete thousands of files.
#[test]
fn a_single_sweep_removes_no_more_than_its_budget() {
    let dir = scratch_dir("budget");
    for i in 0..40 {
        write(&dir, &format!("ns{i}__work.sid"), "1");
    }

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, 10, all_dead);

    assert_eq!(pruned, 10, "the sweep must stop once its budget is spent");
    assert_eq!(
        std::fs::read_dir(&dir).unwrap().count(),
        30,
        "the rest of the backlog must survive for the next sweep"
    );

    let mut total = 10;
    for _ in 0..3 {
        total += prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, 10, all_dead);
    }
    assert_eq!(total, 40, "successive sweeps must clear the whole backlog");
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The stamp keeps the directory walk off the hot path: psmux commands are run
/// constantly by scripts, and orphans only appear at session teardown.
#[test]
fn a_sweep_is_rate_limited_by_its_stamp() {
    let dir = scratch_dir("stamp");

    assert!(
        registry_sweep_due(&dir, Duration::from_secs(300)),
        "with no stamp present a sweep is due"
    );
    assert!(
        !registry_sweep_due(&dir, Duration::from_secs(300)),
        "the stamp written by the first call must suppress the next one"
    );
    assert!(
        registry_sweep_due(&dir, Duration::ZERO),
        "once the interval has elapsed a sweep is due again"
    );

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, usize::MAX, all_dead);
    assert_eq!(pruned, 0, "the stamp is not a registry satellite");
    assert!(
        exists(&dir, ".registry_sweep"),
        "the stamp must survive the sweep it schedules"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
