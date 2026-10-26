// psmux issue #641: scrollback rows used to be kept dense at the pane's full
// width, so history cost `history_limit * cols * 44` bytes no matter how little
// text the lines held.  A row is now compacted to its used width when it leaves
// the visible grid, which is what tmux does: `grid_expand_line` (grid.c:564)
// only ever grows a line as far as the column actually written, and
// `grid_scroll_history` compacts the line as it becomes history (grid.c:508),
// while `grid_get_cell` serves `grid_default_cell` for anything past the stored
// data (grid.c:650).
//
// These tests pin the two halves of that: the memory really does shrink, and
// every read path still sees exactly what it saw when rows were dense.

use rand::RngExt as _;

fn parser(rows: u16, cols: u16, scrollback: usize) -> vt100_psmux::Parser {
    vt100_psmux::Parser::new(rows, cols, scrollback)
}

/// Feed `n` lines of `text` and let them all scroll into history.
fn flood(p: &mut vt100_psmux::Parser, n: usize, text: &str) {
    for _ in 0..n {
        p.process(text.as_bytes());
        p.process(b"\r\n");
    }
}

// ---------------------------------------------------------------------------
// memory
// ---------------------------------------------------------------------------

#[test]
fn scrollback_row_is_compacted_to_its_used_width() {
    // A 500 column pane holding 20 character lines must not pay for 500 cells.
    let mut p = parser(5, 500, 1000);
    flood(&mut p, 50, "01234567890123456789");

    let screen = p.screen();
    assert!(screen.scrollback_filled() >= 40, "lines should have scrolled");

    let cell = std::mem::size_of::<vt100_psmux::Cell>();
    let bytes = screen.history_bytes();
    let rows = screen.scrollback_filled();
    let per_row = bytes / rows;

    // 20 cells of text plus the per row bookkeeping, nowhere near 500 cells.
    assert!(
        per_row < 40 * cell,
        "compacted row should cost about 20 cells, got {per_row} bytes per row \
         ({cell} bytes per cell)"
    );
    // And prove the old model would have been far worse.
    assert!(
        per_row * 5 < 500 * cell,
        "compaction should be at least a 5x win at 500 columns, \
         got {per_row} bytes per row"
    );
}

#[test]
fn fully_blank_scrollback_row_costs_no_cells() {
    let mut p = parser(5, 500, 1000);
    // Nothing but newlines: every scrolled row is blank.
    for _ in 0..50 {
        p.process(b"\r\n");
    }
    let screen = p.screen();
    let rows = screen.scrollback_filled();
    assert!(rows >= 40, "blank lines should still scroll into history");

    let row_overhead = screen.history_bytes() / rows;
    // Only the Row struct itself remains; no cell storage at all.
    assert!(
        row_overhead < std::mem::size_of::<vt100_psmux::Cell>(),
        "a blank history row should cost less than one cell, got {row_overhead}"
    );
}

#[test]
fn a_row_erased_to_a_non_default_background_is_not_dropped() {
    // Compaction may only drop cells indistinguishable from the blank cell.  A
    // cell erased under a background colour is not, so it has to survive.
    let mut p = parser(3, 40, 100);
    p.process(b"\x1b[41m\x1b[2J"); // erase the screen to red
    p.process(b"\r\n\r\n\r\n\r\n\r\n");

    let screen = p.screen();
    assert!(screen.scrollback_filled() > 0);
    // The red background has to still be there in the scrolled-back view.
    let mut p2 = p;
    p2.screen_mut().set_scrollback(3);
    let cell = p2.screen().cell(0, 39).unwrap();
    assert_eq!(
        cell.bgcolor(),
        vt100_psmux::Color::Idx(1),
        "a background-coloured blank cell must not be compacted away"
    );
}

// ---------------------------------------------------------------------------
// read paths: dense vs compacted must be indistinguishable
// ---------------------------------------------------------------------------

/// Build the same content twice, once with a scrollback (rows get compacted on
/// eviction) and once with the rows still in the visible grid (dense), and
/// compare what every reader sees.
fn dense_and_compacted(
    cols: u16,
    lines: &[String],
) -> (vt100_psmux::Parser, vt100_psmux::Parser) {
    // Tall enough that nothing scrolls off even when every line wraps several
    // times: this is the dense reference, and with scrollback_len 0 anything
    // that did scroll off would be lost and break the comparison.
    let tall = u16::try_from(lines.len() * 12 + 8).unwrap();
    let mut dense = parser(tall, cols, 0);
    // Short, so everything but the last rows is compacted history.
    let mut compacted = parser(3, cols, 10_000);
    for line in lines {
        for p in [&mut dense, &mut compacted] {
            p.process(line.as_bytes());
            p.process(b"\r\n");
        }
    }
    (dense, compacted)
}

#[test]
fn capture_of_compacted_history_matches_the_dense_rows() {
    let lines: Vec<String> = (0..40)
        .map(|i| format!("\x1b[3{}mline {i} \x1b[1mbold\x1b[m tail", i % 8))
        .collect();
    let (dense, mut compacted) = dense_and_compacted(200, &lines);

    // Scroll the compacted parser back so its history is the visible region.
    compacted.screen_mut().set_scrollback(40);

    let dense_rows: Vec<String> = dense.screen().rows(0, 200).collect();
    let compacted_rows: Vec<String> = compacted.screen().rows(0, 200).collect();

    // The compacted view is a window onto the same text; every one of its rows
    // must appear verbatim in the dense rendering.
    for row in &compacted_rows {
        if row.is_empty() {
            continue;
        }
        assert!(
            dense_rows.contains(row),
            "compacted history row {row:?} is not in the dense rendering"
        );
    }
    // And the escape-code rendering has to agree too, byte for byte.
    let dense_fmt: Vec<Vec<u8>> = dense.screen().rows_formatted(0, 200).collect();
    let compacted_fmt: Vec<Vec<u8>> =
        compacted.screen().rows_formatted(0, 200).collect();
    for row in &compacted_fmt {
        if row.is_empty() {
            continue;
        }
        assert!(
            dense_fmt.contains(row),
            "compacted formatted row {:?} is not in the dense rendering",
            String::from_utf8_lossy(row)
        );
    }
}

#[test]
fn wide_glyph_at_the_compaction_boundary_survives() {
    // The last thing on the line is a CJK glyph, so the row's final stored cell
    // is that glyph's continuation.  Compaction must keep both halves.
    let mut p = parser(3, 60, 100);
    for _ in 0..10 {
        p.process("ab\u{4f60}\u{597d}".as_bytes());
        p.process(b"\r\n");
    }
    p.screen_mut().set_scrollback(8);
    let screen = p.screen();
    let row: String = screen.rows(0, 60).next().unwrap();
    assert_eq!(row, "ab\u{4f60}\u{597d}", "wide glyphs lost at the boundary");

    // The continuation cell has to still be flagged, or the renderer would
    // advance the cursor by one column instead of two.
    assert!(screen.cell(0, 2).unwrap().is_wide());
    assert!(screen.cell(0, 3).unwrap().is_wide_continuation());
    assert!(screen.cell(0, 4).unwrap().is_wide());
    assert!(screen.cell(0, 5).unwrap().is_wide_continuation());
}

#[test]
fn reading_past_a_compacted_row_yields_blanks_not_a_panic() {
    // Copy mode selects by absolute column, so reads land well past a short
    // history row's stored end.  Those must read as blank cells and the
    // selection text must be the same as for a dense row.
    let mut p = parser(3, 400, 100);
    for i in 0..20 {
        p.process(format!("short {i}").as_bytes());
        p.process(b"\r\n");
    }
    p.screen_mut().set_scrollback(18);
    let screen = p.screen();

    for col in 0..400 {
        let cell = screen
            .cell(0, col)
            .unwrap_or_else(|| panic!("column {col} of a compacted row is missing"));
        if col >= 8 {
            assert!(
                !cell.has_contents(),
                "column {col} past the text should be blank"
            );
            assert_eq!(cell.fgcolor(), vt100_psmux::Color::Default);
            assert_eq!(cell.bgcolor(), vt100_psmux::Color::Default);
        }
    }
    // One past the row is still absent, exactly as before.
    assert!(screen.cell(0, 400).is_none());

    // A selection running off the end of the row is trailing-space trimmed the
    // same way a dense row's is.
    let sel = screen.contents_between(0, 0, 0, 400);
    assert_eq!(sel, "short 0");
}

#[test]
fn resize_after_compaction_leaves_history_readable() {
    // psmux does not reflow history on resize (tmux does), so the point here is
    // that a compacted row keeps rendering correctly at the width it was
    // written at, and a narrower pane clips it rather than panicking.
    let mut p = parser(3, 300, 200);
    for i in 0..30 {
        p.process(format!("row {i} with some text").as_bytes());
        p.process(b"\r\n");
    }
    let before: Vec<String> = {
        p.screen_mut().set_scrollback(25);
        p.screen().rows(0, 300).collect()
    };
    p.screen_mut().set_scrollback(0);

    for cols in [40u16, 500, 12, 300] {
        p.screen_mut().set_size(3, cols);
        p.screen_mut().set_scrollback(25);
        // Reading must not panic and must not invent characters.
        let rows: Vec<String> = p.screen().rows(0, cols).collect();
        for (i, row) in rows.iter().enumerate() {
            if let Some(orig) = before.get(i) {
                if !orig.is_empty() && !row.is_empty() {
                    assert!(
                        orig.starts_with(row.trim_end()) || orig == row,
                        "at {cols} cols, history row {row:?} does not match {orig:?}"
                    );
                }
            }
        }
        // The formatted rendering must not panic either.
        let _: Vec<Vec<u8>> = p.screen().rows_formatted(0, cols).collect();
        let _ = p.screen().contents_formatted();
        p.screen_mut().set_scrollback(0);
    }
}

#[test]
fn random_mutations_render_the_same_compacted_as_dense() {
    // Property style: throw random text, colours, erases, cursor moves, wide
    // glyphs and scroll regions at two parsers of the same width, one whose
    // rows end up compacted in history and one whose rows stay dense in the
    // visible grid, and require the same text out of both.
    let mut rng = rand::rng();
    let glyphs = [
        "a", "Z", "9", " ", "\u{4f60}", "\u{597d}", "\u{e9}", "\u{1f600}",
    ];

    for _ in 0..200 {
        let mut lines = Vec::new();
        for _ in 0..rng.random_range(5..25) {
            let mut line = String::new();
            for _ in 0..rng.random_range(0..30) {
                match rng.random_range(0..10) {
                    0 => line.push_str("\x1b[31m"),
                    1 => line.push_str("\x1b[1;44m"),
                    2 => line.push_str("\x1b[m"),
                    3 => line.push_str("\x1b[K"),
                    4 => line.push_str("\x1b[3C"),
                    _ => line.push_str(glyphs[rng.random_range(0..glyphs.len())]),
                }
            }
            lines.push(line);
        }

        let cols: u16 = rng.random_range(10..120);
        let (dense, mut compacted) = dense_and_compacted(cols, &lines);
        compacted.screen_mut().set_scrollback(lines.len());

        let dense_rows: Vec<String> = dense.screen().rows(0, cols).collect();
        let compacted_rows: Vec<String> = compacted.screen().rows(0, cols).collect();
        for row in &compacted_rows {
            if row.is_empty() {
                continue;
            }
            assert!(
                dense_rows.contains(row),
                "compacted row {row:?} absent from dense rows {dense_rows:?} \
                 at {cols} cols"
            );
        }
    }
}

#[test]
fn history_bytes_tracks_text_not_pane_width() {
    // The whole point of the fix: the same text costs the same whether the pane
    // is narrow or very wide.
    let text = "0123456789";
    let mut narrow = parser(3, 40, 500);
    let mut wide = parser(3, 1000, 500);
    flood(&mut narrow, 100, text);
    flood(&mut wide, 100, text);

    let narrow_bytes = narrow.screen().history_bytes();
    let wide_bytes = wide.screen().history_bytes();
    assert_eq!(
        narrow_bytes, wide_bytes,
        "history cost must not depend on pane width \
         (narrow {narrow_bytes}, wide {wide_bytes})"
    );
}

#[test]
fn alt_screen_exit_pushes_compacted_rows() {
    // The other eviction point: the alt-screen-to-scrollback copy (issue #88).
    // That copy only runs with `alternate-screen off`, which is the whole
    // reason the option exists, so turn it off first.
    let mut p = parser(5, 400, 500);
    p.screen_mut().set_allow_alternate_screen(false);
    p.process(b"\x1b[?1049h"); // enter alt screen
    p.process(b"tui line one\r\ntui line two");
    p.process(b"\x1b[?1049l"); // leave, copying the alt rows into history

    let screen = p.screen();
    let rows = screen.scrollback_filled();
    assert!(rows >= 2, "alt screen rows should have reached history");
    let per_row = screen.history_bytes() / rows;
    assert!(
        per_row < 60 * std::mem::size_of::<vt100_psmux::Cell>(),
        "alt screen rows reached history uncompacted: {per_row} bytes per row"
    );

    let mut p = p;
    p.screen_mut().set_scrollback(rows);
    let text: Vec<String> = p.screen().rows(0, 400).collect();
    assert!(
        text.iter().any(|r| r == "tui line one"),
        "alt screen text lost: {text:?}"
    );
}
