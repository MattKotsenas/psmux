// Regression guard: `new-window -- prog args...` must name the window after
// the program, like tmux, not after the `--` marker.
//
// 9bfdfc3 (#582) made the server keep the `--` marker at the head of the
// command string so `build_command` knows to exec the argv directly instead of
// wrapping it in a shell. `build_command` decodes the marker; the naming path
// did not, so `resolve_shell_program("-- cmd /k echo hi")` returned `--` and
// the window was called `--`. Before 9bfdfc3 the server passed only the first
// non-flag token through, so the window was named `cmd`.

use super::*;

#[test]
fn argv_marker_is_stripped_before_naming() {
    assert_eq!(
        command_text_for_naming("-- cmd /k echo hi"),
        Some("cmd /k echo hi"),
        "the `--` marker must not become part of the window name"
    );
}

#[test]
fn argv_marker_alone_means_default_shell() {
    assert_eq!(command_text_for_naming("--"), None);
    assert_eq!(command_text_for_naming("--   "), None);
}

#[test]
fn a_leading_double_dash_option_is_not_the_marker() {
    // "--foo" is an ordinary command string, not the argv marker (build_command
    // makes the same distinction: the marker needs whitespace or end-of-string
    // after the dashes).
    assert_eq!(command_text_for_naming("--foo"), Some("--foo"));
    assert_eq!(command_text_for_naming("--version"), Some("--version"));
}

#[test]
fn plain_commands_are_untouched() {
    assert_eq!(command_text_for_naming("nvim"), Some("nvim"));
    assert_eq!(command_text_for_naming("cmd /k echo hi"), Some("cmd /k echo hi"));
}

#[test]
fn window_name_for_a_dashdash_argv_is_the_program() {
    // The end-to-end naming call: this is what create_window_with_env uses.
    assert_eq!(
        default_shell_name(Some("-- cmd /k echo hi"), None),
        "cmd",
        "BUG: the window would be named after the `--` marker"
    );
    // And the plain (pre-#582) form keeps naming the same program.
    assert_eq!(default_shell_name(Some("cmd /k echo hi"), None), "cmd");
}

#[test]
fn window_name_falls_back_to_the_configured_shell_for_a_bare_marker() {
    assert_eq!(default_shell_name(Some("--"), Some("bash")), "bash");
}
