// Issue #947: status-format as tmux's array option (options-table.c:1030-1040
// at tag 3.8: OPTIONS_TABLE_IS_ARRAY, no separator named, so a value without
// an index is split on space and `,`, options.c:640-641). Each line keeps its
// own index, so `status-format[N]` and `-u status-format[N]` work on one line,
// `-a` takes the lowest free index and show prints a line per element. Each
// frame expands and sends only the lines below the number of status lines,
// as tmux's status.c:269-300 draws them, so a huge index costs nothing.
//
// The expected values are what tmux 3.8 (`-f /dev/null`, WSL) printed for the
// same commands after `set -g status-format ''`. psmux's default is empty,
// where tmux's is three formats (see option_array::ARRAY_OPTIONS).

use super::*;
use crate::types::AppState;

const OPTION: &str = "status-format";

fn app() -> AppState {
    AppState::new("test_sf_array".to_string())
}

fn items(a: &AppState) -> Vec<(u32, String)> {
    a.status_format.numbered().map(|(index, entry)| (index, entry.to_string())).collect()
}

fn item(index: u32, entry: &str) -> (u32, String) {
    (index, entry.to_string())
}

#[test]
fn a_new_server_has_no_line() {
    let a = app();
    assert!(a.status_format.is_empty());
    assert_eq!(get_option_value(&a, OPTION), "");
    assert_eq!(array_option_show_lines(&a, OPTION, false), "status-format\n");
    assert_eq!(crate::server::helpers::status_format_json(&a), "[]");
}

#[test]
fn an_index_sets_one_line_and_show_and_format_read_it() {
    // `set -g status-format[1] X`: show prints `status-format[1] X`, and
    // `show -gv status-format[1]`, `#{status-format}` and
    // `#{status-format[1]}` all give X. psmux printed nothing for all three.
    let mut a = app();
    apply_set_option(&mut a, "status-format[1]", "X", false).unwrap();
    assert_eq!(items(&a), vec![item(1, "X")]);
    assert_eq!(array_option_show_lines(&a, OPTION, false), "status-format[1] X\n");
    assert_eq!(get_option_value(&a, "status-format[1]"), "X");
    assert_eq!(crate::format::expand_format("#{status-format}", &a), "X");
    assert_eq!(crate::format::expand_format("#{status-format[1]}", &a), "X");
}

#[test]
fn runtime_set_append_and_unset_follow_tmux() {
    let mut a = app();
    apply_set_option(&mut a, OPTION, "a b,c", false).unwrap();
    assert_eq!(items(&a), vec![item(0, "a"), item(1, "b"), item(2, "c")]);
    assert_eq!(crate::format::expand_format("#{status-format}", &a), "a b c");
    set_array_option(&mut a, OPTION, "d", true).unwrap();
    set_array_option(&mut a, "status-format[0]", "e", true).unwrap();
    assert_eq!(items(&a), vec![item(0, "ae"), item(1, "b"), item(2, "c"), item(3, "d")]);
    reset_option_to_default(&mut a, "status-format[1]");
    assert_eq!(items(&a), vec![item(0, "ae"), item(2, "c"), item(3, "d")]);
    set_array_option(&mut a, OPTION, "f", true).unwrap();
    assert_eq!(items(&a), vec![item(0, "ae"), item(1, "f"), item(2, "c"), item(3, "d")]);
    apply_set_option(&mut a, OPTION, " a , b ", false).unwrap();
    assert_eq!(items(&a), vec![item(0, "a"), item(1, "b")]);
    apply_set_option(&mut a, "status-format[2]", " spaced value ", false).unwrap();
    assert_eq!(
        array_option_show_lines(&a, "status-format[2]", false),
        "status-format[2] \" spaced value \"\n"
    );
    assert_eq!(array_option_show_lines(&a, "status-format[9]", false), "status-format[9] ''\n");
    reset_option_to_default(&mut a, OPTION);
    assert!(a.status_format.is_empty());
}

#[test]
fn config_set_append_index_and_unset_follow_tmux() {
    let mut a = app();
    crate::config::parse_config_content(
        &mut a,
        "set -g status-format[1] 'L1 #{session_name}'\n\
         set -ga status-format L0\n\
         set -ga status-format[1] ' more'\n\
         set -g status-format[4] L4\n\
         set -gu status-format[4]\n",
    );
    assert_eq!(items(&a), vec![item(0, "L0"), item(1, "L1 #{session_name} more")]);
    crate::config::parse_config_content(&mut a, "set -g status-format 'x,y'\n");
    assert_eq!(items(&a), vec![item(0, "x"), item(1, "y")]);
}

#[test]
fn a_key_that_is_no_key_is_no_option() {
    let mut a = app();
    let error = apply_set_option(&mut a, "status-format[]", "Y", false).unwrap_err();
    assert!(error.contains("invalid option"), "{error}");
    assert!(a.status_format.is_empty());
}

#[test]
fn a_frame_carries_only_the_shown_lines() {
    // status.c:269-300: `status-format[i]` for each `i` below the number of
    // status lines, a missing one drawn blank. psmux sent every index up to
    // the largest, padded with empty strings.
    let mut a = app();
    a.status_lines = 1;
    apply_set_option(&mut a, "status-format[1]", "L1 #{session_name}", false).unwrap();
    apply_set_option(&mut a, "status-format[7]", "never", false).unwrap();
    assert_eq!(crate::server::helpers::status_format_json(&a), "[]");
    a.status_lines = 2;
    assert_eq!(crate::server::helpers::status_format_json(&a), "[\"\",\"L1 test_sf_array\"]");
    apply_set_option(&mut a, "status-format[0]", "L0", false).unwrap();
    a.status_lines = 8;
    let json = crate::server::helpers::status_format_json(&a);
    let lines: Vec<String> = serde_json::from_str(&json).unwrap();
    assert_eq!(lines.len(), 8, "{json}");
    assert_eq!((lines[0].as_str(), lines[2].as_str(), lines[7].as_str()), ("L0", "", "never"));
}

#[test]
fn a_huge_index_costs_nothing() {
    // `set -g status-format[1000000] Z` used to push a million empty strings
    // and expand them all on every frame.
    let mut a = app();
    a.status_lines = 3;
    apply_set_option(&mut a, "status-format[4000000000]", "Z", false).unwrap();
    assert_eq!(items(&a), vec![item(4_000_000_000, "Z")]);
    assert_eq!(crate::server::helpers::status_format_json(&a), "[]");
    apply_set_option(&mut a, "status-format[2]", "two", false).unwrap();
    assert_eq!(crate::server::helpers::status_format_json(&a), "[\"\",\"\",\"two\"]");
}
