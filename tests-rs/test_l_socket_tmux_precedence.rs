// -L / $TMUX socket-selection precedence (tmux parity).
//
// The rule and its tmux rationale live on `session::resolve_routing_target`.
// These pin the observable invariant — an out-of-namespace `$TMUX` never wins
// under `-L X`, and `-L X` with nothing to resolve targets `X__default`, never
// the un-namespaced `default` — against a throwaway registry directory: no
// server, no env mutation, so they run in-process under `cargo test` and never
// touch the live ~/.psmux.

use super::*;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static TMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A throwaway registry directory holding `<base>.port` files, removed on drop.
struct TempRegistry {
    dir: PathBuf,
}

impl TempRegistry {
    fn new() -> Self {
        let mut dir = std::env::temp_dir();
        let n = TMP_COUNTER.fetch_add(1, Ordering::SeqCst);
        dir.push(format!("psmux_lprec_{}_{}", std::process::id(), n));
        std::fs::create_dir_all(&dir).expect("create temp registry dir");
        TempRegistry { dir }
    }

    /// Write `<base>.port` containing `port` (as a live session would).
    fn with_session(&self, base: &str, port: u16) -> &Self {
        std::fs::write(self.dir.join(format!("{}.port", base)), port.to_string())
            .expect("write .port file");
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

/// A `$TMUX` value whose control `<port>` is `port`. Mirrors set_tmux_env's
/// `<socketpath>,<port>,<idx>` — only the middle field drives resolution.
fn tmux_for(port: u16) -> String {
    format!("/tmp/psmux-1/default,{},0", port)
}

// ── Scenario A: `-L X` must take precedence over `$TMUX` when nested elsewhere ──

#[test]
fn dash_l_overrides_tmux_when_nested_outside_namespace() {
    // The current server is `main` (port 6001); an isolated `X__work` session
    // (port 7001) also exists.
    let reg = TempRegistry::new();
    reg.with_session("main", 6001).with_session("X__work", 7001);
    // Precondition: prove the setup so a drift can't make this pass vacuously.
    assert!(reg.path().join("main.port").exists(), "precondition: main.port present");
    assert!(reg.path().join("X__work.port").exists(), "precondition: X__work.port present");

    // Attached inside `main` (its port is in $TMUX), running `psmux -L X <cmd>`.
    // tmux parity: `-L X` overrides `$TMUX`, so the command targets the X
    // namespace (X__work), NOT the current `main` server.
    let tmux = tmux_for(6001);
    let got = resolve_routing_target(Some("X"), Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("X__work"),
        "`-L X` from inside `main` must route to the X namespace, not the current server"
    );
}

// ── Scenario B: `-L X` with no in-namespace session must not leak to `default` ──

#[test]
fn dash_l_with_no_session_targets_namespaced_default_not_real_default() {
    // A real `default` server (5000) and the current `main` (6001) exist, but
    // NO session in the X namespace.
    let reg = TempRegistry::new();
    reg.with_session("default", 5000).with_session("main", 6001);
    assert!(
        !reg.path().join("X__default.port").exists(),
        "precondition: no X-namespace session exists"
    );

    // Nested inside `main`, `-L X` must resolve within X. With nothing to
    // resolve it targets the namespaced `X__default` (which does not exist ->
    // "no server running on X__default"), never the real `default` server.
    let tmux = tmux_for(6001);
    let got = resolve_routing_target(Some("X"), Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("X__default"),
        "`-L X` with no session must target the namespaced default, never `default` or the current `main`"
    );
}

#[test]
fn dash_l_with_no_session_and_no_tmux_targets_namespaced_default() {
    // Clean shell (no $TMUX), a real `default` server exists, no X session.
    let reg = TempRegistry::new();
    reg.with_session("default", 5000);
    assert!(
        !reg.path().join("X__default.port").exists(),
        "precondition: no X-namespace session exists"
    );

    let got = resolve_routing_target(Some("X"), None, reg.path());
    assert_eq!(
        got.as_deref(),
        Some("X__default"),
        "clean-shell `-L X` with no X session must target X__default, not `default`"
    );
}

// ── No-regression guards ──────────────────────────────────────────────────

#[test]
fn dash_l_adopts_current_session_when_nested_inside_same_namespace() {
    // Attached inside `X__work` (7001); another X session `X__other` (7002) is
    // newer. The command must act on the CURRENT session (X__work), so the fix
    // must not naively ignore $TMUX whenever `-L` is present.
    let reg = TempRegistry::new();
    reg.with_session("X__work", 7001).with_session("X__other", 7002);
    let tmux = tmux_for(7001);
    let got = resolve_routing_target(Some("X"), Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("X__work"),
        "`-L X` nested inside an X session must act on that current session"
    );
}

#[test]
fn no_dash_l_adopts_current_server_from_tmux() {
    // With no `-L`, `$TMUX` selects the current server (tmux: `$TMUX` socket wins).
    let reg = TempRegistry::new();
    reg.with_session("main", 6001);
    let tmux = tmux_for(6001);
    let got = resolve_routing_target(None, Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("main"),
        "with no `-L`, `$TMUX` selects the current server"
    );
}

#[test]
fn issue485_tmux_beats_a_newer_last_created_session() {
    // Issue #485: two real sessions, `repro` (6001) attached in this pane and a
    // NEWER `repro_other` (6002) created afterwards. `$TMUX` names `repro`, so a
    // no-`-t` query (display-message -p '#S') must resolve to `repro`, NOT the
    // most-recently-created `repro_other`. This is the resolve-layer invariant
    // that main() must honor by always consulting $TMUX when no explicit `-t
    // session` is given (a stale PSMUX_TARGET_SESSION must never short-circuit it).
    let reg = TempRegistry::new();
    reg.with_session("repro", 6001).with_session("repro_other", 6002);
    let tmux = tmux_for(6001);
    let got = resolve_routing_target(None, Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("repro"),
        "$TMUX must select the current session, never the newer last-created one"
    );
}

#[test]
fn warm_session_is_never_adopted_from_tmux() {
    // $TMUX points at the internal warm (standby) server; a real `main` exists.
    let reg = TempRegistry::new();
    reg.with_session("__warm__", 9001).with_session("main", 6001);
    assert!(is_warm_session("__warm__"), "precondition: __warm__ is a warm base");

    let tmux = tmux_for(9001);
    let got = resolve_routing_target(None, Some(&tmux), reg.path());
    assert_eq!(
        got.as_deref(),
        Some("main"),
        "a warm server must never be adopted; fall through to the real session"
    );
}
