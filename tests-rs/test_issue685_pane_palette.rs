// Issue #685: an indexed colour whose pane palette has an OSC 4 entry must
// leave the server as that RGB, and a pane that never set a palette must
// serialise byte for byte as before.
//
// This is psmux's equivalent of tmux's `tty_check_fg` / `tty_check_bg` /
// `tty_check_us` substitution (`tty.c:2822`, `2892`, `2945`, all reached from
// `tty_attributes` at `tty.c:2685`), which replaces an indexed colour with the
// pane palette's RGB on the way to the terminal.  psmux does it where a cell
// is serialised for the client, so the palette never has to travel: the wire
// already carries `rgb:R,G,B` (`util.rs` `color_to_name`, parsed back by
// `style.rs` `map_color`), so a resolved cell is an ordinary RGB cell and no
// frame grows by a byte.
//
// Reproduced before the fix by hosting the psmux CLIENT under a pseudoconsole
// and reading the SGR it wrote: a pane that had sent `\e]4;4;rgb:00/00/80\e\\`
// still emitted `\e[44m`, which Windows Terminal paints Campbell `#0037DA`.
// After the fix the same capture reads `\e[48;2;0;0;128m`.

use vt100::Parser;

fn rows_for(bytes: &[u8]) -> Vec<crate::layout::RowRunsJson> {
    let mut p: Parser = Parser::new(5, 40, 0);
    p.process(bytes);
    crate::layout::serialize_screen_rows(p.screen(), 5, 40)
}

fn run_with<'a>(
    rows: &'a [crate::layout::RowRunsJson],
    text: &str,
) -> &'a crate::layout::CellRunJson {
    rows[0]
        .runs
        .iter()
        .find(|r| r.text.starts_with(text))
        .expect("run exists")
}

// ---- the bug, in the serialiser ----------------------------------------

#[test]
fn legacy_sgr_44_serialises_as_the_palette_rgb() {
    // `\e[44m` is index 4; the palette says index 4 is #000080.
    let rows = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[44mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "rgb:0,0,128");
}

#[test]
fn indexed_sgr_48_5_4_serialises_as_the_same_rgb() {
    // The form conhost actually emits for a record reading app like Far.
    let rows = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[48;5;4mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "rgb:0,0,128");
}

#[test]
fn indexed_foreground_resolves_too() {
    let rows = rows_for(b"\x1b]4;14;rgb:00/ff/ff\x1b\\\x1b[38;5;14mAAA");
    assert_eq!(run_with(&rows, "AAA").fg, "rgb:0,255,255");
}

#[test]
fn a_high_index_resolves_as_well_as_a_low_one() {
    let rows = rows_for(b"\x1b]4;200;rgb:11/22/33\x1b\\\x1b[38;5;200mAAA");
    assert_eq!(run_with(&rows, "AAA").fg, "rgb:17,34,51");
}

#[test]
fn the_underline_colour_resolves() {
    let rows =
        rows_for(b"\x1b]4;5;rgb:80/00/80\x1b\\\x1b[4:3m\x1b[58;5;5mAAA");
    assert_eq!(run_with(&rows, "AAA").ulc.as_deref(), Some("rgb:128,0,128"));
}

// ---- no palette means byte for byte what it was ------------------------

#[test]
fn a_pane_with_no_palette_still_serialises_the_index() {
    let rows = rows_for(b"\x1b[44mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "idx:4");
}

#[test]
fn an_index_the_palette_does_not_cover_keeps_its_index() {
    let rows = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[46mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "idx:6");
}

#[test]
fn default_colours_are_untouched_by_a_palette() {
    let rows = rows_for(b"\x1b]4;0;rgb:11/22/33\x1b\\AAA");
    let run = run_with(&rows, "AAA");
    assert_eq!(run.fg, "default");
    assert_eq!(run.bg, "default");
}

#[test]
fn a_true_colour_cell_is_not_rewritten() {
    let rows = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[48;2;1;2;3mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "rgb:1,2,3");
}

// ---- reset paths --------------------------------------------------------

#[test]
fn osc_104_with_an_index_puts_the_index_back() {
    let rows = rows_for(
        b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b]104;4\x1b\\\x1b[44mAAA",
    );
    assert_eq!(run_with(&rows, "AAA").bg, "idx:4");
}

#[test]
fn a_bare_osc_104_puts_every_index_back() {
    let rows = rows_for(
        b"\x1b]4;4;rgb:00/00/80;6;rgb:00/80/80\x1b\\\x1b]104\x1b\\\x1b[44mAAA",
    );
    assert_eq!(run_with(&rows, "AAA").bg, "idx:4");
}

#[test]
fn already_painted_cells_follow_a_later_palette_change() {
    // tmux schedules a full redraw when colour_palette_set reports a change
    // (input.c:2966), so cells written BEFORE the OSC 4 repaint too.  psmux
    // resolves at serialisation time, so this falls out for free.
    let rows = rows_for(b"\x1b[44mAAA\x1b]4;4;rgb:00/00/80\x1b\\");
    assert_eq!(run_with(&rows, "AAA").bg, "rgb:0,0,128");
}

#[test]
fn ris_puts_the_index_back() {
    // RIS clears the palette, as tmux does (input.c:1407). A respawn does
    // NOT: tmux keeps the palette on the window_pane across spawn_pane, and
    // so does psmux since #708 (Screen::reinit_keep_history).
    let rows = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1bc\x1b[44mAAA");
    assert_eq!(run_with(&rows, "AAA").bg, "idx:4");
}

// ---- panes do not share a palette --------------------------------------

#[test]
fn two_panes_keep_their_own_palettes() {
    let mut a: Parser = Parser::new(5, 40, 0);
    let mut b: Parser = Parser::new(5, 40, 0);
    a.process(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[44mAAA");
    b.process(b"\x1b[44mBBB");
    let ra = crate::layout::serialize_screen_rows(a.screen(), 5, 40);
    let rb = crate::layout::serialize_screen_rows(b.screen(), 5, 40);
    assert_eq!(run_with(&ra, "AAA").bg, "rgb:0,0,128");
    assert_eq!(run_with(&rb, "BBB").bg, "idx:4");
}

// ---- the palette never leaves as OSC 4 ---------------------------------

#[test]
fn the_wire_form_is_an_ordinary_rgb_run() {
    // Deliberate: psmux must NOT forward OSC 4 to the outer terminal, because
    // two panes with different palettes would fight over one terminal.  The
    // resolved cell has to be indistinguishable from a cell the child painted
    // with true colour in the first place.
    let palette = rows_for(b"\x1b]4;4;rgb:00/00/80\x1b\\\x1b[44mAAA");
    let truecolour = rows_for(b"\x1b[48;2;0;0;128mAAA");
    let p = run_with(&palette, "AAA");
    let t = run_with(&truecolour, "AAA");
    assert_eq!(p.bg, t.bg);
    assert_eq!(p.fg, t.fg);
    assert_eq!(p.flags, t.flags);
}

// ---- the OSC 4 query answer prefers the pane's own entry ---------------

#[test]
fn a_palette_query_is_answered_from_the_pane_first() {
    // tmux input.c:2947 answers from wp->palette and only asks the real
    // terminal when the pane has no entry of its own.
    let mut host = crate::types::HostColors::empty();
    host.palette[4] = Some((0x00, 0x37, 0xda)); // Windows Terminal Campbell
    let mut own: [Option<(u8, u8, u8)>; 16] = [None; 16];
    own[4] = Some((0, 0, 128));
    let (_, osc) = crate::server::helpers::build_color_replies_for_pane(
        1 << 4,
        &host,
        Some(own),
    );
    assert_eq!(osc, "\x1b]4;4;rgb:0000/0000/8080\x1b\\");
}

#[test]
fn a_palette_query_falls_back_to_the_host_when_the_pane_has_no_entry() {
    let mut host = crate::types::HostColors::empty();
    host.palette[4] = Some((0x00, 0x37, 0xda));
    let own: [Option<(u8, u8, u8)>; 16] = [None; 16];
    let (_, osc) = crate::server::helpers::build_color_replies_for_pane(
        1 << 4,
        &host,
        Some(own),
    );
    assert_eq!(osc, "\x1b]4;4;rgb:0000/3737/dada\x1b\\");
}

#[test]
fn a_pane_with_no_mirror_at_all_answers_exactly_as_before() {
    let mut host = crate::types::HostColors::empty();
    host.palette[6] = Some((0x3a, 0x96, 0xdd));
    let (_, with_none) =
        crate::server::helpers::build_color_replies_for_pane(1 << 6, &host, None);
    let (_, legacy) = crate::server::helpers::build_color_replies(1 << 6, &host);
    assert_eq!(with_none, legacy);
    assert_eq!(legacy, "\x1b]4;6;rgb:3a3a/9696/dddd\x1b\\");
}

// ---- the mirror the query responder reads ------------------------------

#[test]
fn publishing_and_withdrawing_a_mirrored_palette() {
    let id = 685_001usize;
    assert_eq!(crate::types::pane_palette(id), None);
    let mut entries: [Option<(u8, u8, u8)>; 16] = [None; 16];
    entries[4] = Some((0, 0, 128));
    crate::types::publish_pane_palette(id, entries);
    assert_eq!(crate::types::pane_palette(id).and_then(|p| p[4]), Some((0, 0, 128)));
    // An all-None publish is how an OSC 104 withdraws the entry.
    crate::types::publish_pane_palette(id, [None; 16]);
    assert_eq!(crate::types::pane_palette(id).and_then(|p| p[4]), None);
}
