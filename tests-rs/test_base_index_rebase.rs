// Task #7 batch A bug 3: `set-option base-index N` after session start had no
// visible effect on #I / find-window for windows that already existed.
//
// Root cause: `window_indices` (the parallel array holding each window's
// tmux-style display index, baked in at window-creation time) was never
// updated when `window_base_index` changed at runtime. `win_display_index`
// and `win_pos` read straight from `window_indices` whenever it is "valid"
// (populated, matching `windows` in length), so the stale baked value kept
// winning over the new base-index -- both `display-message -p "#I"` and
// `find-window` go through `win_display_index`, which is why both symptoms
// (batch A bug 3's two failures) shared one fix.
//
// Fix: `AppState::rebase_window_indices(new_base)` shifts every entry of
// `window_indices` by `new_base - window_base_index`, preserving gaps
// (windows created by `move-window`/kills keep their relative spacing --
// only the numbering origin moves), matching how real tmux does not
// renumber contiguous but does shift the effective origin.

use super::*;

fn make_window(name: &str, id: usize) -> Window {
    Window {
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

fn app_with_windows(indices: &[usize]) -> AppState {
    let mut app = AppState::new("test_session".to_string());
    for (i, name) in ["one", "two", "three"].iter().take(indices.len()).enumerate() {
        app.windows.push(make_window(name, i));
    }
    app.window_indices = indices.to_vec();
    app
}

#[test]
fn rebase_shifts_single_window_index_up() {
    // Reproduces the exact bug-3 CLI repro: one window baked at index 0
    // (base-index 0 at creation time), then `set-option base-index 1`.
    let mut app = app_with_windows(&[0]);
    app.window_base_index = 0;
    app.rebase_window_indices(1);
    assert_eq!(app.window_indices, vec![1], "existing window must move to the new base");
    assert_eq!(app.win_display_index(0), 1);
}

#[test]
fn rebase_shifts_back_down() {
    let mut app = app_with_windows(&[1]);
    app.window_base_index = 1;
    app.rebase_window_indices(0);
    assert_eq!(app.window_indices, vec![0]);
}

#[test]
fn rebase_preserves_gaps_between_windows() {
    // A window was killed leaving a gap (0, 2 survive out of 0,1,2).
    let mut app = app_with_windows(&[0, 2]);
    app.window_base_index = 0;
    app.rebase_window_indices(1);
    // Gap of 2 between the two windows must survive the origin shift.
    assert_eq!(app.window_indices, vec![1, 3]);
}

#[test]
fn rebase_is_noop_when_base_unchanged() {
    let mut app = app_with_windows(&[0, 1]);
    app.window_base_index = 0;
    app.rebase_window_indices(0);
    assert_eq!(app.window_indices, vec![0, 1]);
}

#[test]
fn rebase_is_noop_when_window_indices_not_valid() {
    // No windows at all: window_indices_valid() is false, so a bare
    // AppState (e.g. a config-file base-index line parsed before any window
    // exists) must not panic or fabricate entries.
    let mut app = AppState::new("test_session".to_string());
    app.window_base_index = 0;
    app.rebase_window_indices(1);
    assert!(app.window_indices.is_empty());
}

#[test]
fn rebase_clamps_at_zero_instead_of_underflowing() {
    // Defensive: base-index moving down further than an index would allow
    // must clamp rather than wrap/panic via usize underflow.
    let mut app = app_with_windows(&[0]);
    app.window_base_index = 5;
    app.rebase_window_indices(0);
    assert_eq!(app.window_indices, vec![0]);
}

#[test]
fn find_window_display_uses_rebased_index() {
    // find-window (server/mod.rs CtrlReq::FindWindow) formats with
    // `app.win_display_index(i)` -- same helper display-message's #I uses --
    // so this single check covers both reported symptoms of bug 3.
    let mut app = app_with_windows(&[0]);
    app.window_base_index = 0;
    app.rebase_window_indices(1);
    app.window_base_index = 1;
    let displayed: Vec<usize> = (0..app.windows.len()).map(|i| app.win_display_index(i)).collect();
    assert_eq!(displayed, vec![1]);
}
