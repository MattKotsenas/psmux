// Issue #502: DECSC (ESC 7 / CSI s) issued INSIDE the alternate screen must not
// clobber the graphic rendition that DECSET 1049 saved on the way in.
//
// tmux keeps the two in separate slots: DECSC/DECRC use ictx->old_cell
// (input.c), while the alternate screen uses s->saved_cell (screen.c). A full
// screen app that saves the cursor while its colorscheme is active therefore
// cannot poison the main screen. Sharing one slot means the app's own colours
// are restored into the main screen when it exits, and every line the shell
// prints afterwards inherits them.

fn fg_bg_after(input: &[u8]) -> (vt100_psmux::Color, vt100_psmux::Color) {
    let mut parser = vt100_psmux::Parser::new(10, 40, 0);
    parser.process(input);
    parser.process(b"Z");
    let screen = parser.screen();
    let (row, col) = screen.cursor_position();
    let cell = screen.cell(row, col - 1).expect("cell written");
    (cell.fgcolor(), cell.bgcolor())
}

#[test]
fn decsc_inside_alt_screen_does_not_poison_main_screen() {
    // green fg on the main screen, then a full screen app enters the alternate
    // screen, sets its own colours and saves the cursor (ESC 7) while they are
    // active, then exits.
    let (fg, bg) = fg_bg_after(b"\x1b[32m\x1b[?1049h\x1b[35;45m\x1b7X\x1b[?1049l");
    assert_eq!(
        fg,
        vt100_psmux::Color::Idx(2),
        "main screen foreground must survive a DECSC made inside the alternate screen"
    );
    assert_eq!(
        bg,
        vt100_psmux::Color::Default,
        "BUG #502: the alternate screen's background was restored into the main screen"
    );
}

#[test]
fn csi_s_inside_alt_screen_does_not_poison_main_screen() {
    // Same thing via the ANSI.SYS style save (CSI s).
    let (fg, bg) = fg_bg_after(b"\x1b[32m\x1b[?1049h\x1b[35;45m\x1b[sX\x1b[?1049l");
    assert_eq!(fg, vt100_psmux::Color::Idx(2), "foreground must survive CSI s");
    assert_eq!(
        bg,
        vt100_psmux::Color::Default,
        "BUG #502: CSI s inside the alternate screen poisoned the main screen"
    );
}

#[test]
fn decsc_in_main_screen_still_restores_normally() {
    // Guard the normal case: DECSC/DECRC on one screen keeps working.
    let (fg, bg) = fg_bg_after(b"\x1b[31;44m\x1b7\x1b[0m\x1b8");
    assert_eq!(fg, vt100_psmux::Color::Idx(1), "DECRC restores the saved foreground");
    assert_eq!(bg, vt100_psmux::Color::Idx(4), "DECRC restores the saved background");
}

#[test]
fn alt_screen_decrc_uses_its_own_slot() {
    // A DECSC made in the MAIN screen must not be consumed by a DECRC made
    // inside the alternate screen, and vice versa.
    let (fg, bg) = fg_bg_after(b"\x1b[31;44m\x1b7\x1b[?1049h\x1b[32;45m\x1b8Z\x1b[?1049l");
    assert_eq!(fg, vt100_psmux::Color::Idx(1), "main screen fg restored on exit");
    assert_eq!(bg, vt100_psmux::Color::Idx(4), "main screen bg restored on exit");
}
