// Issue #589: "Undercurl style is not supported".
//
// The parser side lives in crates/vt100-psmux/tests/issue589_undercurl.rs.
// This file covers the psmux side of the pipeline:
//   * the extended style survives the ratatui `Modifier` bit smuggling,
//   * `PsmuxBackend`'s cell loop turns it into `CSI 4:N m` plus SGR 58,
//   * nothing bleeds into the cells that follow,
//   * the run JSON the client renders from carries `ul` / `ulc`,
//   * tmux's `double-underscore` / `curly-underscore` / `dotted-underscore` /
//     `dashed-underscore` style names and `us=` map onto the same thing
//     (tmux attributes.c:77-80, style.c:236).

use ratatui::buffer::{Buffer, Cell as RCell};
use ratatui::layout::Rect;
use ratatui::style::{Color as RColor, Modifier, Style};

use crate::platform::draw_cells;
use crate::rendering::{strip_ul_style, ul_style_of, with_underline, UL_STYLE_MASK};

fn render_cells(cells: &[(&'static str, Style)]) -> String {
    let mut buf = Buffer::empty(Rect::new(0, 0, cells.len() as u16, 1));
    for (i, (sym, style)) in cells.iter().enumerate() {
        let mut c = RCell::new(sym);
        c.set_style(*style);
        buf[(i as u16, 0)] = c;
    }
    let content: Vec<(u16, u16, &RCell)> =
        (0..cells.len() as u16).map(|x| (x, 0u16, &buf[(x, 0)])).collect();
    let mut out: Vec<u8> = Vec::new();
    draw_cells(&mut out, content.into_iter()).unwrap();
    String::from_utf8(out).unwrap()
}

// ─── modifier smuggling ─────────────────────────────────────────────────────

#[test]
fn smuggled_bits_round_trip_and_never_reach_ratatui() {
    for ul in 1u8..=5 {
        let s = with_underline(Style::default(), ul, None);
        let m = s.add_modifier;
        assert!(m.contains(Modifier::UNDERLINED), "ul={ul} lost UNDERLINED");
        assert_eq!(ul_style_of(m).max(1), ul, "ul={ul} did not round trip");
        // Everything ratatui itself defines must be untouched.
        assert_eq!(strip_ul_style(m), Modifier::UNDERLINED, "ul={ul} leaked bits");
    }
    // The smuggled bits live above every ratatui flag.
    assert_eq!(UL_STYLE_MASK & Modifier::all().bits(), 0);
}

#[test]
fn underline_style_zero_adds_nothing() {
    let s = with_underline(Style::default(), 0, None);
    assert_eq!(s.add_modifier, Modifier::empty());
}

// ─── the bytes the client writes to the outer terminal ──────────────────────

#[test]
fn draw_emits_the_sgr_4_subparameter_forms() {
    for (ul, want) in [(2u8, "\x1b[4:2m"), (3, "\x1b[4:3m"), (4, "\x1b[4:4m"), (5, "\x1b[4:5m")] {
        let out = render_cells(&[("X", with_underline(Style::default(), ul, None))]);
        assert!(out.contains(want), "ul={ul}: {want:?} missing from {out:?}");
    }
}

#[test]
fn draw_emits_plain_sgr_4_for_a_single_underline() {
    let out = render_cells(&[("X", with_underline(Style::default(), 1, None))]);
    assert!(out.contains("\x1b[4m"), "{out:?}");
    assert!(!out.contains("4:"), "single underline must not be a styled one: {out:?}");
}

#[test]
fn draw_emits_the_underline_colour() {
    let style = with_underline(Style::default(), 3, Some(RColor::Rgb(255, 0, 0)));
    let out = render_cells(&[("X", style)]);
    assert!(out.contains("\x1b[4:3m"), "{out:?}");
    // Colon form on purpose: the Windows system conhost mis-parses the
    // semicolon form crossterm would emit (see write_underline_color).
    assert!(out.contains("\x1b[58:2::255:0:0m"), "{out:?}");
    assert!(!out.contains("58;2"), "semicolon form must not be used: {out:?}");
}

#[test]
fn draw_does_not_bleed_the_style_into_plain_cells() {
    let curly = with_underline(Style::default(), 3, Some(RColor::Rgb(255, 0, 0)));
    let out = render_cells(&[("A", curly), ("B", Style::default())]);
    let after_a = &out[out.find('A').unwrap()..];
    // Between A and B the underline must be switched off and the underline
    // colour reset, otherwise B is drawn with a red curl.
    assert!(after_a.contains("\x1b[24m"), "no SGR 24 before B: {out:?}");
    assert!(after_a.contains("\x1b[59m"),
        "underline colour not reset before B: {out:?}");
}

#[test]
fn draw_downgrades_a_curl_to_a_plain_line_between_cells() {
    let curly = with_underline(Style::default(), 3, None);
    let plain = with_underline(Style::default(), 1, None);
    let out = render_cells(&[("A", curly), ("B", plain)]);
    let after_a = &out[out.find('A').unwrap()..];
    assert!(after_a.contains("\x1b[4m"), "no plain SGR 4 before B: {out:?}");
}

#[test]
fn draw_switches_between_two_styled_underlines() {
    let out = render_cells(&[
        ("A", with_underline(Style::default(), 3, None)),
        ("B", with_underline(Style::default(), 5, None)),
    ]);
    let after_a = &out[out.find('A').unwrap()..];
    assert!(after_a.contains("\x1b[4:5m"), "{out:?}");
}

// ─── the run JSON the attached client renders from ──────────────────────────

#[test]
fn serialize_screen_rows_carries_the_style_and_colour() {
    let mut parser = vt100::Parser::new(3, 20, 0);
    parser.process(b"\x1b[4:3m\x1b[58;2;255;0;0mAB\x1b[0mCD");
    let rows = crate::layout::serialize_screen_rows(parser.screen(), 3, 20);
    let runs = &rows[0].runs;
    let first = &runs[0];
    assert_eq!(first.text, "AB", "runs: {:?}", runs.iter().map(|r| &r.text).collect::<Vec<_>>());
    assert_eq!(first.ul, 3);
    assert_eq!(first.ulc.as_deref(), Some("rgb:255,0,0"));
    assert_eq!(crate::style::map_color("rgb:255,0,0"), RColor::Rgb(255, 0, 0), "ulc must round trip through map_color");
    assert_eq!(first.flags & 8, 8, "FLAG_UNDERLINE must stay set for old clients");
    let second = &runs[1];
    assert!(second.text.starts_with("CD"));
    assert_eq!(second.ul, 0);
    assert_eq!(second.ulc, None);
}

#[test]
fn a_style_change_alone_breaks_the_run() {
    let mut parser = vt100::Parser::new(3, 20, 0);
    parser.process(b"\x1b[4:3mA\x1b[4:5mB");
    let rows = crate::layout::serialize_screen_rows(parser.screen(), 3, 20);
    assert_eq!(rows[0].runs[0].text, "A");
    assert_eq!(rows[0].runs[0].ul, 3);
    assert_eq!(rows[0].runs[1].text, "B");
    assert_eq!(rows[0].runs[1].ul, 5);
}

// ─── tmux style names ───────────────────────────────────────────────────────

#[test]
fn tmux_styled_underscore_names_are_honoured() {
    for (name, want) in [
        ("double-underscore", 2u8),
        ("curly-underscore", 3),
        ("dotted-underscore", 4),
        ("dashed-underscore", 5),
        ("underscore", 1),
    ] {
        let s = crate::style::parse_tmux_style(name);
        assert!(s.add_modifier.contains(Modifier::UNDERLINED), "{name}");
        assert_eq!(ul_style_of(s.add_modifier).max(1), want, "{name}");
    }
}

#[test]
fn us_sets_the_underscore_colour() {
    let s = crate::style::parse_tmux_style("curly-underscore,us=red");
    assert_eq!(ul_style_of(s.add_modifier), 3);
    assert_eq!(s.underline_color, Some(RColor::Red));
}

#[test]
fn nounderscore_clears_the_extended_style_too() {
    let s = crate::style::parse_tmux_style("curly-underscore,nounderscore");
    assert!(!s.add_modifier.contains(Modifier::UNDERLINED));
    assert_eq!(ul_style_of(s.add_modifier), 0);
}

#[test]
fn indexed_underline_colour_uses_the_colon_form() {
    let style = with_underline(Style::default(), 3, Some(RColor::Indexed(9)));
    let out = render_cells(&[("X", style)]);
    assert!(out.contains("\x1b[58:5:9m"), "{out:?}");
    assert!(!out.contains("58;5;9"), "semicolon form must not be used: {out:?}");
}
