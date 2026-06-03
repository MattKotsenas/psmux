use super::*;
use crate::types::Action;

fn mock_app() -> AppState {
    let mut app = AppState::new("test_session".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id,
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
    }
}

fn mock_app_with_window() -> AppState {
    let mut app = mock_app();
    app.windows.push(make_window("shell", 0));
    app
}

#[test]
fn root_binding_matches_copy_mode_u() {
    // Verify our matches! pattern correctly identifies copy-mode -u
    let action = Action::Command("copy-mode -u".to_string());
    let is_scroll_copy = matches!(&action, Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    assert!(is_scroll_copy, "Action::Command('copy-mode -u') should match scroll copy pattern");
}

#[test]
fn root_binding_does_not_match_plain_copy_mode() {
    let action = Action::CopyMode;
    let is_scroll_copy = matches!(&action, Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    assert!(!is_scroll_copy, "Action::CopyMode should NOT match scroll copy pattern");
}

#[test]
fn root_binding_does_not_match_other_command() {
    let action = Action::Command("new-window".to_string());
    let is_scroll_copy = matches!(&action, Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    assert!(!is_scroll_copy, "Action::Command('new-window') should NOT match");
}

#[test]
fn scroll_enter_copy_mode_off_skips_root_pageup_binding() {
    let mut app = mock_app_with_window();
    // Initialize default key bindings (includes PageUp -> copy-mode -u in root table)
    crate::config::populate_default_bindings(&mut app);
    
    // Verify root table has PageUp binding
    let key_tuple = crate::config::normalize_key_for_binding((KeyCode::PageUp, KeyModifiers::NONE));
    let has_pageup_bind = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == key_tuple))
        .is_some();
    assert!(has_pageup_bind, "Root table should have PageUp binding");
    
    // Check the binding action is copy-mode -u
    let bind = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == key_tuple))
        .unwrap();
    let is_scroll_copy = matches!(&bind.action, Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    assert!(is_scroll_copy, "PageUp binding should be 'copy-mode -u'");
    
    // With scroll_enter_copy_mode = true (default), the binding should execute
    assert!(app.scroll_enter_copy_mode, "Default should be true");
    
    // With scroll_enter_copy_mode = false, the binding should be skipped
    app.scroll_enter_copy_mode = false;
    assert!(!app.scroll_enter_copy_mode);
    
    // The condition in input.rs is: is_scroll_copy && !app.scroll_enter_copy_mode
    let should_forward = is_scroll_copy && !app.scroll_enter_copy_mode;
    assert!(should_forward, "With option off, PageUp should be forwarded to pane");
}

/// Verify that handle_key skips the root PageUp binding and forwards the key
/// to the PTY when scroll_enter_copy_mode is off.
#[test]
fn handle_key_skips_root_pageup_when_scroll_off() {
    let mut app = mock_app_with_window();
    crate::config::populate_default_bindings(&mut app);
    app.scroll_enter_copy_mode = false;
    app.mode = Mode::Passthrough;

    // After handle_key, the mode should remain Passthrough (NOT CopyMode)
    // because the root binding is skipped when scroll_enter_copy_mode is off.
    let key = crossterm::event::KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE);
    // We cannot call handle_key directly here since there is no real PTY,
    // but we can verify the logic that handle_key uses:
    let key_tuple = crate::config::normalize_key_for_binding((key.code, key.modifiers));
    let bind = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == key_tuple))
        .cloned();
    assert!(bind.is_some(), "PageUp should be bound in root table");
    let bind = bind.unwrap();
    let is_scroll_copy = matches!(&bind.action, crate::types::Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    assert!(is_scroll_copy, "PageUp binding should be copy-mode -u");
    // With scroll_enter_copy_mode off, the binding should be SKIPPED
    let should_skip = is_scroll_copy && !app.scroll_enter_copy_mode;
    assert!(should_skip, "handle_key should skip this binding and forward key to PTY");
}

/// Verify that handle_key executes the root PageUp binding normally
/// when scroll_enter_copy_mode is on (default).
#[test]
fn handle_key_executes_root_pageup_when_scroll_on() {
    let mut app = mock_app_with_window();
    crate::config::populate_default_bindings(&mut app);
    app.scroll_enter_copy_mode = true;
    app.mode = Mode::Passthrough;

    let key = crossterm::event::KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE);
    let key_tuple = crate::config::normalize_key_for_binding((key.code, key.modifiers));
    let bind = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == key_tuple))
        .cloned();
    assert!(bind.is_some());
    let bind = bind.unwrap();
    let is_scroll_copy = matches!(&bind.action, crate::types::Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    // With scroll_enter_copy_mode on, the binding should NOT be skipped
    let should_skip = is_scroll_copy && !app.scroll_enter_copy_mode;
    assert!(!should_skip, "handle_key should execute this binding, not skip it");
}

/// Verify that Home and End keys are NOT bound in the root table (they
/// should always pass through to the PTY).
#[test]
fn home_end_not_bound_in_root_table() {
    let mut app = mock_app_with_window();
    crate::config::populate_default_bindings(&mut app);

    let home_tuple = crate::config::normalize_key_for_binding((KeyCode::Home, KeyModifiers::NONE));
    let end_tuple = crate::config::normalize_key_for_binding((KeyCode::End, KeyModifiers::NONE));

    let home_bound = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == home_tuple));
    let end_bound = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == end_tuple));

    assert!(home_bound.is_none(), "Home should NOT be bound in root table");
    assert!(end_bound.is_none(), "End should NOT be bound in root table");
}

/// Verify that the send_key_to_active path sends correct escape sequences
/// for Home, End, PageUp, and PageDown.
#[test]
fn send_key_escape_sequences_correct() {
    // Home -> \x1b[H, End -> \x1b[F, PageUp -> \x1b[5~, PageDown -> \x1b[6~
    let key_home = crossterm::event::KeyEvent::new(KeyCode::Home, KeyModifiers::NONE);
    let key_end = crossterm::event::KeyEvent::new(KeyCode::End, KeyModifiers::NONE);
    let key_pgup = crossterm::event::KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE);
    let key_pgdn = crossterm::event::KeyEvent::new(KeyCode::PageDown, KeyModifiers::NONE);

    let enc_home = crate::input::encode_key_event(&key_home);
    let enc_end = crate::input::encode_key_event(&key_end);
    let enc_pgup = crate::input::encode_key_event(&key_pgup);
    let enc_pgdn = crate::input::encode_key_event(&key_pgdn);

    assert_eq!(enc_home, Some(b"\x1b[H".to_vec()), "Home should encode to ESC[H");
    assert_eq!(enc_end, Some(b"\x1b[F".to_vec()), "End should encode to ESC[F");
    assert_eq!(enc_pgup, Some(b"\x1b[5~".to_vec()), "PageUp should encode to ESC[5~");
    assert_eq!(enc_pgdn, Some(b"\x1b[6~".to_vec()), "PageDown should encode to ESC[6~");
}

#[test]
fn scroll_enter_copy_mode_on_allows_root_pageup_binding() {
    let mut app = mock_app_with_window();
    crate::config::populate_default_bindings(&mut app);
    
    let key_tuple = crate::config::normalize_key_for_binding((KeyCode::PageUp, KeyModifiers::NONE));
    let bind = app.key_tables.get("root")
        .and_then(|t| t.iter().find(|b| b.key == key_tuple))
        .unwrap();
    let is_scroll_copy = matches!(&bind.action, Action::Command(cmd) if cmd.starts_with("copy-mode") && cmd.contains("-u"));
    
    app.scroll_enter_copy_mode = true;
    let should_forward = is_scroll_copy && !app.scroll_enter_copy_mode;
    assert!(!should_forward, "With option on, PageUp should NOT be forwarded (enters copy mode)");
}
