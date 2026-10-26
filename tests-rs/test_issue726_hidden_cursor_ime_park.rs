// Issue #726: IME composition lands one cell right of the caret.
//
// A pane app that draws its own caret hides the hardware cursor (ESC[?25l)
// and still parks it on the caret with CUP, because the host terminal anchors
// IME composition (Korean, Japanese, Chinese) to the hardware cursor whether
// it is shown or not. Claude Code and other Ink based CLIs work this way.
//
// psmux used to drop that position: with the pane cursor hidden the client
// requested nothing, end_frame only wrote ?25l, and the host cursor stayed
// wherever the last drawn cell left it, one cell right of a reverse-video
// caret. Korean `충돌` then composed as `충▮돌` instead of `충돌▮`.
//
// tmux moves the cursor regardless of the cursor mode (server-client.c
// server_client_reset_state: tty_cursor(tty, cx, cy) runs unless MODE_SYNC,
// and tty_update_mode applies the mode afterwards).
//
// These tests drive the real ratatui Terminal over PsmuxBackend and assert:
//   * a hidden pane cursor is parked with CUP after ?25l, never shown,
//   * an unchanged parked frame writes nothing,
//   * a frame without a park request keeps the old hide-only policy.

use std::cell::RefCell;
use std::rc::Rc;

use ratatui::layout::Rect;
use ratatui::{Terminal, TerminalOptions, Viewport};

use crate::platform::{HostCursor, PsmuxBackend};

#[derive(Clone, Default)]
struct Recorder {
    pending: Rc<RefCell<Vec<u8>>>,
    writes: Rc<RefCell<Vec<Vec<u8>>>>,
}

impl std::io::Write for Recorder {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.pending.borrow_mut().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        let mut p = self.pending.borrow_mut();
        if !p.is_empty() {
            self.writes.borrow_mut().push(std::mem::take(&mut *p));
        }
        Ok(())
    }
}

impl Recorder {
    fn take_writes(&self) -> Vec<String> {
        self.writes
            .borrow_mut()
            .drain(..)
            .map(|w| String::from_utf8_lossy(&w).into_owned())
            .collect()
    }
}

fn terminal(rec: &Recorder) -> Terminal<PsmuxBackend<Recorder>> {
    Terminal::with_options(
        PsmuxBackend::new(rec.clone()),
        TerminalOptions { viewport: Viewport::Fixed(Rect::new(0, 0, 120, 30)) },
    )
    .unwrap()
}

/// One client frame: a visible cursor request, or a park for a hidden one.
fn frame(
    term: &mut Terminal<PsmuxBackend<Recorder>>,
    cells: &[(u16, u16, &str)],
    cursor: Option<(u16, u16)>,
    park: Option<(u16, u16)>,
) {
    term.backend_mut().begin_frame();
    term.draw(|f| {
        for (x, y, s) in cells {
            f.buffer_mut()[(*x, *y)].set_symbol(s);
        }
    })
    .unwrap();
    term.backend_mut().request_cursor(cursor);
    if let Some(p) = park {
        term.backend_mut().park_cursor(p);
    }
    term.backend_mut().end_frame().unwrap();
}

#[test]
fn hidden_pane_cursor_is_parked_on_the_caret() {
    let rec = Recorder::default();
    let mut term = terminal(&rec);
    frame(&mut term, &[(0, 0, "x")], Some((5, 5)), None);
    rec.take_writes();
    // The app typed `c` at column 8 and drew its caret (a reverse-video
    // space) at column 9, then hid the cursor and parked it on the caret.
    frame(&mut term, &[(8, 24, "c"), (9, 24, " ")], None, Some((9, 24)));
    let w = rec.take_writes();
    assert_eq!(w.len(), 1, "the frame must reach the host as one write: {w:?}");
    let s = &w[0];
    assert!(s.starts_with("\x1b[?25l"), "hidden before the first cell: {s:?}");
    assert!(s.ends_with("\x1b[25;10H"), "parked on the caret, not after it: {s:?}");
    assert!(!s.contains("\x1b[?25h"), "a parked cursor stays hidden: {s:?}");
}

#[test]
fn unchanged_parked_frame_writes_nothing() {
    let rec = Recorder::default();
    let mut term = terminal(&rec);
    frame(&mut term, &[(9, 24, " ")], None, Some((9, 24)));
    rec.take_writes();
    for _ in 0..5 {
        frame(&mut term, &[(9, 24, " ")], None, Some((9, 24)));
    }
    let w = rec.take_writes();
    assert!(w.is_empty(), "idle parked frames must write nothing: {w:?}");
}

#[test]
fn park_is_dropped_by_the_next_frame() {
    let rec = Recorder::default();
    let mut term = terminal(&rec);
    frame(&mut term, &[(0, 0, "x")], None, Some((3, 3)));
    rec.take_writes();
    // No park request: the frame keeps the hide-only policy and adds no CUP
    // after its cells.
    frame(&mut term, &[(1, 0, "y")], None, None);
    let w = rec.take_writes();
    assert_eq!(w.len(), 1, "{w:?}");
    assert!(!w[0].ends_with("\x1b[4;4H"), "an old park must not leak: {:?}", w[0]);
}

#[test]
fn host_cursor_policy_park_hides_then_places() {
    let mut c = HostCursor::default();
    let mut out = Vec::new();
    c.begin_frame();
    c.before_draw(&mut out);
    c.request(None);
    c.request_park((2, 3));
    c.end_frame(&mut out);
    assert_eq!(String::from_utf8(out).unwrap(), "\x1b[?25l\x1b[4;3H");
}

#[test]
fn visible_request_wins_over_park() {
    let mut c = HostCursor::default();
    let mut out = Vec::new();
    c.begin_frame();
    c.before_draw(&mut out);
    c.request(Some((0, 0)));
    c.request_park((2, 3));
    c.end_frame(&mut out);
    assert_eq!(String::from_utf8(out).unwrap(), "\x1b[?25l\x1b[1;1H\x1b[?25h");
}
