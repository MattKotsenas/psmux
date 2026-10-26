// Issue #621: "Mouse-wheel scroll stops working while a program is blocking on
// a stdin read" (psmux 3.3.8, 66cf613).
//
// MEASURED ON THIS TREE with a real attached client and real MOUSE_EVENT wheel
// injection (tests/test_issue621_wheel_stdin_block.ps1), against a build that
// carries the 3.3.8 wheel fallback verbatim:
//
//   [PASS] baseline: the wheel at a pwsh prompt enters copy mode
//   [PASS] the script printed 40 lines and is blocked in input()
//   [PASS] the pane's foreground is a confirmed non-shell process ('python')
//   [PASS] the pane is on the main screen (alternate_on=0)
//   [FAIL] BUG #621: wheel-up over the blocked read did NOT enter copy mode
//                    (pane_in_mode=0)
//   [FAIL] the view did not move; the wheel scrolled nothing
//   [FAIL] the wheel behaves differently across the Ctrl+C (during=0 after=1)
//
// and against this tree, all of them pass.
//
// ROOT CAUSE.  The 3.3.8 wheel fallback had a general alternate-scroll branch
// keyed on the pane's FOREGROUND PROCESS IDENTITY rather than on the pane's
// terminal state (window_ops.rs at 66cf613):
//
//     } else if non_shell_fg && !is_legacy_pager {
//         // General alternate-scroll: arrow keys (tmux DECSET-1007 parity).
//         let seq: &[u8] = if up { b"\x1b[A" } else { b"\x1b[B" };
//         for _ in 0..3 { crate::input::write_key_seq(pane, seq); }
//     } else if up && app.scroll_enter_copy_mode {
//         enter_copy_mode(app);
//
// `non_shell_fg` comes from `scroll_foreground_classify`, i.e. a confirmed
// `foreground_is_shell(pid) == Some(false)`.  A program blocked in `input()` IS
// the pane's foreground and is not a shell, so every notch wrote three
// `ESC [ A` into the pty instead of opening copy mode.  Those arrows land in a
// Windows canonical read (`ENABLE_LINE_INPUT`; measured 0x01F7 while `input()`
// blocks, against 0x01E4 at the PSReadLine prompt), where the console's own
// line editor answers Up with "recall the previous history entry" -- the
// reported prompt-history cycling and cursor flicker.  Killing the program made
// the shell the foreground again, `non_shell_fg` went false, and the wheel
// worked, which is exactly the Ctrl+C workaround in the report.
//
// TMUX PARITY.  tmux's default WheelUpPane binding (key-bindings.c:510) is
//
//     if -F '#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}' \
//         'send -M' 'copy-mode -e'
//
// Three terms, all of them properties of the pane's own screen.  "The
// foreground process is not a shell" is not among them, and alternate-scroll
// (DECSET 1007) is defined for ALTERNATE-screen panes only, so in tmux a
// main-screen program blocked on a canonical read gets copy-mode scrollback no
// matter what it is doing with stdin.
//
// FIX.  The blanket arrow-key branch is gone (PR #548, merged 6ff92a4, three
// days after the 3.3.8 release commit 66cf613): forwarding is decided by
// `pane_wheel_forward` -- the alternate screen, or a mouse protocol the
// application itself enabled -- and everything else falls through to copy mode.
// `more.com` survives as an exact one-name allowlist because it parses no
// escape sequences at all and cannot be reached any other way.
//
// These tests pin that the decision never consults the foreground identity for
// anything but that one name.

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

/// An `AppState` with one pane holding 80 lines of scrollback, plus the far end
/// of that pane's pty so the test can see every byte psmux writes towards the
/// application.
struct Harness {
    app: AppState,
    /// Peer of the pane writer.  Anything the wheel types at the application
    /// arrives here.
    peer: TcpStream,
    /// Kept alive: dropping either half closes the pane's sockets.
    _reader_peer: TcpStream,
}

const PANE_ID: usize = 621;

impl Harness {
    /// `fg` is seeded straight into `Pane::scroll_fg_cache`, which is what
    /// `scroll_foreground_classify` returns for the next two seconds.  That is
    /// the whole of the process probe as far as the wheel is concerned, so
    /// seeding it reproduces "a confirmed non-shell program is the pane's
    /// foreground" without needing a live child.
    fn new(fg: Option<(bool, Option<&str>)>) -> Harness {
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
            8,
            40,
            PANE_ID,
            None,
        )
        .expect("create proxy pane");

        let history = (0..80)
            .map(|line| format!("i621-history-{line}\r\n"))
            .collect::<String>();
        pane.term
            .lock()
            .expect("term lock")
            .process(history.as_bytes());

        if let Some((non_shell, name)) = fg {
            pane.scroll_fg_cache =
                Some((Instant::now(), non_shell, name.map(|s| s.to_string())));
        }

        let mut app = AppState::new("i621".to_string());
        app.mouse_enabled = true;
        app.scroll_enter_copy_mode = true;
        app.last_window_area = Rect { x: 0, y: 0, width: 40, height: 8 };
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

    fn wheel(&mut self, up: bool) {
        super::handle_pane_scroll(&mut self.app, PANE_ID, up, None);
    }

    /// Everything the wheel typed at the application.  The pane writer is an
    /// async queue, so this deliberately blocks on the socket for its full read
    /// timeout rather than sampling.
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
// PART 1: the bug.  A confirmed non-shell foreground must not change the
// wheel.
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue621_wheel_over_a_blocked_reader_enters_copy_mode() {
    // `python test.py`, stopped in `input()`: the pane's foreground is a
    // confirmed non-shell program on the MAIN screen with no mouse protocol.
    let mut h = Harness::new(Some((true, Some("python"))));

    h.wheel(true);

    assert!(
        matches!(h.app.mode, Mode::CopyMode),
        "#621: wheel-up over a program blocked on a stdin read must enter copy \
         mode, exactly as it does at the shell prompt; 3.3.8 took the \
         alternate-scroll branch instead and left the pane in passthrough"
    );
    assert!(
        h.app.copy_scroll_offset > 0,
        "#621: the wheel must actually move into the pane's history"
    );
}

#[test]
fn issue621_wheel_over_a_blocked_reader_types_nothing_at_it() {
    let mut h = Harness::new(Some((true, Some("python"))));

    h.wheel(true);
    let typed = h.typed();

    assert!(
        typed.is_empty(),
        "#621: the wheel must write nothing into a program blocked on a \
         canonical read; 3.3.8 wrote three ESC[A per notch, which the Windows \
         line editor answers with prompt-history recall.  Got {:?}",
        String::from_utf8_lossy(&typed)
    );
}

#[test]
fn issue621_wheel_down_over_a_blocked_reader_types_nothing_at_it() {
    // Wheel-down had the same branch with ESC[B, so it recalled history
    // forwards.  At the bottom of the scrollback tmux does nothing at all.
    let mut h = Harness::new(Some((true, Some("python"))));

    h.wheel(false);
    let typed = h.typed();

    assert!(
        typed.is_empty(),
        "#621: wheel-down must not type ESC[B at a blocked reader; got {:?}",
        String::from_utf8_lossy(&typed)
    );
    assert!(
        matches!(h.app.mode, Mode::Passthrough),
        "wheel-down at the live bottom opens nothing (tmux parity)"
    );
}

#[test]
fn issue621_repeated_notches_keep_scrolling_a_blocked_reader() {
    // The report is of a wheel that does not work at all, so one recovered
    // notch is not the fix.
    let mut h = Harness::new(Some((true, Some("python"))));

    h.wheel(true);
    let first = h.app.copy_scroll_offset;
    h.wheel(true);
    let second = h.app.copy_scroll_offset;
    h.wheel(true);

    assert!(first > 0 && second > first && h.app.copy_scroll_offset > second,
        "#621: every notch must keep scrolling ({first} -> {second} -> {})",
        h.app.copy_scroll_offset);
    assert!(h.typed().is_empty(), "#621: and none of them may type at the program");
}

// ─────────────────────────────────────────────────────────────────────────
// PART 2: the foreground identity must not be able to change the answer.
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue621_blocked_reader_and_shell_prompt_agree() {
    // The reporter's evidence for the cause was that Ctrl+C fixed it: the only
    // thing that changed was which process was in the foreground.  Pin that
    // those two now produce identical wheel behavior.
    let mut blocked = Harness::new(Some((true, Some("python"))));
    let mut prompt = Harness::new(Some((false, Some("pwsh"))));

    blocked.wheel(true);
    prompt.wheel(true);

    assert_eq!(
        blocked.app.copy_scroll_offset, prompt.app.copy_scroll_offset,
        "#621: a blocked non-shell foreground and a shell prompt must scroll \
         the same amount; the Ctrl+C in the report was a workaround for these \
         two disagreeing"
    );
    assert!(matches!(blocked.app.mode, Mode::CopyMode));
    assert!(matches!(prompt.app.mode, Mode::CopyMode));
}

#[test]
fn issue621_unprobeable_foreground_still_enters_copy_mode() {
    // A probe failure must land on the same side, never on "type at it".
    let mut h = Harness::new(None);

    h.wheel(true);

    assert!(matches!(h.app.mode, Mode::CopyMode),
        "a foreground the process walk could not classify still gets copy mode");
    assert!(h.typed().is_empty());
}

// ─────────────────────────────────────────────────────────────────────────
// PART 3: what stays.  The one deliberate exception, and the forwarding gate
// itself, are untouched by #621.
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn issue621_more_com_keeps_its_wheel_down_enter() {
    // `more.com` is an exact one-name allowlist (#277): a DOS-heritage reader
    // that parses no escape sequences, so Enter is its only "advance" key.
    // #621 must not take that away.
    let mut h = Harness::new(Some((true, Some("more"))));

    h.wheel(false);
    let typed = h.typed();

    assert_eq!(typed, b"\r\r\r".to_vec(),
        "more.com still gets three Enters on wheel-down (#277); got {:?}",
        String::from_utf8_lossy(&typed));
}

#[test]
fn issue621_more_com_wheel_up_still_enters_copy_mode() {
    // more.com cannot page backwards, so wheel-up was always copy mode.
    let mut h = Harness::new(Some((true, Some("more"))));

    h.wheel(true);

    assert!(matches!(h.app.mode, Mode::CopyMode));
    assert!(h.typed().is_empty(), "wheel-up types nothing at more.com");
}

#[test]
fn issue621_forwarding_gate_is_pane_state_not_foreground_identity() {
    // The surviving gate reads the pane's own terminal state, the same three
    // properties tmux's WheelUpPane binding reads.  A blocked non-shell
    // foreground on the main screen with no mouse protocol is not one of them.
    let h = Harness::new(Some((true, Some("python"))));
    let pane = match &h.app.windows[0].root {
        Node::Leaf(p) => p,
        _ => unreachable!("single leaf"),
    };
    assert!(!super::pane_in_alt_screen(pane), "main screen");
    assert!(pane.mouse_proto_owner.is_none(), "no application mouse protocol");
    assert!(!super::pane_wheel_forward(pane),
        "#621: nothing about a blocked stdin read may authorize forwarding");
}

#[test]
fn issue621_an_app_that_asked_still_gets_the_wheel() {
    // The fix is a fallback change only.  A pane whose application enabled the
    // mouse itself must still forward (#570 / #613 audience), even though its
    // foreground is just as much "a confirmed non-shell program" as python is.
    let mut h = Harness::new(Some((true, Some("nvim"))));
    if let Node::Leaf(pane) = &mut h.app.windows[0].root {
        pane.mouse_proto_owner = Some((vt100::MouseProtocolMode::AnyMotion, true));
        assert!(super::pane_wheel_forward(pane),
            "an application-owned mouse protocol still authorizes forwarding");
    } else {
        unreachable!("single leaf");
    }

    h.wheel(true);
    assert!(!matches!(h.app.mode, Mode::CopyMode),
        "#598/#570: copy mode must not open over a pane that forwards");
}
