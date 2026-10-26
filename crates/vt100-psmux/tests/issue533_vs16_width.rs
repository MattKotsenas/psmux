// Issue #533: a text-presentation base character followed by U+FE0F (VS16) requests
// emoji presentation, which real terminals and tmux count as TWO columns. Measuring
// width one char at a time settles the cell at one column and folds the selector in
// as a zero-width mark, so the grid ends up one column narrower than the child
// process believes, and everything after it drifts left by one cell.
//
// Parity oracle (tmux 3.4, cursor_x after writing the sequence):
//   U+2733            -> 1
//   U+2733 U+FE0F     -> 2
//   U+2733 U+FE0E     -> 1   (VS15 asks for TEXT presentation, stays narrow)
//   U+1F4DB           -> 2
//
// Read the cursor column straight off the emulator: this isolates the grid width
// computation from ConPTY entirely.

fn parse(chunks: &[&str]) -> vt100_psmux::Parser {
    let mut p = vt100_psmux::Parser::new(4, 40, 0);
    for c in chunks {
        p.process(c.as_bytes());
    }
    p
}

fn cursor_col_after(s: &str) -> u16 {
    parse(&[s]).screen().cursor_position().1
}

// U+2733 EIGHT SPOKED ASTERISK: Emoji=Yes, Emoji_Presentation=No.
// Narrow on its own, wide when followed by VS16. This is the exact character
// from the report (the Claude Code status line spinner).
const ASTERISK: &str = "\u{2733}";
const VS16: &str = "\u{FE0F}";
const VS15: &str = "\u{FE0E}";

// ---------------------------------------------------------------------------
// The core claim
// ---------------------------------------------------------------------------

#[test]
fn vs16_sequence_occupies_two_columns() {
    assert_eq!(
        cursor_col_after(&format!("{ASTERISK}{VS16}")),
        2,
        "base + VS16 requests emoji presentation and must reserve 2 columns (tmux: 2)"
    );
}

#[test]
fn text_after_vs16_does_not_drift_left() {
    // The reported symptom: 'A' should land on column 2, as it does in a real
    // terminal and in tmux. Drift here is what leaves stale residue on screen.
    let p = parse(&[&format!("{ASTERISK}{VS16}AB")]);
    let s = p.screen();
    assert_eq!(s.cell(0, 2).map(|c| c.contents()), Some("A".to_string()).as_deref(),
        "'A' must land on col 2, not col 1");
    assert_eq!(s.cell(0, 3).map(|c| c.contents()), Some("B".to_string()).as_deref(),
        "'B' must land on col 3");
    assert_eq!(s.cursor_position().1, 4, "cursor after base+VS16+AB is col 4");
}

#[test]
fn vs16_cell_is_wide_with_a_continuation() {
    let p = parse(&[&format!("{ASTERISK}{VS16}")]);
    let s = p.screen();

    let base = s.cell(0, 0).expect("cell 0,0 exists");
    assert_eq!(base.contents(), format!("{ASTERISK}{VS16}"),
        "base cell keeps the whole sequence including the selector");
    assert!(base.is_wide(), "the promoted cell must be flagged wide");
    assert!(!base.is_wide_continuation(), "the base cell is not a continuation");

    let cont = s.cell(0, 1).expect("cell 0,1 exists");
    assert!(cont.is_wide_continuation(),
        "col 1 must be the wide continuation of the emoji, not free space");
}

// ---------------------------------------------------------------------------
// Chunk-boundary independence: a PTY read() splitting the pair is routine
// ---------------------------------------------------------------------------

#[test]
fn promotion_survives_every_chunk_boundary() {
    let base_and_vs16 = format!("{ASTERISK}{VS16}");
    let bytes = base_and_vs16.as_bytes();

    // 1. one chunk
    assert_eq!(parse(&[&base_and_vs16]).screen().cursor_position().1, 2,
        "single chunk");

    // 2. split before the selector
    assert_eq!(parse(&[ASTERISK, VS16]).screen().cursor_position().1, 2,
        "split between base and selector");

    // 3. selector arriving alone after other processing
    {
        let mut p = vt100_psmux::Parser::new(4, 40, 0);
        p.process(ASTERISK.as_bytes());
        assert_eq!(p.screen().cursor_position().1, 1, "base alone is 1 column");
        p.process(VS16.as_bytes());
        assert_eq!(p.screen().cursor_position().1, 2,
            "selector alone must still promote the cell already in the grid");
    }

    // 4. split mid-UTF-8 inside the selector's own 3 bytes
    for cut in 1..bytes.len() {
        let mut p = vt100_psmux::Parser::new(4, 40, 0);
        p.process(&bytes[..cut]);
        p.process(&bytes[cut..]);
        assert_eq!(p.screen().cursor_position().1, 2,
            "byte split at offset {cut} must still yield 2 columns");
    }
}

#[test]
fn promotion_holds_when_text_follows_in_a_later_chunk() {
    let p = parse(&[ASTERISK, VS16, "A"]);
    assert_eq!(p.screen().cell(0, 2).map(|c| c.contents()), Some("A".to_string()).as_deref(),
        "text arriving in its own chunk still lands past the promoted cell");
}

// ---------------------------------------------------------------------------
// Promotion must not corrupt what it overwrites
// ---------------------------------------------------------------------------

#[test]
fn promotion_clears_the_continuation_of_a_clobbered_wide_glyph() {
    // Draw a wide CJK glyph at cols 1-2, then park the cursor back on col 0 and
    // write base+VS16 there. Promotion takes col 1, which was that glyph's base;
    // col 2 must not be left as an orphaned continuation.
    let mut p = vt100_psmux::Parser::new(4, 40, 0);
    p.process(" \u{4E00}".as_bytes()); // space, then CJK at cols 1-2
    p.process(b"\x1b[1;1H"); // home
    p.process(format!("{ASTERISK}{VS16}").as_bytes());

    let s = p.screen();
    assert!(s.cell(0, 0).unwrap().is_wide(), "emoji promoted at col 0");
    assert!(s.cell(0, 1).unwrap().is_wide_continuation(), "col 1 is the emoji continuation");
    let orphan = s.cell(0, 2).expect("cell 0,2 exists");
    assert!(!orphan.is_wide_continuation(),
        "col 2 must not stay a continuation of a glyph that no longer has a base");
}

#[test]
fn promotion_does_not_run_off_the_last_column() {
    // Base lands on the final column; there is no room for a continuation cell.
    // Whatever the emulator decides, it must not panic and the grid must stay sane.
    let mut p = vt100_psmux::Parser::new(4, 5, 0);
    p.process(format!("aaaa{ASTERISK}{VS16}").as_bytes());
    let s = p.screen();
    // 4 narrow cells then the emoji: nothing may be a continuation past the edge.
    for col in 0..5u16 {
        assert!(s.cell(0, col).is_some(), "cell 0,{col} must exist");
    }
}

// ---------------------------------------------------------------------------
// Round trip through the serialisers
// ---------------------------------------------------------------------------

#[test]
fn contents_and_formatted_round_trip_the_sequence() {
    let p = parse(&[&format!("{ASTERISK}{VS16}AB")]);
    let s = p.screen();

    let text = s.contents();
    assert!(text.starts_with(&format!("{ASTERISK}{VS16}AB")),
        "screen contents must carry base+selector then AB, got {text:?}");

    // Replay contents_formatted into a fresh parser: the geometry must survive.
    let formatted = s.contents_formatted();
    let mut p2 = vt100_psmux::Parser::new(4, 40, 0);
    p2.process(&formatted);
    let s2 = p2.screen();
    assert!(s2.cell(0, 0).unwrap().is_wide(), "replayed emoji is still wide");
    assert!(s2.cell(0, 1).unwrap().is_wide_continuation(), "replayed continuation survives");
    assert_eq!(s2.cell(0, 2).map(|c| c.contents()), Some("A".to_string()).as_deref(),
        "replayed 'A' still sits on col 2");
}

// ---------------------------------------------------------------------------
// Regression guards: everything that was already correct must stay correct
// ---------------------------------------------------------------------------

#[test]
fn vs15_keeps_text_presentation_narrow() {
    assert_eq!(cursor_col_after(&format!("{ASTERISK}{VS15}")), 1,
        "VS15 asks for TEXT presentation, the cell must stay 1 column (tmux: 1)");
}

#[test]
fn bare_base_character_stays_narrow() {
    assert_eq!(cursor_col_after(ASTERISK), 1,
        "U+2733 on its own is Emoji_Presentation=No, 1 column (tmux: 1)");
}

#[test]
fn plain_wide_emoji_unchanged() {
    // The report notes rows with these were untouched: they are already wide.
    assert_eq!(cursor_col_after("\u{1F4DB}"), 2, "U+1F4DB is 2 columns");
    assert_eq!(cursor_col_after("\u{1F4C1}"), 2, "U+1F4C1 is 2 columns");
    // A plain emoji followed by a redundant VS16 must stay 2, not grow to 4.
    assert_eq!(cursor_col_after(&format!("\u{1F4DB}{VS16}")), 2,
        "already-wide emoji + VS16 must not double-promote");
}

#[test]
fn issue_441_combining_marks_still_zero_width() {
    // #533 is the same code path as #441 in the opposite direction. Promoting on
    // VS16 must not start widening ordinary combining marks.
    assert_eq!(cursor_col_after("\u{0E01}\u{0E48}"), 1, "Thai base + tone mark stays 1");
    assert_eq!(cursor_col_after("\u{0E01}\u{0E34}"), 1, "Thai base + above vowel stays 1");
    assert_eq!(cursor_col_after("\u{0627}\u{064E}"), 1, "Arabic base + fatha stays 1");
    assert_eq!(cursor_col_after("e\u{0301}"), 1, "e + combining acute stays 1");
    assert_eq!(cursor_col_after("\u{4E00}"), 2, "CJK ideograph stays 2");
    assert_eq!(cursor_col_after("abc"), 3, "ascii sanity");
}

#[test]
fn keycap_and_zwj_sequences_do_not_regress() {
    // Keycap: digit + VS16 + U+20E3. The VS16 promotes the digit to wide, and the
    // enclosing keycap that follows must not widen it further.
    assert_eq!(cursor_col_after(&format!("1{VS16}\u{20E3}")), 2,
        "keycap sequence occupies 2 columns");
    // Family ZWJ sequence: each wide emoji is its own cell in a cell-based grid,
    // exactly as tmux stores it. Just assert we do not panic and stay monotonic.
    let col = cursor_col_after("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}");
    assert!(col >= 2, "ZWJ sequence must occupy at least 2 columns, got {col}");
}

#[test]
fn mixed_row_matches_the_reported_status_line_shape() {
    // The reported damage: a ten cell bar drawn after a VS16 emoji rendered across
    // eleven cells. Model that row and assert every column index.
    let row = format!("{ASTERISK}{VS16} 1234567890");
    let p = parse(&[&row]);
    let s = p.screen();
    assert!(s.cell(0, 0).unwrap().is_wide(), "col 0 emoji wide");
    assert!(s.cell(0, 1).unwrap().is_wide_continuation(), "col 1 continuation");
    assert_eq!(s.cell(0, 2).map(|c| c.contents()), Some(" ".to_string()).as_deref(), "col 2 space");
    for (i, ch) in "1234567890".chars().enumerate() {
        let col = 3 + i as u16;
        assert_eq!(
            s.cell(0, col).map(|c| c.contents()),
            Some(ch.to_string()).as_deref(),
            "bar digit {ch} must sit on col {col}"
        );
    }
    assert_eq!(s.cursor_position().1, 13, "row consumes 13 columns total");
}
