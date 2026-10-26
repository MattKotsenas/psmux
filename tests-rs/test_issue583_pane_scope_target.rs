// Regression pins for the #583 arm-6 regression: set-option kept its -t in
// the argument list for the shared parser (PR #628), so the pane-scope arms
// began forwarding rich targets like "session:win.pane" to SetPaneOption,
// whose resolver understands only bare ids. pane_scope_target collapses
// anything the resolver cannot parse to "" (the active pane), which the
// validated FocusTargetTemp issued before dispatch has already pointed at the
// requested pane.
use super::*;

#[test]
fn bare_pane_ids_pass_through() {
    assert_eq!(pane_scope_target("%3".to_string()), "%3");
    assert_eq!(pane_scope_target("7".to_string()), "7");
    assert_eq!(pane_scope_target(" %12 ".to_string()), " %12 ");
    assert_eq!(pane_scope_target(String::new()), "");
}

#[test]
fn rich_targets_collapse_to_active_pane() {
    // The temp focus has already resolved and validated these; the arm must
    // not hand them to the bare-id parser and report the pane as missing.
    assert_eq!(pane_scope_target("chk:0.0".to_string()), "");
    assert_eq!(pane_scope_target("sess:1.2".to_string()), "");
    assert_eq!(pane_scope_target("0.0".to_string()), "");
    assert_eq!(pane_scope_target("mywin.1".to_string()), "");
    assert_eq!(pane_scope_target("{last}".to_string()), "");
}
