// Issue #266 — show-options -w automatic-rename must reflect per-window state.
//
// Setup: psmux already correctly sets `Window::manual_rename = true` when
// a window is born with `-n NAME` (server/mod.rs:784,807) and the rename
// loop respects that flag (server/mod.rs:1212), so the *user-visible*
// behaviour is fine — explicit names persist.
//
// The bug was reporting-only: `show-options -w -v automatic-rename -t :N`
// always returned the GLOBAL `app.automatic_rename` (`"on"`) instead of
// consulting `app.windows[N].manual_rename` for that window. Scripts that
// branched on the option value were lied to.
//
// Fix lives in `server/options::get_window_option_value_for(app, name,
// target_window)` plus -t plumbing through `CtrlReq::ShowWindowOptionValue`.
// These tests pin the contract at the helper level so any future
// regression flips them red without needing the full TCP harness.

use super::*;
use crate::types::{AppState, Node, LayoutKind};

fn mock_app_with_two_windows() -> AppState {
    let mut app = AppState::new("issue266".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    // Window 0: "explicit_alpha", born with -n (manual_rename = true)
    let mut w0 = make_window("explicit_alpha", 0);
    w0.manual_rename = true;
    app.windows.push(w0);
    // Window 1: "shell", born without -n (manual_rename = false, default)
    app.windows.push(make_window("shell", 1));
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

// ───────────────────────── tests ─────────────────────────

#[test]
fn explicit_n_window_reports_automatic_rename_off() {
    // The exact assertion from tests/test_issue266_explicit_name.ps1:
    //   Window 0 was created with `new-session -d -s X -n explicit_alpha`,
    //   so manual_rename=true; show-options -w -v automatic-rename -t :0
    //   must return "off".
    let app = mock_app_with_two_windows();
    let v = get_window_option_value_for(&app, "automatic-rename", Some(0));
    assert_eq!(
        v, "off",
        "BUG #266: -n window should report automatic-rename=off, got {:?}",
        v
    );
}

#[test]
fn non_explicit_window_reports_global_automatic_rename() {
    // Control case: window without -n keeps the global value.
    // Global default is "on", so window 1 reports "on".
    let app = mock_app_with_two_windows();
    let v = get_window_option_value_for(&app, "automatic-rename", Some(1));
    assert_eq!(
        v, "on",
        "Window without -n should report the global value, got {:?}",
        v
    );
}

#[test]
fn target_none_falls_back_to_active_window() {
    // tmux semantics: -t omitted → active window. Make window 0 active
    // (explicit-named) and verify the helper picks up its override.
    let mut app = mock_app_with_two_windows();
    app.active_idx = 0;
    let v = get_window_option_value_for(&app, "automatic-rename", None);
    assert_eq!(v, "off", "Active window with manual_rename should report off");
}

#[test]
fn target_none_with_active_unnamed_returns_global() {
    let mut app = mock_app_with_two_windows();
    app.active_idx = 1;
    let v = get_window_option_value_for(&app, "automatic-rename", None);
    assert_eq!(v, "on", "Active unnamed window should report global value");
}

#[test]
fn out_of_range_target_falls_back_to_global() {
    // Defensive: a stale or bogus -t :42 must not panic and must not
    // claim "off" — fall back to the global value.
    let app = mock_app_with_two_windows();
    let v = get_window_option_value_for(&app, "automatic-rename", Some(42));
    assert_eq!(v, "on", "Out-of-range window should fall back to global");
}

#[test]
fn non_window_option_returns_empty_via_window_lookup() {
    // Window-scoped lookups for session-only options must return empty
    // (matches tmux behaviour for show-options -w on an option that isn't
    // a window option). This guards against the helper accidentally
    // returning the global value for everything.
    let app = mock_app_with_two_windows();
    let v = get_window_option_value_for(&app, "prefix", Some(0));
    assert_eq!(v, "", "Non-window option must not be returned via -w");
}

#[test]
fn other_window_options_still_return_global_value() {
    // We only added per-window logic for automatic-rename. Other window
    // options (window-status-format etc) don't have per-window storage
    // in psmux today and should keep returning the global value, both
    // for backwards compatibility and to match what users see in
    // existing tests.
    let mut app = mock_app_with_two_windows();
    app.window_status_format = "[#I:#W]".to_string();
    let v = get_window_option_value_for(&app, "window-status-format", Some(0));
    assert_eq!(v, "[#I:#W]", "window-status-format should mirror global");
}

#[test]
fn global_automatic_rename_off_propagates_when_no_window_override() {
    // If the user has already disabled automatic-rename globally and
    // the window doesn't have manual_rename set, "off" still wins.
    // Guards against the helper accidentally returning "on" because it
    // checks manual_rename first.
    let mut app = mock_app_with_two_windows();
    app.automatic_rename = false;
    let v = get_window_option_value_for(&app, "automatic-rename", Some(1));
    assert_eq!(
        v, "off",
        "Global off must propagate when window has no override, got {:?}",
        v
    );
}
