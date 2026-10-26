// Issue #507: `display-popup -E pwsh` left the cursor invisible inside the popup.
//
// The cursor was not hidden by a flag: the client only ever computed a cursor
// from the ACTIVE PANE, so while a PTY popup was up the terminal cursor stayed
// parked on the pane underneath and never tracked the process in the popup.
// Measured on a live session before the fix: the cursor sat at screen (46,0),
// the background pane's prompt, and typing 15 characters into the popup moved
// it by exactly 0 columns.
//
// tmux parity: popup.c popup_mode_cb returns the popup's own screen and maps
// the child's cursor to px+1+s.cx / py+1+s.cy, and server-client.c
// server_client_reset_state takes BOTH cursor and cursor mode from the overlay
// whenever one is drawn. These tests pin the equivalent psmux mapping.

use ratatui::layout::Rect;

use crate::client::{popup_cursor_screen_pos, popup_overlay_rect};

// ── popup_overlay_rect: geometry the draw pass and the cursor pass share ──

#[test]
fn popup_rect_is_centered_in_the_content_area() {
    // 120x30 content area, popup wants 80x24 (the display-popup defaults).
    let area = Rect::new(0, 0, 120, 30);
    let r = popup_overlay_rect(area, 80, 24);
    assert_eq!(r.width, 80);
    assert_eq!(r.height, 24);
    assert_eq!(r.x, 20, "centered horizontally: (120-80)/2");
    assert_eq!(r.y, 3, "centered vertically: (30-24)/2");
}

#[test]
fn popup_rect_honours_the_content_chunk_origin() {
    // status-position top shifts the content chunk down by one row.
    let area = Rect::new(0, 1, 120, 29);
    let r = popup_overlay_rect(area, 80, 24);
    assert_eq!(r.x, 20);
    assert_eq!(r.y, 1 + (29 - 24) / 2, "origin must be added, not ignored");
}

#[test]
fn popup_rect_is_clamped_to_the_available_area() {
    // A popup larger than the terminal is clamped, leaving room for a margin.
    let area = Rect::new(0, 0, 40, 10);
    let r = popup_overlay_rect(area, 200, 200);
    assert_eq!(r.width, 38, "clamped to width-2");
    assert_eq!(r.height, 8, "clamped to height-2");
    assert!(r.x + r.width <= area.x + area.width);
    assert!(r.y + r.height <= area.y + area.height);
}

// ── popup_cursor_screen_pos: popup-inner cell -> absolute screen cell ──

#[test]
fn cursor_maps_inside_the_popup_border() {
    let area = Rect::new(0, 0, 120, 30);
    // Popup child cursor at its own origin (0,0) must land just inside the box.
    let pos = popup_cursor_screen_pos(area, 80, 24, 0, (0, 0)).unwrap();
    assert_eq!(pos, (21, 4), "popup at x=20,y=3 plus the 1-cell border");
}

#[test]
fn cursor_tracks_the_column_of_the_process_in_the_popup() {
    let area = Rect::new(0, 0, 120, 30);
    let a = popup_cursor_screen_pos(area, 80, 24, 0, (46, 1)).unwrap();
    let b = popup_cursor_screen_pos(area, 80, 24, 0, (61, 1)).unwrap();
    assert_eq!(a, (67, 5));
    assert_eq!(
        (b.0 - a.0, b.1 - a.1),
        (15, 0),
        "typing 15 characters must move the cursor exactly 15 columns"
    );
}

#[test]
fn cursor_follows_the_popup_scroll_offset() {
    let area = Rect::new(0, 0, 120, 30);
    let unscrolled = popup_cursor_screen_pos(area, 80, 24, 0, (0, 5)).unwrap();
    let scrolled = popup_cursor_screen_pos(area, 80, 24, 2, (0, 5)).unwrap();
    assert_eq!(unscrolled.1 - scrolled.1, 2, "cursor scrolls with the content");
}

#[test]
fn cursor_scrolled_above_the_popup_is_not_drawn() {
    let area = Rect::new(0, 0, 120, 30);
    assert!(
        popup_cursor_screen_pos(area, 80, 24, 5, (0, 2)).is_none(),
        "a cursor scrolled out of view must not be parked at the popup edge"
    );
}

#[test]
fn cursor_outside_the_popup_interior_is_not_drawn() {
    let area = Rect::new(0, 0, 120, 30);
    // Interior of an 80x24 popup is 78x22.
    assert!(popup_cursor_screen_pos(area, 80, 24, 0, (78, 0)).is_none(), "column past the interior");
    assert!(popup_cursor_screen_pos(area, 80, 24, 0, (0, 22)).is_none(), "row past the interior");
    assert!(popup_cursor_screen_pos(area, 80, 24, 0, (77, 21)).is_some(), "last interior cell is valid");
}

#[test]
fn degenerate_popup_has_no_cursor_cell() {
    // Too small to have an interior at all: must not underflow or land on the border.
    let area = Rect::new(0, 0, 4, 4);
    assert!(popup_cursor_screen_pos(area, 2, 2, 0, (0, 0)).is_none());
}

#[test]
fn cursor_stays_within_the_popup_for_every_interior_cell() {
    let area = Rect::new(0, 0, 120, 30);
    let r = popup_overlay_rect(area, 80, 24);
    for row in 0..r.height - 2 {
        for col in 0..r.width - 2 {
            let (cx, cy) = popup_cursor_screen_pos(area, 80, 24, 0, (col, row)).unwrap();
            assert!(cx > r.x && cx < r.x + r.width - 1, "col {col} escaped the popup box");
            assert!(cy > r.y && cy < r.y + r.height - 1, "row {row} escaped the popup box");
        }
    }
}

// ── Regression guard: the exact numbers from the live reproduction ──

#[test]
fn issue507_cursor_no_longer_parks_on_the_pane_underneath() {
    // Reproduced on a 120x30 terminal: the popup box was drawn at cols 20..99,
    // rows 2..25, and the pwsh prompt inside it put the child cursor at
    // inner (46,1). Before the fix the terminal cursor stayed at (46,0), which
    // is the BACKGROUND pane's prompt on row 0, outside the popup entirely.
    let content = Rect::new(0, 0, 120, 29); // status bar occupies the last row
    let r = popup_overlay_rect(content, 80, 24);
    assert_eq!((r.x, r.y), (20, 2), "popup box origin from the live repro");

    let (cx, cy) = popup_cursor_screen_pos(content, 80, 24, 0, (46, 1)).unwrap();
    assert_eq!((cx, cy), (67, 4), "cursor sits on the popup's prompt row");
    assert_ne!((cx, cy), (46, 0), "BUG #507: cursor parked on the pane underneath");
    assert!(
        cx > r.x && cx < r.x + r.width - 1 && cy > r.y && cy < r.y + r.height - 1,
        "cursor must be strictly inside the popup border"
    );
}
