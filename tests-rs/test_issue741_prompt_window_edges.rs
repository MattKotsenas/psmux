//! #741 follow up: edge cases of `util::prompt_window` beyond the ones PR 743
//! pinned.
//!
//! The invariant every case checks: the cursor column returned is the display
//! width of the SHOWN text that lies before the cursor. The draw renders
//! `shown` from column 0 of the prompt and puts the cursor at that column, so
//! if the two disagree the cursor is drawn away from the text it belongs to.
//!
//! The one place they used to disagree: when the window scrolls and a wide
//! character straddles its left edge, that character is dropped whole, so the
//! shown text starts one column later than `offset`. Returning
//! `pcursor - offset` then put the cursor one column right of where the text
//! ends (a blank cell between the last character and the cursor). tmux's
//! status.c:947 has the same arithmetic, but tmux also skips the straddling
//! character in status_prompt_redraw_character and draws the rest from the
//! window's first column, so its cursor is one column off its own text in the
//! same case; psmux measures the cursor from where the shown text really
//! starts instead.
//!
//! Registered from src/util.rs.

use super::prompt_window;
use unicode_width::UnicodeWidthChar;

fn width(s: &str) -> usize {
    s.chars().map(|c| c.width().unwrap_or(0)).sum()
}

/// Checks the invariants for one call and returns (shown, col).
fn check(s: &str, cursor: usize, cols: usize) -> (String, usize) {
    let (shown, col) = prompt_window(s, cursor, cols);
    if cols == 0 {
        assert_eq!((shown, col), ("", 0));
        return (String::new(), 0);
    }
    // `shown` is a slice of the input; where it starts, in bytes.
    let start = shown.as_ptr() as usize - s.as_ptr() as usize;
    assert!(start + shown.len() <= s.len(), "{:?} is not a slice of the input", shown);
    assert!(width(shown) <= cols, "shown {:?} is wider than {} columns", shown, cols);
    assert!(col < cols, "cursor column {} is outside a prompt {} wide", col, cols);
    // The cursor sits right after the shown text that precedes it.
    let cur = super::str_prefix_within(s, cursor).len();
    assert!(start <= cur, "the window starts after the cursor");
    let before_in_shown = &s[start..cur];
    assert_eq!(
        col,
        width(before_in_shown),
        "cursor at column {} but the shown text before it is {:?} ({} columns); cursor {}, cols {}",
        col, before_in_shown, width(before_in_shown), cursor, cols
    );
    (shown.to_string(), col)
}

#[test]
fn cursor_at_zero_never_scrolls() {
    let s = "\u{65e5}\u{672c}\u{8a9e}abcdef";
    let (shown, col) = check(s, 0, 5);
    assert_eq!(col, 0);
    assert!(s.starts_with(&shown));
}

#[test]
fn cursor_at_end_of_a_full_prompt_has_a_cell_to_sit_in() {
    let s = "0123456789";
    let (shown, col) = check(s, s.len(), 10);
    assert_eq!(col, 9);
    assert_eq!(shown, "123456789");
}

#[test]
fn a_wide_character_straddling_the_left_edge_leaves_no_gap_before_the_cursor() {
    // `a` then eight CJK characters: 17 columns, in a prompt 10 wide. The
    // window starts at column 8, inside the fourth CJK character, which is
    // dropped whole, so the shown text is the last four (8 columns).
    let s = "a\u{65e5}\u{672c}\u{8a9e}\u{3067}\u{30b3}\u{30de}\u{30f3}\u{30c9}";
    let (shown, col) = check(s, s.len(), 10);
    assert_eq!(shown, "\u{30b3}\u{30de}\u{30f3}\u{30c9}");
    assert_eq!(col, 8, "right after the 8 columns of shown text, not one cell further");
}

#[test]
fn the_straddle_case_with_the_cursor_mid_text() {
    let s = "a\u{65e5}\u{672c}\u{8a9e}\u{3067}\u{30b3}\u{30de}\u{30f3}\u{30c9}";
    // Every cursor position on a boundary, every narrow prompt width.
    for cols in 1..=20 {
        for (cur, _) in s.char_indices().chain(std::iter::once((s.len(), ' '))) {
            check(s, cur, cols);
        }
    }
}

#[test]
fn a_prompt_one_column_wide() {
    assert_eq!(check("abc", 3, 1), (String::new(), 0));
    // A cursor on `b` shows `b` under it.
    assert_eq!(check("abc", 1, 1), ("b".to_string(), 0));
    // A wide character cannot fit one column: nothing is shown, no panic.
    let (_, col) = check("\u{65e5}\u{672c}", 3, 1);
    assert_eq!(col, 0);
}

#[test]
fn a_cursor_past_the_end_or_inside_a_character_is_floored() {
    let s = "a\u{3042}b";
    check(s, 2, 70);
    check(s, 3, 70);
    let (_, col) = check(s, 999, 70);
    assert_eq!(col, 4, "an offset past the end counts the whole input");
}

#[test]
fn very_long_input_stays_inside_and_ends_at_the_cursor() {
    let mut s = String::new();
    for i in 0..5000 {
        s.push(if i % 3 == 0 { '\u{2500}' } else if i % 3 == 1 { '\u{65e5}' } else { 'x' });
    }
    for cols in [1usize, 2, 3, 10, 68, 500] {
        let (shown, col) = check(&s, s.len(), cols);
        assert!(s.ends_with(&shown));
        assert!(col <= cols - 1);
    }
    // And with the cursor somewhere in the middle.
    let mid = s.char_indices().nth(2500).unwrap().0;
    check(&s, mid, 68);
}

#[test]
fn zero_width_combining_marks_do_not_move_the_cursor() {
    let s = "e\u{301}e\u{301}"; // two e with combining acute
    let (_, col) = check(s, s.len(), 70);
    assert_eq!(col, 2);
}
