// Discussion #749: tmux folds an emoji cluster (a ZWJ sequence, a skin tone
// modifier sequence, a regional indicator pair, an emoji followed by U+FE0F)
// into ONE cell of TWO columns, which is what seven of the eight measured
// Windows terminals draw (mintty is the outlier and draws the parts apart).
// psmux used to give every wide member of the cluster its own cell, so the
// child believed in two columns while the grid spent four or eight.
//
// Parity oracle (tmux 3.7c, cursor_x after writing the sequence to a fresh
// pane), see tmux utf8-combined.c utf8_should_combine and screen-write.c
// screen_write_cell:
//   U+0041                                        -> 1
//   U+3042                                        -> 2
//   U+2764                                        -> 1
//   U+2764 U+FE0F                                 -> 2
//   U+2733 U+FE0F                                 -> 2
//   U+1F44D                                       -> 2
//   U+1F44D U+1F3FD                               -> 2
//   U+1F1EF U+1F1F5                               -> 2
//   U+1F3F3 U+FE0F U+200D U+1F308                 -> 2
//   U+1F468 U+200D U+1F469 U+200D U+1F467 U+200D U+1F466 -> 2

fn parse(cols: u16, chunks: &[&str]) -> vt100_psmux::Parser {
    let mut p = vt100_psmux::Parser::new(4, cols, 0);
    for c in chunks {
        p.process(c.as_bytes());
    }
    p
}

fn cursor_col_after(s: &str) -> u16 {
    parse(40, &[s]).screen().cursor_position().1
}

const SEQUENCES: [(&str, &str, u16); 10] = [
    ("A", "\u{0041}", 1),
    ("hiragana a", "\u{3042}", 2),
    ("heart", "\u{2764}", 1),
    ("heart VS16", "\u{2764}\u{FE0F}", 2),
    ("asterisk VS16", "\u{2733}\u{FE0F}", 2),
    ("thumbs up", "\u{1F44D}", 2),
    ("thumbs up skin tone", "\u{1F44D}\u{1F3FD}", 2),
    ("flag JP", "\u{1F1EF}\u{1F1F5}", 2),
    ("rainbow flag", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", 2),
    (
        "family",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
        2,
    ),
];

const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";

#[test]
fn ten_sequences_match_tmux_cursor_columns() {
    let got: Vec<u16> = SEQUENCES.iter().map(|(_, s, _)| cursor_col_after(s)).collect();
    let want: Vec<u16> = SEQUENCES.iter().map(|(_, _, w)| *w).collect();
    println!("psmux cursor columns: {got:?}");
    println!("tmux  cursor columns: {want:?}");
    assert_eq!(got, want, "cursor columns must match tmux 3.7c");
}

#[test]
fn every_cluster_is_one_cell_and_text_follows_on_col_2() {
    for (name, s, w) in SEQUENCES.iter().filter(|(_, _, w)| *w == 2) {
        let p = parse(40, &[&format!("{s}X")]);
        let scr = p.screen();
        let base = scr.cell(0, 0).unwrap();
        assert_eq!(base.contents(), *s, "{name}: cell 0 holds the whole cluster");
        assert!(base.is_wide(), "{name}: cluster cell is wide");
        assert!(scr.cell(0, 1).unwrap().is_wide_continuation(), "{name}: col 1 continuation");
        assert_eq!(scr.cell(0, *w).unwrap().contents(), "X", "{name}: X lands on col 2");
    }
}

#[test]
fn clusters_survive_every_chunk_boundary() {
    for (name, s, w) in SEQUENCES.iter() {
        let bytes = s.as_bytes();
        for cut in 1..bytes.len() {
            let mut p = vt100_psmux::Parser::new(4, 40, 0);
            p.process(&bytes[..cut]);
            p.process(&bytes[cut..]);
            assert_eq!(p.screen().cursor_position().1, *w, "{name}: byte split at {cut}");
            assert_eq!(p.screen().cell(0, 0).unwrap().contents(), *s, "{name}: split at {cut}");
        }
    }
}

// tmux: a ZWJ is zero width and folds into whatever cell came before it, a
// letter included, and a character after a cell ending in ZWJ joins that
// cell WITHOUT widening it (screen_write_combine only forces width 2 for
// should_combine pairs and VS16). So letter, ZWJ, boy stays one column in
// tmux 3.7c and the X after it lands on col 1.
#[test]
fn letter_followed_by_zwj_keeps_the_letter_cell_narrow() {
    let p = parse(40, &["a\u{200D}\u{1F466}X"]);
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().contents(), "a\u{200D}\u{1F466}", "all three in one cell");
    assert!(!s.cell(0, 0).unwrap().is_wide(), "the letter cell stays narrow");
    assert_eq!(s.cell(0, 1).unwrap().contents(), "X");
    assert_eq!(s.cursor_position().1, 2);
}

// A letter followed by ZWJ alone: the joiner folds into the letter.
#[test]
fn letter_followed_by_zwj_alone() {
    let p = parse(40, &["a\u{200D}"]);
    assert_eq!(p.screen().cell(0, 0).unwrap().contents(), "a\u{200D}");
    assert_eq!(p.screen().cursor_position().1, 1);
}

// Zero width characters at column 0 have nothing to combine with and tmux
// discards them.
#[test]
fn zero_width_at_column_0_is_discarded() {
    assert_eq!(cursor_col_after("\u{200D}\u{FE0F}\u{0301}"), 0);
    let p = parse(40, &["\u{200D}A"]);
    assert_eq!(p.screen().cell(0, 0).unwrap().contents(), "A");
}

// A skin tone modifier with nothing before it is an ordinary wide emoji.
#[test]
fn modifier_with_nothing_before_it_is_a_wide_cell() {
    assert_eq!(cursor_col_after("\u{1F3FD}"), 2);
    let p = parse(40, &["\u{1F3FD}X"]);
    assert_eq!(p.screen().cell(0, 0).unwrap().contents(), "\u{1F3FD}");
    assert_eq!(p.screen().cell(0, 2).unwrap().contents(), "X");
}

// A modifier after a narrow letter does not combine: tmux only combines into
// a width 2 cell, so the modifier stands as its own wide emoji.
#[test]
fn modifier_after_a_letter_stands_alone() {
    assert_eq!(cursor_col_after("a\u{1F3FD}"), 3);
}

// Three regional indicators: the first two pair into a flag, the third does
// not join the flag (tmux utf8_should_combine refuses a third indicator when
// the cell already holds a pair). A lone indicator is one column wide, as
// wcwidth has it, so the third takes one column and a fourth pairs with it.
#[test]
fn third_regional_indicator_starts_a_new_cell() {
    let p = parse(40, &["\u{1F1EF}\u{1F1F5}\u{1F1FA}"]);
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().contents(), "\u{1F1EF}\u{1F1F5}");
    assert_eq!(s.cell(0, 2).unwrap().contents(), "\u{1F1FA}");
    assert!(!s.cell(0, 2).unwrap().is_wide());
    assert_eq!(s.cursor_position().1, 3);
    let p = parse(40, &["\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}"]);
    assert_eq!(p.screen().cell(0, 2).unwrap().contents(), "\u{1F1FA}\u{1F1F8}");
    assert_eq!(p.screen().cursor_position().1, 4);
}

// A cluster longer than a cell can hold (tmux UTF8_SIZE, 32 bytes): tmux
// stops combining at the byte that would overflow. The zero width ZWJ that
// does not fit is discarded and the next emoji starts a new cell, which the
// rest of the sequence then joins through its own ZWJs.
//   cell 0: family ZWJ man                            (32 bytes)
//   cell 2: woman ZWJ girl ZWJ boy ZWJ man ZWJ woman  (32 bytes)
//   cell 4: girl ZWJ boy
#[test]
fn cluster_longer_than_a_cell_spills_like_tmux() {
    let long = format!("{FAMILY}\u{200D}{FAMILY}\u{200D}{FAMILY}");
    let p = parse(40, &[&format!("{long}X")]);
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().contents(), format!("{FAMILY}\u{200D}\u{1F468}"));
    assert_eq!(
        s.cell(0, 2).unwrap().contents(),
        "\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\u{200D}\u{1F468}\u{200D}\u{1F469}"
    );
    assert_eq!(s.cell(0, 4).unwrap().contents(), "\u{1F467}\u{200D}\u{1F466}");
    for col in [0, 2, 4] {
        assert!(s.cell(0, col).unwrap().is_wide(), "col {col} wide");
        assert!(s.cell(0, col + 1).unwrap().is_wide_continuation(), "col {} cont", col + 1);
    }
    assert_eq!(s.cell(0, 6).unwrap().contents(), "X");
    assert_eq!(s.cursor_position().1, 7);
}

// Cells holding clusters past the inline bytes still compare by text.
#[test]
fn long_clusters_compare_by_text() {
    let a = parse(40, &[FAMILY]);
    let b = parse(40, &[FAMILY]);
    assert_eq!(a.screen().cell(0, 0), b.screen().cell(0, 0));
    let other = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}\u{200D}\u{1F466}";
    let c = parse(40, &[other]);
    assert_ne!(a.screen().cell(0, 0), c.screen().cell(0, 0));
    assert_eq!(c.screen().cell(0, 0).unwrap().contents(), other);
    // Overwriting a long cluster with a plain character leaves no trace.
    let mut d = parse(40, &[FAMILY]);
    d.process(b"\x1b[1;1HZ");
    assert_eq!(d.screen().cell(0, 0).unwrap().contents(), "Z");
    assert!(!d.screen().cell(0, 0).unwrap().is_wide());
}

// A modifier BEFORE its emoji also combines: screen_write_combine tries
// utf8_should_combine in both orders.
#[test]
fn modifier_before_its_emoji_combines() {
    let p = parse(40, &["\u{1F3FD}\u{1F44D}X"]);
    assert_eq!(p.screen().cell(0, 0).unwrap().contents(), "\u{1F3FD}\u{1F44D}");
    assert_eq!(p.screen().cell(0, 2).unwrap().contents(), "X");
}

// Two skin tone modifiers do not combine with each other, and a modifier
// does not attach to an emoji outside tmux's table.
#[test]
fn modifier_outside_the_table_stands_alone() {
    assert_eq!(cursor_col_after("\u{1F3FD}\u{1F3FD}"), 4);
    assert_eq!(cursor_col_after("\u{1F4DB}\u{1F3FD}"), 4);
}

// The cluster arrives with its first emoji on the last column: the wide base
// wraps to the next row and the rest of the cluster follows it there.
#[test]
fn cluster_at_the_last_column_wraps_whole() {
    let p = parse(5, &[&format!("abcd{FAMILY}X")]);
    let s = p.screen();
    assert_eq!(s.cell(1, 0).unwrap().contents(), FAMILY, "family wrapped whole");
    assert!(s.cell(1, 1).unwrap().is_wide_continuation());
    assert_eq!(s.cell(1, 2).unwrap().contents(), "X");
    assert_eq!(s.cursor_position(), (1, 3));
}

// Text extraction (capture-pane, copy mode) must reproduce the original
// bytes of a combined cell, not just its first code point.
#[test]
fn text_extraction_reproduces_the_cluster_bytes() {
    let row = format!("{FAMILY} \u{1F44D}\u{1F3FD} \u{1F1EF}\u{1F1F5} \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}!");
    let p = parse(40, &[&row]);
    let s = p.screen();
    assert_eq!(s.contents().trim_end(), row);
    assert_eq!(s.rows(0, 40).next().unwrap().trim_end(), row);
    // The 2 + 1 + 2 + 1 + 2 + 1 + 2 + 1 columns of the row.
    assert_eq!(s.cursor_position().1, 12);
    // A copy mode style range read over the family cell alone.
    assert_eq!(s.contents_between(0, 0, 0, 2), FAMILY);

    let formatted = s.contents_formatted();
    let mut p2 = vt100_psmux::Parser::new(4, 40, 0);
    p2.process(&formatted);
    assert_eq!(p2.screen().contents().trim_end(), row, "formatted replay");
    assert_eq!(p2.screen().cursor_position().1, 12);
}

// `str_cells` is what a prompt counts with. It must give the cells the grid
// gives, start for start and width for width, so there is one opinion.
#[test]
fn str_cells_agrees_with_the_grid() {
    let long = format!("{FAMILY}\u{200D}{FAMILY}\u{200D}{FAMILY}");
    let mut cases: Vec<String> = SEQUENCES.iter().map(|(_, s, _)| (*s).to_string()).collect();
    cases.extend(
        [
            "a\u{200D}\u{1F466}X",
            "\u{1F3FD}\u{1F44D}",
            "\u{1F3FD}\u{1F3FD}",
            "\u{1F4DB}\u{FE0F}",
            "1\u{FE0F}\u{20E3}",
            "\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}\u{1F1FA}",
            "e\u{0301}\u{0E01}\u{0E48}",
            "\u{200D}A\u{3164}B",
            &long,
        ]
        .iter()
        .map(|s| (*s).to_string()),
    );
    for s in &cases {
        let p = parse(80, &[s]);
        let scr = p.screen();
        let mut grid: Vec<(String, usize)> = Vec::new();
        let mut col = 0u16;
        while col < scr.cursor_position().1 {
            let cell = scr.cell(0, col).unwrap();
            let w = if cell.is_wide() { 2 } else { 1 };
            grid.push((cell.contents().to_string(), w));
            col += u16::try_from(w).unwrap();
        }
        let cells = vt100_psmux::str_cells(s);
        let widths: Vec<usize> = cells.iter().map(|&(_, w)| w).collect();
        let grid_widths: Vec<usize> = grid.iter().map(|(_, w)| *w).collect();
        assert_eq!(widths, grid_widths, "{s:?}: str_cells widths vs grid");
        // Each cell's text in the grid begins with the character str_cells
        // says the cell starts on.
        for ((start, _), (text, _)) in cells.iter().zip(&grid) {
            assert_eq!(s[*start..].chars().next(), text.chars().next(), "{s:?}: cell at byte {start}");
        }
    }
}
