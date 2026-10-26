//! Issue #625: the choose-tree list model must follow tmux's mode-tree rules.
//!
//! `prefix+w` runs `choose-tree -Zw`, which is `WINDOW_TREE_WINDOW`, so in
//! `window_tree_build_window` (window-tree.c) every window row is built with
//! `expanded = 0` while `window_tree_build_session` leaves the session rows
//! expanded. `mode_tree_build_lines` (mode-tree.c) then emits a line per item
//! and only recurses into the children of an expanded one, stamping
//! `'0' + mti->line` on the first ten VISIBLE lines and `M-a`..`M-z` on lines
//! 10..35. `mode_tree_key` looks a pressed key up in that list, sets
//! `mtd->current` and rewrites the key to `'\r'`, so a bare digit jumps and
//! activates in one keystroke.
//!
//! Before the fix psmux listed every pane from the start and treated digits as
//! a multi digit accumulator applied on Enter with a 1-based index, so the
//! digit a user needed depended on the pane counts of the earlier windows and
//! `0` was outside the accepted range.

use super::*;
use std::collections::HashSet;

/// The reporter's tree: one session, four windows (base-index 1), and window 2
/// holding three panes.
fn reporter_tree() -> Vec<RowKind> {
    vec![
        RowKind::Session, // i625
        RowKind::Window,  // 1
        RowKind::Pane,
        RowKind::Window, // 2
        RowKind::Pane,
        RowKind::Pane,
        RowKind::Pane,
        RowKind::Window, // 3
        RowKind::Pane,
        RowKind::Window, // 4
        RowKind::Pane,
    ]
}

#[test]
fn row_kind_reads_the_psmux_tuple() {
    assert_eq!(row_kind(true, usize::MAX), RowKind::Session);
    assert_eq!(row_kind(true, 7), RowKind::Window);
    assert_eq!(row_kind(false, 7), RowKind::Pane);
}

#[test]
fn depth_matches_the_mode_tree_recursion_levels() {
    assert_eq!(depth(RowKind::Session), 0);
    assert_eq!(depth(RowKind::Window), 1);
    assert_eq!(depth(RowKind::Pane), 2);
}

#[test]
fn windows_start_collapsed_and_sessions_do_not() {
    let kinds = reporter_tree();
    let collapsed = default_collapsed(&kinds);
    // Every window row, and only the window rows.
    assert_eq!(collapsed, HashSet::from([1, 3, 7, 9]));
    assert!(!collapsed.contains(&0), "the session row must stay expanded");
}

#[test]
fn the_default_view_is_the_session_and_its_windows() {
    let kinds = reporter_tree();
    let collapsed = default_collapsed(&kinds);
    // Five visible lines, not the eleven the flat listing showed.
    assert_eq!(visible_lines(&kinds, &collapsed), vec![0, 1, 3, 7, 9]);
}

#[test]
fn a_three_pane_window_does_not_shift_the_later_windows() {
    let kinds = reporter_tree();
    let collapsed = default_collapsed(&kinds);
    let lines = visible_lines(&kinds, &collapsed);
    // Line 1 is window 1, line 2 is window 2, line 3 is window 3, line 4 is
    // window 4: with base-index 1 the jump digit IS the window number, however
    // many panes any window holds. The old flat list put window 3 on row 8.
    assert_eq!(lines[1], 1, "line 1 is the window 1 row");
    assert_eq!(lines[2], 3, "line 2 is the window 2 row");
    assert_eq!(lines[3], 7, "line 3 is the window 3 row");
    assert_eq!(lines[4], 9, "line 4 is the window 4 row");
}

#[test]
fn expanding_a_window_reveals_only_its_own_panes() {
    let kinds = reporter_tree();
    let mut collapsed = default_collapsed(&kinds);
    collapsed.remove(&3); // expand window 2
    assert_eq!(
        visible_lines(&kinds, &collapsed),
        vec![0, 1, 3, 4, 5, 6, 7, 9]
    );
}

#[test]
fn collapsing_the_session_hides_every_window_and_pane() {
    let kinds = reporter_tree();
    let mut collapsed = default_collapsed(&kinds);
    collapsed.insert(0);
    assert_eq!(visible_lines(&kinds, &collapsed), vec![0]);
}

#[test]
fn an_expanded_session_over_expanded_windows_is_the_whole_tree() {
    let kinds = reporter_tree();
    let collapsed = HashSet::new();
    assert_eq!(
        visible_lines(&kinds, &collapsed),
        (0..kinds.len()).collect::<Vec<_>>()
    );
}

#[test]
fn line_keys_follow_mode_tree_build_lines() {
    // } else if (mti->line < 10)  mti->key = '0' + mti->line;
    assert_eq!(line_key(0), LineKey::Digit('0'));
    assert_eq!(line_key(9), LineKey::Digit('9'));
    // else if (mti->line < 36)  mti->key = KEYC_META|('a' + mti->line - 10);
    assert_eq!(line_key(10), LineKey::Meta('a'));
    assert_eq!(line_key(35), LineKey::Meta('z'));
    // else  mti->key = KEYC_NONE;
    assert_eq!(line_key(36), LineKey::None);
    assert_eq!(line_key(1000), LineKey::None);
}

#[test]
fn line_key_labels_read_like_key_string_lookup_key() {
    assert_eq!(line_key_label(0), "0");
    assert_eq!(line_key_label(4), "4");
    assert_eq!(line_key_label(10), "M-a");
    assert_eq!(line_key_label(35), "M-z");
    assert_eq!(line_key_label(36), "");
}

#[test]
fn a_digit_is_a_zero_based_visible_line_not_a_one_based_row() {
    // The bug the reporter hit: psmux read "1" as row one, which was the
    // session header, and rejected "0" outright.
    assert_eq!(digit_line('0'), Some(0));
    assert_eq!(digit_line('1'), Some(1));
    assert_eq!(digit_line('9'), Some(9));
    assert_eq!(digit_line('a'), None);
    assert_eq!(digit_line(' '), None);
}

#[test]
fn zero_selects_the_session_row_of_the_default_view() {
    let kinds = reporter_tree();
    let collapsed = default_collapsed(&kinds);
    let lines = visible_lines(&kinds, &collapsed);
    let line = digit_line('0').expect("0 is a jump key");
    assert!(line < lines.len(), "0 must address a real line, not nothing");
    assert_eq!(kinds[lines[line]], RowKind::Session);
}

#[test]
fn meta_letters_address_lines_ten_and_up() {
    assert_eq!(meta_line('a'), Some(10));
    assert_eq!(meta_line('z'), Some(35));
    assert_eq!(meta_line('A'), Some(10));
    assert_eq!(meta_line('1'), None);
}

#[test]
fn parent_of_walks_one_level_up() {
    let kinds = reporter_tree();
    assert_eq!(parent_of(&kinds, 0), None, "a session has no parent");
    assert_eq!(parent_of(&kinds, 1), Some(0));
    assert_eq!(parent_of(&kinds, 6), Some(3), "the third pane of window 2");
    assert_eq!(parent_of(&kinds, 9), Some(0));
}

#[test]
fn has_children_marks_only_expandable_rows() {
    let kinds = reporter_tree();
    assert!(has_children(&kinds, 0), "the session holds windows");
    assert!(has_children(&kinds, 3), "window 2 holds panes");
    assert!(!has_children(&kinds, 4), "a pane is a leaf");
    assert!(!has_children(&kinds, 10), "the last row is a leaf");
}

#[test]
fn a_session_only_listing_is_flat() {
    assert!(is_flat(&[RowKind::Session, RowKind::Session]));
    assert!(!is_flat(&reporter_tree()));
}

#[test]
fn right_expands_a_collapsed_window_then_just_moves_down() {
    let kinds = reporter_tree();
    let mut collapsed = default_collapsed(&kinds);
    // if (line->flat || current->expanded) mode_tree_down(...)
    // else if (!line->flat) current->expanded = 1;
    assert_eq!(expand_action(&kinds, &collapsed, 3), ExpandAction::Expand(3));
    collapsed.remove(&3);
    assert_eq!(expand_action(&kinds, &collapsed, 3), ExpandAction::MoveDown);
    // A leaf never expands.
    assert_eq!(expand_action(&kinds, &collapsed, 4), ExpandAction::MoveDown);
}

#[test]
fn left_collapses_the_current_row_then_climbs_to_the_parent() {
    let kinds = reporter_tree();
    let mut collapsed = default_collapsed(&kinds);
    collapsed.remove(&3); // window 2 expanded
    // Expanded row: collapse it in place.
    assert_eq!(
        collapse_action(&kinds, &collapsed, 3),
        CollapseAction::Collapse(3)
    );
    collapsed.insert(3);
    // Already collapsed: climb to the session and collapse that.
    assert_eq!(
        collapse_action(&kinds, &collapsed, 3),
        CollapseAction::Collapse(0)
    );
    // An expanded session collapses in place: mode_tree_key only climbs when
    // `line->flat || !current->expanded`.
    assert_eq!(
        collapse_action(&kinds, &collapsed, 0),
        CollapseAction::Collapse(0)
    );
    // Once the session is collapsed there is no parent to climb to, so tmux
    // falls back to `mode_tree_up`.
    collapsed.insert(0);
    assert_eq!(collapse_action(&kinds, &collapsed, 0), CollapseAction::MoveUp);
}

#[test]
fn left_on_a_pane_climbs_to_its_window() {
    let kinds = reporter_tree();
    let mut collapsed = default_collapsed(&kinds);
    collapsed.remove(&3);
    assert_eq!(
        collapse_action(&kinds, &collapsed, 5),
        CollapseAction::Collapse(3)
    );
}

#[test]
fn several_sessions_keep_their_windows_and_hide_their_panes() {
    let kinds = vec![
        RowKind::Session,
        RowKind::Window,
        RowKind::Pane,
        RowKind::Pane,
        RowKind::Session,
        RowKind::Window,
        RowKind::Window,
    ];
    let collapsed = default_collapsed(&kinds);
    assert_eq!(visible_lines(&kinds, &collapsed), vec![0, 1, 4, 5, 6]);
    // Second session header is line 2, so M- keys are never needed here and
    // the digits stay in step with what the user sees.
    assert_eq!(line_key_label(2), "2");
}

#[test]
fn an_empty_tree_has_no_lines_and_no_keys_resolve() {
    let kinds: Vec<RowKind> = Vec::new();
    let collapsed = default_collapsed(&kinds);
    assert!(visible_lines(&kinds, &collapsed).is_empty());
    assert!(parent_of(&kinds, 0).is_none());
    assert!(!has_children(&kinds, 0));
}
