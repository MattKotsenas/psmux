// Issue #494: entering copy mode must freeze the visible screen while new
// output keeps flowing into the scrollback (tmux parity).  The vendored vt100
// grid already anchored the view at scrollback_offset > 0; the `frozen` flag
// extends that anchoring to offset 0 (entering copy mode without scrolling).

fn feed_lines(parser: &mut vt100::Parser, from: usize, to: usize) {
    for i in from..to {
        parser.process(format!("LINE {}\r\n", i).as_bytes());
    }
}

#[test]
fn frozen_screen_stays_anchored_as_output_arrives() {
    let mut parser = vt100::Parser::new(5, 40, 100);
    feed_lines(&mut parser, 0, 20);
    // Park the cursor at the end of a visible line so the screen is full —
    // mirrors a program mid-output when the user hits prefix+[.
    parser.process(b"LINE 20");
    let before = parser.screen().contents();
    assert!(before.contains("LINE 20"), "setup: tail line visible");

    // Enter copy mode at offset 0: freeze.
    parser.screen_mut().set_frozen(true);
    assert_eq!(parser.screen().scrollback(), 0);

    for i in 21..40 {
        parser.process(format!("\r\nLINE {}", i).as_bytes());
    }
    let during = parser.screen().contents();
    assert_eq!(before, during, "frozen view must not change as new lines arrive");
    assert!(parser.screen().scrollback() > 0, "offset auto-bumped to anchor the view");
}

#[test]
fn frozen_view_stabilizes_after_visible_prompt_row_fills() {
    // A pane frozen while the cursor sits on an EMPTY bottom row (e.g. ping
    // just printed a newline) fills that already-visible row once; every
    // subsequent line is anchored away.  tmux's snapshot hides even that
    // first line — the anchor approach trades that one-row fill for zero
    // copies, and crucially never scrolls the frozen content again.
    let mut parser = vt100::Parser::new(5, 40, 100);
    feed_lines(&mut parser, 0, 20);
    parser.screen_mut().set_frozen(true);
    feed_lines(&mut parser, 20, 21); // fills the visible empty prompt row
    let steady = parser.screen().contents();
    feed_lines(&mut parser, 21, 60);
    let later = parser.screen().contents();
    assert_eq!(steady, later, "no further change after the visible rows are full");
}

#[test]
fn unfreeze_and_reset_follows_live_output_again() {
    let mut parser = vt100::Parser::new(5, 40, 100);
    feed_lines(&mut parser, 0, 20);
    parser.screen_mut().set_frozen(true);
    feed_lines(&mut parser, 20, 40);

    // Exit copy mode: unfreeze + jump back to the live bottom.
    parser.screen_mut().set_frozen(false);
    parser.screen_mut().set_scrollback(0);
    let live = parser.screen().contents();
    assert!(live.contains("LINE 39"), "live tail visible after exit");

    feed_lines(&mut parser, 40, 45);
    let after = parser.screen().contents();
    assert!(after.contains("LINE 44"), "view follows output after unfreeze");
}

#[test]
fn scrolled_up_view_still_anchored_regardless_of_frozen() {
    // Pre-existing behavior guard: offset > 0 anchors even without frozen.
    let mut parser = vt100::Parser::new(5, 40, 100);
    feed_lines(&mut parser, 0, 20);
    parser.screen_mut().set_scrollback(5);
    let before = parser.screen().contents();
    feed_lines(&mut parser, 20, 30);
    let during = parser.screen().contents();
    assert_eq!(before, during, "scrolled-up view already anchored (regression guard)");
}

#[test]
fn freeze_survives_scroll_operations() {
    // While frozen, the user can still page around; the anchor keeps working
    // for subsequent output.
    let mut parser = vt100::Parser::new(5, 40, 100);
    feed_lines(&mut parser, 0, 30);
    parser.screen_mut().set_frozen(true);
    parser.screen_mut().set_scrollback(10);
    let scrolled = parser.screen().contents();
    feed_lines(&mut parser, 30, 40);
    let during = parser.screen().contents();
    assert_eq!(scrolled, during, "scrolled frozen view stays anchored");
    assert!(parser.screen().frozen());
}
