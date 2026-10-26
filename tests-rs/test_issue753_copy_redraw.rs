// Issue #753: a copy-mode command that changes only how the mode is drawn did
// not ask for the frame that would show it.
//
// The mark, the selection shape and the search highlights are drawn by the
// CLIENT from what the frame carries (`copy_hl` and the selection fields), and
// none of them touches a pane cell or the layout. `SendKey` and `SendText`,
// which is what a keystroke becomes, are outside `mutates_state`, so nothing
// marks the state dirty and no frame is pushed: the change waits for an
// unrelated one. `copy_needs_redraw` is the flag that exists for this, the
// server loop turns it into one frame, and tmux says the same thing by
// returning `WINDOW_COPY_CMD_REDRAW` from the command.
//
// The `-X` route was never affected, because a command request marks the state
// dirty on its own, so these are only reachable by pressing the key.

use super::*;
use super::test_copy_mode_snapshot::{app_with_pane, feed, view_term};

/// An app in copy mode with some text, the flag already cleared, so a test
/// sees only what the command it calls does.
fn ready() -> AppState {
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "line", 0, 40);
    crate::copy_mode::enter_copy_mode(&mut app);
    app.copy_needs_redraw = false;
    app
}

#[test]
fn set_mark_asks_for_the_frame_that_draws_it() {
    let mut app = ready();
    crate::copy_mode::set_mark(&mut app);
    assert!(app.copy_mark.is_some(), "the mark was recorded");
    assert!(
        app.copy_needs_redraw,
        "X draws the marked line through copy_hl, and nothing else would push a frame"
    );
}

#[test]
fn rectangle_toggle_asks_for_a_frame() {
    let mut app = ready();
    crate::copy_mode::toggle_rectangle(&mut app);
    assert_eq!(app.copy_selection_mode, crate::types::SelectionMode::Rect);
    assert!(app.copy_needs_redraw, "the block shape is the client's to draw");
}

#[test]
fn clear_selection_asks_for_a_frame_to_take_the_colour_off() {
    let mut app = ready();
    crate::copy_mode::search_copy_mode(&mut app, "line", true);
    app.copy_needs_redraw = false;
    crate::copy_mode::clear_selection(&mut app);
    assert!(!app.copy_search_marks, "the highlights are off");
    assert!(
        app.copy_needs_redraw,
        "taking colour off the screen needs a frame as much as putting it on"
    );
}

#[test]
fn select_line_asks_for_a_frame_when_nothing_else_moved() {
    // V right after Space: the cursor and the anchor are already where they
    // will be, so only the selection mode changes.
    let mut app = ready();
    crate::copy_mode::begin_selection(&mut app);
    app.copy_needs_redraw = false;
    crate::copy_mode::select_line(&mut app);
    assert_eq!(app.copy_selection_mode, crate::types::SelectionMode::Line);
    assert!(app.copy_needs_redraw, "only the mode changed, so only this says so");
}

#[test]
fn a_command_that_moves_the_cursor_does_not_need_the_flag() {
    // Not everything gets it. A move changes `copy_pos`, which is mixed into
    // the data version the dump-state path compares, so the frame is rebuilt
    // without being asked. Flagging those too would be harmless but it would
    // blur what the flag means, and the flag is the record of which commands
    // are invisible to everything else.
    let mut app = ready();
    crate::copy_mode::set_mark(&mut app);
    app.copy_needs_redraw = false;
    crate::copy_mode::jump_to_mark(&mut app);
    assert!(
        !app.copy_needs_redraw,
        "jump-to-mark moves the cursor, which the version already notices"
    );
}
