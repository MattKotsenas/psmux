// Issue #702: the copy mode position indicator printed the scroll offset on
// both sides of the slash (`[97/97]`) and drew nothing at the live bottom.
//
// tmux draws its default `copy-mode-position-format`,
// `[#{copy_position}/#{copy_position_limit}]`, on every copy mode frame
// (window-copy.c `window_copy_write_line`, `py == 0`, no lower bound on the
// offset), from the pair `window_copy_formats` builds:
//
//   copy-mode-line-numbers off/default     oy                 / hsize
//   absolute/relative/hybrid               hsize - oy + 1     / hsize + sy
//
// Measured on the reporter's rig and again on WSL tmux 3.4 with `seq 1 200`
// in a 30 row pane: `[0/174]` at the bottom, `[97/174]` scrolled 97 up.

use super::*;
use crate::types::{AppState, Mode};

#[test]
fn off_mode_reads_offset_over_scrollback() {
    // The exact numbers from the issue: 173 rows of history, 29 row pane.
    assert_eq!(position_indicator(CopyLnMode::Off, 97, 173, 29), "[97/173]");
    assert_eq!(copy_position(CopyLnMode::Off, 97, 173, 29), (97, 173));
}

#[test]
fn live_bottom_reads_zero_not_nothing() {
    // Entering copy mode at the bottom must still say where the view is.
    assert_eq!(position_indicator(CopyLnMode::Off, 0, 173, 29), "[0/173]");
}

#[test]
fn position_and_limit_are_different_numbers() {
    // The old code formatted the offset twice. Any history larger than the
    // offset must give a limit different from the position.
    for oy in [0usize, 1, 12, 97, 172] {
        let (p, l) = copy_position(CopyLnMode::Off, oy, 173, 29);
        assert_eq!(p, oy);
        assert_eq!(l, 173, "limit must be the scrollback size, not the offset");
    }
}

#[test]
fn top_of_history() {
    assert_eq!(position_indicator(CopyLnMode::Off, 173, 173, 29), "[173/173]");
}

#[test]
fn default_mode_matches_off() {
    // tmux groups `default` with `off` in window_copy_line_number_is_absolute.
    assert!(!is_absolute(CopyLnMode::Default));
    assert_eq!(copy_position(CopyLnMode::Default, 68, 173, 30), (68, 173));
}

#[test]
fn absolute_family_reads_top_line_over_total() {
    // tmux 3.7c on the reporter's rig, gutter absolute: `106/203` at oy 68,
    // hsize 173, a 30 row pane.
    for mode in [CopyLnMode::Absolute, CopyLnMode::Relative, CopyLnMode::Hybrid] {
        assert!(is_absolute(mode));
        assert_eq!(copy_position(mode, 68, 173, 30), (106, 203));
        assert_eq!(position_indicator(mode, 68, 173, 30), "[106/203]");
        // Live bottom: the first visible line is hsize + 1.
        assert_eq!(copy_position(mode, 0, 173, 30), (174, 203));
    }
}

#[test]
fn absolute_position_agrees_with_gutter_top_row() {
    // The reason the second reading exists: the indicator and the number on
    // the top row of the gutter must be the same line.
    for oy in [0usize, 5, 68, 173] {
        let (p, _) = copy_position(CopyLnMode::Absolute, oy, 173, 30);
        assert_eq!(p, line_number(CopyLnMode::Absolute, 0, oy, 0, 173));
    }
}

#[test]
fn server_ships_scrollback_size_in_copy_mode_with_option_off() {
    // The client can only print the limit if the server sends it. It used to
    // ship `copy_hsize` only when copy-mode-line-numbers was on.
    let mut app = AppState::new("i702".to_string());
    app.mode = Mode::CopyMode;
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    assert!(buf.contains("\"copy_hsize\":0"), "copy_hsize missing: {buf}");
    assert!(!buf.contains("copy_mode_line_numbers"), "option is off: {buf}");
    assert!(buf.ends_with('}'));
    let v: serde_json::Value = serde_json::from_str(&buf).expect("valid json");
    assert_eq!(v["copy_hsize"], 0);
}

#[test]
fn server_sends_nothing_outside_copy_mode_with_option_off() {
    let app = AppState::new("i702".to_string());
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    assert_eq!(buf, "{\"x\":1}");
}

#[test]
fn server_keeps_line_number_fields_when_option_on() {
    let mut app = AppState::new("i702".to_string());
    app.user_options.insert("copy-mode-line-numbers".to_string(), "absolute".to_string());
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    let v: serde_json::Value = serde_json::from_str(&buf).expect("valid json");
    assert_eq!(v["copy_mode_line_numbers"], "absolute");
    assert_eq!(v["copy_hsize"], 0);
}
