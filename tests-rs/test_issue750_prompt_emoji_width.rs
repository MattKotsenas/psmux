// Issue #750: a prompt counted its text one character at a time, where the
// pane's grid counts a variation selector sequence as one two column cell
// (#533). The two disagreed inside one psmux, and the cursor landed on top of
// the next character.
//
// GROUND TRUTH for the sequence this fixes: eight terminals, measured by
// writing it with WriteConsoleW and reading how far the console's own cursor
// advanced. Windows Terminal, VS Code, JetBrains, conhost, WezTerm, Alacritty,
// mintty and ConEmu all give `U+2764 U+FE0F` TWO columns, and `U+2764` alone
// one. tmux 3.7c gives it two as well (`#{cursor_x}` after a write), with
// `variation-selector-always-wide` on by default.
//
// A cluster joined across characters that carry a width of their own, a skin
// tone pair, a regional indicator pair or a ZWJ sequence, is one two column
// cell in the grid since #749, as in tmux. The prompt asks the grid's own rule
// (`vt100::str_cells`), so it counts those the same way.

use super::{prompt_window, str_prefix_within_cols};

/// The column `prompt_window` puts the cursor at with the cursor at the end of
/// `s` and room to spare.
fn end_column(s: &str) -> usize {
    let (shown, col) = prompt_window(s, s.len(), 80);
    assert_eq!(shown, s, "the whole text fits in 80 columns");
    col
}

#[test]
fn a_variation_selector_makes_the_sequence_two_columns() {
    assert_eq!(end_column("\u{2764}"), 1, "the heart on its own is one column");
    assert_eq!(end_column("\u{2764}\u{FE0F}"), 2, "with VS16 every terminal draws two");
    assert_eq!(end_column("\u{2733}\u{FE0F}"), 2, "the sequence #533 fixed in the grid");
}

#[test]
fn the_prompt_agrees_with_the_grid() {
    // Measured from a psmux pane with `#{cursor_x}`: these are the columns the
    // grid gives each sequence, and the prompt now gives the same.
    assert_eq!(end_column("A"), 1);
    assert_eq!(end_column("\u{3042}"), 2);
    assert_eq!(end_column("\u{2764}\u{FE0F}"), 2);
    assert_eq!(end_column("\u{1F44D}"), 2);
    assert_eq!(end_column("\u{1F44D}\u{1F3FD}"), 2, "a skin tone pair is one cell (#749)");
    assert_eq!(end_column("\u{1F1EF}\u{1F1F5}"), 2, "a regional indicator pair");
    assert_eq!(end_column("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"), 2, "the rainbow joins the flag through the ZWJ (#749)");
    assert_eq!(
        end_column("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"),
        2,
        "the family is one cell of two columns (#749)"
    );
}

#[test]
fn clusters_follow_the_grid_rule() {
    // A skin tone modifier joins its emoji in either order, as tmux tries
    // utf8_should_combine both ways round.
    assert_eq!(end_column("\u{1F3FD}\u{1F44D}"), 2);
    // A modifier outside tmux's table, or two modifiers, stay apart.
    assert_eq!(end_column("\u{1F4DB}\u{1F3FD}"), 4);
    assert_eq!(end_column("\u{1F3FD}\u{1F3FD}"), 4);
    // A flag takes no third indicator; the third stands alone at one column.
    assert_eq!(end_column("\u{1F1EF}\u{1F1F5}\u{1F1FA}"), 3);
    assert_eq!(end_column("\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}"), 4);
    // A letter, ZWJ and an emoji stay one column, as tmux keeps them.
    assert_eq!(end_column("a\u{200D}\u{1F466}"), 1);
    // Text after a cluster is counted from the end of its one cell.
    let fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    let s = format!("{fam}AB");
    assert_eq!(end_column(&s), 4);
    let (_, col) = prompt_window(&s, fam.len(), 80);
    assert_eq!(col, 2, "right after the family");
    // A cell that does not fit is not drawn in half.
    assert_eq!(str_prefix_within_cols(&s, 1), "");
    assert_eq!(str_prefix_within_cols(&s, 3), format!("{fam}A"));
}

// Discussion #749: the ten sequences measured against tmux 3.7c. The prompt
// gives each the columns the pane's grid gives it, which since #749 are
// tmux's: a ZWJ sequence, a skin tone pair, a regional indicator pair and a
// VS16 sequence are each one two column cell.
#[test]
fn the_ten_749_sequences_match_tmux() {
    let seqs = [
        "\u{0041}",
        "\u{3042}",
        "\u{2764}",
        "\u{2764}\u{FE0F}",
        "\u{2733}\u{FE0F}",
        "\u{1F44D}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F1EF}\u{1F1F5}",
        "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
    ];
    let got: Vec<usize> = seqs.iter().map(|s| end_column(s)).collect();
    println!("prompt cursor columns: {got:?}");
    assert_eq!(got, vec![1, 2, 1, 2, 2, 2, 2, 2, 2, 2]);
}

#[test]
fn a_zero_width_character_joins_the_cell_before_it() {
    // A combining mark does not add a column, and cannot promote a cell that
    // is already wide.
    assert_eq!(end_column("e\u{0301}"), 1, "e with a combining acute");
    assert_eq!(end_column("\u{3042}\u{0301}"), 2, "already wide, nothing to promote");
    assert_eq!(end_column("\u{FE0F}"), 0, "a selector with no cell to join is dropped");
    assert_eq!(end_column("\u{200D}"), 0, "so is a lone joiner");
}

#[test]
fn a_cursor_inside_the_text_counts_what_precedes_it() {
    let heart = "\u{2764}\u{FE0F}";
    let s = format!("A{heart}B");
    let (_, col) = prompt_window(&s, 1, 80);
    assert_eq!(col, 1, "before the heart");
    let (_, col) = prompt_window(&s, 1 + heart.len(), 80);
    assert_eq!(col, 3, "one for A, two for the heart, which used to say two");
    let (_, col) = prompt_window(&s, s.len(), 80);
    assert_eq!(col, 4, "after the B");
}

#[test]
fn a_cursor_inside_a_cell_counts_the_cell_it_is_in() {
    // The editing keys move by whole characters, but a byte offset between the
    // base and its selector is reachable through `str_prefix_within`, and it
    // must not be rounded up past the cell.
    let s = "\u{2764}\u{FE0F}X";
    let (_, col) = prompt_window(s, 3, 80);
    assert_eq!(col, 1, "between the heart and its selector the cell is still narrow");
}

#[test]
fn the_window_scrolls_by_cells() {
    // Ten hearts with selectors: twenty columns in fifty bytes. The old per
    // character sum thought this was ten columns wide and never scrolled.
    let heart = "\u{2764}\u{FE0F}";
    let s = heart.repeat(10);
    assert_eq!(end_column(&s), 20);
    let (shown, col) = prompt_window(&s, s.len(), 12);
    assert!(col < 12, "the cursor stays on the line, at {col}");
    assert!(s.ends_with(shown), "the window keeps the end, where the cursor is");
    assert_eq!(shown.len() % heart.len(), 0, "the window starts on a cell, not inside one");
}

#[test]
fn a_cell_that_does_not_fit_is_not_drawn_in_half() {
    assert_eq!(
        str_prefix_within_cols("\u{2764}\u{FE0F}", 1),
        "",
        "the promoted cell needs two columns, so one column shows nothing"
    );
    assert_eq!(
        str_prefix_within_cols("\u{2764}", 1),
        "\u{2764}",
        "without the selector it fits"
    );
    assert_eq!(
        str_prefix_within_cols("A\u{2764}\u{FE0F}", 2),
        "A",
        "the A fits and the cell after it does not"
    );
    assert_eq!(str_prefix_within_cols("A\u{2764}\u{FE0F}", 3), "A\u{2764}\u{FE0F}");
}

#[test]
fn an_empty_prompt_and_no_room_still_behave() {
    assert_eq!(prompt_window("", 0, 80), ("", 0));
    assert_eq!(prompt_window("\u{2764}\u{FE0F}", 6, 0), ("", 0), "no room at all");
}
