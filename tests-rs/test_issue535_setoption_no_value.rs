// Issue #535: `set-option` with an option name but no value was dropped in
// silence (nothing set, empty stderr, exit 0).
//
// These tests pin the classification that decides between the two legal
// outcomes, measured against tmux 3.4:
//   * boolean/flag option  -> toggle, exit 0, no message
//   * anything else        -> "empty value", exit 1
//
// The `-q` flag intentionally does not appear here: tmux scopes -q to unknown
// or ambiguous options, and tmux 3.4 still fails `set -gq @foo` with
// "empty value", so quietness must not be consulted when deciding this.

use super::*;

fn mock_app() -> AppState {
    AppState::new("test_session".to_string())
}

#[test]
fn missing_value_toggles_boolean_options() {
    // Every option the server parses as on/off must toggle rather than error,
    // otherwise fixing #535 would break the tmux-parity toggle from #278.
    for opt in [
        "mouse",
        "status",
        "focus-events",
        "renumber-windows",
        "automatic-rename",
        "synchronize-panes",
        "monitor-activity",
        "aggressive-resize",
        "visual-bell",
        "alternate-screen",
        "allow-predictions",
        "cursor-blink",
    ] {
        assert!(
            missing_value_toggles(opt),
            "boolean option '{}' must toggle when given no value, not error",
            opt
        );
    }
}

#[test]
fn missing_value_is_error_for_non_boolean_options() {
    // @user options are the case from the bug report; the rest are the other
    // option kinds tmux rejects with "empty value".
    for opt in [
        "@vpn_pill",
        "@foo",
        "status-left",
        "status-right",
        "history-limit",
        "escape-time",
        "default-shell",
        "base-index",
    ] {
        assert!(
            !missing_value_toggles(opt),
            "option '{}' has no toggle semantics, so a missing value must be an error",
            opt
        );
    }
}

#[test]
fn bold_is_bright_is_classified_as_boolean() {
    // Regression guard: bold-is-bright is parsed as on/off by apply_set_option
    // but was missing from is_boolean_option, so `set -g bold-is-bright` would
    // have started erroring instead of toggling once #535 was fixed.
    assert!(missing_value_toggles("bold-is-bright"));
}

#[test]
fn toggle_option_flips_boolean_and_refuses_others() {
    let mut app = mock_app();

    apply_set_option(&mut app, "mouse", "on", false);
    assert_eq!(get_option_value(&app, "mouse"), "on");

    assert!(toggle_option(&mut app, "mouse"), "mouse must be toggleable");
    assert_eq!(
        get_option_value(&app, "mouse"),
        "off",
        "no-value set-option must flip a boolean"
    );

    assert!(toggle_option(&mut app, "mouse"));
    assert_eq!(get_option_value(&app, "mouse"), "on", "toggling twice restores");

    // A non-boolean must be refused so the caller reports "empty value"
    // instead of silently writing a bogus value.
    assert!(
        !toggle_option(&mut app, "@vpn_pill"),
        "a user option must not be toggled"
    );
    assert!(
        !toggle_option(&mut app, "status-left"),
        "a string option must not be toggled"
    );
}

#[test]
fn toggling_never_invents_a_value_for_user_options() {
    // The reported command was `set -g @vpn_pill` (value eaten by PowerShell
    // splatting). It must leave the option completely untouched, not set it to
    // "on"/"off"/"".
    let mut app = mock_app();
    apply_set_option(&mut app, "@vpn_pill", "VPN: up", false);
    assert!(!toggle_option(&mut app, "@vpn_pill"));
    assert_eq!(
        app.user_options.get("@vpn_pill").map(|s| s.as_str()),
        Some("VPN: up"),
        "a rejected no-value set-option must not modify the existing value"
    );
}
