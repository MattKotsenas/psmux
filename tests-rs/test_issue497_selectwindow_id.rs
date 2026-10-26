// Issue #497: select-window -t session:@id rejected client-side and, once past
// the CLI check, resolved as a window INDEX by the server's select-window
// handler. These tests pin down parse_target's @id handling for every target
// shape the fix touches, including the @id.pane suffix forms.

use super::*;

#[test]
fn issue497_session_qualified_window_id() {
    let pt = parse_target("repro:@2");
    assert_eq!(pt.session, Some("repro".to_string()));
    assert_eq!(pt.window, Some(2));
    assert!(pt.window_is_id, "@2 after session: must be an id, not an index");
    assert_eq!(pt.window_name, None);
    assert_eq!(pt.pane, None);
}

#[test]
fn issue497_exact_match_prefix_stripped() {
    let pt = parse_target("=repro:@2");
    assert_eq!(pt.session, Some("repro".to_string()));
    assert_eq!(pt.window, Some(2));
    assert!(pt.window_is_id);
}

#[test]
fn issue497_bare_window_id() {
    let pt = parse_target("@7");
    assert_eq!(pt.session, None);
    assert_eq!(pt.window, Some(7));
    assert!(pt.window_is_id);
}

#[test]
fn issue497_bare_window_id_with_pane_index() {
    let pt = parse_target("@2.0");
    assert_eq!(pt.window, Some(2));
    assert!(pt.window_is_id);
    assert_eq!(pt.pane, Some(0));
    assert!(!pt.pane_is_id);
}

#[test]
fn issue497_session_qualified_id_with_pane_index() {
    let pt = parse_target("repro:@2.1");
    assert_eq!(pt.session, Some("repro".to_string()));
    assert_eq!(pt.window, Some(2));
    assert!(pt.window_is_id);
    assert_eq!(pt.pane, Some(1));
    assert!(!pt.pane_is_id);
}

#[test]
fn issue497_session_qualified_id_with_pane_id() {
    let pt = parse_target("repro:@2.%5");
    assert_eq!(pt.window, Some(2));
    assert!(pt.window_is_id);
    assert_eq!(pt.pane, Some(5));
    assert!(pt.pane_is_id, "%5 pane suffix must be an id");
}

#[test]
fn issue497_non_numeric_id_ignored() {
    // "@abc" is not a valid window id; nothing should be inferred from it
    let pt = parse_target("repro:@abc");
    assert_eq!(pt.window, None);
    assert!(!pt.window_is_id);
}

#[test]
fn issue497_index_form_unchanged() {
    let pt = parse_target("repro:2");
    assert_eq!(pt.window, Some(2));
    assert!(!pt.window_is_id, "plain numeric window spec is an index, not an id");
}

#[test]
fn issue497_name_form_unchanged() {
    let pt = parse_target("repro:two");
    assert_eq!(pt.window, None);
    assert_eq!(pt.window_name, Some("two".to_string()));
}

#[test]
fn issue497_name_with_pane_unchanged() {
    let pt = parse_target("repro:two.1");
    assert_eq!(pt.window_name, Some("two".to_string()));
    assert_eq!(pt.pane, Some(1));
}
