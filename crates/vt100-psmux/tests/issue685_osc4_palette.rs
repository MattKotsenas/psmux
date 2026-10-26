// Issue #685: "Pane OSC 4 palette sets are dropped, so record based apps like
// Far paint with the outer terminal's scheme instead of their own".
//
// A pane child on ConPTY announces its console colour table as OSC 4 palette
// sets (Far's pane emits all 512 entries, the low sixteen being the classic
// console table, index 4 = #000080, 6 = #008080, 14 = #00FFFF) and then paints
// with indexed SGR.  The parser had no OSC 4 arm, so every one of those sets
// fell through to `unhandled_osc` and the indexes meant whatever the outer
// terminal's scheme said, which is why Far's panels came out Campbell
// #0037DA instead of #000080.
//
// tmux parity:
//   * `input.c:2733`  OSC dispatch sends option 4 to `input_osc_4`
//   * `input.c:2927`  `input_osc_4` parses `<idx>;<colour>` pairs, several per
//                     sequence, stops on a bad index, skips a bad colour
//   * `input.c:2963`  each good pair goes to `colour_palette_set`
//   * `input.c:3446`  `input_osc_104` resets one index, several, or all
//   * `input.c:1407`  RIS clears the palette
//   * `colour.c:1176` `colour_parseX11` accepts `rgb:`, `#`, and decimal forms

use vt100_psmux as vt100;

fn parse(bytes: &[u8]) -> vt100::Parser {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser
}

// ---- OSC 4 set forms ----------------------------------------------------

#[test]
fn osc4_rgb_two_digit_sets_entry() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\");
    assert_eq!(p.screen().palette_entry(4), Some((0, 0, 128)));
}

#[test]
fn osc4_bel_terminated_sets_entry() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x07");
    assert_eq!(p.screen().palette_entry(4), Some((0, 0, 128)));
}

#[test]
fn osc4_rgb_four_digit_scales_to_eight_bits() {
    let p = parse(b"\x1b]4;6;rgb:0000/8080/8080\x1b\\");
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
}

#[test]
fn osc4_rgb_one_digit_scales_like_xterm() {
    // A single digit is a fraction of 0xf, so 8 becomes 0x88.
    let p = parse(b"\x1b]4;1;rgb:8/0/0\x1b\\");
    assert_eq!(p.screen().palette_entry(1), Some((0x88, 0, 0)));
}

#[test]
fn osc4_hash_rrggbb_sets_entry() {
    let p = parse(b"\x1b]4;14;#00FFFF\x1b\\");
    assert_eq!(p.screen().palette_entry(14), Some((0, 255, 255)));
}

#[test]
fn osc4_hash_rgb_short_form_sets_entry() {
    let p = parse(b"\x1b]4;2;#0f0\x1b\\");
    assert_eq!(p.screen().palette_entry(2), Some((0, 255, 0)));
}

#[test]
fn osc4_decimal_triple_sets_entry() {
    let p = parse(b"\x1b]4;3;128,128,0\x1b\\");
    assert_eq!(p.screen().palette_entry(3), Some((128, 128, 0)));
}

#[test]
fn osc4_multiple_pairs_in_one_sequence() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80;6;rgb:00/80/80;14;rgb:00/ff/ff\x1b\\");
    assert_eq!(p.screen().palette_entry(4), Some((0, 0, 128)));
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
    assert_eq!(p.screen().palette_entry(14), Some((0, 255, 255)));
}

#[test]
fn osc4_reaches_the_high_indexes_too() {
    let p = parse(b"\x1b]4;255;rgb:12/34/56\x1b\\");
    assert_eq!(p.screen().palette_entry(255), Some((0x12, 0x34, 0x56)));
}

#[test]
fn osc4_index_above_255_is_rejected() {
    let p = parse(b"\x1b]4;256;rgb:00/00/80\x1b\\");
    assert!(p.screen().colour_palette().is_none());
}

#[test]
fn osc4_unparseable_colour_is_skipped_not_fatal() {
    // tmux continues to the next pair when colour_parseX11 fails.
    let p = parse(b"\x1b]4;4;notacolour;6;rgb:00/80/80\x1b\\");
    assert_eq!(p.screen().palette_entry(4), None);
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
}

#[test]
fn osc4_bad_index_stops_the_sequence() {
    // tmux sets bad = 1 and breaks, so nothing after the bad index is taken.
    let p = parse(b"\x1b]4;zz;rgb:00/00/80;6;rgb:00/80/80\x1b\\");
    assert_eq!(p.screen().palette_entry(6), None);
}

#[test]
fn osc4_conhost_style_burst_sets_the_whole_low_table() {
    // The shape Far's pane really emits: one OSC 4 per entry, back to back.
    let mut bytes = Vec::new();
    for i in 0..16u16 {
        bytes.extend_from_slice(
            format!("\x1b]4;{};rgb:{:02x}/00/00\x1b\\", i, i).as_bytes(),
        );
    }
    let p = parse(&bytes);
    for i in 0..16u8 {
        assert_eq!(p.screen().palette_entry(i), Some((i, 0, 0)), "index {i}");
    }
}

// ---- OSC 4 query form ---------------------------------------------------

#[test]
fn osc4_query_does_not_disturb_the_entry() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b]4;4;?\x1b\\");
    assert_eq!(p.screen().palette_entry(4), Some((0, 0, 128)));
}

#[test]
fn osc4_query_alone_sets_nothing() {
    let p = parse(b"\x1b]4;4;?\x1b\\");
    assert!(p.screen().colour_palette().is_none());
}

#[test]
fn osc4_query_then_set_in_one_sequence() {
    let p = parse(b"\x1b]4;4;?;6;rgb:00/80/80\x1b\\");
    assert_eq!(p.screen().palette_entry(4), None);
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
}

// ---- OSC 104 reset ------------------------------------------------------

#[test]
fn osc104_with_index_clears_just_that_entry() {
    let p = parse(
        b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b]4;6;rgb:00/80/80\x1b\\\x1b]104;4\x1b\\",
    );
    assert_eq!(p.screen().palette_entry(4), None);
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
}

#[test]
fn osc104_with_several_indexes_clears_each() {
    let p = parse(
        b"\x1b]4;4;rgb:00/00/80;6;rgb:00/80/80;14;rgb:00/ff/ff\x1b\\\x1b]104;4;14\x1b\\",
    );
    assert_eq!(p.screen().palette_entry(4), None);
    assert_eq!(p.screen().palette_entry(6), Some((0, 128, 128)));
    assert_eq!(p.screen().palette_entry(14), None);
}

#[test]
fn osc104_bare_clears_everything() {
    // NOTE: conhost swallows a bare OSC 104 on the ConPTY output path, so this
    // form is only reachable from a pane that is not behind ConPTY.  Measured
    // on Windows 11 26200: `\e]104;4\e\\` arrives, `\e]104\e\\` does not.
    let p = parse(b"\x1b]4;4;rgb:00/00/80;6;rgb:00/80/80\x1b\\\x1b]104\x1b\\");
    assert!(p.screen().colour_palette().is_none());
}

#[test]
fn osc104_with_empty_payload_clears_everything() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b]104;\x1b\\");
    assert!(p.screen().colour_palette().is_none());
}

#[test]
fn ris_clears_the_palette() {
    // tmux input.c:1407 clears the palette on RIS.
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1bc");
    assert!(p.screen().colour_palette().is_none());
}

// ---- resolution ---------------------------------------------------------

#[test]
fn indexed_cell_resolves_through_the_palette() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[44mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(cell.bgcolor(), vt100::Color::Idx(4));
    assert_eq!(
        p.screen().resolve_colour(cell.bgcolor()),
        vt100::Color::Rgb(0, 0, 128)
    );
}

#[test]
fn sgr_38_5_n_resolves_through_the_same_entry() {
    let p = parse(b"\x1b]4;14;rgb:00/ff/ff\x1b\\\x1b[38;5;14mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(
        p.screen().resolve_colour(cell.fgcolor()),
        vt100::Color::Rgb(0, 255, 255)
    );
}

#[test]
fn an_index_with_no_entry_is_left_alone() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[46mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(
        p.screen().resolve_colour(cell.bgcolor()),
        vt100::Color::Idx(6)
    );
}

#[test]
fn a_true_colour_cell_is_never_rewritten() {
    let p = parse(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[48;2;1;2;3mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(
        p.screen().resolve_colour(cell.bgcolor()),
        vt100::Color::Rgb(1, 2, 3)
    );
}

#[test]
fn the_default_colour_is_never_rewritten() {
    let p = parse(b"\x1b]4;0;rgb:11/22/33\x1b\\X");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(cell.bgcolor(), vt100::Color::Default);
    assert_eq!(
        p.screen().resolve_colour(cell.bgcolor()),
        vt100::Color::Default
    );
}

#[test]
fn a_pane_with_no_palette_resolves_to_itself() {
    let p = parse(b"\x1b[44m\x1b[38;5;14mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert!(p.screen().colour_palette().is_none());
    assert_eq!(
        p.screen().resolve_colour(cell.bgcolor()),
        vt100::Color::Idx(4)
    );
    assert_eq!(
        p.screen().resolve_colour(cell.fgcolor()),
        vt100::Color::Idx(14)
    );
}

#[test]
fn underline_colour_resolves_too() {
    // tmux applies the palette to SGR 58 as well, in tty_check_us (tty.c:2945).
    let p = parse(b"\x1b]4;5;rgb:80/00/80\x1b\\\x1b[4:3m\x1b[58;5;5mX");
    let cell = p.screen().cell(0, 0).unwrap();
    assert_eq!(
        p.screen().resolve_colour(cell.underline_color()),
        vt100::Color::Rgb(128, 0, 128)
    );
}

#[test]
fn the_palette_survives_a_resize() {
    let mut p = vt100::Parser::new(5, 80, 0);
    p.process(b"\x1b]4;4;rgb:00/00/80\x1b\\");
    p.screen_mut().set_size(10, 40);
    assert_eq!(p.screen().palette_entry(4), Some((0, 0, 128)));
}

#[test]
fn the_generation_moves_only_on_a_real_change() {
    let mut p = vt100::Parser::new(5, 80, 0);
    let g0 = p.screen().palette_generation();
    p.process(b"\x1b]4;4;rgb:00/00/80\x1b\\");
    let g1 = p.screen().palette_generation();
    assert_ne!(g0, g1);
    // Setting the same value again is not a change.
    p.process(b"\x1b]4;4;rgb:00/00/80\x1b\\");
    assert_eq!(p.screen().palette_generation(), g1);
    p.process(b"\x1b]104;4\x1b\\");
    assert_ne!(p.screen().palette_generation(), g1);
}

// ---- the spec parser in isolation --------------------------------------

#[test]
fn parse_x11_colour_accepts_the_forms_tmux_accepts() {
    assert_eq!(vt100::parse_x11_colour(b"rgb:00/00/80"), Some((0, 0, 128)));
    assert_eq!(
        vt100::parse_x11_colour(b"rgb:0000/0000/8080"),
        Some((0, 0, 128))
    );
    assert_eq!(vt100::parse_x11_colour(b"RGB:00/00/80"), Some((0, 0, 128)));
    assert_eq!(vt100::parse_x11_colour(b"#000080"), Some((0, 0, 128)));
    assert_eq!(vt100::parse_x11_colour(b"#00000000 8080"), None);
    assert_eq!(vt100::parse_x11_colour(b"0,0,128"), Some((0, 0, 128)));
    assert_eq!(vt100::parse_x11_colour(b"  #000080  "), Some((0, 0, 128)));
}

#[test]
fn parse_x11_colour_rejects_junk() {
    assert_eq!(vt100::parse_x11_colour(b""), None);
    assert_eq!(vt100::parse_x11_colour(b"?"), None);
    assert_eq!(vt100::parse_x11_colour(b"blue"), None);
    assert_eq!(vt100::parse_x11_colour(b"rgb:00/00"), None);
    assert_eq!(vt100::parse_x11_colour(b"rgb:00/00/80/40"), None);
    assert_eq!(vt100::parse_x11_colour(b"rgb:zz/00/80"), None);
    assert_eq!(vt100::parse_x11_colour(b"#00008"), None);
    assert_eq!(vt100::parse_x11_colour(b"300,0,0"), None);
}

#[test]
fn parse_palette_index_matches_tmux_bounds() {
    assert_eq!(vt100::parse_palette_index(b"0"), Some(0));
    assert_eq!(vt100::parse_palette_index(b"255"), Some(255));
    assert_eq!(vt100::parse_palette_index(b"256"), None);
    assert_eq!(vt100::parse_palette_index(b""), None);
    assert_eq!(vt100::parse_palette_index(b"-1"), None);
    assert_eq!(vt100::parse_palette_index(b"4x"), None);
}
