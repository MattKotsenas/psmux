// Issue #962: bold together with dim, and the overline, from a pane to the
// terminal the client draws on.
//
// The parser side lives in
// crates/vt100-psmux/tests/issue962_sgr_bold_dim_overline.rs.
// This file covers psmux:
//   * the run JSON carries both bold and dim, and the overline as `ol`,
//     written only when set,
//   * the overline survives the ratatui `Modifier` smuggling and never
//     reaches ratatui itself,
//   * `draw_cells` writes `CSI 53 m` and `CSI 55 m` around it, as tmux writes
//     Smol (tty.c:2757 at tag 3.8), and bold with dim as SGR 1 and 2.

use ratatui::buffer::{Buffer, Cell as RCell};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};

use crate::platform::draw_cells;
use crate::rendering::{overline_of, strip_ul_style, with_overline, OVERLINE_BIT};

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

fn runs_of(bytes: &[u8]) -> Vec<crate::layout::CellRunJson> {
    let mut parser = vt100::Parser::new(3, 20, 0);
    parser.process(bytes);
    crate::layout::serialize_screen_rows(parser.screen(), 3, 20).remove(0).runs
}

#[test]
fn the_overline_bit_round_trips_and_never_reaches_ratatui() {
    let style = with_overline(Style::default().add_modifier(Modifier::BOLD), true);
    assert!(overline_of(style.add_modifier));
    let stripped = strip_ul_style(style.add_modifier);
    assert_eq!(stripped, Modifier::BOLD, "only ratatui's own bits are left");
    assert_eq!(stripped.bits() & OVERLINE_BIT, 0);
    assert_eq!(with_overline(Style::default(), false), Style::default());
}

#[test]
fn draw_writes_53_and_55_around_an_overlined_cell() {
    let plain = Style::default();
    let over = with_overline(Style::default(), true);
    let out = render_cells(&[("a", plain), ("O", over), ("o", over), ("p", plain)]);
    let on = out.find("\x1b[53mO").unwrap_or_else(|| panic!("no 53 before O: {out:?}"));
    let off = out.find("\x1b[55mp").unwrap_or_else(|| panic!("no 55 before p: {out:?}"));
    assert!(on < off);
    assert_eq!(out.matches("\x1b[53m").count(), 1, "written once for the run: {out:?}");
    assert!(!out[..on].contains("53m"), "nothing before the overline: {out:?}");
}

#[test]
fn draw_writes_bold_and_dim_together() {
    let both = Style::default().add_modifier(Modifier::BOLD | Modifier::DIM);
    let bold = Style::default().add_modifier(Modifier::BOLD);
    let out = render_cells(&[("A", both), ("B", bold)]);
    let a = out.find('A').unwrap();
    assert!(out[..a].contains("\x1b[1m") && out[..a].contains("\x1b[2m"), "{out:?}");
    // Dim goes: 22 clears both, then bold again.
    let b = out.find('B').unwrap();
    assert!(out[a..b].contains("\x1b[22m") && out[a..b].contains("\x1b[1m"), "{out:?}");
}

#[test]
fn a_run_carries_bold_and_dim_together() {
    let runs = runs_of(b"\x1b[1;2mA\x1b[0mB");
    assert_eq!(runs[0].text, "A");
    assert_eq!(runs[0].flags & 3, 3, "FLAG_DIM | FLAG_BOLD");
    assert_eq!(runs[1].flags & 3, 0);
}

#[test]
fn a_run_carries_the_overline_and_only_when_set() {
    let runs = runs_of(b"a\x1b[53mOo\x1b[55mp");
    assert_eq!((runs[0].text.as_str(), runs[0].ol), ("a", false));
    assert_eq!((runs[1].text.as_str(), runs[1].ol), ("Oo", true), "the overline alone breaks the run");
    // The rest of the row is blank, so `p` starts the last run.
    assert!(runs[2].text.starts_with('p') && !runs[2].ol);
    let json = serde_json::to_string(&runs).unwrap();
    assert_eq!(json.matches("\"ol\":true").count(), 1, "{json}");
    assert!(!json.contains("\"ol\":false"), "an ordinary run carries no ol: {json}");
    // An older client's JSON with no ol reads as no overline.
    let back: crate::layout::CellRunJson =
        serde_json::from_str(r#"{"text":"x","fg":"default","bg":"default","flags":0,"width":1}"#).unwrap();
    assert!(!back.ol);
}
