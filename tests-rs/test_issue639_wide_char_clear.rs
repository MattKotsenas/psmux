//! Issue #639: "Chinese characters not clear when pane content changed".
//!
//! Reported as: ssh to a box, run psmux, run a full screen program (`tig`),
//! quit it, and the double width Chinese glyphs stay painted on the screen.
//!
//! A double width glyph occupies TWO grid cells: a lead cell that carries the
//! character, and a continuation cell that carries nothing. tmux models this
//! the same way (`grid.c`, `GRID_FLAG_PADDING`) and enforces one rule in
//! `screen_write_overwrite` (`screen-write.c`):
//!
//!   * writing over a PADDING cell clears the padding AND the lead character
//!     it belongs to (tmux walks backwards to the owning character), and
//!   * writing a character clears every padding cell the old character owned
//!     (tmux walks forwards).
//!
//! Erasing has the same duty: ED, EL, ECH, DCH and ICH must never leave half
//! a glyph behind. A surviving half is exactly the reported ghost, because the
//! renderer will keep painting a cell the emulator still believes has content.
//!
//! These tests drive the emulator directly with the exact byte sequences and
//! assert on the cells, including the continuation cells that `capture-pane`
//! deliberately hides (`src/copy_mode.rs::push_capture_cell` skips the trailing
//! half of a wide glyph, so a grid level orphan is invisible from there).

/// U+4E2D .. U+7B26, six double width Han characters, twelve columns.
const CJK: &str = "\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}\u{5B57}\u{7B26}";

fn parser(rows: u16, cols: u16) -> vt100::Parser {
    vt100::Parser::new(rows, cols, 0)
}

/// The whole visible row, continuation cells rendered as the empty string so a
/// leaked half shows up as a doubled glyph rather than silently vanishing.
fn row_text(screen: &vt100::Screen, row: u16, cols: u16) -> String {
    let mut s = String::new();
    for c in 0..cols {
        if let Some(cell) = screen.cell(row, c) {
            s.push_str(cell.contents());
        }
    }
    s.trim_end().to_string()
}

/// Panics unless every wide cell on the row is followed by a continuation cell
/// and every continuation cell is preceded by a wide cell. This is the
/// invariant tmux maintains through `screen_write_overwrite`; a violation is
/// the ghost.
fn assert_wide_pairs_intact(screen: &vt100::Screen, rows: u16, cols: u16) {
    for r in 0..rows {
        for c in 0..cols {
            let cell = match screen.cell(r, c) {
                Some(cell) => cell,
                None => continue,
            };
            if cell.is_wide() {
                assert!(
                    c + 1 < cols,
                    "row {r} col {c}: wide glyph {:?} sits in the last column \
                     with no room for its continuation",
                    cell.contents()
                );
                let next = screen.cell(r, c + 1).expect("continuation in bounds");
                assert!(
                    next.is_wide_continuation(),
                    "row {r} col {c}: wide glyph {:?} is not followed by a \
                     continuation cell (it holds {:?})",
                    cell.contents(),
                    next.contents()
                );
                assert!(
                    !next.has_contents(),
                    "row {r} col {}: continuation cell carries content {:?}",
                    c + 1,
                    next.contents()
                );
            }
            if cell.is_wide_continuation() {
                assert!(
                    c > 0,
                    "row {r} col 0 is a continuation cell with no lead before it"
                );
                let prev = screen.cell(r, c - 1).expect("lead in bounds");
                assert!(
                    prev.is_wide(),
                    "row {r} col {c}: ORPHANED continuation cell, the cell \
                     before it is {:?} and is not wide. This is the #639 ghost: \
                     half a Chinese glyph outliving the character it belonged to.",
                    prev.contents()
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Overwriting a wide glyph
// ---------------------------------------------------------------------------

/// Two ASCII columns land exactly on a wide glyph's two cells.
#[test]
fn issue639_narrow_pair_replaces_a_wide_glyph() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[H");
    p.process(b"ab");

    let s = p.screen();
    assert_eq!(row_text(s, 0, 20), "ab\u{6587}\u{6D4B}\u{8BD5}\u{5B57}\u{7B26}");
    assert_wide_pairs_intact(s, 5, 20);
}

/// One ASCII column lands on the LEFT half. tmux clears the whole glyph, so the
/// orphaned right half must become a blank cell, not a stray continuation.
#[test]
fn issue639_single_narrow_over_the_lead_half_clears_both() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[H");
    p.process(b"X");

    let s = p.screen();
    let c0 = s.cell(0, 0).unwrap();
    assert_eq!(c0.contents(), "X");
    assert!(!c0.is_wide(), "the narrow X must not inherit the wide flag");

    let c1 = s.cell(0, 1).unwrap();
    assert!(
        !c1.is_wide_continuation(),
        "col 1 is still flagged as a continuation after its lead was overwritten"
    );
    // tmux resets the orphaned half to `grid_default_cell`, which is a SPACE
    // (grid.c), so a blank cell and a space cell are both correct here. What
    // must NOT survive is the old glyph.
    assert!(
        c1.contents().is_empty() || c1.contents() == " ",
        "col 1 kept the old glyph {:?} after its lead was overwritten",
        c1.contents()
    );

    // "X", the blanked orphan half, then the glyphs that were never touched.
    assert_eq!(row_text(s, 0, 20), "X \u{6587}\u{6D4B}\u{8BD5}\u{5B57}\u{7B26}");
    assert_wide_pairs_intact(s, 5, 20);
}

/// One ASCII column lands on the RIGHT half. tmux walks BACK to the owning
/// character and clears it, so the lead must not survive as a lone half glyph.
#[test]
fn issue639_single_narrow_over_the_continuation_half_clears_the_lead() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;2H");
    p.process(b"X");

    let s = p.screen();
    let lead = s.cell(0, 0).unwrap();
    assert!(
        !lead.has_contents(),
        "the lead half survived as {:?} after its continuation was overwritten",
        lead.contents()
    );
    assert!(!lead.is_wide(), "the lead half kept its wide flag");

    let written = s.cell(0, 1).unwrap();
    assert_eq!(written.contents(), "X");
    assert!(!written.is_wide_continuation());

    assert_wide_pairs_intact(s, 5, 20);
}

/// A wide glyph written over another wide glyph at an odd offset has to clear
/// the halves on BOTH sides of itself.
#[test]
fn issue639_wide_over_wide_at_an_odd_offset() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;2H");
    p.process("\u{4E01}".as_bytes());

    let s = p.screen();
    assert!(!s.cell(0, 0).unwrap().has_contents(), "left neighbour survived");
    assert_eq!(s.cell(0, 1).unwrap().contents(), "\u{4E01}");
    assert!(s.cell(0, 1).unwrap().is_wide());
    assert!(s.cell(0, 2).unwrap().is_wide_continuation());
    assert!(!s.cell(0, 3).unwrap().has_contents(), "right neighbour survived");
    assert_wide_pairs_intact(s, 5, 20);
}

// ---------------------------------------------------------------------------
// Erasing across a wide glyph
// ---------------------------------------------------------------------------

/// ED(2): the reporter's "clear the screen" step.
#[test]
fn issue639_ed_all_clears_wide_glyphs() {
    let mut p = parser(5, 20);
    for _ in 0..3 {
        p.process(format!("{CJK}\r\n").as_bytes());
    }
    p.process(b"\x1b[2J\x1b[H");
    p.process(b"AFTER");

    let s = p.screen();
    assert_eq!(row_text(s, 0, 20), "AFTER");
    for r in 1..5 {
        assert_eq!(row_text(s, r, 20), "", "row {r} kept content after ED(2)");
    }
    assert_wide_pairs_intact(s, 5, 20);
}

/// EL(0) starting in the MIDDLE of a wide glyph must take the lead half too.
#[test]
fn issue639_el_forward_from_a_continuation_cell() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;4H\x1b[K"); // col 4 is the continuation of the 2nd glyph

    let s = p.screen();
    assert_eq!(
        row_text(s, 0, 20),
        "\u{4E2D}",
        "EL from inside a glyph left half of it behind"
    );
    assert_wide_pairs_intact(s, 5, 20);
}

/// EL(1) ending in the MIDDLE of a wide glyph must take the continuation too.
#[test]
fn issue639_el_backward_into_a_lead_cell() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;3H\x1b[1K"); // col 3 is the lead of the 2nd glyph

    let s = p.screen();
    assert_eq!(
        row_text(s, 0, 20),
        "  \u{6D4B}\u{8BD5}\u{5B57}\u{7B26}".trim_start(),
        "EL(1) left a dangling continuation behind"
    );
    assert_wide_pairs_intact(s, 5, 20);
}

/// ED(0) from inside a wide glyph, plus the rows below.
#[test]
fn issue639_ed_forward_from_a_continuation_cell() {
    let mut p = parser(5, 20);
    for _ in 0..4 {
        p.process(format!("{CJK}\r\n").as_bytes());
    }
    p.process(b"\x1b[2;4H\x1b[J");

    let s = p.screen();
    assert_eq!(row_text(s, 0, 20), CJK);
    assert_eq!(row_text(s, 1, 20), "\u{4E2D}");
    for r in 2..5 {
        assert_eq!(row_text(s, r, 20), "", "row {r} survived ED(0)");
    }
    assert_wide_pairs_intact(s, 5, 20);
}

/// ECH with an ODD count, so the erased span ends inside a glyph.
#[test]
fn issue639_ech_with_an_odd_count() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;1H\x1b[3X"); // erases cols 1..3, splitting glyph 2

    let s = p.screen();
    assert_eq!(row_text(s, 0, 20), "\u{6D4B}\u{8BD5}\u{5B57}\u{7B26}");
    assert_wide_pairs_intact(s, 5, 20);
}

/// DCH shifts the row left by an ODD amount, so every following pair changes
/// parity. This is the classic way to strand a continuation cell.
#[test]
fn issue639_dch_by_an_odd_count() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;1H\x1b[1P");

    let s = p.screen();
    assert_wide_pairs_intact(s, 5, 20);
}

/// ICH shifts the row right by an ODD amount.
#[test]
fn issue639_ich_by_an_odd_count() {
    let mut p = parser(5, 20);
    p.process(format!("\x1b[H\x1b[2J{CJK}").as_bytes());
    p.process(b"\x1b[1;1H\x1b[1@");

    let s = p.screen();
    assert_wide_pairs_intact(s, 5, 20);
}

// ---------------------------------------------------------------------------
// The reporter's actual sequence: a full screen app that drew CJK, then quit
// ---------------------------------------------------------------------------

/// `tig` enters the alternate screen, paints Chinese text, then quits. The
/// primary screen must come back with none of the alt screen's glyphs on it.
#[test]
fn issue639_alt_screen_exit_leaves_no_wide_glyphs() {
    let mut p = parser(10, 40);
    p.process(b"\x1b[H\x1b[2J");
    for i in 1..=6 {
        p.process(format!("\x1b[{i};1Hprimary row {i}").as_bytes());
    }

    p.process(b"\x1b[?1049h\x1b[H\x1b[2J");
    for i in 1..=8 {
        p.process(format!("\x1b[{i};1H{CJK}{CJK}").as_bytes());
    }
    p.process(b"\x1b[?1049l");

    let s = p.screen();
    for r in 0..10 {
        let text = row_text(s, r, 40);
        assert!(
            !text.chars().any(|c| ('\u{2E80}'..='\u{9FFF}').contains(&c)),
            "row {r} still shows alt screen Chinese text after ?1049l: {text:?}"
        );
    }
    assert_eq!(row_text(s, 0, 40), "primary row 1");
    assert_wide_pairs_intact(s, 10, 40);
}

/// Same trip, but the alt screen mixes ASCII and CJK the way a commit list
/// does, and the primary screen underneath is blank.
#[test]
fn issue639_alt_screen_exit_from_a_mixed_commit_list() {
    let mut p = parser(10, 40);
    p.process(b"\x1b[H\x1b[2J");
    p.process(b"$ tig");

    p.process(b"\x1b[?1049h\x1b[H\x1b[2J");
    for i in 1..=8 {
        p.process(format!("\x1b[{i};1H{i:07} {CJK} msg {i} {CJK}").as_bytes());
    }
    p.process(b"\x1b[?1049l");

    let s = p.screen();
    assert_eq!(row_text(s, 0, 40), "$ tig");
    for r in 1..10 {
        assert_eq!(row_text(s, r, 40), "", "row {r} kept alt screen content");
    }
    assert_wide_pairs_intact(s, 10, 40);
}

// ---------------------------------------------------------------------------
// Edges
// ---------------------------------------------------------------------------

/// A wide glyph must never be split across the right edge: tmux wraps it whole.
#[test]
fn issue639_wide_glyph_does_not_straddle_the_right_edge() {
    // 5 columns: two glyphs fit (cols 0..3), the third must wrap to row 1.
    let mut p = parser(4, 5);
    p.process(b"\x1b[H\x1b[2J");
    p.process("\u{4E2D}\u{6587}\u{6D4B}".as_bytes());

    let s = p.screen();
    assert!(
        !s.cell(0, 4).map_or(false, |c| c.is_wide()),
        "a wide glyph was placed in the last column with no room for its half"
    );
    assert_eq!(row_text(s, 1, 5), "\u{6D4B}");
    assert_wide_pairs_intact(s, 4, 5);
}

/// Narrowing the pane through a wide pair must not leave a lead cell whose
/// continuation was cut away (issue #534 territory, same invariant).
#[test]
fn issue639_narrowing_through_a_wide_pair() {
    let mut p = parser(4, 10);
    p.process(b"\x1b[H\x1b[2J");
    p.process(format!("{CJK}").as_bytes());
    // 9 columns cuts the 5th glyph (cols 8..9) in half.
    p.screen_mut().set_size(4, 9);
    assert_wide_pairs_intact(p.screen(), 4, 9);
    p.screen_mut().set_size(4, 1);
    assert_wide_pairs_intact(p.screen(), 4, 1);
    p.screen_mut().set_size(4, 10);
    assert_wide_pairs_intact(p.screen(), 4, 10);
}

/// Every erase op, applied at every offset across a row of wide glyphs. This is
/// the sweep that would catch a hole the hand written cases above miss.
#[test]
fn issue639_erase_matrix_never_strands_a_half_glyph() {
    const COLS: u16 = 24;
    let ops: &[&str] = &[
        "\x1b[K", "\x1b[1K", "\x1b[2K", "\x1b[J", "\x1b[1J", "\x1b[2J",
        "\x1b[1X", "\x1b[2X", "\x1b[3X", "\x1b[7X",
        "\x1b[1P", "\x1b[2P", "\x1b[3P",
        "\x1b[1@", "\x1b[2@", "\x1b[3@",
        "a", "ab", "\u{4E01}", "a\u{4E01}",
    ];
    for op in ops {
        for col in 1..=COLS {
            let mut p = parser(3, COLS);
            p.process(b"\x1b[H\x1b[2J");
            p.process(format!("{CJK}{CJK}").as_bytes()); // 24 columns exactly
            p.process(format!("\x1b[1;{col}H").as_bytes());
            p.process(op.as_bytes());

            let s = p.screen();
            for c in 0..COLS {
                let cell = s.cell(0, c).unwrap();
                if cell.is_wide_continuation() {
                    let prev = s.cell(0, c - 1).unwrap();
                    assert!(
                        c > 0 && prev.is_wide(),
                        "op {op:?} at col {col}: col {c} is an ORPHANED \
                         continuation cell (the cell before it is {:?}). This \
                         is the #639 ghost.",
                        prev.contents()
                    );
                }
                if cell.is_wide() {
                    assert!(
                        c + 1 < COLS && s.cell(0, c + 1).unwrap().is_wide_continuation(),
                        "op {op:?} at col {col}: wide glyph at col {c} lost its \
                         continuation cell"
                    );
                }
            }
        }
    }
}
