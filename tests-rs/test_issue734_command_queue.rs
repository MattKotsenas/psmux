// Issue #734: the commands queued after `start-server` are split the way
// tmux's cmd_parse_from_arguments (cmd-parse.y:1063-1130) splits argv.

use super::*;

fn q(args: &[&str]) -> Vec<Vec<String>> {
    split_command_queue(args)
}

fn v(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_lone_semicolon_separates_commands() {
    assert_eq!(
        q(&[";", "set-option", "-g", "exit-empty", "off"]),
        vec![v(&[]), v(&["set-option", "-g", "exit-empty", "off"])]
    );
}

#[test]
fn nothing_queued_is_one_empty_group() {
    assert_eq!(q(&[]), vec![v(&[])]);
}

#[test]
fn a_trailing_semicolon_ends_the_command_and_keeps_the_text() {
    assert_eq!(
        q(&["off;", "show", "-g"]),
        vec![v(&["off"]), v(&["show", "-g"])]
    );
}

#[test]
fn an_escaped_trailing_semicolon_is_literal() {
    assert_eq!(q(&["a\\;", "b"]), vec![v(&["a;", "b"])]);
}

#[test]
fn a_lone_backslash_semicolon_from_a_windows_shell_separates() {
    assert_eq!(
        q(&["\\;", "set", "-g", "exit-empty", "off", "\\;", "new-session", "-d"]),
        vec![v(&[]), v(&["set", "-g", "exit-empty", "off"]), v(&["new-session", "-d"])]
    );
}

#[test]
fn empty_commands_after_the_first_are_dropped() {
    assert_eq!(q(&[";", ";", "ls", ";"]), vec![v(&[]), v(&["ls"])]);
}

#[test]
fn a_nested_command_string_is_not_split() {
    // `if-shell cond "a ; b"` reaches us as ONE argument containing ` ; `.
    assert_eq!(
        q(&[";", "if-shell", "true", "display a ; display b"]),
        vec![v(&[]), v(&["if-shell", "true", "display a ; display b"])]
    );
}
