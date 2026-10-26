//! Format modifier lists that tmux reads differently from psmux.
//!
//! tmux's `format_build_modifiers` (format.c:4790 to :4900) gives up on the
//! WHOLE list at the first character it does not know and then looks the
//! complete text up as one name, which is empty. psmux skipped the unknown
//! segment and applied the rest. A modifier's arguments are wrapped in ASCII
//! punctuation other than `-`; any other character after the letter starts
//! one bare argument, and `s` with fewer than two arguments is skipped
//! (format.c:5857) while the rest of the list applies.
//!
//! Every expectation below is what tmux 3.4 printed for the same spec, with
//! the session named `s` and `@v` set to `abcdefgh aA`. Registered from
//! src/format.rs.

use super::*;

fn app() -> AppState {
    let mut a = AppState::new("s".to_string());
    a.window_base_index = 0;
    a.user_options.insert("@v".to_string(), "abcdefgh aA".to_string());
    a.user_options.insert("@n".to_string(), "3".to_string());
    a.windows.push(crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: "shell".to_string(),
        id: 0,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    });
    a
}

fn check(cases: &[(&str, &str)]) {
    let a = app();
    let mut bad = Vec::new();
    for (spec, want) in cases {
        let got = expand_format(spec, &a);
        if got != *want {
            bad.push(format!("{spec}: tmux [{want}] psmux [{got}]"));
        }
    }
    assert!(bad.is_empty(), "differ from tmux 3.4:\n{}", bad.join("\n"));
}

#[test]
fn an_unknown_letter_abandons_the_whole_list() {
    check(&[
        ("#{t;Z:session_name}", ""),
        ("#{t;\u{e9}:session_name}", ""),
        ("#{t;Z;s/s/X/:session_name}", ""),
        ("#{Z:session_name}", ""),
    ]);
}

#[test]
fn an_abandoned_list_holding_a_format_is_expanded_as_text() {
    // `=` takes `#` as its wrapper, the list falls apart, and the key with its
    // inner #{@n} is expanded as a format (format_replace's final branch).
    check(&[("#{=#{@n}:@v}", "=3:@v")]);
}

#[test]
fn a_wrapper_must_be_ascii_punctuation_other_than_dash() {
    check(&[
        ("#{sXsXYX:session_name}", "s"),
        ("#{s\u{a7}s\u{a7}X\u{a7}:session_name}", "s"),
        ("#{s0s0X0:session_name}", "s"),
        ("#{s s X :session_name}", "s"),
        ("#{sXaXbX:@v}", "abcdefgh aA"),
    ]);
}

#[test]
fn substitute_without_arguments_is_skipped_and_the_rest_applies() {
    check(&[("#{s:session_name}", "s"), ("#{s;=1:@v}", "a")]);
}

#[test]
fn an_empty_list_is_a_plain_lookup() {
    check(&[
        ("#{:session_name}", "s"),
        ("#{;:session_name}", "s"),
        // Only ONE separator is skipped per step (format.c:4813); the second
        // `;` is an unknown modifier, so the list is abandoned.
        ("#{;;:session_name}", ""),
    ]);
}

#[test]
fn valid_lists_are_unchanged() {
    check(&[
        ("#{s/s/X/:session_name}", "X"),
        ("#{s|s|X|:session_name}", "X"),
        ("#{=2:session_name}", "s"),
        ("#{e|+|:1,2}", "3"),
        ("#{e|*|:3,4}", "12"),
        ("#{e|+|f|2:1.5,2}", "3.50"),
        ("#{l;:session_name}", "session_name"),
        ("#{l::session_name}", ":session_name"),
        ("#{l:hello}", "hello"),
        ("#{s/a/b/;=3:@v}", "bbc"),
        ("#{q:@v}", "abcdefgh\\ aA"),
        ("#{b:@v}", "abcdefgh aA"),
        ("#{=-3:@v}", " aA"),
        ("#{=/2/...:@v}", "ab..."),
        ("#{p5:session_name}", "s    "),
        ("#{p-5:session_name}", "    s"),
        ("#{T:session_name}", "s"),
        ("#{E:session_name}", "s"),
        ("#{m:s*,session_name}", "1"),
        ("#{w:session_name}", "1"),
        ("#{session_name:}", ""),
        ("#{session_name}", "s"),
    ]);
}

#[test]
fn the_list_ends_where_tmux_ends_it() {
    assert_eq!(tmux_modifier_colon("t;Z:x"), None);
    assert_eq!(tmux_modifier_colon("session_name"), None);
    assert_eq!(tmux_modifier_colon(":x"), Some(0));
    assert_eq!(tmux_modifier_colon("s/a/b/:x"), Some(6));
    assert_eq!(tmux_modifier_colon("s/a/b:x"), Some(5), "the closing wrapper is optional (format.c:4805)");
    assert_eq!(tmux_modifier_colon("e|+|f|2:1,2"), Some(7));
    assert_eq!(tmux_modifier_colon("s/#{a:b}/c/:x"), Some(11), "a nested format is skipped whole");
    assert_eq!(tmux_modifier_colon("=/5/#:x/:y"), Some(8), "#: is an escaped colon");
    assert_eq!(tmux_modifier_colon("||:1,0"), Some(2));
    assert_eq!(tmux_modifier_colon("s\u{a7}a:x"), Some(4), "a UTF-8 byte starts a bare argument");
}
