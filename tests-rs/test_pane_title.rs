use crate::commands::parse_command_line;

// ── #177 root cause: parse_command_line must preserve explicitly-quoted EMPTY
//    arguments so `select-pane -T ""` carries an empty value to SetPaneTitle.
//    (Previously `""` was dropped, the -T value was lost, and the title never
//    cleared.) These exercise the real tokenizer, not a tautology. ──

#[test]
fn parse_preserves_quoted_empty_arg_double() {
    // The exact #177 scenario: the empty title value must survive tokenizing.
    assert_eq!(
        parse_command_line(r#"select-pane -T """#),
        vec!["select-pane", "-T", ""],
        "explicitly-quoted empty arg must be preserved (regression guard for #177)"
    );
}

#[test]
fn parse_preserves_quoted_empty_arg_single() {
    assert_eq!(parse_command_line("select-pane -T ''"), vec!["select-pane", "-T", ""]);
}

#[test]
fn parse_empty_arg_in_middle() {
    assert_eq!(parse_command_line(r#"cmd a "" b"#), vec!["cmd", "a", "", "b"]);
}

#[test]
fn parse_trailing_whitespace_no_spurious_empty() {
    // A whitespace-only gap is NOT an argument; only quoted emptiness is.
    assert_eq!(parse_command_line("cmd a "), vec!["cmd", "a"]);
    assert_eq!(parse_command_line("cmd  a"), vec!["cmd", "a"]);
}

#[test]
fn parse_quote_in_middle_joins() {
    assert_eq!(parse_command_line(r#"cmd a"b"c"#), vec!["cmd", "abc"]);
}

#[test]
fn parse_genuinely_empty_input() {
    let empty: Vec<String> = parse_command_line("");
    assert!(empty.is_empty(), "empty input yields no args");
}
