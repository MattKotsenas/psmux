// `@kill-descendants` user option: gates the descendant sweep that runs when a
// pane's shell exits on its own (prune_exited, non-remain-on-exit branch).
//
// Default is ON (Windows has no SIGHUP/pty process groups, so un-swept
// descendants and their conhosts leak; see the #445 merge). Setting
// `set -g @kill-descendants off` restores tmux-on-Unix semantics where a
// deliberately backgrounded process outlives its pane's shell.
//
// These tests cover the option parsing half (AppState::kill_descendants_on_exit).
// The behavioural half (a real backgrounded process surviving or dying when the
// pane shell exits) is covered end to end by tests/test_kill_descendants.ps1.

use super::*;

fn app_with_option(val: Option<&str>) -> AppState {
    let mut app = AppState::new("test_session".to_string());
    if let Some(v) = val {
        app.user_options
            .insert("@kill-descendants".to_string(), v.to_string());
    }
    app
}

#[test]
fn default_is_on() {
    // No option set: the sweep must run, preserving the #445 leak fix.
    let app = app_with_option(None);
    assert!(
        app.kill_descendants_on_exit(),
        "default must be on so self-exited panes do not leak descendants"
    );
}

#[test]
fn off_disables_the_sweep() {
    for v in ["off", "0", "false", "no", "OFF", " Off ", "FALSE"] {
        let app = app_with_option(Some(v));
        assert!(
            !app.kill_descendants_on_exit(),
            "@kill-descendants {v:?} must disable the sweep"
        );
    }
}

#[test]
fn on_and_unrecognized_values_keep_the_sweep() {
    // tmux-style boolean options treat anything not recognized as off-ish as on;
    // fail safe toward not leaking.
    for v in ["on", "1", "true", "yes", "banana"] {
        let app = app_with_option(Some(v));
        assert!(
            app.kill_descendants_on_exit(),
            "@kill-descendants {v:?} must keep the sweep enabled"
        );
    }
}

#[test]
fn option_is_settable_via_set_option_command() {
    // The @-prefixed option must round-trip through the generic user-option
    // store used by set-option, since that is how a config file sets it.
    let mut app = AppState::new("test_session".to_string());
    assert!(app.kill_descendants_on_exit(), "sanity: default on");
    app.user_options
        .insert("@kill-descendants".to_string(), "off".to_string());
    assert!(!app.kill_descendants_on_exit());
    app.user_options
        .insert("@kill-descendants".to_string(), "on".to_string());
    assert!(app.kill_descendants_on_exit());
}
