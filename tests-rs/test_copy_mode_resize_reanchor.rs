// Issue: a pane resize while in copy mode stranded the view at the top.
//
// Live reproduction (phone client, on-screen keyboard toggling the pane
// height): mode=1, scroll=3771 of hist=4359 -> the resize dropped retained
// history to 508 while the offset went to 4390, and the view settled at
// scroll == history_size, i.e. line 1, until the user pressed Esc.
//
// `copy_scroll_offset` counts lines above the live bottom, so a trim of N
// retained lines must shift it down by N to keep showing the same content.


#[test]
fn no_trim_keeps_the_offset() {
    assert_eq!(crate::copy_mode::offset_after_trim(10, 100, 100), 10);
    assert_eq!(crate::copy_mode::offset_after_trim(10, 100, 200), 10);
}

#[test]
fn a_trim_shifts_the_offset_by_the_dropped_lines() {
    // 100 -> 90 retained lines: 10 lines dropped off the old end, so an offset
    // of 30 now sits 20 lines above the bottom and shows the same content.
    assert_eq!(crate::copy_mode::offset_after_trim(30, 100, 90), 20);
}

#[test]
fn a_trim_below_the_offset_clamps_to_the_live_bottom() {
    assert_eq!(crate::copy_mode::offset_after_trim(5, 100, 2), 0);
}

#[test]
fn an_offset_beyond_the_old_history_lands_on_the_oldest_retained_line() {
    // The resize happened while the offset already pointed past the retained
    // history (the live case). tmux's window_copy_resize pre-clamps `oy` to
    // the history size and re-derives it after the reflow, so the view lands
    // on the top of what is retained and copy mode stays up. psmux does the
    // same: the offset clamps to the retained depth, it never leaves copy
    // mode on a resize.
    assert_eq!(crate::copy_mode::offset_after_trim(4390, 4366, 508), 508);
    assert_eq!(crate::copy_mode::offset_after_trim(150, 100, 10), 10);
}

#[test]
fn landing_exactly_on_the_top_of_the_new_history_is_still_valid() {
    assert_eq!(crate::copy_mode::offset_after_trim(100, 100, 40), 40);
}

/// The whole re-anchor, through the real function on a real pane: a resize
/// that trims history past the view must leave the pane IN copy mode, on the
/// oldest retained line, as tmux does. (The pre parity behaviour dropped out
/// of copy mode instead.)
#[test]
fn reanchor_after_resize_never_leaves_copy_mode() {
    let mut app = crate::copy_mode::test_copy_mode_snapshot::app_with_pane();
    let live = crate::copy_mode::test_copy_mode_snapshot::view_term(&app);
    crate::copy_mode::test_copy_mode_snapshot::feed(&live, "line", 0, 300);
    crate::copy_mode::enter_copy_mode(&mut app);
    assert!(matches!(app.mode, crate::types::Mode::CopyMode));
    // Pretend the view sat far beyond what the pane retains after a trim.
    let filled_before = 4366usize;
    app.copy_scroll_offset = 4390;
    crate::copy_mode::reanchor_after_resize(&mut app, 4390, filled_before);
    assert!(
        matches!(app.mode, crate::types::Mode::CopyMode),
        "a resize must never leave copy mode (tmux window_copy_resize)"
    );
    let filled_after = crate::copy_mode::test_copy_mode_snapshot::filled(
        &crate::copy_mode::test_copy_mode_snapshot::view_term(&app),
    );
    assert_eq!(
        app.copy_scroll_offset, filled_after,
        "the view lands on the oldest retained line"
    );
}
