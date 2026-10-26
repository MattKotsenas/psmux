// Issue #245: Add `mouse-selection on/off` option so apps inside a pane
// (opencode, nvim, etc.) can implement their own mouse selection without
// psmux drawing its drag-selection overlay on top.

use super::*;

fn mock_app() -> AppState {
    let mut app = AppState::new("test245".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split {
            kind: LayoutKind::Horizontal,
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

fn mock_app_with_window() -> AppState {
    let mut app = mock_app();
    app.windows.push(make_window("shell", 0));
    app
}

#[test]
fn default_mouse_selection_is_on() {
    let app = mock_app();
    assert!(app.mouse_selection,
        "mouse-selection must default to true (on) for backwards compatibility");
}

#[test]
fn default_mouse_selection_force_is_off() {
    let app = mock_app();
    assert!(!app.mouse_selection_force);
}

#[test]
fn config_and_server_options_support_mouse_selection_force() {
    let mut app = mock_app_with_window();
    crate::config::parse_config_content(&mut app, "set -g mouse-selection-force on\n");
    assert!(app.mouse_selection_force);
    assert_eq!(
        crate::server::options::get_option_value(&app, "mouse-selection-force"),
        "on"
    );

    crate::server::options::apply_set_option(
        &mut app,
        "mouse-selection-force",
        "off",
        false,
    );
    assert!(!app.mouse_selection_force);
}

#[test]
fn option_catalog_registers_mouse_selection_force() {
    let entry = crate::server::option_catalog::OPTION_CATALOG
        .iter()
        .find(|o| o.name == "mouse-selection-force")
        .expect("mouse-selection-force must be in catalog");
    assert_eq!(entry.default, "off");
    assert_eq!(
        entry.option_type,
        crate::server::option_catalog::OptionType::Boolean
    );
    assert_eq!(
        entry.scope,
        crate::server::option_catalog::OptionScope::Session,
    );
}

#[test]
fn config_parses_mouse_selection_off() {
    let mut app = mock_app_with_window();
    crate::config::parse_config_content(&mut app, "set -g mouse-selection off\n");
    assert!(!app.mouse_selection,
        "set -g mouse-selection off must set mouse_selection = false");
}

#[test]
fn config_parses_mouse_selection_on() {
    let mut app = mock_app_with_window();
    app.mouse_selection = false;
    crate::config::parse_config_content(&mut app, "set -g mouse-selection on\n");
    assert!(app.mouse_selection,
        "set -g mouse-selection on must set mouse_selection = true");
}

#[test]
fn config_truthy_values_accepted() {
    for v in &["on", "true", "1"] {
        let mut app = mock_app_with_window();
        app.mouse_selection = false;
        crate::config::parse_config_content(&mut app, &format!("set -g mouse-selection {}\n", v));
        assert!(app.mouse_selection, "value '{}' should enable mouse-selection", v);
    }
}

#[test]
fn config_falsy_values_disable() {
    for v in &["off", "false", "0", "garbage"] {
        let mut app = mock_app_with_window();
        app.mouse_selection = true;
        crate::config::parse_config_content(&mut app, &format!("set -g mouse-selection {}\n", v));
        assert!(!app.mouse_selection,
            "value '{}' should disable mouse-selection (matches!() pattern)", v);
    }
}

#[test]
fn execute_command_string_set_option() {
    let mut app = mock_app_with_window();
    execute_command_string(&mut app, "set-option -g mouse-selection off").unwrap();
    assert!(!app.mouse_selection,
        "execute_command_string set-option -g mouse-selection off must apply");

    execute_command_string(&mut app, "set-option -g mouse-selection on").unwrap();
    assert!(app.mouse_selection,
        "execute_command_string toggling back to 'on' must apply");
}

#[test]
fn server_options_get_returns_correct_value() {
    let mut app = mock_app_with_window();
    app.mouse_selection = true;
    let v = crate::server::options::get_option_value(&app, "mouse-selection");
    assert_eq!(v, "on", "get_option_value for mouse-selection should return 'on'");

    app.mouse_selection = false;
    let v = crate::server::options::get_option_value(&app, "mouse-selection");
    assert_eq!(v, "off", "get_option_value for mouse-selection should return 'off'");
}

#[test]
fn server_options_apply_set_option() {
    let mut app = mock_app_with_window();
    crate::server::options::apply_set_option(&mut app, "mouse-selection", "off", false);
    assert!(!app.mouse_selection, "apply_set_option off must disable mouse_selection");

    crate::server::options::apply_set_option(&mut app, "mouse-selection", "on", false);
    assert!(app.mouse_selection, "apply_set_option on must enable mouse_selection");
}

#[test]
fn option_catalog_registers_mouse_selection() {
    let found = crate::server::option_catalog::OPTION_CATALOG
        .iter()
        .any(|o| o.name == "mouse-selection");
    assert!(found,
        "mouse-selection must be registered in OPTIONS catalog (used by customize-mode and tab-completion)");
}

#[test]
fn option_catalog_default_is_on() {
    let entry = crate::server::option_catalog::OPTION_CATALOG
        .iter()
        .find(|o| o.name == "mouse-selection")
        .expect("mouse-selection must be in catalog");
    assert_eq!(entry.default, "on",
        "Catalog default for mouse-selection must be 'on' (preserves existing behavior)");
    assert_eq!(
        entry.option_type,
        crate::server::option_catalog::OptionType::Boolean
    );
    assert_eq!(
        entry.scope,
        crate::server::option_catalog::OptionScope::Session,
    );
}

#[test]
fn mouse_selection_independent_of_mouse_enabled() {
    // Disabling mouse-selection must NOT touch mouse_enabled — selection
    // and event-forwarding are separate concerns. (issue #245)
    let mut app = mock_app_with_window();
    assert!(app.mouse_enabled, "mouse defaults to on");
    assert!(app.mouse_selection, "mouse-selection defaults to on");

    execute_command_string(&mut app, "set-option -g mouse-selection off").unwrap();
    assert!(!app.mouse_selection);
    assert!(app.mouse_enabled,
        "Disabling mouse-selection must NOT disable mouse forwarding");
}

#[test]
fn mouse_selection_independent_of_pwsh_mouse_selection() {
    let mut app = mock_app_with_window();
    execute_command_string(&mut app, "set-option -g pwsh-mouse-selection on").unwrap();
    execute_command_string(&mut app, "set-option -g mouse-selection off").unwrap();
    assert!(app.pwsh_mouse_selection, "pwsh-mouse-selection unchanged");
    assert!(!app.mouse_selection, "mouse-selection toggled independently");
}
