// Issue #589: "Undercurl style is not supported".
//
// Windows ConPTY hands psmux the SGR 4 subparameter forms verbatim
// (`ESC[4:3m` for undercurl, `ESC[4:4m`, `ESC[4:5m`) and rewrites `4:2` to the
// legacy `ESC[21m`.  Before this fix the parser matched only the single
// parameter `[4]`, so every subparameter form fell through to `unhandled` and
// the cell ended up with NO underline at all.  SGR 58 (underline colour) and
// SGR 59 (reset it) were dropped for the same reason.
//
// tmux parity: tmux 3.4 input.c input_csi_dispatch_sgr_colon handles p[0]==4
// with cases 0..5 mapping onto GRID_ATTR_UNDERSCORE..UNDERSCORE_5, case 21
// maps onto UNDERSCORE_2, and p[0]==58 sets gc->us.

use vt100_psmux as vt100;

fn style_at(bytes: &[u8], col: u16) -> vt100::UnderlineStyle {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser.screen().cell(0, col).unwrap().underline_style()
}

fn ulcolor_at(bytes: &[u8], col: u16) -> vt100::Color {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser.screen().cell(0, col).unwrap().underline_color()
}

#[test]
fn sgr_4_plain_is_single_underline() {
    assert_eq!(style_at(b"\x1b[4mX", 0), vt100::UnderlineStyle::Single);
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4mX");
    assert!(parser.screen().cell(0, 0).unwrap().underline());
}

#[test]
fn sgr_4_semicolon_1_is_underline_plus_bold_not_undercurl() {
    // `ESC[4;1m` is two parameters: underline and bold.  It must NOT be read
    // as the subparameter form.
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4;1mX");
    let cell = parser.screen().cell(0, 0).unwrap();
    assert_eq!(cell.underline_style(), vt100::UnderlineStyle::Single);
    assert!(cell.bold());
}

#[test]
fn sgr_4_subparams_select_extended_styles() {
    assert_eq!(style_at(b"\x1b[4:0mX", 0), vt100::UnderlineStyle::None);
    assert_eq!(style_at(b"\x1b[4:1mX", 0), vt100::UnderlineStyle::Single);
    assert_eq!(style_at(b"\x1b[4:2mX", 0), vt100::UnderlineStyle::Double);
    assert_eq!(style_at(b"\x1b[4:3mX", 0), vt100::UnderlineStyle::Curly);
    assert_eq!(style_at(b"\x1b[4:4mX", 0), vt100::UnderlineStyle::Dotted);
    assert_eq!(style_at(b"\x1b[4:5mX", 0), vt100::UnderlineStyle::Dashed);
}

#[test]
fn extended_styles_still_report_underline() {
    // Everything that only knows about SGR 4 must keep drawing a line.
    for seq in [
        &b"\x1b[4:2mX"[..],
        &b"\x1b[4:3mX"[..],
        &b"\x1b[4:4mX"[..],
        &b"\x1b[4:5mX"[..],
        &b"\x1b[21mX"[..],
    ] {
        let mut parser = vt100::Parser::new(5, 80, 0);
        parser.process(seq);
        assert!(
            parser.screen().cell(0, 0).unwrap().underline(),
            "underline() false for {seq:?}"
        );
    }
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4:0mX");
    assert!(!parser.screen().cell(0, 0).unwrap().underline());
}

#[test]
fn sgr_21_is_double_underline() {
    // ConPTY rewrites `4:2` into `21`, so this arm is the one that fires for
    // double underlines coming out of a Windows pane.
    assert_eq!(style_at(b"\x1b[21mX", 0), vt100::UnderlineStyle::Double);
}

#[test]
fn sgr_58_sets_underline_colour_semicolon_form() {
    assert_eq!(
        ulcolor_at(b"\x1b[4:3m\x1b[58;2;255;0;0mX", 0),
        vt100::Color::Rgb(255, 0, 0)
    );
    assert_eq!(
        ulcolor_at(b"\x1b[58;5;9mX", 0),
        vt100::Color::Idx(9)
    );
}

#[test]
fn sgr_58_sets_underline_colour_colon_forms() {
    // `58:2::r:g:b` carries an empty colour space id; `58:2:r:g:b` does not.
    assert_eq!(
        ulcolor_at(b"\x1b[58:2::0:255:0mX", 0),
        vt100::Color::Rgb(0, 255, 0)
    );
    assert_eq!(
        ulcolor_at(b"\x1b[58:2:0:255:0mX", 0),
        vt100::Color::Rgb(0, 255, 0)
    );
    assert_eq!(ulcolor_at(b"\x1b[58:5:9mX", 0), vt100::Color::Idx(9));
}

#[test]
fn colon_form_truecolour_fg_and_bg_also_parse() {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[38:2::1:2:3m\x1b[48:2::4:5:6mX");
    let cell = parser.screen().cell(0, 0).unwrap();
    assert_eq!(cell.fgcolor(), vt100::Color::Rgb(1, 2, 3));
    assert_eq!(cell.bgcolor(), vt100::Color::Rgb(4, 5, 6));
}

// ─── reset paths: nothing may bleed into the following text ─────────────────

#[test]
fn sgr_0_clears_style_and_colour() {
    let bytes = b"\x1b[4:3m\x1b[58;2;255;0;0mA\x1b[0mB";
    assert_eq!(style_at(bytes, 0), vt100::UnderlineStyle::Curly);
    assert_eq!(style_at(bytes, 1), vt100::UnderlineStyle::None);
    assert_eq!(ulcolor_at(bytes, 1), vt100::Color::Default);
}

#[test]
fn sgr_24_clears_every_underline_style() {
    for seq in [
        &b"\x1b[4:2mA\x1b[24mB"[..],
        &b"\x1b[4:3mA\x1b[24mB"[..],
        &b"\x1b[4:4mA\x1b[24mB"[..],
        &b"\x1b[4:5mA\x1b[24mB"[..],
        &b"\x1b[21mA\x1b[24mB"[..],
    ] {
        assert_eq!(
            style_at(seq, 1),
            vt100::UnderlineStyle::None,
            "style leaked past SGR 24 for {seq:?}"
        );
    }
}

#[test]
fn sgr_4_colon_0_clears_every_underline_style() {
    assert_eq!(
        style_at(b"\x1b[4:3mA\x1b[4:0mB", 1),
        vt100::UnderlineStyle::None
    );
}

#[test]
fn sgr_59_clears_only_the_underline_colour() {
    let bytes = b"\x1b[4:3m\x1b[58;2;255;0;0mA\x1b[59mB";
    assert_eq!(ulcolor_at(bytes, 0), vt100::Color::Rgb(255, 0, 0));
    assert_eq!(ulcolor_at(bytes, 1), vt100::Color::Default);
    // The curl itself survives, exactly like tmux's `case 59: gc->us = 8`.
    assert_eq!(style_at(bytes, 1), vt100::UnderlineStyle::Curly);
}

#[test]
fn plain_sgr_4_downgrades_a_curl_to_a_straight_line() {
    assert_eq!(
        style_at(b"\x1b[4:3mA\x1b[4mB", 1),
        vt100::UnderlineStyle::Single
    );
}

// ─── re-encoding: contents_formatted must replay the style ──────────────────

#[test]
fn contents_formatted_replays_extended_styles() {
    let mut parser = vt100::Parser::new(3, 40, 0);
    parser.process(b"\x1b[4:3m\x1b[58;2;255;0;0mcurly");
    let out = parser.screen().contents_formatted();
    let text = String::from_utf8_lossy(&out).into_owned();
    assert!(text.contains("4:3"), "no 4:3 in {text:?}");
    assert!(text.contains("58;2;255;0;0"), "no underline colour in {text:?}");
}

#[test]
fn contents_formatted_replays_each_style_code() {
    for (seq, want) in [
        (&b"\x1b[4:2mx"[..], "4:2"),
        (&b"\x1b[4:3mx"[..], "4:3"),
        (&b"\x1b[4:4mx"[..], "4:4"),
        (&b"\x1b[4:5mx"[..], "4:5"),
    ] {
        let mut parser = vt100::Parser::new(3, 40, 0);
        parser.process(seq);
        let out = parser.screen().contents_formatted();
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(text.contains(want), "expected {want} in {text:?}");
    }
}

// ─── reset paths, every spelling (regression guard for the #589 review) ─────
//
// These were written after a review run of tests/test_issue589_undercurl.ps1
// came back 24/28 on a machine with NO_COLOR=1 exported.  PowerShell 7 then
// sets `$PSStyle.OutputRendering = PlainText` and strips the SGR sequences it
// recognises out of Write-Host output, but its matcher does not recognise the
// COLON subparameter forms.  The pane therefore received `4:3m` and `58:5:9m`
// with every `ESC[0m` and `ESC[24m` around them deleted, so the style really
// did run on until the end of the screen.  Real tmux 3.4 renders that same
// byte stream identically (verified in WSL: `capture-pane -e` prints
// `ESC[58;5;9mAFTER_ALL ESC[0m`), so the behaviour is correct and it was the
// environment that changed.  The tests below pin every reset spelling so a
// future regression in one of them cannot hide behind that explanation.

#[test]
fn bare_csi_m_clears_style_and_colour() {
    // `ESC[m` with no parameters at all, which is what ConPTY emits.
    let bytes = b"\x1b[4:3m\x1b[58:5:9mA\x1b[mB";
    assert_eq!(style_at(bytes, 1), vt100::UnderlineStyle::None);
    assert_eq!(ulcolor_at(bytes, 1), vt100::Color::Default);
}

#[test]
fn sgr_0_in_the_middle_of_a_longer_list_clears_style_and_colour() {
    // `ESC[0;1;4m` is exactly what psmux's own capture-pane -e writes, so it
    // has to behave as reset-then-bold-then-underline.
    let bytes = b"\x1b[4:3m\x1b[58:5:9mA\x1b[0;1;4mB";
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    let b = parser.screen().cell(0, 1).unwrap();
    assert_eq!(b.underline_style(), vt100::UnderlineStyle::Single);
    assert_eq!(b.underline_color(), vt100::Color::Default);
    assert!(b.bold());
}

#[test]
fn sgr_0_at_the_end_of_a_list_clears_style_and_colour() {
    let bytes = b"\x1b[4:3m\x1b[58:5:9mA\x1b[1;0mB";
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    let b = parser.screen().cell(0, 1).unwrap();
    assert_eq!(b.underline_style(), vt100::UnderlineStyle::None);
    assert_eq!(b.underline_color(), vt100::Color::Default);
    assert!(!b.bold());
}

#[test]
fn sgr_4_semicolon_1_is_not_the_subparameter_form_in_any_order() {
    // Two parameters in one CSI, both orders, plus the same pair delivered as
    // two separate CSIs.  None of them may become an extended style.
    for seq in [
        &b"\x1b[4;1mX"[..],
        &b"\x1b[1;4mX"[..],
        &b"\x1b[1m\x1b[4mX"[..],
        &b"\x1b[4m\x1b[1mX"[..],
    ] {
        let mut parser = vt100::Parser::new(5, 80, 0);
        parser.process(seq);
        let cell = parser.screen().cell(0, 0).unwrap();
        assert_eq!(
            cell.underline_style(),
            vt100::UnderlineStyle::Single,
            "wrong style for {seq:?}"
        );
        assert!(cell.bold(), "lost bold for {seq:?}");
    }
}

#[test]
fn a_leading_reset_wipes_attributes_set_before_it() {
    // ConPTY's frame preamble is `ESC[2J ESC[m ESC[H`.  Anything set before it
    // must be gone, which is what a stripped `ESC[4;1m` looks like from the
    // outside.  tmux 3.4 does the same (verified: `ESC[1m ESC[4m ESC[m STD_UL`
    // captures as plain `STD_UL`).
    let bytes = b"\x1b[1m\x1b[4m\x1b[2J\x1b[m\x1b[HSTD_UL";
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    let cell = parser.screen().cell(0, 0).unwrap();
    assert_eq!(cell.underline_style(), vt100::UnderlineStyle::None);
    assert!(!cell.bold());
}

#[test]
fn underline_colour_outlives_sgr_24_exactly_like_tmux() {
    // SGR 24 clears the underline, NOT the underline colour (tmux input.c
    // `case 24` touches only GRID_ATTR_ALL_UNDERSCORE; only `case 59` and a
    // full reset touch gc->us).  A cell can therefore legitimately carry an
    // underline colour with no underline, which is what the NO_COLOR run
    // above produced for AFTER_ALL.
    let bytes = b"\x1b[4:3m\x1b[58:5:9mA\x1b[24mB";
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    let b = parser.screen().cell(0, 1).unwrap();
    assert_eq!(b.underline_style(), vt100::UnderlineStyle::None);
    assert!(!b.underline());
    assert_eq!(b.underline_color(), vt100::Color::Idx(9));
}

#[test]
fn the_no_color_stripped_conhost_stream_renders_like_tmux() {
    // The exact pre-parse bytes psmux received from ConPTY on the machine that
    // reported 24/28, captured with PSMUX_PANE_RAW=1.  Every `ESC[0m` the
    // payload wrote had been deleted by PowerShell before ConPTY ever saw it.
    let bytes = b"COLOR_CURLY\x1b[58:5:9m\r\n\
IDX_CURLY\r\n\
BLEED_ONBLEED_OFF\r\n\
COLON0_ON\x1b[24mCOLON0_OFF\r\n\
AFTER_ALL\r\n";
    let mut parser = vt100::Parser::new(8, 100, 0);
    parser.process(b"\x1b[4:3m");
    parser.process(bytes);
    let screen = parser.screen();
    // IDX_CURLY keeps the curl and the colour: nothing reset them.
    let idx = screen.cell(1, 0).unwrap();
    assert_eq!(idx.underline_style(), vt100::UnderlineStyle::Curly);
    assert_eq!(idx.underline_color(), vt100::Color::Idx(9));
    // AFTER_ALL keeps the colour but not the underline, because the only
    // reset in the stream is the `ESC[24m` on the COLON0 line.  tmux 3.4
    // prints `ESC[58;5;9mAFTER_ALL ESC[0m` for the same bytes.
    let after = screen.cell(4, 0).unwrap();
    assert_eq!(after.underline_style(), vt100::UnderlineStyle::None);
    assert_eq!(after.underline_color(), vt100::Color::Idx(9));
}

#[test]
fn the_unstripped_stream_leaves_nothing_behind() {
    // The same lines with the resets intact, which is what the pane receives
    // once NO_COLOR is out of the way.  Nothing may survive onto AFTER_ALL.
    let bytes = b"\x1b[4:3m\x1b[58:5:9mIDX_CURLY\x1b[m\r\n\
\x1b[4:3mBLEED_ON\x1b[24mBLEED_OFF\r\n\
\x1b[4:3mCOLON0_ON\x1b[4:0mCOLON0_OFF\r\n\
AFTER_ALL\r\n";
    let mut parser = vt100::Parser::new(8, 100, 0);
    parser.process(bytes);
    let after = parser.screen().cell(3, 0).unwrap();
    assert_eq!(after.underline_style(), vt100::UnderlineStyle::None);
    assert_eq!(after.underline_color(), vt100::Color::Default);
    assert!(!after.underline());
}
