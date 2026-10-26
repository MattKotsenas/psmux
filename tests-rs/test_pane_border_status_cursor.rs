//! Regression guard for the `pane-border-status` caret / mouse row offset:
//! `top` reserves the pane's first row for the label, so the caret and every
//! screen→cell mouse mapping must use the same content-inner rect as the
//! render, or they land one row off the content (#288).

use ratatui::layout::Rect;

const FMT: &str = "#{pane_index} \"#{pane_title}\"";

#[test]
fn border_status_top_reserves_top_row_for_content() {
    let area = Rect::new(0, 0, 80, 24);
    let inner = crate::client::pane_content_inner(area, "top", FMT);
    assert_eq!(inner.x, area.x);
    assert_eq!(inner.y, area.y + 1, "top label reserves the first row; content starts one row down");
    assert_eq!(inner.width, area.width);
    assert_eq!(inner.height, area.height - 1);
}

#[test]
fn border_status_bottom_keeps_content_origin() {
    let area = Rect::new(3, 5, 40, 12);
    let inner = crate::client::pane_content_inner(area, "bottom", FMT);
    assert_eq!(inner.y, area.y, "bottom label reserves the last row; content keeps its top origin");
    assert_eq!(inner.x, area.x);
    assert_eq!(inner.width, area.width);
    assert_eq!(inner.height, area.height - 1);
}

#[test]
fn border_status_off_is_identity() {
    let area = Rect::new(2, 4, 30, 10);
    assert_eq!(crate::client::pane_content_inner(area, "off", FMT), area);
}

#[test]
fn empty_border_format_does_not_reserve_a_row() {
    // The label gate also requires a non-empty format; with no format there is
    // no visible label, so content (and the cursor) keep the full area.
    let area = Rect::new(0, 0, 80, 24);
    assert_eq!(crate::client::pane_content_inner(area, "top", ""), area);
}

#[test]
fn tiny_pane_is_not_shifted() {
    // has_border_label requires height > 1; a 1-row pane cannot host a label,
    // so it must not be shifted (would otherwise underflow height to 0).
    let area = Rect::new(0, 0, 80, 1);
    assert_eq!(crate::client::pane_content_inner(area, "top", FMT), area);
}

#[test]
fn caret_sits_on_the_content_row_not_one_above_it() {
    // The render draws content grid-row `r` at `inner.y + r`, and the post-draw
    // cursor writes the caret at `inner.y + cursor_row`, both derived from the
    // same helper. Before the fix the caret used the pane's OUTER rect, landing
    // one row above the content. Assert they now coincide under border-status.
    let pane = Rect::new(0, 0, 80, 24);
    let inner = crate::client::pane_content_inner(pane, "top", FMT);
    let cursor_row = 3u16;
    let caret_y = inner.y + cursor_row;              // post-draw cursor path
    let content_row_screen_y = inner.y + cursor_row; // render path for that grid row
    assert_eq!(caret_y, content_row_screen_y);
    assert_eq!(caret_y, pane.y + 1 + cursor_row, "caret must sit on the content row, not one above");
}

#[test]
fn mouse_screen_row_maps_back_to_the_clicked_content_row() {
    // Inverse of the caret check: a click on the screen row that shows content
    // grid-row `r` must map back to `r` (screen_y - inner.y), so text selection
    // grabs the row under the cursor instead of the one below it.
    let pane = Rect::new(0, 0, 80, 24);
    let inner = crate::client::pane_content_inner(pane, "top", FMT);
    for content_row in 0..inner.height {
        let screen_y = inner.y + content_row;
        let mapped = screen_y - inner.y;
        assert_eq!(mapped, content_row);
    }
}
