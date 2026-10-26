// Issue #662: `psmux display-message -p '#{mouse_any_flag}'` printed an empty
// string, and so did the other five mouse tracking flags.
//
// MEASURED on 37e2990, `-L i662`, a detached session:
//
//   mouse_any_flag         rc=0 -> ''
//   mouse_standard_flag    rc=0 -> ''
//   mouse_button_flag      rc=0 -> ''
//   mouse_all_flag         rc=0 -> ''
//   mouse_utf8_flag        rc=0 -> ''
//   mouse_sgr_flag         rc=0 -> ''
//   alternate_on           rc=0 -> '0'
//   pane_in_mode           rc=0 -> '0'
//
// and on this tree, the same session with a pane program that wrote ESC[?1000h:
//
//   plain shell pane : 'any=0 std=0 btn=0 all=0 utf8=0 sgr=0 alt=0 mode=0 cond=0'
//   after ESC[?1000h : 'any=1 std=1 btn=0 all=0 utf8=0 sgr=1 alt=0 mode=0 cond=1'
//
// WHY IT MATTERS.  tmux's default wheel binding is written in terms of the
// third flag (key-bindings.c:510):
//
//   bind -n WheelUpPane { if -F '#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}' \
//       { send -M } { copy-mode -e } }
//
// `#{||:...}` reads an empty string as false, so that line in a psmux config
// could only ever reach `copy-mode -e`, whatever the pane's application had
// asked for.
//
// TMUX PARITY.  All six are read straight off the pane's own screen mode:
//
//   format.c:1940  mouse_all_flag       wp->base.mode & MODE_MOUSE_ALL      (1003)
//   format.c:1952  mouse_any_flag       wp->base.mode & ALL_MOUSE_MODES
//   format.c:1964  mouse_button_flag    wp->base.mode & MODE_MOUSE_BUTTON   (1002)
//   format.c:1991  mouse_sgr_flag       wp->base.mode & MODE_MOUSE_SGR      (1006)
//   format.c:2003  mouse_standard_flag  wp->base.mode & MODE_MOUSE_STANDARD (1000)
//   format.c:2015  mouse_utf8_flag      wp->base.mode & MODE_MOUSE_UTF8     (1005)
//   tmux.h:698     ALL_MOUSE_MODES = STANDARD|BUTTON|ALL, so the two ENCODING
//                  bits are deliberately NOT part of mouse_any_flag
//
// and the three tracking modes are mutually exclusive, because every DECSET
// clears the family before setting its own bit (input.c:2053-2065) and every
// DECRST clears the whole family (input.c:1955-1959).  The two encoding bits
// are independent of each other and of the tracking mode.

use crate::types::{AppState, Node, Pane, Window};
use std::net::{TcpListener, TcpStream};

const PANE_ID: usize = 662;
const COLS: u16 = 40;
const ROWS: u16 = 8;

fn tcp_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let accept_thr = std::thread::spawn(move || listener.accept().expect("accept").0);
    let client = TcpStream::connect(addr).expect("connect");
    let server = accept_thr.join().expect("join accept thread");
    (client, server)
}

/// A pane with a real parser on one end and a live pty peer on the other, kept
/// alive by the returned streams.
fn make_pane(id: usize) -> (Pane, TcpStream, TcpStream) {
    let (reader, reader_peer) = tcp_pair();
    let (writer, peer) = tcp_pair();
    let pane = crate::proxy_pane::create_proxy_pane(
        reader,
        writer,
        "127.0.0.1:1".to_string(),
        "test-key".to_string(),
        "test-session".to_string(),
        id as u64,
        None,
        format!("pane-{id}"),
        ROWS,
        COLS,
        id,
        None,
    )
    .expect("create proxy pane");
    (pane, peer, reader_peer)
}

fn feed(pane: &Pane, bytes: &[u8]) {
    pane.term.lock().expect("term lock").process(bytes);
}

/// One window holding one pane whose parser can be fed real DECSET bytes, so
/// every assertion below goes through the same path a pane program's output
/// takes.
struct Harness {
    app: AppState,
    _peer: TcpStream,
    _reader_peer: TcpStream,
}

impl Harness {
    fn new() -> Harness {
        let (pane, peer, reader_peer) = make_pane(PANE_ID);

        let mut app = AppState::new("i662".to_string());
        app.window_base_index = 0;
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
        Harness { app, _peer: peer, _reader_peer: reader_peer }
    }

    /// Feed bytes to the pane's parser, the way pane output arrives.
    fn emit(&mut self, bytes: &[u8]) {
        let Node::Leaf(pane) = &self.app.windows[0].root else {
            panic!("harness window is not a leaf");
        };
        feed(pane, bytes);
    }

    fn var(&self, name: &str) -> String {
        super::expand_format(&format!("#{{{name}}}"), &self.app)
    }

    /// `any std btn all utf8 sgr`, the reading order used by the E2E script.
    fn flags(&self) -> String {
        super::expand_format(
            "#{mouse_any_flag} #{mouse_standard_flag} #{mouse_button_flag} \
             #{mouse_all_flag} #{mouse_utf8_flag} #{mouse_sgr_flag}",
            &self.app,
        )
    }
}

/// The bug itself: the names must resolve at all.  An unknown variable is NOT
/// an empty string in this code base, it is UNKNOWN_VAR, and the six names
/// used to fall through to the option lookup and out the other side.
#[test]
fn every_mouse_flag_resolves_to_a_digit() {
    let h = Harness::new();
    for name in [
        "mouse_any_flag",
        "mouse_standard_flag",
        "mouse_button_flag",
        "mouse_all_flag",
        "mouse_utf8_flag",
        "mouse_sgr_flag",
    ] {
        let v = h.var(name);
        assert!(
            v == "0" || v == "1",
            "#{{{name}}} rendered {v:?}, expected \"0\" or \"1\" (#662)"
        );
    }
}

/// A pane that has asked for nothing reports nothing.
#[test]
fn defaults_are_all_zero() {
    let h = Harness::new();
    assert_eq!(h.flags(), "0 0 0 0 0 0");
}

/// DECSET 1000 is tmux's MODE_MOUSE_STANDARD and nothing else.
#[test]
fn decset_1000_sets_only_the_standard_flag() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1000h");
    assert_eq!(h.flags(), "1 1 0 0 0 0");
}

/// DECSET 1002 is MODE_MOUSE_BUTTON, and it replaces 1000 rather than adding
/// to it (input.c:2057 clears ALL_MOUSE_MODES first).
#[test]
fn decset_1002_sets_only_the_button_flag_and_replaces_1000() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1000h");
    h.emit(b"\x1b[?1002h");
    assert_eq!(h.flags(), "1 0 1 0 0 0");
}

/// DECSET 1003 is MODE_MOUSE_ALL, likewise exclusive.
#[test]
fn decset_1003_sets_only_the_all_flag() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1002h");
    h.emit(b"\x1b[?1003h");
    assert_eq!(h.flags(), "1 0 0 1 0 0");
}

/// X10 tracking (DECSET 9) is press-only reporting, the mode 1000 extends.
/// tmux does not implement 9 at all; this parser does, and a pane that has it
/// on is a pane the wheel belongs to, so it must not read as "no mouse".
#[test]
fn decset_9_counts_as_standard_tracking() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?9h");
    assert_eq!(h.flags(), "1 1 0 0 0 0");
}

/// The encoding modes report themselves and nothing else: an encoding with no
/// tracking mode sends no reports, which is why tmux leaves both out of
/// ALL_MOUSE_MODES (tmux.h:698).
#[test]
fn encodings_alone_do_not_set_mouse_any_flag() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1005h");
    assert_eq!(h.flags(), "0 0 0 0 1 0");
    let mut h = Harness::new();
    h.emit(b"\x1b[?1006h");
    assert_eq!(h.flags(), "0 0 0 0 0 1");
}

/// MODE_MOUSE_UTF8 and MODE_MOUSE_SGR are two bits, not one setting: an
/// application that turned both on has both flags set, and withdrawing one
/// leaves the other alone.
#[test]
fn utf8_and_sgr_are_independent_bits() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1000h\x1b[?1005h\x1b[?1006h");
    assert_eq!(h.flags(), "1 1 0 0 1 1");
    h.emit(b"\x1b[?1006l");
    assert_eq!(h.flags(), "1 1 0 0 1 0");
    h.emit(b"\x1b[?1005l");
    assert_eq!(h.flags(), "1 1 0 0 0 0");
}

/// The app's own teardown sequence, in the order crossterm and friends write
/// it, must leave the pane reporting nothing.
#[test]
fn decrst_clears_what_decset_set() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h");
    assert_eq!(h.flags(), "1 0 0 1 0 1");
    h.emit(b"\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l");
    assert_eq!(h.flags(), "0 0 0 0 0 0");
}

/// tmux turns the whole tracking family off for ANY of 1000/1001/1002/1003
/// (input.c:1955-1959), so an app that enabled 1003 and disables with a bare
/// ESC[?1000l really does go quiet.
#[test]
fn decrst_of_a_sibling_mode_clears_the_family_like_tmux() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1003h");
    assert_eq!(h.var("mouse_all_flag"), "1");
    h.emit(b"\x1b[?1000l");
    assert_eq!(h.flags(), "0 0 0 0 0 0");
}

/// The alternate screen and the mouse modes are separate state in tmux: only
/// the app's own DECRST takes the mouse away, not leaving the alt screen.
#[test]
fn leaving_the_alternate_screen_keeps_the_mouse_flags() {
    let mut h = Harness::new();
    h.emit(b"\x1b[?1049h\x1b[?1003h\x1b[?1006h");
    assert_eq!(h.var("alternate_on"), "1");
    assert_eq!(h.flags(), "1 0 0 1 0 1");
    h.emit(b"\x1b[?1049l");
    assert_eq!(h.var("alternate_on"), "0");
    assert_eq!(
        h.flags(),
        "1 0 0 1 0 1",
        "leaving the alternate screen must not clear mouse modes (tmux keeps \
         them on the pane's base screen)"
    );
}

/// The line the issue is about, verbatim from tmux's key-bindings.c:510, must
/// evaluate: false over a plain pane, true once the application asks for the
/// mouse, and true again for each of the other two terms on their own.
#[test]
fn tmux_wheel_binding_condition_evaluates() {
    const COND: &str = "#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}";

    let h = Harness::new();
    assert_eq!(
        super::expand_format(COND, &h.app),
        "0",
        "a pane that asked for nothing must take the copy-mode branch"
    );

    let mut h = Harness::new();
    h.emit(b"\x1b[?1000h");
    assert_eq!(
        super::expand_format(COND, &h.app),
        "1",
        "a pane whose application enabled mouse tracking must take `send -M`"
    );

    let mut h = Harness::new();
    h.emit(b"\x1b[?1049h");
    assert_eq!(super::expand_format(COND, &h.app), "1", "alternate_on term");

    // And the conditional form the same binding could be written with.
    let mut h = Harness::new();
    h.emit(b"\x1b[?1003h");
    assert_eq!(
        super::expand_format("#{?mouse_any_flag,send,copy}", &h.app),
        "send"
    );
    h.emit(b"\x1b[?1003l");
    assert_eq!(
        super::expand_format("#{?mouse_any_flag,send,copy}", &h.app),
        "copy"
    );
}

/// The flags belong to the pane being asked about, not to the active one:
/// `list-panes -F` and `display-message -t %N` must answer per pane the way
/// tmux's `ft->wp` does.
#[test]
fn flags_follow_the_target_pane_not_the_active_one() {
    let mut h = Harness::new();

    // The pane on the left asked for 1003; the one on the right asked for
    // nothing.  The active pane is the quiet one, so an implementation that
    // reads the active pane (the way `#{alternate_on}` does) answers 0 twice.
    let (noisy, _p1, _r1) = make_pane(PANE_ID);
    let (quiet, _p2, _r2) = make_pane(PANE_ID + 1);
    feed(&noisy, b"\x1b[?1003h");

    h.app.windows[0].root = Node::Split {
        kind: crate::types::LayoutKind::Horizontal,
        sizes: vec![50, 50],
        children: vec![Node::Leaf(noisy), Node::Leaf(quiet)],
    };
    h.app.windows[0].active_path = vec![1];
    h.app.windows[0].pane_mru = vec![PANE_ID + 1, PANE_ID];

    let per_pane = super::format_list_panes(&h.app, "#{pane_id}:#{mouse_all_flag}", 0);
    let lines: Vec<&str> = per_pane.lines().collect();
    assert_eq!(lines.len(), 2, "expected two panes, got {per_pane:?}");
    assert_eq!(
        lines[0],
        format!("%{PANE_ID}:1"),
        "the pane that enabled 1003 must report it: {per_pane:?}"
    );
    assert_eq!(
        lines[1],
        format!("%{}:0", PANE_ID + 1),
        "the pane next door asked for nothing: {per_pane:?}"
    );
}
