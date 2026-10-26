// Issue #730: `-S <path>` maps onto a namespace, and `#{socket_path}` names the
// server that answered. Pure functions only: nothing here reads the process
// environment or starts a server.
use super::*;

const DIR: &str = r"C:\Users\someone\.psmux";

#[test]
fn foreign_path_maps_to_a_hashed_namespace() {
    let ns = namespace_for_socket_path(r"C:\Temp\probe.sock", DIR).unwrap().unwrap();
    assert!(is_hashed_namespace(&ns), "{ns}");
    assert!(!ns.contains("__"), "a namespace may not contain the session separator: {ns}");
}

#[test]
fn every_spelling_of_one_path_reaches_one_namespace() {
    let a = namespace_for_socket_path(r"C:\Temp\probe.sock", DIR).unwrap();
    let b = namespace_for_socket_path("c:/temp/PROBE.sock", DIR).unwrap();
    let c = namespace_for_socket_path(r"C:\Temp\sub\..\probe.sock", DIR).unwrap();
    assert_eq!(a, b);
    assert_eq!(a, c);
}

#[test]
fn different_paths_never_share_a_namespace() {
    let a = namespace_for_socket_path(r"C:\Temp\one.sock", DIR).unwrap();
    let b = namespace_for_socket_path(r"C:\Temp\two.sock", DIR).unwrap();
    let c = namespace_for_socket_path(r"D:\Temp\one.sock", DIR).unwrap();
    assert_ne!(a, b);
    assert_ne!(a, c);
    assert_ne!(b, c);
}

#[test]
fn hash_is_fixed_across_builds() {
    // FNV-1a 64 of "c:\\temp\\probe.sock", checked against an independent Python FNV-1a. If this changes, servers started by
    // an older psmux under `-S` become unreachable from a newer client.
    assert_eq!(hashed_namespace(r"C:\Temp\probe.sock"), "sock-8d550438e15bb506");
}

#[test]
fn data_dir_paths_select_the_label_like_dash_l() {
    assert_eq!(namespace_for_socket_path(&format!("{DIR}/default"), DIR).unwrap(), None);
    assert_eq!(namespace_for_socket_path(&format!(r"{DIR}\default"), DIR).unwrap(), None);
    assert_eq!(
        namespace_for_socket_path(&format!("{DIR}/work"), DIR).unwrap().as_deref(),
        Some("work")
    );
    // The label keeps its spelling: -L names are case sensitive prefixes.
    assert_eq!(
        namespace_for_socket_path(r"c:\users\SOMEONE\.psmux\MyNs", DIR).unwrap().as_deref(),
        Some("MyNs")
    );
}

#[test]
fn legacy_tmux_env_first_field_selects_its_label() {
    assert_eq!(namespace_for_socket_path("/tmp/psmux-1234/default", DIR).unwrap(), None);
    assert_eq!(
        namespace_for_socket_path("/tmp/psmux-1234/omc", DIR).unwrap().as_deref(),
        Some("omc")
    );
}

#[test]
fn empty_path_is_refused_not_defaulted() {
    assert!(namespace_for_socket_path("", DIR).is_err());
    assert!(namespace_for_socket_path("   ", DIR).is_err());
}

#[test]
fn socket_path_reports_the_server_that_answered() {
    assert_eq!(socket_path_for(None, DIR, None), format!("{DIR}/default"));
    assert_eq!(socket_path_for(Some("omc"), DIR, None), format!("{DIR}/omc"));
    let p = r"C:\Temp\probe.sock";
    let ns = hashed_namespace(p);
    assert_eq!(socket_path_for(Some(&ns), DIR, Some(p)), p);
}

#[test]
fn socket_path_ignores_a_recorded_path_of_another_namespace() {
    let ns = hashed_namespace(r"C:\Temp\one.sock");
    assert_eq!(
        socket_path_for(Some(&ns), DIR, Some(r"C:\Temp\two.sock")),
        format!("{DIR}/{ns}")
    );
    // A -L server never reports a -S path, whatever the environment holds.
    assert_eq!(socket_path_for(Some("omc"), DIR, Some(r"C:\Temp\one.sock")), format!("{DIR}/omc"));
}

#[test]
fn every_reported_path_round_trips_through_dash_s() {
    let p = r"C:\Temp\probe.sock";
    let hashed = hashed_namespace(p);
    for ns in [None, Some("omc"), Some(hashed.as_str())] {
        let shown = socket_path_for(ns, DIR, Some(p));
        assert_eq!(namespace_for_socket_path(&shown, DIR).unwrap().as_deref(), ns, "{shown}");
        let tmux = tmux_env_path_for(ns, 4242, Some(p));
        assert_eq!(namespace_for_socket_path(&tmux, DIR).unwrap().as_deref(), ns, "{tmux}");
    }
}

#[test]
fn tmux_env_first_field() {
    assert_eq!(tmux_env_path_for(None, 7, None), "/tmp/psmux-7/default");
    assert_eq!(tmux_env_path_for(Some("omc"), 7, None), "/tmp/psmux-7/omc");
    let p = r"C:\Temp\probe.sock";
    assert_eq!(tmux_env_path_for(Some(&hashed_namespace(p)), 7, Some(p)), p);
}
