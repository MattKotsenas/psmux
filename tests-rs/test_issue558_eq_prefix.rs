// Issue #558: the tmux '=' exact-match marker must be invisible past the
// target parser. kill-session compared the RAW "-t" string against the
// server's session name, so "=name" never matched and the session survived.
use super::*;

#[test]
fn strips_single_leading_eq() {
    assert_eq!(strip_exact_match_prefix("=name"), "name");
}

#[test]
fn plain_name_unchanged() {
    assert_eq!(strip_exact_match_prefix("name"), "name");
}

#[test]
fn only_one_marker_is_stripped() {
    // "==x" is the marker plus a literal "=x"; the literal remains.
    assert_eq!(strip_exact_match_prefix("==x"), "=x");
}

#[test]
fn window_pane_suffix_preserved() {
    assert_eq!(strip_exact_match_prefix("=sess:2.1"), "sess:2.1");
}

#[test]
fn relative_pane_forms_untouched() {
    // The raw string is kept for these; stripping must not corrupt them.
    assert_eq!(strip_exact_match_prefix(":.+"), ":.+");
    assert_eq!(strip_exact_match_prefix(":.-"), ":.-");
    assert_eq!(strip_exact_match_prefix("+"), "+");
}

#[test]
fn parse_target_agrees_with_stripped_form() {
    // The normalized raw string must parse to the same target the raw form
    // did, so window/pane routing is unchanged by the #558 normalization.
    let raw = parse_target("=sess:3.%7");
    let stripped = parse_target(strip_exact_match_prefix("=sess:3.%7"));
    assert_eq!(raw.window, stripped.window);
    assert_eq!(raw.window_is_id, stripped.window_is_id);
    assert_eq!(raw.pane, stripped.pane);
    assert_eq!(raw.pane_is_id, stripped.pane_is_id);
}
