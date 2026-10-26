// #712 audit: format modifier parsing sliced at byte 1. A segment or a
// wrapper that starts with a multi byte character panicked the server
// (`display-message -p '#{s§a§b§:x}'`, `'#{t;é:x}'`).
// tmux (format.c format_build_modifiers) takes only ASCII punctuation as a
// wrapper and stops at a modifier letter it does not know.

use super::{parse_modifier_chain, parse_single_modifier, Modifier};

#[test]
fn non_ascii_first_char_is_not_a_modifier() {
    assert!(parse_single_modifier("\u{e9}").is_none());
    assert!(parse_single_modifier("\u{65e5}x").is_none());
    assert!(parse_single_modifier("\u{1f600}").is_none());
}

#[test]
fn chain_with_non_ascii_segment_does_not_panic() {
    let m = parse_modifier_chain("t;\u{e9}");
    assert_eq!(m.len(), 1);
    assert!(matches!(m[0], Modifier::Time));
}

#[test]
fn substitute_with_non_ascii_wrapper_is_ignored() {
    // A non ASCII byte is not a wrapper, so tmux reads one bare argument and
    // then skips `s` for having fewer than two (format.c:4855, :5857). The
    // modifier is ignored while the rest of the list still applies, which is
    // what Modifier::Ignored is; `None` would have dropped the whole list
    // and rendered `#{s\u{a7}s\u{a7}X\u{a7}:session_name}` empty, where tmux 3.4 prints the
    // session name.
    assert!(matches!(parse_single_modifier("s\u{a7}a\u{a7}b\u{a7}"), Some(Modifier::Ignored)));
    assert!(parse_single_modifier("e\u{a7}+\u{a7}").is_none());
}

#[test]
fn ascii_wrappers_still_work() {
    match parse_single_modifier("s/a/b/") {
        Some(Modifier::Substitute { pattern, replacement, .. }) => {
            assert_eq!(pattern, "a");
            assert_eq!(replacement, "b");
        }
        other => panic!("unexpected {:?}", other),
    }
    // A non ASCII pattern inside an ASCII wrapper is fine.
    match parse_single_modifier("s|\u{65e5}|\u{672c}|") {
        Some(Modifier::Substitute { pattern, replacement, .. }) => {
            assert_eq!(pattern, "\u{65e5}");
            assert_eq!(replacement, "\u{672c}");
        }
        other => panic!("unexpected {:?}", other),
    }
    assert!(matches!(parse_single_modifier("e|+|"), Some(Modifier::MathExpr { op: '+', .. })));
}

#[test]
fn bare_letters_after_the_fix() {
    // `s` with no arguments is parsed and skipped by tmux (format.c:5857).
    assert!(matches!(parse_single_modifier("s"), Some(Modifier::Ignored)));
    assert!(parse_single_modifier("e").is_none());
    assert!(parse_single_modifier("").is_none());
}
