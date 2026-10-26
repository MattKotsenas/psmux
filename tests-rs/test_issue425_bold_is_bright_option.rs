// Issue #425 follow-up: the `bold-is-bright` option.
//
// The fix in 77f0dc9 rewrites crossterm's 256-indexed `38;5;N`/`48;5;N`
// (N<=15) back to standard SGR so Windows Terminal applies "bold is bright"
// to the 16 basic colors.  Reporter dkaszews confirmed the fix but flagged a
// side effect: an EXPLICIT 256-indexed low color plus bold (`ESC[38;5;2;1m`)
// now renders bright in psmux but not outside, because crossterm collapses a
// basic color and an explicit 256-indexed 0-15 into the same bytes so the
// rewrite cannot tell them apart.  He asked for a config option so users who
// rely on 256-color accuracy can opt out.
//
// These tests lock in that the `bold-is-bright` option parses on the config
// path and round-trips through the server option store, defaulting to on.

use super::*;

fn mock_app() -> AppState {
    AppState::new("test_session".to_string())
}

#[test]
fn bold_is_bright_defaults_on() {
    let app = mock_app();
    assert!(app.bold_is_bright, "bold-is-bright must default to on (issue #425 fix stays active)");
}

#[test]
fn config_can_disable_bold_is_bright() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g bold-is-bright off\n");
    assert!(!app.bold_is_bright, "set -g bold-is-bright off should disable the rewrite");
}

#[test]
fn config_can_re_enable_bold_is_bright() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g bold-is-bright off\n");
    parse_config_content(&mut app, "set -g bold-is-bright on\n");
    assert!(app.bold_is_bright, "set -g bold-is-bright on should re-enable the rewrite");
}

#[test]
fn config_accepts_boolean_synonyms() {
    for v in ["off", "false", "0"] {
        let mut app = mock_app();
        parse_config_content(&mut app, &format!("set -g bold-is-bright {v}\n"));
        assert!(!app.bold_is_bright, "'{v}' should turn bold-is-bright off");
    }
    for v in ["on", "true", "1"] {
        let mut app = mock_app();
        parse_config_content(&mut app, "set -g bold-is-bright off\n");
        parse_config_content(&mut app, &format!("set -g bold-is-bright {v}\n"));
        assert!(app.bold_is_bright, "'{v}' should turn bold-is-bright on");
    }
}

#[test]
fn server_apply_and_report_round_trip() {
    let mut app = mock_app();
    // Default reports "on".
    assert_eq!(crate::server::options::get_option_value(&app, "bold-is-bright"), "on");
    // Disable via the server-side apply path (the forwarded set-option path).
    crate::server::options::apply_set_option(&mut app, "bold-is-bright", "off", false);
    assert!(!app.bold_is_bright);
    assert_eq!(crate::server::options::get_option_value(&app, "bold-is-bright"), "off");
    // Re-enable.
    crate::server::options::apply_set_option(&mut app, "bold-is-bright", "on", false);
    assert_eq!(crate::server::options::get_option_value(&app, "bold-is-bright"), "on");
}

#[test]
fn bold_is_bright_is_in_option_catalog_as_boolean() {
    let def = crate::server::option_catalog::OPTION_CATALOG
        .iter()
        .find(|d| d.name == "bold-is-bright")
        .expect("bold-is-bright must be registered in the option catalog");
    assert_eq!(
        def.option_type,
        crate::server::option_catalog::OptionType::Boolean
    );
    assert_eq!(def.default, "on");
}
