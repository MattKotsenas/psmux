// Issue #537: display-popup cannot attach to another session.
//
// A popup child inherited PSMUX_SESSION, and the nested-session guard refused
// on that alone, so `display-popup -E "psmux attach -t other"` died before it
// rendered anything.
//
// tmux only refuses when $TMUX is set AND the client's tty belongs to one of
// the server's window panes (server_client_check_nested walks all_window_panes).
// A popup pty comes from job_run() and is never a window pane, so upstream lets
// the attach through. Verified live against tmux 3.4: a popup running
// `tmux attach -t popupsess` produced a second client and marked the target
// session (attached), while `tmux attach` from inside a real pane still printed
// "sessions should be nested with care".
//
// These tests pin the psmux equivalent: PSMUX_POPUP=1 means "this pty is not a
// window pane", so inside_psmux_pane() must report false there.

use super::*;

/// Snapshot/restore of every env var the guard reads, so a test cannot leak
/// state into the rest of the suite.
struct GuardEnv {
    saved: Vec<(&'static str, Option<String>)>,
}

impl GuardEnv {
    fn new() -> Self {
        let keys = ["PSMUX_ACTIVE", "PSMUX_SESSION", POPUP_CHILD_ENV];
        let saved = keys
            .iter()
            .map(|k| (*k, std::env::var(k).ok()))
            .collect::<Vec<_>>();
        for (k, _) in &saved {
            std::env::remove_var(k);
        }
        Self { saved }
    }

    fn set(&self, key: &str, value: &str) {
        std::env::set_var(key, value);
    }
}

impl Drop for GuardEnv {
    fn drop(&mut self) {
        for (k, v) in &self.saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
}

#[test]
fn plain_terminal_is_not_inside_a_pane() {
    let _lock = crate::util::lock_test_env();
    let _env = GuardEnv::new();
    assert!(
        !inside_psmux_pane(),
        "a shell with no psmux env vars must never be treated as nested"
    );
}

#[test]
fn pane_child_is_inside_a_pane() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    assert!(
        inside_psmux_pane(),
        "PSMUX_SESSION alone still marks a real pane child as nested (tmux parity: \
         attaching from inside a pane is refused)"
    );
}

#[test]
fn client_process_is_inside_a_pane() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_ACTIVE", "1");
    assert!(
        inside_psmux_pane(),
        "PSMUX_ACTIVE marks the client process itself"
    );
}

#[test]
fn popup_child_is_not_inside_a_pane() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    // Exactly what create_popup_pane() puts on a popup child.
    env.set("PSMUX_SESSION", "work");
    env.set(POPUP_CHILD_ENV, "1");
    assert!(
        !inside_psmux_pane(),
        "BUG #537: a popup child was treated as a nested pane, so `psmux attach` \
         inside display-popup was refused"
    );
}

#[test]
fn popup_child_is_not_inside_a_pane_even_with_active_set() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_ACTIVE", "1");
    env.set("PSMUX_SESSION", "work");
    env.set(POPUP_CHILD_ENV, "1");
    assert!(
        !inside_psmux_pane(),
        "the popup marker must win over BOTH nesting signals"
    );
}

#[test]
fn empty_psmux_session_does_not_count() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "");
    assert!(
        !inside_psmux_pane(),
        "an empty PSMUX_SESSION is the unset case (tmux: `*envent->value == '\\0'`)"
    );
}

#[test]
fn popup_marker_must_be_exactly_one() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    env.set(POPUP_CHILD_ENV, "0");
    assert!(
        inside_psmux_pane(),
        "only PSMUX_POPUP=1 opts out; a stray value must not disable the guard"
    );
}

/// The guard is only useful if a pane spawned by a server that itself lives in
/// a popup clears the marker again, otherwise nesting would be permitted
/// forever down that process tree.
#[test]
fn pane_spawn_clears_the_popup_marker() {
    let mut builder = portable_pty::CommandBuilder::new("pwsh");
    builder.env(POPUP_CHILD_ENV, "1");
    crate::pane::set_tmux_env(&mut builder, 7, Some(1234), None, "work", false, false);

    assert!(
        builder.get_env(POPUP_CHILD_ENV).is_none(),
        "set_tmux_env must strip {} so a real pane child is still guarded",
        POPUP_CHILD_ENV
    );
    assert_eq!(
        builder.get_env("PSMUX_SESSION").and_then(|v| v.to_str()),
        Some("work"),
        "pane child should still be marked with PSMUX_SESSION"
    );
}
