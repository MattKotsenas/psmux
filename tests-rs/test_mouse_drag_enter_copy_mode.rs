// Tests for the mouse-drag-enter-copy-mode option.
//
// Dragging with the left button in a pane that does not track the mouse
// normally paints psmux's client-side selection overlay (copy on release).
// With this option on, the client instead sends `copy-enter` plus the press
// cell and lets the server's copy mode select (tmux: MouseDragStart ->
// `copy-mode -M`), so the drag yanks through the same path as a
// copy-mode mouse selection and the mode keys stay available while dragging.

use super::*;

fn mock_app() -> crate::types::AppState {
    crate::types::AppState::new("test_session".to_string())
}

#[test]
fn defaults_to_off() {
    let app = mock_app();
    assert!(
        !app.mouse_drag_enter_copy_mode,
        "client-side selection must stay the default"
    );
}

#[test]
fn config_can_turn_it_on() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g mouse-drag-enter-copy-mode on");
    assert!(app.mouse_drag_enter_copy_mode);
}

#[test]
fn config_can_turn_it_off_again() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g mouse-drag-enter-copy-mode on");
    parse_config_content(&mut app, "set -g mouse-drag-enter-copy-mode off");
    assert!(!app.mouse_drag_enter_copy_mode);
}

#[test]
fn show_options_reports_it() {
    let mut app = mock_app();
    assert_eq!(
        crate::server::options::get_option_value(&app, "mouse-drag-enter-copy-mode"),
        "off"
    );
    app.mouse_drag_enter_copy_mode = true;
    assert_eq!(
        crate::server::options::get_option_value(&app, "mouse-drag-enter-copy-mode"),
        "on"
    );
}

#[test]
fn apply_set_option_sets_it() {
    let mut app = mock_app();
    crate::server::options::apply_set_option(&mut app, "mouse-drag-enter-copy-mode", "on", false)
        .expect("apply_set_option must accept the option");
    assert!(app.mouse_drag_enter_copy_mode);
    crate::server::options::apply_set_option(&mut app, "mouse-drag-enter-copy-mode", "off", false)
        .expect("apply_set_option must accept the option");
    assert!(!app.mouse_drag_enter_copy_mode);
}

#[test]
fn is_a_boolean_option() {
    assert!(crate::server::options::is_boolean_option("mouse-drag-enter-copy-mode"));
    assert!(crate::server::options::missing_value_toggles("mouse-drag-enter-copy-mode"));
}

#[test]
fn the_catalog_knows_it_so_set_u_can_restore_the_default() {
    // `set -gu <option>` restores the catalog default (#619). Without an
    // OptionDef the reset was a silent no-op: `set -g ... on` followed by
    // `set -gu ...` left it on.
    let def = crate::server::option_catalog::option_definition("mouse-drag-enter-copy-mode")
        .expect("the option must be in the catalog");
    assert_eq!(def.default, "off");

    let mut app = mock_app();
    crate::server::options::apply_set_option(&mut app, "mouse-drag-enter-copy-mode", "on", false)
        .expect("apply_set_option must accept the option");
    assert!(app.mouse_drag_enter_copy_mode);
    crate::server::options::reset_option_to_default(&mut app, "mouse-drag-enter-copy-mode");
    assert!(
        !app.mouse_drag_enter_copy_mode,
        "set -u must put the option back to its default"
    );
}
