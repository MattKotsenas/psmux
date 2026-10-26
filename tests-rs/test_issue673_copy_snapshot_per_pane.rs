// Issue #673 part 2: every pane in copy mode holds its OWN snapshot, for as
// long as it is in copy mode.
//
// PR #671 reconciled snapshots with `sync_copy_snapshot`, which gated on the
// active pane of the active window:
//
//     if want && is_active_window && Some(p.id) == active_id { enter } else { leave }
//
// psmux allows several panes in copy mode at once (#607), and `copy-mode -t`
// puts a pane that is not the focused one into copy mode. Such a pane took a
// snapshot while the target focus was borrowed, then lost it on the very next
// frame, so its own output kept pushing the view it was meant to freeze.
// Reproduced against the real server with two panes, both printing, the NON
// active one in copy mode:
//
//   [NON ACTIVE PANE] last visible line before: 'P LINE 93'  after 4s: 'P LINE 152'
//   [ACTIVE PANE]     last visible line before: 'P LINE 32'  after 4s: 'P LINE 32'
//
// tmux has no such gate: `window_copy_init` copies the grid of whichever pane
// enters the mode, and the mode lives on that `window_pane` until it is
// dismissed, focused or not.
//
// These tests drive `sync_copy_snapshot` over a two pane window and a second
// window, with the copy mode pane never being the focused one.

use super::*;

use crate::copy_mode::sync_copy_snapshot;
use crate::types::{CopyModeState, Mode, Node, SelectionMode};

fn tcp_pair() -> (std::net::TcpStream, std::net::TcpStream) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let accept = std::thread::spawn(move || listener.accept().expect("accept").0);
    let client = std::net::TcpStream::connect(addr).expect("connect");
    let server = accept.join().expect("join accept thread");
    (client, server)
}

/// A real `Pane` with a real vt100 parser and no child process behind it.
fn proxy_pane(id: usize) -> crate::types::Pane {
    let (reader, _peer_reader) = tcp_pair();
    let (writer, _peer_writer) = tcp_pair();
    crate::proxy_pane::create_proxy_pane(
        reader,
        writer,
        "127.0.0.1:1".to_string(),
        "test-key".to_string(),
        "test-session".to_string(),
        0,
        None,
        format!("pane-{id}"),
        24,
        80,
        id,
        None,
    )
    .expect("create proxy pane")
}

fn window(root: Node, id: usize, active_path: Vec<usize>, area: ratatui::layout::Rect) -> crate::types::Window {
    crate::types::Window {
        root,
        active_path,
        name: format!("w{id}"),
        id,
        area,
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

/// One window, two panes side by side. Pane 1 is the focused one, pane 2 is
/// not; both are live.
fn app_with_two_panes() -> AppState {
    let mut app = AppState::new("copyscope".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app.last_window_area = ratatui::layout::Rect { x: 0, y: 0, width: 80, height: 24 };
    let root = Node::Split {
        kind: crate::types::LayoutKind::Horizontal,
        sizes: vec![50, 50],
        children: vec![Node::Leaf(proxy_pane(1)), Node::Leaf(proxy_pane(2))],
    };
    let w = window(root, 0, vec![0], app.last_window_area);
    app.windows.clear();
    app.windows.push(w);
    app.active_idx = 0;
    app
}

fn pane_by_id(app: &AppState, id: usize) -> &crate::types::Pane {
    for win in &app.windows {
        if let Some(path) = crate::tree::find_path_by_id(&win.root, id) {
            if let Some(p) = crate::tree::active_pane(&win.root, &path) {
                return p;
            }
        }
    }
    panic!("pane {id} not found");
}

fn pane_mut_by_id(app: &mut AppState, id: usize) -> &mut crate::types::Pane {
    for win in app.windows.iter_mut() {
        if let Some(path) = crate::tree::find_path_by_id(&win.root, id) {
            if let Some(p) = crate::tree::active_pane_mut(&mut win.root, &path) {
                return p;
            }
        }
    }
    panic!("pane {id} not found");
}

fn holds_snapshot(app: &AppState, id: usize) -> bool {
    pane_by_id(app, id).live_term.is_some()
}

fn view_of(app: &AppState, id: usize) -> String {
    pane_by_id(app, id)
        .term
        .lock()
        .map(|p| p.screen().contents())
        .unwrap_or_default()
}

fn feed_live(app: &AppState, id: usize, prefix: &str, from: usize, to: usize) {
    let live = pane_by_id(app, id).live_parser().clone();
    if let Ok(mut parser) = live.lock() {
        for i in from..to {
            parser.process(format!("{prefix} {i}\r\n").as_bytes());
        }
    };
}

/// The pane's own parked copy mode state, which is what `#{pane_in_mode}`
/// answers with for every pane that is not the focused one.
fn parked_copy_state(offset: usize) -> CopyModeState {
    CopyModeState {
        anchor: None,
        anchor_scroll_offset: 0,
        pos: Some((0, 0)),
        scroll_offset: offset,
        selection_mode: SelectionMode::Char,
        search_query: String::new(),
        count: None,
        search_matches: Vec::new(),
        search_idx: 0,
        search_forward: true,
        find_char_pending: None,
        text_object_pending: None,
        register_pending: false,
        register: None,
        mark: None,
        last_jump: None,
        hide_position: false,
        in_search: false,
        search_input: String::new(),
        search_input_forward: true,
    }
}

/// The reported defect: a pane in copy mode that is not the focused one must
/// keep its snapshot instead of having it taken away every frame.
#[test]
fn a_non_active_pane_in_copy_mode_keeps_its_own_snapshot() {
    let mut app = app_with_two_panes();
    // Pane 2 is in copy mode; pane 1 is focused and is not.
    pane_mut_by_id(&mut app, 2).copy_state = Some(parked_copy_state(0));
    app.mode = Mode::Passthrough;

    sync_copy_snapshot(&mut app);

    assert!(
        holds_snapshot(&app, 2),
        "the pane in copy mode must hold a snapshot even though another pane has focus"
    );
    assert!(
        !holds_snapshot(&app, 1),
        "a pane that is not in copy mode must read the live screen"
    );

    // And the frame after, and the frame after that: the reconciliation must
    // not take it away again.
    sync_copy_snapshot(&mut app);
    sync_copy_snapshot(&mut app);
    assert!(
        holds_snapshot(&app, 2),
        "the snapshot must survive every later frame the pane stays in copy mode"
    );
}

/// What the snapshot is FOR: the pane's own output can no longer push the view
/// the reader is holding still.
#[test]
fn the_non_active_copy_mode_pane_view_does_not_follow_its_output() {
    let mut app = app_with_two_panes();
    feed_live(&app, 2, "before", 0, 40);
    pane_mut_by_id(&mut app, 2).copy_state = Some(parked_copy_state(0));

    sync_copy_snapshot(&mut app);
    let frozen = view_of(&app, 2);
    assert!(frozen.contains("before 39"), "fixture must have printed into pane 2");

    // The pane keeps printing while it is in copy mode, and frames keep going
    // through the reconciliation.
    for _ in 0..5 {
        feed_live(&app, 2, "after", 0, 200);
        sync_copy_snapshot(&mut app);
    }

    assert_eq!(
        view_of(&app, 2),
        frozen,
        "the non active pane's copy mode view must be frozen, not pushed by its own output"
    );
    let live = pane_by_id(&app, 2).live_parser().clone();
    let live_text = live.lock().map(|p| p.screen().contents()).unwrap_or_default();
    assert!(
        live_text.contains("after 199"),
        "the live screen behind the snapshot must keep running"
    );
}

/// Leaving copy mode still gives the pane back its live screen, whether or not
/// it ever held focus.
#[test]
fn dropping_the_mode_returns_the_non_active_pane_to_the_live_screen() {
    let mut app = app_with_two_panes();
    pane_mut_by_id(&mut app, 2).copy_state = Some(parked_copy_state(0));
    sync_copy_snapshot(&mut app);
    assert!(holds_snapshot(&app, 2));

    feed_live(&app, 2, "while-in-copy-mode", 0, 30);
    pane_mut_by_id(&mut app, 2).copy_state = None;
    sync_copy_snapshot(&mut app);

    assert!(
        !holds_snapshot(&app, 2),
        "leaving copy mode must release the snapshot"
    );
    assert!(
        view_of(&app, 2).contains("while-in-copy-mode 29"),
        "the pane must come back to everything that arrived while it was frozen"
    );
}

/// A pane in copy mode in a window that is not the current one is still in copy
/// mode. The old gate dropped its snapshot on every frame too.
#[test]
fn a_copy_mode_pane_in_another_window_keeps_its_snapshot() {
    let mut app = app_with_two_panes();
    let area = app.last_window_area;
    app.windows.push(window(Node::Leaf(proxy_pane(3)), 1, vec![], area));
    // Window 0 is current; pane 3 lives in window 1 and is in copy mode.
    app.active_idx = 0;
    pane_mut_by_id(&mut app, 3).copy_state = Some(parked_copy_state(0));

    sync_copy_snapshot(&mut app);

    assert!(
        holds_snapshot(&app, 3),
        "a copy mode pane in another window must hold its snapshot too"
    );
}

/// The focused pane still follows the live mode: its snapshot is installed
/// exactly while copy mode is up, which is what PR #671 established.
#[test]
fn the_focused_pane_still_follows_the_live_mode() {
    let mut app = app_with_two_panes();
    app.mode = Mode::CopyMode;
    sync_copy_snapshot(&mut app);
    assert!(holds_snapshot(&app, 1), "the focused pane takes a snapshot in copy mode");
    assert!(!holds_snapshot(&app, 2), "the other pane is not in copy mode");

    app.mode = Mode::Passthrough;
    sync_copy_snapshot(&mut app);
    assert!(
        !holds_snapshot(&app, 1),
        "leaving copy mode releases the focused pane's snapshot"
    );
}
