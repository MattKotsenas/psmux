// Issue #657: "mouse wheel does not auto enter copy mode in a normal pane when a
// non shell application has filled the screen" (Alacritty 0.17, psmux 3.3.8).
//
// THE REPORTED SHAPE.  A Spring Boot / Java process runs in a normal pane and
// prints its boot log until every single row carries text and the cursor sits on
// the last one.  It never emits a DECSET mouse sequence and never switches to
// the alternate screen.  Rolling the wheel up does nothing; scrollback is only
// reachable after typing prefix + [.
//
// MEASURED (tests/test_issue657_wheel_copy_mode_nonshell.ps1, a real attached
// client, a real screen filling non shell child, and real wheel notches):
//
//   psmux 3.3.8 (66cf613, the reporter's build)
//     [FAIL] wheel up did NOT enter copy mode (before=0 after=0)
//     [FAIL] the wheel was translated into arrow keys: RECV <ESC>[A<ESC>[A<ESC>[A
//   this tree
//     [PASS] wheel up entered copy mode over the filled non shell pane
//     [PASS] nothing was forwarded to the application
//
// WHY 3.3.8 BEHAVED THAT WAY.  Its wheel fallback keyed on the pane's
// FOREGROUND PROCESS IDENTITY, not on the pane's terminal state
// (window_ops.rs at 66cf613):
//
//     } else if non_shell_fg && !is_legacy_pager {
//         // General alternate-scroll: arrow keys (tmux DECSET-1007 parity).
//         let seq: &[u8] = if up { b"\x1b[A" } else { b"\x1b[B" };
//         for _ in 0..3 { crate::input::write_key_seq(pane, seq); }
//     } else if up && app.scroll_enter_copy_mode {
//         enter_copy_mode(app);
//
// A JVM IS the pane's foreground and is not a shell, so every notch wrote three
// Up arrows into its pty.  An application that reads nothing swallows them and
// the pane never moves, which is the report verbatim.  The same release also
// carried a content heuristic (`is_fullscreen_tui`, consulted through
// `pane_wants_mouse`) that called any pane whose last rows are non blank a
// fullscreen TUI, so the screen the reporter was looking at was the worst
// possible one to be looking at.
//
// TMUX PARITY.  tmux's default WheelUpPane binding (key-bindings.c:510) is
//
//     bind -n WheelUpPane { if -F '#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}' \
//         { send -M } { copy-mode -e } }
//
// with `mouse_any_flag` = `wp->base.mode & ALL_MOUSE_MODES` (format.c:1952,
// tmux.h:698).  All three terms are properties of the pane's own screen.  What
// program is in the foreground and what is painted on the screen are not terms
// at all, so a main screen logger gets copy mode scrollback in tmux however
// full the screen is.
//
// WHAT THESE TESTS PIN.  `pane_wheel_forward` (PR #548) is the single gate on
// both wheel entry points, and neither of them may regain a foreground-identity
// or screen-content term.  The cases below are written as the reporter's pane:
// every row full, cursor on the last row, foreground "java".

use crate::types::{AppState, Mode, Node, Window};
use ratatui::layout::Rect;
use std::io::Read;
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

fn tcp_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let accept_thr = std::thread::spawn(move || listener.accept().expect("accept").0);
    let client = TcpStream::connect(addr).expect("connect");
    let server = accept_thr.join().expect("join accept thread");
    (client, server)
}

const PANE_ID: usize = 657;
const COLS: u16 = 40;
const ROWS: u16 = 8;

/// One pane whose visible screen is COMPLETELY full of Spring Boot shaped log
/// lines with the cursor parked on the last row, plus the far end of its pty so
/// a test can see every byte the wheel writes towards the application.
struct Harness {
    app: AppState,
    peer: TcpStream,
    _reader_peer: TcpStream,
}

impl Harness {
    fn new(fg: Option<(bool, Option<&str>)>) -> Harness {
        Harness::build(fg, false, None)
    }

    /// `alt` puts the pane on the alternate screen; `proto` seeds a mouse
    /// protocol owner the way `update_mouse_proto_owner` would after the
    /// application's own DECSET.  Both are the audience that MUST keep the
    /// wheel (#598, #548, #613).
    fn build(
        fg: Option<(bool, Option<&str>)>,
        alt: bool,
        proto: Option<(vt100::MouseProtocolMode, bool)>,
    ) -> Harness {
        let (reader, reader_peer) = tcp_pair();
        let (writer, peer) = tcp_pair();
        let mut pane = crate::proxy_pane::create_proxy_pane(
            reader,
            writer,
            "127.0.0.1:1".to_string(),
            "test-key".to_string(),
            "test-session".to_string(),
            PANE_ID as u64,
            None,
            format!("pane-{PANE_ID}"),
            ROWS,
            COLS,
            PANE_ID,
            None,
        )
        .expect("create proxy pane");

        // Scrollback to scroll into, then a screen with no blank row left and
        // the cursor on the bottom one: the reporter's exact picture, and the
        // shape 3.3.8's `is_fullscreen_tui` misread as a TUI.
        let mut boot = String::new();
        for line in 0..80 {
            boot.push_str(&format!(
                "{line:5} INFO 12345 --- [  main] c.e.demo.DemoApplication : step ready\r\n"
            ));
        }
        // The final line is written without a trailing newline so the cursor
        // stays on the last row instead of scrolling one more time.
        boot.push_str("  ... started DemoApplication in 4.113 seconds");
        pane.term
            .lock()
            .expect("term lock")
            .process(boot.as_bytes());

        if alt {
            pane.term
                .lock()
                .expect("term lock")
                .process(b"\x1b[?1049h");
        }
        pane.mouse_proto_owner = proto;
        if let Some((non_shell, name)) = fg {
            pane.scroll_fg_cache =
                Some((Instant::now(), non_shell, name.map(|s| s.to_string())));
        }

        let mut app = AppState::new("i657".to_string());
        app.mouse_enabled = true;
        app.scroll_enter_copy_mode = true;
        app.last_window_area = Rect { x: 0, y: 0, width: COLS, height: ROWS };
        app.windows.push(Window {
            root: Node::Leaf(pane),
            active_path: vec![],
            name: "w0".to_string(),
            id: 0,
            area: app.client_area,
            window_size: None,
            window_options: Default::default(),
            activity_flag: false,
            bell_flag: false,
            silence_flag: false,
            last_output_time: std::time::Instant::now(),
            last_seen_version: 0,
            manual_rename: false,
            layout_index: 0,
            pane_mru: vec![PANE_ID],
            zoom_saved: None,
            linked_from: None,
            floating: Vec::new(),
            floating_focus: None,
        });
        peer.set_read_timeout(Some(Duration::from_millis(400)))
            .expect("read timeout");
        Harness { app, peer, _reader_peer: reader_peer }
    }

    /// The `pane-scroll` verb: what an attached client sends for every notch
    /// whose pointer is inside a pane.
    fn wheel(&mut self, up: bool) {
        super::handle_pane_scroll(&mut self.app, PANE_ID, up, Some((5, 5)));
    }

    /// The `scroll-up` / `scroll-down` verb: the fallback the client sends when
    /// the pointer is not inside any pane rect.  #657 claimed the two paths had
    /// drifted apart, so both are driven here.
    fn wheel_by_coords(&mut self, up: bool) {
        if up {
            super::remote_scroll_up(&mut self.app, 5, 5);
        } else {
            super::remote_scroll_down(&mut self.app, 5, 5);
        }
    }

    /// Is the visible screen really full, with the cursor on the last row?
    /// The bug report is about that picture, so the harness asserts it rather
    /// than assuming it.
    fn screen_is_full(&self) -> bool {
        let win = &self.app.windows[0];
        let Node::Leaf(pane) = &win.root else { return false };
        let parser = pane.term.lock().expect("term lock");
        let screen = parser.screen();
        let (cursor_row, _) = screen.cursor_position();
        let every_row_has_text = (0..ROWS).all(|row| {
            !screen.contents_between(row, 0, row, COLS).trim().is_empty()
        });
        every_row_has_text && cursor_row == ROWS - 1
    }

    fn forward_gate(&self) -> bool {
        let win = &self.app.windows[0];
        let Node::Leaf(pane) = &win.root else { return false };
        super::pane_wheel_forward(pane)
    }

    /// Everything the wheel typed at the application.
    fn typed(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut buf = [0u8; 256];
        loop {
            match self.peer.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    out.extend_from_slice(&buf[..n]);
                    if out.len() > 64 {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        out
    }
}

// ─────────────────────────────────────────────────────────────────────────
// PART 1: the reporter's pane.  A full screen of log lines from a non shell
// application is still a plain pane.
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue657_the_harness_really_builds_the_reported_picture() {
    let h = Harness::new(Some((true, Some("java"))));

    assert!(
        h.screen_is_full(),
        "#657 is about a pane with no blank row left and the cursor on the last \
         one; if the harness does not paint that, nothing below tests the report"
    );
}

#[test]
fn issue657_full_screen_non_shell_pane_is_not_a_wheel_forward_target() {
    let h = Harness::new(Some((true, Some("java"))));

    assert!(
        !h.forward_gate(),
        "#657: a pane that never enabled a mouse protocol and is not on the \
         alternate screen must not be a forward target, however full its screen \
         is and whatever program is in the foreground (tmux mouse_any_flag)"
    );
}

#[test]
fn issue657_wheel_up_over_a_full_screen_java_pane_enters_copy_mode() {
    let mut h = Harness::new(Some((true, Some("java"))));

    h.wheel(true);

    assert!(
        matches!(h.app.mode, Mode::CopyMode),
        "#657: wheel up over a screen filling non shell application must enter \
         copy mode; 3.3.8 took its foreground-identity branch instead and the \
         pane never moved"
    );
    assert!(
        h.app.copy_scroll_offset > 0,
        "#657: the notch must actually move into the pane's history"
    );
}

#[test]
fn issue657_wheel_up_over_a_full_screen_java_pane_types_nothing_at_it() {
    let mut h = Harness::new(Some((true, Some("java"))));

    h.wheel(true);
    let typed = h.typed();

    assert!(
        typed.is_empty(),
        "#657: the wheel must write nothing at an application that asked for \
         nothing, neither an SGR report nor the three ESC[A of the 3.3.8 \
         alternate-scroll branch.  Got {:?}",
        String::from_utf8_lossy(&typed)
    );
}

#[test]
fn issue657_every_notch_keeps_scrolling_the_full_screen_pane() {
    // "Wheel up does nothing" is not repaired by one recovered notch.
    let mut h = Harness::new(Some((true, Some("java"))));

    h.wheel(true);
    let first = h.app.copy_scroll_offset;
    h.wheel(true);
    let second = h.app.copy_scroll_offset;

    assert!(
        first > 0 && second > first,
        "#657: each notch must keep scrolling ({first} -> {second})"
    );
}

#[test]
fn issue657_wheeling_back_to_the_bottom_leaves_copy_mode() {
    // tmux parity for the other half of the gesture.
    let mut h = Harness::new(Some((true, Some("java"))));

    h.wheel(true);
    assert!(matches!(h.app.mode, Mode::CopyMode));
    for _ in 0..40 {
        h.wheel(false);
    }

    assert!(
        matches!(h.app.mode, Mode::Passthrough),
        "#657: wheeling back down to the live output must leave copy mode"
    );
    assert_eq!(h.app.copy_scroll_offset, 0);
}

// ─────────────────────────────────────────────────────────────────────────
// PART 2: the two wheel entry points must agree.  The report claimed the
// pointer-inside-a-pane path and the coordinate fallback had drifted apart.
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue657_both_wheel_entry_points_agree_on_a_full_screen_non_shell_pane() {
    let mut by_id = Harness::new(Some((true, Some("java"))));
    by_id.wheel(true);
    let by_id_mode = matches!(by_id.app.mode, Mode::CopyMode);
    let by_id_typed = by_id.typed();

    let mut by_xy = Harness::new(Some((true, Some("java"))));
    by_xy.wheel_by_coords(true);
    let by_xy_mode = matches!(by_xy.app.mode, Mode::CopyMode);
    let by_xy_typed = by_xy.typed();

    assert!(
        by_id_mode && by_xy_mode,
        "#657: handle_pane_scroll (pane-scroll) and remote_scroll_wheel \
         (scroll-up) must reach the same decision: copy mode by id={by_id_mode} \
         copy mode by coords={by_xy_mode}"
    );
    assert!(
        by_id_typed.is_empty() && by_xy_typed.is_empty(),
        "#657: neither entry point may type at the application: by id {:?}, by \
         coords {:?}",
        String::from_utf8_lossy(&by_id_typed),
        String::from_utf8_lossy(&by_xy_typed)
    );
}

// ─────────────────────────────────────────────────────────────────────────
// PART 3: the opposite audience.  Loosening the gate for #657 must not take
// the wheel away from the applications that earned it (#598, #548, #613).
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue657_alternate_screen_pane_never_opens_copy_mode() {
    // `less`, `more`, a pager: on the alternate screen without a mouse
    // protocol.  psmux has nothing to encode for it, so the byte level claim
    // belongs to the case below; what matters here is that copy mode does not
    // open over a pane the gate hands to its child.
    let mut h = Harness::build(Some((true, Some("less"))), true, None);

    assert!(h.forward_gate(), "an alternate screen pane is a forward target");
    h.wheel(true);

    assert!(
        !matches!(h.app.mode, Mode::CopyMode),
        "an alternate screen application keeps the wheel; psmux must not open \
         copy mode over it"
    );
}

#[test]
fn issue657_alternate_screen_mouse_app_still_receives_the_wheel() {
    // The codex / htop case from #598: alternate screen AND the application
    // reads the wheel itself.  Every notch must reach it.
    let mut h = Harness::build(
        Some((true, Some("htop"))),
        true,
        Some((vt100::MouseProtocolMode::AnyMotion, true)),
    );

    assert!(h.forward_gate(), "an alt screen mouse app is a forward target");
    h.wheel(true);

    assert!(
        !matches!(h.app.mode, Mode::CopyMode),
        "copy mode must not open over an alt screen mouse application"
    );
    assert!(
        !h.typed().is_empty(),
        "the wheel must reach an alt screen application that enabled mouse \
         tracking (#598)"
    );
}

#[test]
fn issue657_app_owned_mouse_protocol_still_receives_the_wheel() {
    let mut h = Harness::build(
        Some((true, Some("nvim"))),
        false,
        Some((vt100::MouseProtocolMode::PressRelease, true)),
    );

    assert!(
        h.forward_gate(),
        "a pane whose application enabled a mouse protocol is a forward target"
    );
    h.wheel(true);

    assert!(
        !matches!(h.app.mode, Mode::CopyMode),
        "an application that enabled mouse tracking keeps the wheel"
    );
    assert!(
        !h.typed().is_empty(),
        "the wheel must reach an application that enabled mouse tracking"
    );
}

#[test]
fn issue657_shell_attributed_mouse_protocol_does_not_steal_the_wheel() {
    // PSReadLine turns mouse tracking on at a prompt without meaning it; the
    // attribution half of `mouse_proto_owner` says so, and the wheel stays with
    // copy mode (#548).  Pinned here so a #657 style change cannot quietly flip
    // the attribution term instead of the forwarding term.
    let mut h = Harness::build(
        Some((false, Some("pwsh"))),
        false,
        Some((vt100::MouseProtocolMode::PressRelease, false)),
    );

    assert!(!h.forward_gate(), "a shell attributed protocol is not ownership");
    h.wheel(true);

    assert!(
        matches!(h.app.mode, Mode::CopyMode),
        "#548: a mouse protocol psmux attributed to the shell must not take the \
         wheel away from copy mode"
    );
}
