// Issue #618: `set-option -s <option> <value>` was rejected outright with
// "psmux: set-option: unknown flag -s" and exit 1, on every spelling
// (set-option, set, setw, set-window-option) and on every route that shares
// the CLI guard.
//
// tmux 3.2 moved default-terminal, extended-keys and friends onto the server
// option table, so the documented, current way to write them is
// `set-option -s default-terminal xterm-256color`. Tools do exactly that
// (thurbox issues three such calls on every session bootstrap), so the refusal
// turned a correct command into a hard failure.
//
// The read side had the mirror-image gap: `show-options -s` was accepted but
// its `-s` was parsed into a variable nothing read, so the flag changed
// nothing and the command printed the entire option store, session options
// included, where tmux prints server options only.
//
// psmux runs one server per session and keeps a single option store, so `-s`
// cannot select a genuinely cross-session store. It resolves to the same
// global store as `-g` on the write side, and narrows the listing to the
// catalog's server-scope options on the read side. The live CLI, TCP, config
// and attached-client routes are covered by
// tests/test_issue618_set_option_server_scope.ps1.

#[allow(unused_imports)]
use super::*;

use crate::commands::execute_command_string;
use crate::config::parse_config_line;
use crate::server::option_catalog::{is_server_option, server_option_names};
use crate::server::options::get_option_value;
use crate::types::AppState;

fn mock_app() -> AppState {
    AppState::new("srv618".to_string())
}

// ---------------------------------------------------------------------------
// The config-file route (src/config.rs parse_set_option).
// ---------------------------------------------------------------------------

#[test]
fn config_set_s_stores_default_terminal() {
    let mut app = mock_app();
    parse_config_line(&mut app, "set -s default-terminal xterm-256color");
    assert_eq!(
        get_option_value(&app, "default-terminal"),
        "xterm-256color",
        "`set -s default-terminal` in a config file must land the value"
    );
}

#[test]
fn config_set_option_s_long_spelling_stores_value() {
    let mut app = mock_app();
    parse_config_line(&mut app, "set-option -s default-terminal screen-256color");
    assert_eq!(get_option_value(&app, "default-terminal"), "screen-256color");
}

#[test]
fn config_set_s_user_option_stores_value() {
    let mut app = mock_app();
    parse_config_line(&mut app, "set -s @i618cfg viaS");
    assert_eq!(
        app.user_options.get("@i618cfg").map(|s| s.as_str()),
        Some("viaS"),
        "-s must not swallow the option name or the value"
    );
}

#[test]
fn config_set_sg_combined_still_works() {
    // `set -sg escape-time 0` is one of the most copied lines in real tmux
    // configs. It already worked through the 'g' in the token; pin it so the
    // new 's' handling cannot regress it.
    let mut app = mock_app();
    parse_config_line(&mut app, "set -sg escape-time 25");
    assert_eq!(app.escape_time_ms, 25);
}

#[test]
fn config_set_s_never_warns_unknown_flag() {
    let mut app = mock_app();
    parse_config_line(&mut app, "set -s default-terminal xterm-256color");
    assert!(
        !app.config_warnings.iter().any(|w| w.contains("unknown flag")),
        "-s must not be reported as an unknown flag, got: {:?}",
        app.config_warnings
    );
}

// ---------------------------------------------------------------------------
// The command-dispatch route (src/commands.rs execute_command_string), which
// is what the command prompt and key bindings drive.
// ---------------------------------------------------------------------------

#[test]
fn command_set_s_applies_like_g() {
    let mut app = mock_app();
    execute_command_string(&mut app, "set-option -s escape-time 42").unwrap();
    assert_eq!(app.escape_time_ms, 42, "-s must reach the option store");
}

#[test]
fn command_setw_s_applies() {
    // psmux shares one set-option parser across all four spellings, so the
    // setw alias accepts -s too. tmux's own set-window-option table
    // ("aFgoqt:u", cmd-set-option.c) has no -s and would refuse this; psmux
    // stays lenient rather than shipping a second, differently shaped hard
    // failure for the tools this fix exists to unbreak.
    let mut app = mock_app();
    execute_command_string(&mut app, "setw -s @i618w wv").unwrap();
    assert_eq!(app.user_options.get("@i618w").map(|s| s.as_str()), Some("wv"));
}

#[test]
fn command_set_sq_combined_applies() {
    let mut app = mock_app();
    execute_command_string(&mut app, "set -sq @i618q qv").unwrap();
    assert_eq!(app.user_options.get("@i618q").map(|s| s.as_str()), Some("qv"));
}

// ---------------------------------------------------------------------------
// The CLI guard and shared parser consult the same accepted-flag set.
// ---------------------------------------------------------------------------

#[test]
fn cli_flag_set_accepts_s() {
    let parsed = crate::cli::parse_set_option_args(&[
        "-s",
        "default-terminal",
        "xterm-256color",
    ]);
    assert_eq!(parsed.validate(false), Ok(()));
}

#[test]
fn cli_flag_set_keeps_the_older_flags() {
    for ch in "agopqtuUw".chars() {
        assert!(
            crate::SET_OPTION_CLI_FLAGS.contains(ch),
            "-{} was accepted before #618 and must stay accepted",
            ch
        );
    }
}

#[test]
fn cli_flag_set_still_refuses_unknown_letters() {
    // The #553 guard is the point of the const: everything outside the set is
    // still an "unknown flag" exit 1.
    for ch in "xXZbB".chars() {
        assert!(
            !crate::SET_OPTION_CLI_FLAGS.contains(ch),
            "-{} must stay refused",
            ch
        );
    }
}

#[test]
fn cli_flag_show_accepts_s() {
    assert!(crate::SHOW_OPTIONS_CLI_FLAGS.contains('s'));
}

// ---------------------------------------------------------------------------
// The read side: which options a bare `show-options -s` narrows down to.
// ---------------------------------------------------------------------------

#[test]
fn server_scope_list_carries_the_options_tools_write() {
    let names = server_option_names();
    for wanted in ["default-terminal", "escape-time", "set-clipboard", "exit-empty"] {
        assert!(
            names.contains(&wanted),
            "{} is a server option in tmux's table and must appear in show-options -s",
            wanted
        );
    }
}

#[test]
fn server_scope_list_excludes_session_options() {
    let names = server_option_names();
    for unwanted in ["status", "prefix", "mouse", "status-left", "mode-keys"] {
        assert!(
            !names.contains(&unwanted),
            "{} is a session option and must not appear in show-options -s",
            unwanted
        );
    }
}

#[test]
fn server_scope_list_is_sorted_and_unique() {
    let names = server_option_names();
    assert!(!names.is_empty());
    for pair in names.windows(2) {
        assert!(pair[0] < pair[1], "{} then {} is not sorted/unique", pair[0], pair[1]);
    }
}

#[test]
fn is_server_option_agrees_with_the_list() {
    for name in server_option_names() {
        assert!(is_server_option(name));
    }
    assert!(!is_server_option("status"));
    assert!(!is_server_option("@nope"));
}

#[test]
fn every_server_option_resolves_to_a_value_lookup() {
    // The listing is built by asking the app for each name in turn, so a name
    // the value lookup does not know would print a blank line forever.
    //
    // Options whose CATALOG default is itself the empty string are exempt,
    // because for those a blank line is the correct output rather than a
    // missing lookup arm. That is derived from the catalog rather than listed
    // by hand (it used to name copy-command alone) so that adding another
    // legitimately-empty option -- codepoint-widths, whose tmux default is
    // `.default_str = ""` -- does not look like a regression, while a name
    // with a real default and no lookup arm is still caught.
    let app = mock_app();
    for name in server_option_names() {
        if crate::server::option_catalog::default_for(name) == Some("") {
            continue;
        }
        assert!(
            !get_option_value(&app, name).is_empty(),
            "show-options -s would print an empty value for {}",
            name
        );
    }
}
