// Issue #810: `capture-pane -a` returned the visible screen instead of the
// main screen the alternate screen covers (tmux's saved grid),
// `#{alternate_saved_x}`/`_y` were a constant 0 instead of the cursor saved on
// the way in (UINT_MAX when nothing is saved), and `#{cursor_flag}` ignored
// DECTCEM. Registered from src/copy_mode.rs.

fn parser_with(bytes: &[u8]) -> vt100::Parser {
    let mut p = vt100::Parser::new(10, 40, 100);
    p.process(bytes);
    p
}

#[test]
fn no_saved_screen_without_the_alternate_screen() {
    let p = parser_with(b"NORMAL810\r\nprompt> ");
    assert!(p.saved_normal_snapshot().is_none());
    assert_eq!(p.screen().alternate_saved_cursor(), None);
}

#[test]
fn saved_screen_is_the_main_screen_behind_the_alternate_one() {
    let p = parser_with(b"NORMAL810\r\nprompt> \x1b[?1049h\x1b[HALTSCREEN810");
    assert!(p.screen().alternate_screen());
    assert!(p.screen().contents().contains("ALTSCREEN810"));
    let snap = p.saved_normal_snapshot().expect("saved screen while on the alternate screen");
    let text = snap.screen().contents();
    assert!(text.contains("NORMAL810"), "{text:?}");
    assert!(text.contains("prompt>"), "{text:?}");
    assert!(!text.contains("ALTSCREEN810"), "{text:?}");
    // The live screen is untouched.
    assert!(p.screen().alternate_screen());
    assert!(p.screen().contents().contains("ALTSCREEN810"));
}

#[test]
fn alternate_saved_cursor_is_the_cursor_on_entry() {
    let mut p = parser_with(b"NORMAL810\r\nprompt> ");
    p.process(b"\x1b[?1049h\x1b[5;9H");
    // (col, row) of the main screen cursor when 1049 was set.
    assert_eq!(p.screen().alternate_saved_cursor(), Some((8, 1)));
    p.process(b"\x1b[?1049l");
    assert_eq!(p.screen().alternate_saved_cursor(), None);
    assert!(p.saved_normal_snapshot().is_none());
}

#[test]
fn cursor_flag_follows_dectcem() {
    let mut p = parser_with(b"prompt> ");
    assert!(!p.screen().hide_cursor());
    p.process(b"\x1b[?25l");
    assert!(p.screen().hide_cursor());
    p.process(b"\x1b[?25h");
    assert!(!p.screen().hide_cursor());
}
