// Issue #534: shrinking a row past the continuation cell of a wide character
// leaves the row's last cell flagged wide with no continuation after it. An
// erase-in-line over that orphaned cell then panics.
//
// Two distinct defects are claimed:
//   1. Row::resize does not clear a wide cell whose continuation was just
//      truncated when shrinking (Row::truncate already does the equivalent).
//   2. Row::erase derives the logical last column as `cols() - if wide {2} else {1}`.
//      For an orphaned wide cell in a one column row that is `1 - 2`, which
//      underflows u16.
//
// A panic in a terminal emulator is a hard crash of whatever hosts it, so every
// test here asserts the emulator SURVIVES and that the resulting grid is sane,
// not merely that nothing blew up.
//
// Resizing a pane through a CJK glyph is routine, so this is a reachable path.

fn wide_then_shrink(cols_before: u16, cols_after: u16) -> vt100_psmux::Parser {
    let mut parser = vt100_psmux::Parser::new(2, cols_before, 0);
    parser.process("\u{4F60}".as_bytes()); // wide CJK, occupies 2 columns
    parser.screen_mut().set_size(2, cols_after);
    parser
}

// ---------------------------------------------------------------------------
// The exact reproduction from the report
// ---------------------------------------------------------------------------

#[test]
fn exact_repro_from_the_report_does_not_panic() {
    let mut parser = vt100_psmux::Parser::new(2, 4, 0);
    parser.process("\u{4F60}".as_bytes());
    parser.screen_mut().set_size(2, 1);
    parser.process(b"\x1b[K");

    // Survived. Now prove the grid is actually coherent rather than merely alive.
    let screen = parser.screen();
    let cell = screen.cell(0, 0).expect("cell 0,0 must exist after the resize");
    assert!(
        !cell.is_wide(),
        "the truncated cell must not still claim to be wide: its continuation is gone"
    );
    assert_eq!(screen.size(), (2, 1), "the resize must have taken effect");
}

// ---------------------------------------------------------------------------
// Defect 1: the truncation itself must clear the orphaned wide flag
// ---------------------------------------------------------------------------

#[test]
fn shrinking_through_the_continuation_clears_the_wide_flag() {
    // No erase at all. The resize alone must leave a coherent row, otherwise
    // every later consumer inherits an impossible cell.
    let parser = wide_then_shrink(4, 1);
    let cell = parser.screen().cell(0, 0).expect("cell 0,0 exists");
    assert!(
        !cell.is_wide(),
        "resize must clear a wide cell whose continuation it just truncated"
    );
}

#[test]
fn shrinking_to_exactly_the_wide_char_width_keeps_it_intact() {
    // 2 columns is exactly enough for the glyph, so nothing should be disturbed.
    let parser = wide_then_shrink(4, 2);
    let screen = parser.screen();
    assert!(screen.cell(0, 0).unwrap().is_wide(), "the glyph still fits, stay wide");
    assert!(
        screen.cell(0, 1).unwrap().is_wide_continuation(),
        "its continuation must survive at col 1"
    );
}

#[test]
fn wide_char_not_at_the_left_edge_is_handled_too() {
    // Glyph at cols 1 and 2; shrink to 2 columns cuts its continuation.
    let mut parser = vt100_psmux::Parser::new(2, 6, 0);
    parser.process("a\u{4F60}".as_bytes());
    parser.screen_mut().set_size(2, 2);
    parser.process(b"\x1b[K");
    let screen = parser.screen();
    assert_eq!(screen.cell(0, 0).map(|c| c.contents()), Some("a".to_string()).as_deref());
    assert!(
        !screen.cell(0, 1).unwrap().is_wide(),
        "the orphaned glyph at col 1 must lose its wide flag"
    );
}

// ---------------------------------------------------------------------------
// Defect 2: the erase must not underflow, for every erase-in-line variant
// ---------------------------------------------------------------------------

#[test]
fn every_erase_in_line_variant_survives_the_orphaned_cell() {
    // CSI K (to end), CSI 1K (to start), CSI 2K (whole line).
    for seq in [&b"\x1b[K"[..], &b"\x1b[0K"[..], &b"\x1b[1K"[..], &b"\x1b[2K"[..]] {
        let mut parser = wide_then_shrink(4, 1);
        parser.process(seq);
        assert!(
            !parser.screen().cell(0, 0).unwrap().is_wide(),
            "erase variant {seq:?} must leave a coherent cell"
        );
    }
}

#[test]
fn erase_in_display_variants_survive_too() {
    // ED shares the row erase path, so it is reachable the same way.
    for seq in [&b"\x1b[J"[..], &b"\x1b[0J"[..], &b"\x1b[1J"[..], &b"\x1b[2J"[..]] {
        let mut parser = wide_then_shrink(4, 1);
        parser.process(seq);
        assert_eq!(parser.screen().size(), (2, 1), "erase variant {seq:?} kept the size");
    }
}

#[test]
fn erase_survives_at_every_shrink_target() {
    // Sweep the whole interesting range rather than only the 1 column case.
    for cols_before in [2u16, 3, 4, 8] {
        for cols_after in 1..=cols_before {
            let mut parser = wide_then_shrink(cols_before, cols_after);
            parser.process(b"\x1b[K");
            let screen = parser.screen();
            assert_eq!(
                screen.size(),
                (2, cols_after),
                "{cols_before} to {cols_after}: size must hold"
            );
            // Any cell flagged wide must still have its continuation in the row.
            for col in 0..cols_after {
                let c = screen.cell(0, col).expect("cell exists");
                if c.is_wide() {
                    assert!(
                        col + 1 < cols_after,
                        "{cols_before} to {cols_after}: wide cell at {col} has no room for a continuation"
                    );
                    assert!(
                        screen.cell(0, col + 1).unwrap().is_wide_continuation(),
                        "{cols_before} to {cols_after}: wide cell at {col} lost its continuation"
                    );
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The orphaned cell must not poison anything downstream
// ---------------------------------------------------------------------------

#[test]
fn writing_over_the_orphaned_cell_works() {
    let mut parser = wide_then_shrink(4, 1);
    parser.process(b"x");
    assert_eq!(
        parser.screen().cell(0, 0).map(|c| c.contents()),
        Some("x".to_string()).as_deref(),
        "an ordinary write must land on the salvaged cell"
    );
}

#[test]
fn contents_and_formatted_survive_the_orphaned_cell() {
    let mut parser = wide_then_shrink(4, 1);
    let screen = parser.screen();
    let _ = screen.contents();
    let formatted = screen.contents_formatted();
    // Replay into a fresh parser of the same geometry: must not panic and must
    // not resurrect a wide cell that cannot fit.
    let mut p2 = vt100_psmux::Parser::new(2, 1, 0);
    p2.process(&formatted);
    assert!(
        !p2.screen().cell(0, 0).unwrap().is_wide(),
        "a 1 column grid can never hold a wide cell"
    );
    parser.process(b"\x1b[K");
}

#[test]
fn growing_back_does_not_resurrect_a_broken_glyph() {
    let mut parser = wide_then_shrink(4, 1);
    parser.process(b"\x1b[K");
    parser.screen_mut().set_size(2, 4);
    let screen = parser.screen();
    assert_eq!(screen.size(), (2, 4));
    for col in 0..4u16 {
        let c = screen.cell(0, col).expect("cell exists after regrow");
        assert!(
            !c.is_wide_continuation(),
            "col {col} must not be a continuation of a glyph that was truncated away"
        );
    }
}

#[test]
fn repeated_shrink_and_erase_cycles_stay_stable() {
    // Hammer the path the way a user dragging a pane divider would.
    let mut parser = vt100_psmux::Parser::new(2, 8, 0);
    for i in 0..20u16 {
        let cols = 1 + (i % 8);
        parser.screen_mut().set_size(2, cols.max(1));
        parser.process("\u{4F60}\u{4E16}".as_bytes());
        parser.process(b"\x1b[K");
        parser.process(b"\x1b[2J");
    }
    assert!(parser.screen().size().1 >= 1, "emulator survived the resize storm");
}

// ---------------------------------------------------------------------------
// Regression guards: rows with room to spare must be completely unaffected
// ---------------------------------------------------------------------------

#[test]
fn erase_still_works_normally_on_a_roomy_row() {
    let mut parser = vt100_psmux::Parser::new(2, 20, 0);
    parser.process("abc\u{4F60}def".as_bytes());
    parser.process(b"\x1b[K"); // cursor is past the text, erase to end is a no-op there
    let screen = parser.screen();
    assert_eq!(screen.cell(0, 0).map(|c| c.contents()), Some("a".to_string()).as_deref());
    assert!(screen.cell(0, 3).unwrap().is_wide(), "the CJK glyph is untouched");
    assert!(screen.cell(0, 4).unwrap().is_wide_continuation());
    assert_eq!(screen.cell(0, 5).map(|c| c.contents()), Some("d".to_string()).as_deref());
}

#[test]
fn erase_to_start_over_a_wide_char_mid_row_is_unchanged() {
    let mut parser = vt100_psmux::Parser::new(2, 20, 0);
    parser.process("ab\u{4F60}cd".as_bytes());
    parser.process(b"\x1b[1;6H"); // col index 5
    parser.process(b"\x1b[1K");
    let screen = parser.screen();
    assert!(
        !screen.cell(0, 2).unwrap().is_wide(),
        "the erased glyph must not keep its wide flag"
    );
    assert!(
        !screen.cell(0, 3).unwrap().is_wide_continuation(),
        "and its continuation must be cleared with it"
    );
}

#[test]
fn shrinking_a_row_with_no_wide_char_is_unchanged() {
    let mut parser = vt100_psmux::Parser::new(2, 8, 0);
    parser.process(b"abcdefgh");
    parser.screen_mut().set_size(2, 3);
    parser.process(b"\x1b[K");
    let screen = parser.screen();
    assert_eq!(screen.size(), (2, 3));
    assert_eq!(screen.cell(0, 0).map(|c| c.contents()), Some("a".to_string()).as_deref());
}

#[test]
fn vs16_promoted_cell_survives_the_same_truncation() {
    // #533 promotes a narrow cell to wide on a variation selector. That promoted
    // cell must survive this truncation path exactly like a native wide glyph,
    // otherwise the two fixes interact badly.
    let mut parser = vt100_psmux::Parser::new(2, 4, 0);
    parser.process("\u{2733}\u{FE0F}".as_bytes());
    assert!(parser.screen().cell(0, 0).unwrap().is_wide(), "promoted to wide first");
    parser.screen_mut().set_size(2, 1);
    parser.process(b"\x1b[K");
    assert!(
        !parser.screen().cell(0, 0).unwrap().is_wide(),
        "a promoted wide cell must also lose its flag when truncated"
    );
}
