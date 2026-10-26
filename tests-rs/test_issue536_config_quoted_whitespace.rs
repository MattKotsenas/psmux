// Issue #536: quoted whitespace in config-file `set-option` values was
// collapsed, because parse_set_option split the line with split_whitespace()
// and rejoined the value with single spaces. Quoting could not protect a run
// of spaces, so a config-file value and the identical CLI command produced
// different results with no error either way.
//
// Expected values below are tmux 3.4's, measured directly rather than assumed.

use super::*;

fn mock_app() -> AppState {
    AppState::new("test_session".to_string())
}

fn user_opt(app: &AppState, key: &str) -> String {
    app.user_options.get(key).cloned().unwrap_or_default()
}

// ---------------------------------------------------------------- extraction

#[test]
fn quoted_value_keeps_every_space() {
    // The reported case. tmux stores 7 characters.
    assert_eq!(extract_option_value(r#""A     B""#), "A     B");
    assert_eq!(extract_option_value(r#""A     B""#).len(), 7);
}

#[test]
fn single_quoted_value_keeps_every_space() {
    assert_eq!(extract_option_value("'A     B'"), "A     B");
}

#[test]
fn quoted_value_keeps_leading_and_trailing_space() {
    // These are the shapes a rejoined "key value" string could never carry:
    // the receiver trimmed both ends back off.
    assert_eq!(extract_option_value(r#""   leading""#), "   leading");
    assert_eq!(extract_option_value(r#""trailing   ""#), "trailing   ");
    assert_eq!(extract_option_value(r#""   both   ""#), "   both   ");
}

#[test]
fn twelve_space_gap_survives() {
    // The dotfiles-Windows status-right case: a deliberate gap rendered as one
    // space, and the bar still looked plausible so nothing surfaced it.
    let v = extract_option_value(r#""left            right""#);
    assert_eq!(v, "left            right");
    assert_eq!(v.len(), 21);
}

#[test]
fn escapes_are_processed_inside_double_quotes() {
    // tmux yields `say "hi"` (8 chars); psmux used to keep the backslashes.
    assert_eq!(extract_option_value(r#""say \"hi\"""#), r#"say "hi""#);
    assert_eq!(extract_option_value(r#""say \"hi\"""#).len(), 8);
    // A backslash before anything else stays literal (Windows paths).
    assert_eq!(extract_option_value(r#""C:\Users\me""#), r"C:\Users\me");
}

#[test]
fn single_quotes_do_not_process_escapes() {
    // Matching tmux and commands::parse_command_line: only double quotes do.
    assert_eq!(extract_option_value(r"'a\b'"), r"a\b");
}

#[test]
fn empty_quoted_value_is_empty() {
    assert_eq!(extract_option_value(r#""""#), "");
    assert_eq!(extract_option_value("''"), "");
}

#[test]
fn unquoted_value_is_verbatim_without_trailing_space() {
    assert_eq!(extract_option_value("bar"), "bar");
    assert_eq!(extract_option_value("bar   "), "bar");
    assert_eq!(extract_option_value("one two three"), "one two three");
}

#[test]
fn inner_quotes_are_content_not_delimiters() {
    // Regression guard: `a"b"c` is a value, not a quoted string.
    assert_eq!(extract_option_value(r#"a"b"c"#), r#"a"b"c"#);
}

#[test]
fn quote_not_closing_the_line_falls_back_to_legacy_shape() {
    // Two quoted words, or a chained command, are shapes this scan
    // deliberately does not claim: it must not silently keep half of one.
    // Legacy behaviour was to strip one wrapping layer, which is preserved.
    assert_eq!(extract_option_value(r#""a" "b""#), r#"a" "b"#);
    // Unterminated quote also falls back rather than swallowing the line.
    assert_eq!(extract_option_value(r#""unterminated"#), r#""unterminated"#);
}

// ----------------------------------------------------------------- tokenizer

#[test]
fn tokenizer_treats_a_quoted_run_as_one_token() {
    let t = tokens_with_offsets(r#"set -g @x "A     B""#);
    assert_eq!(t.len(), 4, "quoted value must not split: {:?}", t);
    assert_eq!(t[0].1, "set");
    assert_eq!(t[1].1, "-g");
    assert_eq!(t[2].1, "@x");
    assert_eq!(t[3].1, r#""A     B""#);
}

#[test]
fn tokenizer_offsets_point_into_the_original_line() {
    // The offsets are the whole point: they let the caller recover the value
    // verbatim from the original line.
    let line = r#"set -g @x "A     B""#;
    let t = tokens_with_offsets(line);
    let (off, _) = t[3];
    assert_eq!(&line[off..], r#""A     B""#);
    assert_eq!(extract_option_value(&line[off..]), "A     B");
}

#[test]
fn tokenizer_handles_extra_spacing_between_tokens() {
    let line = "set   -g    @x    val";
    let t = tokens_with_offsets(line);
    assert_eq!(t.len(), 4);
    assert_eq!(t[3].1, "val");
    assert_eq!(&line[t[3].0..], "val");
}

// -------------------------------------------------------------- end to end

#[test]
fn config_line_stores_a_quoted_gap_exactly() {
    let mut app = mock_app();
    crate::config::parse_config_content(&mut app, "set -g @gap \"A     B\"\n");
    assert_eq!(user_opt(&app, "@gap"), "A     B");
}

#[test]
fn config_status_right_keeps_its_gap() {
    // A built-in option, not just an @user option.
    let mut app = mock_app();
    crate::config::parse_config_content(
        &mut app,
        "set -g status-right \"left            right\"\n",
    );
    assert_eq!(app.status_right, "left            right");
    assert_eq!(app.status_right.len(), 21);
}

#[test]
fn config_keeps_leading_padding_used_for_width_matching() {
    // The three-branch indicator from the report: the idle branch is three
    // spaces and collapsed to one, shifting the bar when the prefix was held.
    let mut app = mock_app();
    crate::config::parse_config_content(
        &mut app,
        "set -g @ind \"#{?client_prefix, X ,#{?pane_in_mode, Y ,   }}\"\n",
    );
    assert!(
        user_opt(&app, "@ind").ends_with(",   }}"),
        "idle branch lost its padding: {:?}",
        user_opt(&app, "@ind")
    );
}

#[test]
fn config_regression_guards_still_hold() {
    // Everything the old split_whitespace path got right must stay right.
    let mut app = mock_app();
    crate::config::parse_config_content(
        &mut app,
        concat!(
            "set -g @plain bar\n",
            "set -g @comment bar # trailing comment\n",
            "set -g @hashval \"#{session_name} x\"\n",
            "set -g @style \"#[fg=red]TXT#[default]\"\n",
            "set -g @pct \"%H:%M %d-%b\"\n",
            "set -g @semi \"a;b\"\n",
            "set -g @empty \"\"\n",
            "set -g @multiword one two three\n",
            "set -g @trailws bar   \n",
        ),
    );
    assert_eq!(user_opt(&app, "@plain"), "bar");
    assert_eq!(user_opt(&app, "@comment"), "bar", "inline comment (#416)");
    assert_eq!(user_opt(&app, "@hashval"), "#{session_name} x", "format is not a comment");
    assert_eq!(user_opt(&app, "@style"), "#[fg=red]TXT#[default]");
    assert_eq!(user_opt(&app, "@pct"), "%H:%M %d-%b");
    assert_eq!(user_opt(&app, "@semi"), "a;b", "quoted ; is not a splitter (#499)");
    assert_eq!(user_opt(&app, "@empty"), "");
    assert_eq!(user_opt(&app, "@multiword"), "one two three");
    assert_eq!(user_opt(&app, "@trailws"), "bar");
}

#[test]
fn boolean_toggle_with_no_value_still_works() {
    // #278 / #535: an option name with no value toggles a boolean. The
    // rewritten value extraction must still report "no value" for that line.
    let mut app = mock_app();
    crate::config::parse_config_content(&mut app, "set -g mouse on\n");
    assert_eq!(crate::server::options::get_option_value(&app, "mouse"), "on");
    crate::config::parse_config_content(&mut app, "set -g mouse\n");
    assert_eq!(
        crate::server::options::get_option_value(&app, "mouse"),
        "off",
        "no-value set-option must still toggle"
    );
}

#[test]
fn command_prompt_style_lines_still_apply() {
    // The TUI command prompt routes set-option through config::parse_config_line,
    // the same entry point the rewritten parser sits behind. These are the exact
    // strings tests/test_config_exhaustive_tui.ps1 sends.
    let mut app = mock_app();
    crate::config::parse_config_line(&mut app, "set-option -g escape-time 111");
    assert_eq!(app.escape_time_ms, 111);
    crate::config::parse_config_line(&mut app, "set-option -g history-limit 9999");
    assert_eq!(app.history_limit, 9999);
    crate::config::parse_config_line(&mut app, "set-option -g mouse off");
    assert_eq!(crate::server::options::get_option_value(&app, "mouse"), "off");
    crate::config::parse_config_line(&mut app, "set-option -g base-index 1");
    assert_eq!(app.window_base_index, 1);
    crate::config::parse_config_line(&mut app, "set-option -g status-position top");
    assert_eq!(app.status_position, "top");
}

#[test]
fn append_flag_concatenates_exact_values() {
    let mut app = mock_app();
    crate::config::parse_config_content(&mut app, "set -g @acc \"A  \"\n");
    assert_eq!(user_opt(&app, "@acc"), "A  ");
    crate::config::parse_config_content(&mut app, "set -ga @acc \"  B\"\n");
    assert_eq!(
        user_opt(&app, "@acc"),
        "A    B",
        "append must keep both sides' padding"
    );
}
