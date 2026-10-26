// Regression guard: exiting copy mode must clear the PANE-LOCAL copy state.
//
// `exit_copy_mode` has cleared `pane.copy_state` since 48b83a5 ("so re-entering
// this pane won't restore a stale copy mode"). Two days later 4964aaf added the
// `send-keys -X cancel` arm in the server, which hand-rolled the exit sequence
// from before that fix and therefore left `copy_state` behind. Three sibling
// arms (`copy-selection-and-cancel`, `copy-pipe-and-cancel`, `copy-end-of-line`)
// were written the same way.
//
// The leftover is not inert: `switch_with_copy_save` restores any pane whose
// `copy_state.is_some()`, so the next focus change silently re-entered copy
// mode. An attached client sends `select-pane` before every mouse click, so in
// practice a single click after an external `send-keys -X cancel` put the pane
// back into copy mode.
//
// These tests pin the invariant at the level that matters: after any exit,
// a focus change must NOT resurrect copy mode.

use super::*;

fn app_with_pane() -> AppState {
    let mut app = AppState::new("copycancel".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app.last_window_area = ratatui::layout::Rect { x: 0, y: 0, width: 80, height: 24 };
    app
}

/// Put the active pane into copy mode with a live selection, exactly as a
/// keyboard entry followed by a drag would.
fn enter_with_selection(app: &mut AppState) {
    crate::copy_mode::enter_copy_mode(app);
    app.copy_anchor = Some((3, 4));
    app.copy_pos = Some((5, 9));
    crate::copy_mode::save_copy_state_to_pane(app);
    assert!(pane_copy_state_present(app), "fixture must leave copy_state set");
}

fn pane_copy_state_present(app: &AppState) -> bool {
    let win = &app.windows[app.active_idx];
    crate::tree::active_pane(&win.root, &win.active_path)
        .map(|p| p.copy_state.is_some())
        .unwrap_or(false)
}

fn in_copy_mode(app: &AppState) -> bool {
    matches!(app.mode, Mode::CopyMode | Mode::CopySearch { .. })
}

#[test]
fn exit_copy_mode_clears_the_pane_local_state() {
    let mut app = app_with_pane();
    if app.windows.is_empty() { return; }
    enter_with_selection(&mut app);

    crate::copy_mode::exit_copy_mode(&mut app);

    assert!(!in_copy_mode(&app), "exit must leave copy mode");
    assert!(
        !pane_copy_state_present(&app),
        "exit must clear pane.copy_state, or a later focus change restores it"
    );
}

#[test]
fn focus_change_after_exit_does_not_resurrect_copy_mode() {
    let mut app = app_with_pane();
    if app.windows.is_empty() { return; }
    enter_with_selection(&mut app);
    crate::copy_mode::exit_copy_mode(&mut app);

    // `select-pane` (sent by the client before EVERY mouse click) runs the
    // focus save/restore. With a stale copy_state this flipped the pane back
    // into copy mode; with the state cleared it must stay out.
    crate::copy_mode::switch_with_copy_save(&mut app, |_app| {});

    assert!(
        !in_copy_mode(&app),
        "BUG: a focus change after exiting copy mode re-entered it from stale pane state"
    );
}

#[test]
fn a_pane_that_really_is_in_copy_mode_still_restores() {
    // The guard above must not break the feature copy_state exists for:
    // switching away from a pane in copy mode and back must restore it.
    let mut app = app_with_pane();
    if app.windows.is_empty() { return; }
    enter_with_selection(&mut app);

    // Simulate focusing away and back without exiting copy mode.
    app.mode = Mode::Passthrough;
    crate::copy_mode::switch_with_copy_save(&mut app, |_app| {});

    assert!(
        in_copy_mode(&app),
        "a pane with genuine saved copy state must still restore on focus"
    );
}
