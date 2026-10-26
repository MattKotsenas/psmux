// Issue #268: set-titles should forward expanded set-titles-string to client
// so the client can emit OSC 0 to its host terminal.
//
// These tests exercise the format-expansion path for set-titles-string and
// the AppState option storage to prove the fields are wired correctly.

use super::*;
use crate::format::expand_format;
use crate::server::options::{apply_set_option, get_option_value};

fn mk_app(name: &str) -> AppState {
    let mut app = AppState::new(name.to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn mk_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: crate::types::Node::Split {
            kind: crate::types::LayoutKind::Horizontal,
            sizes: vec![],
            children: vec![],
        },
        active_path: vec![],
        name: name.to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
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

fn app_with_window(session: &str, win: &str) -> AppState {
    let mut app = mk_app(session);
    app.windows.push(mk_window(win, 0));
    app
}

#[test]
fn set_titles_default_off() {
    let app = mk_app("s");
    assert!(!app.set_titles, "set_titles should default to false");
    assert!(app.set_titles_string.is_empty(), "set_titles_string should default empty");
}

#[test]
fn set_titles_option_persists_via_apply_set_option() {
    let mut app = app_with_window("s", "w");
    apply_set_option(&mut app, "set-titles", "on", false);
    assert!(app.set_titles, "set_titles should be true after apply_set_option on");
    apply_set_option(&mut app, "set-titles", "off", false);
    assert!(!app.set_titles, "set_titles should be false after apply_set_option off");
}

#[test]
fn set_titles_string_option_persists() {
    let mut app = app_with_window("s", "w");
    apply_set_option(&mut app, "set-titles-string", "psmux/#S #W", false);
    assert_eq!(app.set_titles_string, "psmux/#S #W");
}

#[test]
fn show_options_reports_set_titles() {
    let mut app = app_with_window("s", "w");
    app.set_titles = true;
    let v = get_option_value(&app, "set-titles");
    assert_eq!(v, "on");
    app.set_titles = false;
    let v = get_option_value(&app, "set-titles");
    assert_eq!(v, "off");
}

#[test]
fn show_options_reports_set_titles_string() {
    let mut app = app_with_window("s", "w");
    app.set_titles_string = "X #S Y".to_string();
    let v = get_option_value(&app, "set-titles-string");
    assert_eq!(v, "X #S Y");
}

#[test]
fn default_format_expands_session_index_window() {
    // Default format "#S:#I:#W" should expand to "<session>:<index>:<window-name>"
    let app = app_with_window("mysess", "shell");
    let out = expand_format("#S:#I:#W", &app);
    assert_eq!(out, "mysess:0:shell", "default format must expand to S:I:W");
}

#[test]
fn custom_format_expands_window_name_change() {
    // After rename-window, the expansion must reflect the new window name.
    let mut app = app_with_window("dev", "shell");
    let out_before = expand_format("psmux/#S #W", &app);
    assert_eq!(out_before, "psmux/dev shell");

    app.windows[0].name = "vim".to_string();
    let out_after = expand_format("psmux/#S #W", &app);
    assert_eq!(out_after, "psmux/dev vim", "rename-window must update expansion");
}

#[test]
fn pane_title_format_T_falls_back_to_hostname_when_empty() {
    // When pane.title is empty, #T falls back to hostname (matches tmux semantics).
    let app = app_with_window("s", "w");
    let out = expand_format("#T", &app);
    assert!(!out.is_empty(), "#T should not produce empty string when pane.title is empty");
}

#[test]
fn complex_format_with_session_and_window() {
    // tmux convention-ish: "[#S] #W"
    let app = app_with_window("work", "main");
    let out = expand_format("[#S] #W", &app);
    assert_eq!(out, "[work] main");
}

#[test]
fn empty_set_titles_string_falls_back_to_default_format() {
    // The dump-state builder uses #S:#I:#W when set_titles_string is empty.
    // Verify the fallback produces the expected default.
    let app = app_with_window("alpha", "beta");
    let fmt: &str = if app.set_titles_string.is_empty() {
        "#S:#I:#W"
    } else {
        app.set_titles_string.as_str()
    };
    let out = expand_format(fmt, &app);
    assert_eq!(out, "alpha:0:beta");
}

#[test]
fn config_file_parses_set_titles_directives() {
    let mut app = app_with_window("s", "w");
    parse_config_content(
        &mut app,
        "set -g set-titles on\nset -g set-titles-string \"My Title #W\"\n",
    );
    assert!(app.set_titles, "set-titles in config file should set the flag");
    assert_eq!(app.set_titles_string, "My Title #W", "set-titles-string from config");
}
