// Issue #502: leaving the alternate screen (CSI ? 1049 l) must restore the
// FULL graphic rendition saved on entry, not just part of it.
//
// nvim runs in the alternate screen with its colorscheme background active.
// If the background leaks back into the main screen on exit, every line the
// shell prints afterwards (starting with the prompt) is painted on that
// background — the "terminal color turns to chaos after nvim a file" report.

fn attrs_after(input: &[u8]) -> (vt100_psmux::Color, vt100_psmux::Color) {
    let mut parser = vt100_psmux::Parser::new(10, 40, 0);
    parser.process(input);
    // Write one character with the post-restore attributes and read it back.
    parser.process(b"Z");
    let screen = parser.screen();
    let cell = screen
        .cell(screen.cursor_position().0, screen.cursor_position().1 - 1)
        .expect("cell written");
    (cell.fgcolor(), cell.bgcolor())
}

#[test]
fn alt_screen_exit_restores_background() {
    // green fg on default bg -> alt screen -> magenta fg+bg -> leave alt screen
    let (fg, bg) = attrs_after(
        b"\x1b[32m\x1b[?1049h\x1b[35;45mX\x1b[?1049l",
    );
    assert_eq!(
        fg,
        vt100_psmux::Color::Idx(2),
        "foreground saved before the alternate screen must be restored"
    );
    assert_eq!(
        bg,
        vt100_psmux::Color::Default,
        "BUG #502: the alternate screen's background leaked into the main screen"
    );
}

#[test]
fn alt_screen_exit_restores_background_when_entry_had_one() {
    // blue bg active before the alt screen must come back verbatim
    let (fg, bg) = attrs_after(
        b"\x1b[44m\x1b[?1049h\x1b[35;45mX\x1b[?1049l",
    );
    assert_eq!(fg, vt100_psmux::Color::Default, "fg was default on entry");
    assert_eq!(
        bg,
        vt100_psmux::Color::Idx(4),
        "the background active on entry must be restored, not the alt screen's"
    );
}

#[test]
fn alt_screen_exit_clears_bold_from_alt_screen() {
    // Attributes other than color must not leak either.
    let mut parser = vt100_psmux::Parser::new(10, 40, 0);
    parser.process(b"\x1b[?1049h\x1b[1mX\x1b[?1049l");
    parser.process(b"Z");
    let screen = parser.screen();
    let (row, col) = screen.cursor_position();
    let cell = screen.cell(row, col - 1).expect("cell written");
    assert!(
        !cell.bold(),
        "BUG #502: bold set inside the alternate screen leaked out"
    );
}

