// A bare `-t` name of a window or pane command (`kill-window -t keywin` from
// a key binding, the command prompt or a hook) parsed as a session name, and
// the command then acted on the CURRENT window. tmux reads it as a window of
// the current session first and a session name after that
// (cmd-find.c cmd_find_get_window, :328 to :354). Registered from
// src/commands.rs.

use super::*;

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
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

fn app() -> AppState {
    let mut app = AppState::new("demo".to_string());
    app.windows = vec![make_window("main", 1), make_window("keywin", 2), make_window("other", 3)];
    app.active_idx = 0;
    app
}

#[test]
fn bare_name_is_a_window_of_this_session() {
    let app = app();
    assert_eq!(app.resolve_window_target("keywin"), Ok(1));
    assert_eq!(app.resolve_window_target("=keywin"), Ok(1));
    assert_eq!(app.resolve_window_target(":keywin"), Ok(1));
    assert_eq!(app.resolve_window_target("demo:keywin"), Ok(1));
    assert_eq!(app.resolve_window_target("@3"), Ok(2));
}

#[test]
fn session_name_is_its_current_window() {
    let mut app = app();
    app.active_idx = 2;
    assert_eq!(app.resolve_window_target("demo"), Ok(2));
    assert_eq!(app.resolve_window_target("demo:"), Ok(2));
}

#[test]
fn a_name_matching_nothing_never_falls_back() {
    let app = app();
    assert_eq!(app.resolve_window_target("nosuchwin"), Err("can't find window: nosuchwin".to_string()));
    assert_eq!(app.resolve_window_target("7"), Err("can't find window: 7".to_string()));
}

#[test]
fn in_server_resolution_rewrites_bare_names_only() {
    let app = app();
    assert_eq!(resolve_in_server_target(&app, InServerTarget::Window, "keywin"), Ok(Some("@2".to_string())));
    assert!(resolve_in_server_target(&app, InServerTarget::Window, "nosuchwin").is_err());
    // Ids, mouse and marked targets, and other sessions are left alone.
    assert_eq!(resolve_in_server_target(&app, InServerTarget::Window, "@9"), Ok(None));
    assert_eq!(resolve_in_server_target(&app, InServerTarget::Pane, "%4"), Ok(None));
    assert_eq!(resolve_in_server_target(&app, InServerTarget::Pane, "{mouse}"), Ok(None));
    assert_eq!(resolve_in_server_target(&app, InServerTarget::Window, "elsewhere:1"), Ok(None));
    assert_eq!(in_server_target_kind("kill-window"), Some(InServerTarget::Window));
    assert_eq!(in_server_target_kind("send-keys"), Some(InServerTarget::Pane));
    assert_eq!(in_server_target_kind("move-window"), None);
}

#[test]
fn bare_target_name_shape() {
    assert!(crate::cli::bare_target_name("keywin"));
    assert!(crate::cli::bare_target_name("=keywin"));
    assert!(!crate::cli::bare_target_name("0"));
    assert!(!crate::cli::bare_target_name("+1"));
    assert!(!crate::cli::bare_target_name("!"));
    assert!(!crate::cli::bare_target_name("s:w"));
    assert!(!crate::cli::bare_target_name("w.1"));
    assert!(!crate::cli::bare_target_name("%3"));
    assert!(!crate::cli::bare_target_name("@3"));
    assert!(!crate::cli::bare_target_name("{mouse}"));
    assert!(!crate::cli::bare_target_name(""));
}

#[test]
fn bindings_with_arguments_keep_them() {
    // These used to become the bare Action and drop the -t.
    assert!(matches!(parse_command_to_action("kill-pane -t %3"), Some(Action::Command(c)) if c == "kill-pane -t %3"));
    assert!(matches!(parse_command_to_action("kill-pane"), Some(Action::KillPane)));
    assert!(matches!(parse_command_to_action("rename-window -t w x"), Some(Action::Command(c)) if c == "rename-window -t w x"));
    assert!(matches!(parse_command_to_action("rename-window"), Some(Action::RenameWindow)));
    assert!(matches!(parse_command_to_action("resize-pane -Z -t %2"), Some(Action::Command(_))));
    assert!(matches!(parse_command_to_action("resize-pane -Z"), Some(Action::ZoomPane)));
    assert!(matches!(parse_command_to_action("select-pane -L -t %2"), Some(Action::Command(_))));
    assert!(matches!(parse_command_to_action("clear-history -t %2"), Some(Action::Command(c)) if c == "clear-history -t %2"));
    assert!(matches!(parse_command_to_action("delete-buffer -b x"), Some(Action::Command(c)) if c == "delete-buffer -b x"));
    assert!(matches!(parse_command_to_action("next-layout -t w"), Some(Action::Command(c)) if c == "next-layout -t w"));
}
