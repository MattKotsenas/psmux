// `window-size latest` must survive a client reconnect.
//
// The server keys `client_sizes` on the connection, and a reconnect is a new
// TCP connection with a new server-side client id. So the moment a client is
// torn down and reconnects, the size the window was being sized from is gone.
//
// The user-visible shape of getting this wrong, reported here: a phone/SSH
// client (Termius) attaches and narrows the window; the idle desktop client's
// connection is torn down by a read that merely timed out; the desktop
// reconnects under a fresh id *without* re-reporting its size; and from then on
// the window can never grow back -- not by typing in it (`note_client_activity`
// ignores a client with no size) and not by the phone leaving (`client_sizes`
// is empty, so `refresh_dynamic_window_sizes` has nothing to compute and leaves
// every window at its last area).
//
// The client half of the fix re-reports the size on the next tick after a
// reconnect; these tests pin the server-side contract that half relies on, plus
// the failure mode it closes.

use super::*;
use crate::types::{LayoutKind, Node, Window};

fn empty_window(id: usize, name: &str, width: u16, height: u16) -> Window {
    Window {
        root: Node::Split {
            kind: LayoutKind::Horizontal,
            sizes: Vec::new(),
            children: Vec::new(),
        },
        active_path: Vec::new(),
        name: name.to_string(),
        id,
        area: Rect::new(0, 0, width, height),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: Vec::new(),
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

fn window_area(app: &AppState) -> (u16, u16) {
    (app.windows[0].area.width, app.windows[0].area.height)
}

/// A session whose only window follows `window-size latest`, with one client.
fn app_with_client(cid: u64, size: (u16, u16)) -> AppState {
    let mut app = AppState::new("reconnect-size".to_string());
    // Start the window at a third size so the first refresh has real work to
    // do: `refresh_dynamic_window_sizes` reports whether it changed anything.
    app.windows.push(empty_window(1, "one", 80, 24));
    app.window_indices = vec![0];
    app.window_size = "latest".to_string();
    assert!(app.register_client(cid, false), "the first client must register");
    app.client_sizes.insert(cid, size);
    app.latest_client_id = Some(cid);
    app.latest_size_client_id = Some(cid);
    assert!(refresh_dynamic_window_sizes(&mut app), "the client size must reach the window");
    app
}

#[test]
fn a_desktop_that_re_reports_its_size_after_a_reconnect_gets_the_window_back() {
    // desktop 200x50, then phone 42x15: the phone is the client in use.
    let mut app = app_with_client(7, (200, 50));
    assert_eq!(window_area(&app), (200, 50));

    assert!(app.register_client(9, false));
    app.client_sizes.insert(9, (42, 15));
    app.latest_client_id = Some(9);
    app.latest_size_client_id = Some(9);
    assert!(refresh_dynamic_window_sizes(&mut app));
    assert_eq!(window_area(&app), (42, 15), "the phone narrowed the window");

    // The desktop's connection is torn down and reaped.
    assert!(app.reap_client(7));
    assert!(!refresh_dynamic_window_sizes(&mut app), "only the phone is left");
    assert_eq!(window_area(&app), (42, 15));

    // The desktop reconnects under a fresh id. register_client alone is not
    // enough -- the reconnected client must report its size, which is what the
    // client-side fix makes it do on the first tick.
    assert!(app.register_client(11, false));
    app.client_sizes.insert(11, (200, 50));
    app.latest_client_id = Some(11);
    app.latest_size_client_id = Some(11);
    assert!(
        refresh_dynamic_window_sizes(&mut app),
        "the reconnected desktop's size must reach the window"
    );
    assert_eq!(window_area(&app), (200, 50));

    // ...and it must hold when the phone leaves.
    assert!(app.reap_client(9));
    assert!(!refresh_dynamic_window_sizes(&mut app), "geometry already correct");
    assert_eq!(window_area(&app), (200, 50));
}

#[test]
fn a_reconnected_client_that_reports_nothing_cannot_drive_the_window() {
    // The failure this fix closes, pinned deliberately: an attach records the
    // client in the registry (and, for `list-clients`, seeds a display size
    // from the session's own area) but it does NOT record a size, so the
    // reconnected client can neither be sized from nor made "latest" by
    // activity. `list-clients` therefore looks healthy while the window is
    // stuck -- which is exactly why the client now re-reports.
    let mut app = app_with_client(7, (200, 50));

    assert!(app.register_client(9, false));
    app.client_sizes.insert(9, (42, 15));
    app.latest_client_id = Some(9);
    app.latest_size_client_id = Some(9);
    assert!(refresh_dynamic_window_sizes(&mut app));

    // Both original clients go away; the desktop reconnects with no size.
    assert!(app.reap_client(7));
    assert!(app.reap_client(9));
    assert!(app.register_client(11, false));
    assert_eq!(
        app.client_registry.get(&11).map(|c| (c.width, c.height)),
        Some((app.client_area.width, app.client_area.height)),
        "the registry shows the session's area, not the client's: this is the misleading part"
    );

    assert!(
        !note_client_activity(&mut app, 11),
        "activity from a client with no recorded size cannot drive the geometry"
    );
    assert!(
        !refresh_dynamic_window_sizes(&mut app),
        "with no sizes left there is nothing to compute, so the window keeps its last area"
    );
    assert_eq!(window_area(&app), (42, 15));
}
