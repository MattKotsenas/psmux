//! #741: the `command-prompt` cursor was placed with a byte offset used as a
//! column count, so it drifted right of the text on any non ASCII input.
//!
//! `command_cursor` counts bytes, on purpose, because the editing keys insert
//! and remove whole characters by `len_utf8` (#345). The draw then did
//! `inner.x + 2 + command_cursor as u16`, which is the same number only in
//! ASCII: eight box drawing characters are 24 bytes over 8 columns, and the
//! cursor was drawn 16 columns past the text.
//!
//! `util::prompt_window` is the seam. It answers both halves of what the draw
//! needs: the text a prompt that wide can show, and the column the cursor
//! falls in, following tmux (`status.c:932` and `:937` to `:944`, tag 3.7c).
//!
//! Registered from src/util.rs.

use super::prompt_window;

/// Eight U+2500 box drawing horizontals: 24 bytes, 8 columns. The input that
/// took the -CC relay down in #712, met here because someone searched for a
/// TUI's border.
const BOX8: &str = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}";
/// Three CJK characters: 9 bytes, 6 columns.
const CJK3: &str = "\u{65e5}\u{672c}\u{8a9e}";

#[test]
fn ascii_column_equals_byte_offset() {
    // The case that always worked, pinned so the fix does not move it.
    let (shown, col) = prompt_window("ls -la", 6, 70);
    assert_eq!(shown, "ls -la");
    assert_eq!(col, 6);
}

#[test]
fn box_drawing_cursor_sits_on_the_text_not_sixteen_past_it() {
    assert_eq!(BOX8.len(), 24, "three bytes each");
    let (shown, col) = prompt_window(BOX8, BOX8.len(), 70);
    assert_eq!(shown, BOX8, "the whole input fits");
    assert_eq!(col, 8, "eight columns, not the 24 bytes the old draw used");
}

#[test]
fn cjk_counts_two_columns_a_character() {
    assert_eq!(CJK3.len(), 9);
    let (_, col) = prompt_window(CJK3, CJK3.len(), 70);
    assert_eq!(col, 6, "three characters at two columns each");
}

#[test]
fn accented_latin_is_two_bytes_and_one_column() {
    let s = "caf\u{e9}";
    assert_eq!(s.len(), 5);
    let (_, col) = prompt_window(s, s.len(), 70);
    assert_eq!(col, 4);
}

#[test]
fn a_cursor_in_the_middle_counts_only_what_is_before_it() {
    let s = "a\u{3042}b"; // a, a wide hiragana, b
    assert_eq!(s.len(), 5);
    // Right after the wide character: one column for `a`, two for it.
    let (_, col) = prompt_window(s, 4, 70);
    assert_eq!(col, 3);
    // At the start, and at the very end.
    assert_eq!(prompt_window(s, 0, 70).1, 0);
    assert_eq!(prompt_window(s, s.len(), 70).1, 4);
}

#[test]
fn an_offset_inside_a_character_does_not_panic() {
    // The prompt keeps the cursor on a boundary, so this is a guard rather
    // than a case: a byte budgeted offset from anywhere else must not take
    // the client down the way #712 did.
    let s = "a\u{3042}b";
    assert!(!s.is_char_boundary(2));
    let (_, col) = prompt_window(s, 2, 70);
    assert_eq!(col, 1, "counts the characters that fit, drops the split one");
}

#[test]
fn the_window_scrolls_so_the_cursor_stays_inside() {
    // tmux status.c:937: when the cursor would fall past the right edge the
    // drawing starts `offset` columns in and the cursor pins to the last
    // column, rather than being drawn outside the prompt.
    let s = "0123456789abcdef";
    let (shown, col) = prompt_window(s, s.len(), 10);
    assert_eq!(col, 9, "the last column of the ten available");
    assert_eq!(shown, "789abcdef", "the tail, ending at the cursor");
    assert!(shown.chars().count() <= 10);
}

#[test]
fn the_window_scrolls_by_characters_not_bytes() {
    // Eight CJK characters are 16 columns in a prompt 10 wide.
    let s = "\u{65e5}\u{672c}\u{8a9e}\u{3067}\u{30b3}\u{30de}\u{30f3}\u{30c9}";
    assert_eq!(s.len(), 24);
    let (shown, col) = prompt_window(s, s.len(), 10);
    // The window starts at column 7, inside the fourth character, which is
    // dropped whole; the last four (8 columns) are shown and the cursor sits
    // right after them, not one blank cell further at column 9.
    assert_eq!(shown, "\u{30b3}\u{30de}\u{30f3}\u{30c9}");
    assert_eq!(col, 8);
    let width: usize = shown
        .chars()
        .map(|c| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0))
        .sum();
    assert!(width <= 10, "what is shown fits the prompt, got {} columns", width);
    // Every character shown is one of the input's, and whole: a wide one
    // straddling the left edge is dropped, as tmux's redraw drops it.
    assert!(shown.chars().all(|c| s.contains(c)));
    assert!(s.ends_with(shown), "the window ends where the cursor is");
}

#[test]
fn a_cursor_before_the_right_edge_does_not_scroll() {
    let s = "0123456789abcdef";
    let (shown, col) = prompt_window(s, 4, 10);
    assert_eq!(col, 4);
    assert_eq!(shown, "0123456789", "still drawn from the start");
}

#[test]
fn empty_and_degenerate_widths_are_quiet() {
    assert_eq!(prompt_window("", 0, 70), ("", 0));
    assert_eq!(prompt_window("", 0, 0), ("", 0));
    let (shown, col) = prompt_window("abc", 3, 0);
    assert_eq!(shown, "");
    assert_eq!(col, 0, "nowhere to draw it, and no panic either");
}

#[test]
fn the_old_arithmetic_is_what_this_replaces() {
    // Documents the defect in the form the issue reported it: the byte offset
    // the old draw added, beside the column the cursor belongs in.
    for (s, off_by) in [("ls -la", 0usize), (BOX8, 16), (CJK3, 3), ("caf\u{e9}", 1)] {
        let bytes = s.len();
        let (_, col) = prompt_window(s, bytes, 70);
        assert_eq!(bytes - col, off_by, "{:?} was drawn {} columns past the text", s, bytes - col);
    }
}
