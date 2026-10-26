// Issue #627: an unqualified `%N` / `@N` target answered for the WRONG session.
//
// psmux runs one server per session and each allocates pane and window ids from
// its own counter, so `%1` and `@1` exist in every session simultaneously. The
// client used to route an unqualified id by recency alone:
//
//   * `-t %3`, owned only by session `alpha`, was sent to whichever session was
//     created last, and `format::expand_format_for_pane_by_id` silently fell
//     back to that session's ACTIVE pane, so `display-message -p` printed
//     `beta/@1/%1` at exit 0.
//   * `-t @2` had no client-side arm at all, so it reached the same wrong
//     session and its `ERROR: can't find window: @2` reply was printed as
//     ordinary stdout at exit 0.
//
// These cover the pure pieces of the fix. The routing and exit-code behaviour
// itself needs several live servers and is pinned end to end by
// tests/test_issue627_unqualified_targets.ps1.

use super::{cli_display_session_name, split_bare_window_id};

#[test]
fn bare_window_id_splits_into_window_and_pane() {
    assert_eq!(split_bare_window_id("@2"), Some(("@2", None)));
    assert_eq!(split_bare_window_id("@2.0"), Some(("@2", Some("0"))));
    assert_eq!(split_bare_window_id("@2.%3"), Some(("@2", Some("%3"))));
    assert_eq!(split_bare_window_id("@0"), Some(("@0", None)));
    assert_eq!(split_bare_window_id("@12345"), Some(("@12345", None)));
}

#[test]
fn a_trailing_dot_is_not_a_pane_component() {
    // "@2." carries no pane token; validating an empty string as a pane id
    // would be a guaranteed false negative.
    assert_eq!(split_bare_window_id("@2."), Some(("@2", None)));
}

#[test]
fn malformed_at_targets_are_not_window_ids() {
    // parse_target ignores every one of these as a window id, so the validator
    // must not claim them either.
    assert_eq!(split_bare_window_id("@"), None);
    assert_eq!(split_bare_window_id("@dev"), None);
    assert_eq!(split_bare_window_id("@2x"), None);
    assert_eq!(split_bare_window_id("@-1"), None);
    assert_eq!(split_bare_window_id("@dev.5"), None);
}

#[test]
fn non_at_targets_are_left_alone() {
    // Qualified and pane targets belong to the other arms of the validator.
    assert_eq!(split_bare_window_id("%3"), None);
    assert_eq!(split_bare_window_id("alpha:@2"), None);
    assert_eq!(split_bare_window_id("alpha:@2.%3"), None);
    assert_eq!(split_bare_window_id(""), None);
    assert_eq!(split_bare_window_id("2"), None);
}

#[test]
fn ambiguity_message_names_the_session_the_user_can_type() {
    // Inside a `-L` namespace the registry base is "<ns>__<session>"; the
    // refusal must name "alpha", not "bug627__alpha", or the suggested
    // qualified form does not work when pasted back.
    assert_eq!(cli_display_session_name(Some("bug627"), "bug627__alpha"), "alpha");
    assert_eq!(cli_display_session_name(Some("bug627"), "bug627__beta"), "beta");
}

#[test]
fn display_name_is_a_no_op_outside_a_namespace() {
    assert_eq!(cli_display_session_name(None, "alpha"), "alpha");
    // A base that does not carry THIS namespace's prefix is passed through
    // untouched rather than mangled.
    assert_eq!(cli_display_session_name(Some("other"), "bug627__alpha"), "bug627__alpha");
    // A session whose own name contains the separator is not over-stripped.
    assert_eq!(cli_display_session_name(Some("ns"), "ns__a__b"), "a__b");
}
