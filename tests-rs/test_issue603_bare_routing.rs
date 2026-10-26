// Issue #603: bare CLI routing ranks by session ACTIVITY, not by whoever wrote
// the `last_session` file last.
//
// tmux picks this session in cmd-find.c `cmd_find_best_session`, whose
// comparator `cmd_find_session_better` is a single `timercmp` on
// `activity_time` for any command that does not pass CMD_FIND_PREFER_UNATTACHED
// (which is every ordinary one). Activity is restamped on client attach and on
// every key a real client sends (server-client.c). psmux answered from a
// data-dir-global `last_session` file instead, written once per attach and
// never refreshed, so a long-detached session outranked the session the user
// was sitting in forever.
//
// These run against a throwaway registry directory: no server, no env mutation
// for the ranking tests, so they stay in-process under `cargo test` and never
// touch the live ~/.psmux.

use super::*;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static TMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A throwaway registry directory holding `<base>.port` (and optionally
/// `<base>.act`) files, removed on drop.
struct TempRegistry {
    dir: PathBuf,
}

impl TempRegistry {
    fn new(tag: &str) -> Self {
        let mut dir = std::env::temp_dir();
        let n = TMP_COUNTER.fetch_add(1, Ordering::SeqCst);
        dir.push(format!("psmux_603_{}_{}_{}", tag, std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp registry dir");
        TempRegistry { dir }
    }

    /// A live session: `<base>.port` holding `port`, as a running server writes.
    fn with_session(&self, base: &str, port: u16) -> &Self {
        std::fs::write(self.dir.join(format!("{}.port", base)), port.to_string())
            .expect("write .port file");
        self
    }

    /// Stamp `base` active at `micros_since_epoch` (what an attach or a
    /// keystroke in an attached client writes).
    fn with_activity(&self, base: &str, micros_since_epoch: u64) -> &Self {
        std::fs::write(
            self.dir.join(format!("{}.act", base)),
            micros_since_epoch.to_string(),
        )
        .expect("write .act file");
        self
    }

    /// The single data-dir-global routing hint an attach leaves behind.
    fn with_last_session(&self, base: &str) -> &Self {
        std::fs::write(self.dir.join("last_session"), base).expect("write last_session");
        self
    }

    fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for TempRegistry {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn now_micros() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

const ONE_SECOND_US: u64 = 1_000_000;

// ── The reported bug ────────────────────────────────────────────────────────

#[test]
fn stale_last_session_loses_to_the_session_with_newer_activity() {
    // The reported state: `dinit-infra` (here `infra`) was attached at some
    // point and is now detached; `neeman` is the session the user is in and
    // has just typed in. `last_session` still names `infra` because nothing
    // ever rewrites it.
    let reg = TempRegistry::new("stale");
    let now = now_micros();
    reg.with_session("infra", 6001)
        .with_session("neeman", 6002)
        .with_activity("infra", now - 600 * ONE_SECOND_US) // attached ten minutes ago
        .with_activity("neeman", now - 2 * ONE_SECOND_US) // typed in two seconds ago
        .with_last_session("infra");
    assert!(reg.path().join("infra.port").exists(), "precondition: infra is live");
    assert!(reg.path().join("neeman.port").exists(), "precondition: neeman is live");
    assert_eq!(
        std::fs::read_to_string(reg.path().join("last_session")).unwrap(),
        "infra",
        "precondition: the stale hint names infra"
    );

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(
        got.as_deref(),
        Some("neeman"),
        "the session with the newest activity must win over the stale last_session hint"
    );

    // The whole routing entry point must agree: no -L, no $TMUX.
    let routed = crate::session::resolve_routing_target(None, None, reg.path());
    assert_eq!(routed.as_deref(), Some("neeman"));
}

#[test]
fn last_session_naming_a_dead_session_never_wins() {
    let reg = TempRegistry::new("dead");
    let now = now_micros();
    reg.with_session("alpha", 6001)
        .with_activity("alpha", now - ONE_SECOND_US)
        .with_last_session("ghost");
    assert!(!reg.path().join("ghost.port").exists(), "precondition: ghost has no server");

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(got.as_deref(), Some("alpha"));
}

#[test]
fn a_lone_session_is_always_the_target() {
    let reg = TempRegistry::new("lone");
    reg.with_session("only", 6001).with_last_session("ghost");
    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(got.as_deref(), Some("only"));
}

// ── tmux parity on the cases measured against tmux 3.4 ──────────────────────

#[test]
fn newest_created_session_wins_when_none_was_ever_attached() {
    // Neither has an `.act` stamp, so both fall back to the `.port` mtime.
    // tmux seeds activity_time from creation_time (session.c `session_create`)
    // and picks the later-created one, which tmux 3.4 confirmed.
    let reg = TempRegistry::new("created");
    reg.with_session("older", 6001);
    // Past the ~15.6ms tick that Windows file mtimes are quantized to.
    std::thread::sleep(Duration::from_millis(150));
    reg.with_session("newer", 6002);

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(got.as_deref(), Some("newer"));
}

#[test]
fn an_explicit_activity_stamp_outranks_a_newer_port_file() {
    // A session created first but attached since must beat one created later
    // and never touched: the stamp, not the file's age, is the rank.
    let reg = TempRegistry::new("stamp");
    reg.with_session("attached_since", 6001);
    std::thread::sleep(Duration::from_millis(150));
    reg.with_session("just_made", 6002);
    // Past the ~15.6ms system clock tick that file mtimes land on, so the stamp
    // is unambiguously later than the port file it has to beat.
    std::thread::sleep(Duration::from_millis(150));
    reg.with_activity("attached_since", now_micros());

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(got.as_deref(), Some("attached_since"));
}

#[test]
fn warm_standby_sessions_are_never_routing_candidates() {
    let reg = TempRegistry::new("warm");
    let now = now_micros();
    reg.with_session("__warm__", 6001)
        .with_session("real", 6002)
        .with_activity("__warm__", now) // newest by far
        .with_activity("real", now - 60 * ONE_SECOND_US);

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(got.as_deref(), Some("real"), "the warm pool is internal, never a target");
}

#[test]
fn ranking_stays_inside_the_l_namespace() {
    // Activity ordering must not let an out-of-namespace session leak in, and
    // a bare command must not adopt a namespaced one.
    let reg = TempRegistry::new("ns");
    let now = now_micros();
    reg.with_session("bare", 6001)
        .with_session("X__one", 7001)
        .with_session("X__two", 7002)
        .with_activity("bare", now) // newest overall
        .with_activity("X__one", now - 90 * ONE_SECOND_US)
        .with_activity("X__two", now - 30 * ONE_SECOND_US);

    let in_ns = crate::session::resolve_last_session_name_ns_in(reg.path(), Some("X"));
    assert_eq!(in_ns.as_deref(), Some("X__two"), "-L X ranks only X__* sessions");

    let bare = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(bare.as_deref(), Some("bare"), "a bare command ignores namespaced sessions");
}

#[test]
fn identical_stamps_fall_back_to_the_last_session_hint() {
    // The upgrade path: a registry written by an older psmux has no `.act`
    // files at all, so nothing distinguishes two candidates. The hint is what
    // it was always for, and it decides only here.
    let reg = TempRegistry::new("tie");
    reg.with_session("aaa", 6001).with_session("zzz", 6002);
    let stamp = now_micros();
    reg.with_activity("aaa", stamp).with_activity("zzz", stamp);
    reg.with_last_session("zzz");

    let got = crate::session::resolve_last_session_name_ns_in(reg.path(), None);
    assert_eq!(
        got.as_deref(),
        Some("zzz"),
        "with equal activity the last_session hint breaks the tie"
    );
}

#[test]
fn a_tmux_env_current_server_still_beats_the_activity_ranking() {
    // Routing from INSIDE a pane must keep naming that pane's own server, no
    // matter which session was most recently active elsewhere. This is the
    // primary route and #603 must not disturb it.
    let reg = TempRegistry::new("tmuxenv");
    let now = now_micros();
    reg.with_session("inside", 6001)
        .with_session("elsewhere", 6002)
        .with_activity("inside", now - 300 * ONE_SECOND_US)
        .with_activity("elsewhere", now); // far more recently active

    let tmux = format!("/tmp/psmux-1/default,{},0", 6001);
    let routed = crate::session::resolve_routing_target(None, Some(&tmux), reg.path());
    assert_eq!(
        routed.as_deref(),
        Some("inside"),
        "$TMUX names the current server and outranks the activity fallback"
    );
}

// ── The writer side ─────────────────────────────────────────────────────────

#[test]
fn touching_activity_writes_a_readable_stamp_and_throttles_repeats() {
    // The `_in` variants take the registry dir explicitly, so this needs no
    // PSMUX_DATA_DIR mutation and therefore no env lock: other tests read the
    // process-wide data root without one.
    let reg = TempRegistry::new("write");
    reg.with_session("typed_in", 6001).with_session("idle", 6002);
    // `idle` is the newer file; only the stamp should change the answer.
    let before = crate::session::resolve_last_session_name_ns_in(reg.path(), None);

    crate::session::touch_session_activity_in(reg.path(), "typed_in");
    let act = reg.path().join("typed_in.act");
    assert!(act.exists(), "an attach must leave a stamp");
    let first = std::fs::read_to_string(&act).unwrap().trim().parse::<u64>().unwrap();
    assert!(first > 0, "the stamp must be epoch micros, got {}", first);

    assert_eq!(
        crate::session::resolve_last_session_name_ns_in(reg.path(), None).as_deref(),
        Some("typed_in"),
        "stamping must actually change routing (was {:?})",
        before
    );

    // The per-keystroke path must not rewrite the file for every key.
    std::thread::sleep(Duration::from_millis(30));
    crate::session::touch_session_activity_throttled_in(reg.path(), "typed_in");
    let second = std::fs::read_to_string(&act).unwrap().trim().parse::<u64>().unwrap();
    assert_eq!(second, first, "a keystroke inside the throttle window must not rewrite the stamp");

    // A warm session is internal and is never stamped.
    crate::session::touch_session_activity_in(reg.path(), "__warm__");
    assert!(
        !reg.path().join("__warm__.act").exists(),
        "the warm pool must never be stamped"
    );
}

// ---------------------------------------------------------------------------
// Registry hygiene for the stamp (surfaced by test_mouse_hover in sweep
// 2026-08-27_15-06-34: `<ns>__hover_test.act` survived `-L <ns> kill-server`).
// ---------------------------------------------------------------------------

#[test]
fn a_reaped_registry_entry_takes_its_activity_stamp_with_it() {
    let reg = TempRegistry::new("reap_act");
    reg.with_session("gone", 40001).with_activity("gone", now_micros());
    assert!(reg.dir.join("gone.act").exists(), "precondition: stamp written");

    crate::session::remove_session_registry_files(&reg.dir.join("gone.port"));
    assert!(!reg.dir.join("gone.port").exists(), ".port reaped");
    assert!(
        !reg.dir.join("gone.act").exists(),
        "the .act stamp must be reaped with the .port, or a dead session keeps ranking"
    );

    // The teardown helper every kill path calls drops it too.
    reg.with_session("killed", 40002).with_activity("killed", now_micros());
    crate::session::remove_session_activity_file_in(&reg.dir, "killed");
    assert!(!reg.dir.join("killed.act").exists(), "teardown removes the stamp");
}

#[test]
fn a_rename_carries_the_activity_stamp_to_the_new_name() {
    let reg = TempRegistry::new("rename_act");
    let stamp = now_micros();
    reg.with_session("before", 40003).with_activity("before", stamp);

    crate::session::carry_session_activity_file_in(&reg.dir, "before", "after");
    assert!(!reg.dir.join("before.act").exists(), "old name's stamp is gone");
    let carried = std::fs::read_to_string(reg.dir.join("after.act")).expect("stamp moved to the new name");
    assert_eq!(carried.trim(), stamp.to_string(), "the value is carried, not re-minted");

    // A session that was never stamped has nothing to carry, and must not
    // manufacture a stamp for the new name.
    crate::session::carry_session_activity_file_in(&reg.dir, "never", "renamed");
    assert!(!reg.dir.join("renamed.act").exists(), "no stamp is invented on rename");
}
