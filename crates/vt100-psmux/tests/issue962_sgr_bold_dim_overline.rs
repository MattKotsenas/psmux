// Issue #962: SGR 1 and 2 are two attributes, as in tmux and in terminals,
// and SGR 53 and 55 set and clear an overline.
//
// tmux 3.8 input.c input_csi_dispatch_sgr: SGR 1 sets GRID_ATTR_BRIGHT and
// SGR 2 GRID_ATTR_DIM (:2420-2425), each leaving the other alone, and only
// SGR 22 clears both (:2450-2451); SGR 53 sets GRID_ATTR_OVERLINE and SGR 55
// clears it (:2497-2501). vt100 kept bold and dim as one setting, so the
// second of `CSI 1 ; 2 m` replaced the first, and it had no overline.

use vt100_psmux as vt100;

fn cell_after(bytes: &[u8]) -> vt100::Cell {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser.screen().cell(0, 0).unwrap().clone()
}

/// `(bold, dim)` of the cell holding `X`, the first one written.
fn intensity(bytes: &[u8]) -> (bool, bool) {
    let cell = cell_after(bytes);
    (cell.bold(), cell.dim())
}

#[test]
fn bold_and_dim_are_set_together_in_any_order() {
    assert_eq!(intensity(b"\x1b[1;2mX"), (true, true));
    assert_eq!(intensity(b"\x1b[2;1mX"), (true, true));
    assert_eq!(intensity(b"\x1b[1m\x1b[2mX"), (true, true));
    assert_eq!(intensity(b"\x1b[2m\x1b[1mX"), (true, true));
    assert_eq!(intensity(b"\x1b[1mX"), (true, false));
    assert_eq!(intensity(b"\x1b[2mX"), (false, true));
}

#[test]
fn sgr_22_and_0_clear_both() {
    assert_eq!(intensity(b"\x1b[1;2m\x1b[22mX"), (false, false));
    assert_eq!(intensity(b"\x1b[1;2m\x1b[0mX"), (false, false));
    // SGR 21 is a double underline (tmux input.c:2446-2449), not "no bold".
    let cell = cell_after(b"\x1b[1;2m\x1b[21mX");
    assert_eq!((cell.bold(), cell.dim()), (true, true));
    assert_eq!(cell.underline_style(), vt100::UnderlineStyle::Double);
}

#[test]
fn sgr_53_sets_an_overline_that_55_and_0_clear() {
    assert!(cell_after(b"\x1b[53mX").overline());
    assert!(!cell_after(b"\x1b[53m\x1b[55mX").overline());
    assert!(!cell_after(b"\x1b[53m\x1b[0mX").overline());
    assert!(!cell_after(b"X").overline());
    // It goes with the other attributes, and leaves them alone.
    let cell = cell_after(b"\x1b[1;53;31mX");
    assert!(cell.overline() && cell.bold());
    assert_eq!(cell.fgcolor(), vt100::Color::Idx(1));
    let cell = cell_after(b"\x1b[4;53m\x1b[55mX");
    assert!(cell.underline() && !cell.overline());
}

/// What `contents_formatted` writes for one row of `bytes`.
fn formatted(bytes: &[u8]) -> String {
    let mut parser = vt100::Parser::new(1, 20, 0);
    parser.process(bytes);
    String::from_utf8(parser.screen().contents_formatted()).unwrap()
}

#[test]
fn the_formatted_contents_replay_bold_dim_and_overline() {
    let out = formatted(b"\x1b[1;2mA\x1b[22;1mB\x1b[0;2mC\x1b[0;53mD\x1b[55mE");
    // Bold and dim together; then bold alone, which needs 22 first, as a
    // terminal keeps dim through SGR 1; then dim alone; then the overline
    // on and off.
    assert!(out.contains("\x1b[1;2mA"), "{out:?}");
    assert!(out.contains("\x1b[22;1mB"), "{out:?}");
    assert!(out.contains("\x1b[22;2mC"), "{out:?}");
    assert!(out.contains("53mD"), "{out:?}");
    assert!(out.contains("\x1b[55mE") || out.contains("\x1b[mE"), "{out:?}");
    // Replayed into a fresh screen, every cell comes back the same.
    let mut a = vt100::Parser::new(1, 20, 0);
    a.process(b"\x1b[1;2mA\x1b[22;1mB\x1b[0;2mC\x1b[0;53mD\x1b[55mE");
    let mut b = vt100::Parser::new(1, 20, 0);
    b.process(&a.screen().contents_formatted());
    for col in 0..5 {
        let (x, y) = (a.screen().cell(0, col).unwrap(), b.screen().cell(0, col).unwrap());
        assert_eq!(
            (x.contents(), x.bold(), x.dim(), x.overline()),
            (y.contents(), y.bold(), y.dim(), y.overline()),
            "column {col}"
        );
    }
}

#[test]
fn a_cell_did_not_grow() {
    // The overline takes padding the attributes already had.
    assert_eq!(std::mem::size_of::<vt100::Cell>(), 44);
}
