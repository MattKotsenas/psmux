// A detached `confirm-before kill-pane` answered with `send-keys y` closed
// the prompt but killed nothing, while `confirm-respond y` killed the pane.
// The send-keys answer (send_text_to_active for y, send_key_to_active for
// Enter with -y) ran the confirmed command through the config file parser,
// which applies `set` and `bind` but has no arm for kill-pane, split-window
// or any other runtime command. confirm-respond and a real key press run it
// with execute_command_string, so every answer must. tmux runs the command
// of a confirmed prompt as a command list (cmd-confirm-before.c
// cmd_confirm_before_callback, cmdq_append). Registered from src/input.rs.

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
    let mut app = AppState::new("skc".to_string());
    app.windows = vec![make_window("main", 1)];
    app.active_idx = 0;
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn open(app: &mut AppState, line: &str) {
    crate::commands::execute_command_string(app, line).unwrap();
    assert!(matches!(app.mode, Mode::ConfirmMode { .. }), "{line} opens the prompt");
}

#[test]
fn send_keys_y_runs_a_runtime_command() {
    // rename-window stands in for kill-pane: a runtime command the config
    // parser has no arm for, and one a mock AppState can show.
    let mut a = app();
    open(&mut a, "confirm-before \"rename-window CONFIRMED\"");
    send_text_to_active(&mut a, "y").unwrap();
    assert!(matches!(a.mode, Mode::Passthrough), "y closes the prompt");
    assert_eq!(a.windows[0].name, "CONFIRMED", "send-keys y must run the confirmed command");
}

#[test]
fn send_keys_enter_with_dash_y_runs_a_runtime_command() {
    let mut a = app();
    open(&mut a, "confirm-before -y \"rename-window CONFIRMED\"");
    send_key_to_active(&mut a, "enter").unwrap();
    assert!(matches!(a.mode, Mode::Passthrough));
    assert_eq!(a.windows[0].name, "CONFIRMED", "Enter with -y must run the confirmed command");
}

#[test]
fn send_keys_answers_as_confirm_respond_does() {
    // The same prompt answered the two ways leaves the same state.
    let mut by_keys = app();
    open(&mut by_keys, "confirm-before \"rename-window SAME\"");
    send_text_to_active(&mut by_keys, "y").unwrap();

    let mut by_key_press = app();
    open(&mut by_key_press, "confirm-before \"rename-window SAME\"");
    handle_key(&mut by_key_press, KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)).unwrap();

    assert_eq!(by_keys.windows[0].name, by_key_press.windows[0].name);
    assert_eq!(by_keys.windows[0].name, "SAME");
}

#[test]
fn send_keys_n_and_plain_enter_still_run_nothing() {
    for (answer, is_key) in [("n", false), ("q", false), ("enter", true)] {
        let mut a = app();
        open(&mut a, "confirm-before \"rename-window CONFIRMED\"");
        if is_key { send_key_to_active(&mut a, answer).unwrap(); } else { send_text_to_active(&mut a, answer).unwrap(); }
        assert!(matches!(a.mode, Mode::Passthrough), "{answer} closes the prompt");
        assert_eq!(a.windows[0].name, "main", "{answer} must not run the command");
    }
}

#[test]
fn send_keys_y_still_runs_an_option_command() {
    // What test_issue828 relies on: a guarded `set` runs.
    let mut a = app();
    open(&mut a, "confirm-before \"set -g @skc ran\"");
    send_text_to_active(&mut a, "y").unwrap();
    assert_eq!(a.user_options.get("@skc").map(String::as_str), Some("ran"));
}
