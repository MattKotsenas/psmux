// Issue #476: key bound to if-shell/run-shell never fired on a real keypress.
// Root cause: the TCP bind-key handlers rebuilt the bound command from
// quote-aware tokens with a plain join(" "), destroying argument grouping.
// The stored binding `if-shell -F 1 set -g @r A set -g @r B` then dispatched
// a bare `set` (no-op) when the key fired. These tests pin requote_command_tail
// and its round-trip through parse_command_line.

use super::*;
use crate::commands::parse_command_line;

fn roundtrip(args: &[&str]) -> Vec<String> {
    // Prepend a command word because parse_command_line tokenizes a full line.
    let line = format!("cmd {}", requote_command_tail(args));
    parse_command_line(&line)[1..].to_vec()
}

#[test]
fn issue476_repro_binding_grouping_survives() {
    // Exactly the tail the server sees for:
    // bind-key -n C-h "if-shell -F '1' 'set -g @result KEY_MATCH' 'set -g @result KEY_NOMATCH'"
    let tail = ["if-shell", "-F", "1", "set -g @result KEY_MATCH", "set -g @result KEY_NOMATCH"];
    let out = roundtrip(&tail);
    assert_eq!(out, vec![
        "if-shell", "-F", "1", "set -g @result KEY_MATCH", "set -g @result KEY_NOMATCH",
    ], "grouped args must survive requote + re-parse");
}

#[test]
fn plain_tokens_stay_bare() {
    let tail = ["select-pane", "-L"];
    assert_eq!(requote_command_tail(&tail), "select-pane -L");
}

#[test]
fn chain_separators_stay_bare_for_command_chaining() {
    let tail = ["split-window", "\\;", "select-pane", "-D"];
    let joined = requote_command_tail(&tail);
    assert_eq!(joined, "split-window \\; select-pane -D");
    // split_chained_commands must still see the separator
    let chained = crate::config::split_chained_commands_pub(&joined);
    assert_eq!(chained.len(), 2, "chaining must still split, got {:?}", chained);
}

#[test]
fn empty_token_preserved() {
    let tail = ["select-pane", "-T", ""];
    let out = roundtrip(&tail);
    assert_eq!(out, vec!["select-pane", "-T", ""], "empty quoted arg must survive (#177 parity)");
}

#[test]
fn token_with_single_quote_roundtrips_via_double_quotes() {
    let tail = ["display-message", "it's here"];
    let out = roundtrip(&tail);
    assert_eq!(out, vec!["display-message", "it's here"]);
}

#[test]
fn token_with_double_quotes_roundtrips_via_single_quotes() {
    let tail = ["run-shell", "echo \"hello world\""];
    let out = roundtrip(&tail);
    assert_eq!(out, vec!["run-shell", "echo \"hello world\""]);
}

#[test]
fn windows_path_with_spaces_roundtrips() {
    let tail = ["run-shell", "C:\\Program Files\\Git\\bin\\bash.exe"];
    let out = roundtrip(&tail);
    assert_eq!(out, vec!["run-shell", "C:\\Program Files\\Git\\bin\\bash.exe"]);
}

#[test]
fn format_condition_token_stays_bare() {
    let tail = ["if-shell", "-F", "#{m/r:^pwsh$,#{pane_current_command}}", "send-keys C-h", "select-pane -L"];
    let out = roundtrip(&tail);
    assert_eq!(out[2], "#{m/r:^pwsh$,#{pane_current_command}}");
    assert_eq!(out[3], "send-keys C-h");
    assert_eq!(out[4], "select-pane -L");
}

#[test]
fn target_filter_stops_at_deferred_command_boundaries() {
    let cases: &[(&str, &[&str], &[&str])] = &[
        ("bind-key", &["-n", "x", "kill-window", "-t"], &["-n", "x", "kill-window", "-t"]),
        (
            "set-hook",
            &["-g", "-t", "0", "after-split-window", "kill-window", "-t"],
            &["-g", "after-split-window", "kill-window", "-t"],
        ),
        (
            "confirm-before",
            &["-p", "Kill?", "-t", "0", "kill-window", "-t"],
            &["-p", "Kill?", "kill-window", "-t"],
        ),
        ("kill-window", &["-t", "0", "-a"], &["-a"]),
    ];

    for (command, args, expected) in cases {
        assert_eq!(without_outer_target(command, args), *expected, "{command}");
    }
}
