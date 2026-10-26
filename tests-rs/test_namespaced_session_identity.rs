// Session identity under a `-L` namespace.
//
// The routed session (PSMUX_TARGET_SESSION) is the registry base `<ns>__name`
// while a typed `sess:1` target carries the short name. join-pane and
// move-pane compared the two raw strings, read one session as two, took the
// cross session path and failed with `no server for session 'sess'`.

use super::*;

#[test]
fn short_name_gains_the_namespace_prefix() {
    assert_eq!(namespaced_session_base(Some("ns"), "sess"), "ns__sess");
}

#[test]
fn registry_base_is_not_prefixed_twice() {
    assert_eq!(namespaced_session_base(Some("ns"), "ns__sess"), "ns__sess");
}

#[test]
fn default_namespace_leaves_the_name_alone() {
    assert_eq!(namespaced_session_base(None, "sess"), "sess");
    assert_eq!(namespaced_session_base(None, "ns__sess"), "ns__sess");
}

#[test]
fn routed_base_and_typed_short_name_are_one_session() {
    assert!(same_session_identity(Some("ns"), "ns__sess", "sess"));
    assert!(same_session_identity(Some("ns"), "sess", "ns__sess"));
    assert!(same_session_identity(Some("ns"), "sess", "sess"));
    assert!(same_session_identity(Some("ns"), "ns__sess", "ns__sess"));
}

#[test]
fn two_sessions_in_one_namespace_stay_distinct() {
    assert!(!same_session_identity(Some("ns"), "ns__sa", "sb"));
    assert!(!same_session_identity(Some("ns"), "sa", "ns__sb"));
    assert!(!same_session_identity(Some("ns"), "sa", "sb"));
}

#[test]
fn another_namespace_is_a_different_session() {
    // `other__sess` is a short name inside `ns`, so it becomes
    // `ns__other__sess`, never the routed `ns__sess`.
    assert!(!same_session_identity(Some("ns"), "ns__sess", "other__sess"));
}

#[test]
fn without_a_namespace_comparison_is_exact() {
    assert!(same_session_identity(None, "sess", "sess"));
    assert!(!same_session_identity(None, "sa", "sb"));
}

#[test]
fn a_session_named_like_the_namespace_is_not_confused() {
    // A short name that merely starts with the namespace text is still a
    // short name: only the `<ns>__` separator marks a registry base.
    assert_eq!(namespaced_session_base(Some("ns"), "nsx"), "ns__nsx");
    assert!(!same_session_identity(Some("ns"), "ns__nsx", "ns"));
}
