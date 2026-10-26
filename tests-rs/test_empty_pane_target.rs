// A target's empty pane part is no pane part, as tmux's cmd-find.c reads it
// ("Empty is the same as NULL"): `s:1.` is `s:1`.

use super::*;

fn canon(line: &[&str]) -> Vec<String> {
    let mut tokens: Vec<String> = line.iter().map(|s| s.to_string()).collect();
    canonicalize_target_values(&mut tokens);
    tokens
}

#[test]
fn drops_an_empty_pane_part() {
    assert_eq!(drop_empty_pane_part("s:1.").as_deref(), Some("s:1"));
    assert_eq!(drop_empty_pane_part("=s:1.").as_deref(), Some("=s:1"));
    assert_eq!(drop_empty_pane_part("s:two.").as_deref(), Some("s:two"));
    assert_eq!(drop_empty_pane_part("s:.").as_deref(), Some("s:"));
    assert_eq!(drop_empty_pane_part(":1.").as_deref(), Some(":1"));
    assert_eq!(drop_empty_pane_part(":.").as_deref(), Some(":"));
    assert_eq!(drop_empty_pane_part("@2.").as_deref(), Some("@2"));
    assert_eq!(drop_empty_pane_part("=@2.").as_deref(), Some("=@2"));
}

#[test]
fn leaves_every_other_shape_alone() {
    for t in [
        "s:1", "s:1.0", "s:1.%3", "s:", ":", ".", "s", "%3", "@2", "@2.0",
        // the period is not the last character: tmux reads `my` and `name.`
        "s:my.name.", "s:1..",
        // no colon: psmux reads these as session names, left as they were
        "my.session.", "1.",
    ] {
        assert_eq!(drop_empty_pane_part(t), None, "{t}");
    }
}

#[test]
fn rewrites_target_flag_values() {
    assert_eq!(canon(&["select-window", "-t", "s:2."]), ["select-window", "-t", "s:2"]);
    assert_eq!(
        canon(&["display-message", "-p", "-t", "=s:1.", "#{window_index}"]),
        ["display-message", "-p", "-t", "=s:1", "#{window_index}"]
    );
    // a value attached to its flag, alone or in a cluster
    assert_eq!(canon(&["select-window", "-ts:2."]), ["select-window", "-ts:2"]);
    assert_eq!(canon(&["send-keys", "-lts:1.", "x"]), ["send-keys", "-lts:1", "x"]);
}

#[test]
fn source_targets_only_where_minus_s_is_one() {
    assert_eq!(
        canon(&["join-pane", "-s", "s:src.", "-t", "s:0."]),
        ["join-pane", "-s", "s:src", "-t", "s:0"]
    );
    assert_eq!(
        canon(&["swap-window", "-s", "s:1.", "-t", "s:2."]),
        ["swap-window", "-s", "s:1", "-t", "s:2"]
    );
    // new-session -s is a session NAME
    assert_eq!(canon(&["new-session", "-d", "-s", "a:b."]), ["new-session", "-d", "-s", "a:b."]);
}

#[test]
fn operands_and_other_flag_values_are_never_touched() {
    // keys after the flags
    assert_eq!(canon(&["send-keys", "-t", "s:1.", "x:y."]), ["send-keys", "-t", "s:1", "x:y."]);
    // `--` ends the flags
    assert_eq!(
        canon(&["display-message", "--", "-t", "s:1."]),
        ["display-message", "--", "-t", "s:1."]
    );
    // a value of another flag that only looks like a target
    assert_eq!(
        canon(&["new-window", "-n", "s:1.", "-t", "s:1."]),
        ["new-window", "-n", "s:1.", "-t", "s:1"]
    );
}

#[test]
fn reports_whether_anything_changed() {
    let mut same: Vec<String> = ["select-window", "-t", "s:2"].iter().map(|s| s.to_string()).collect();
    assert!(!canonicalize_target_values(&mut same));
    let mut changed: Vec<String> = ["select-window", "-t", "s:2."].iter().map(|s| s.to_string()).collect();
    assert!(canonicalize_target_values(&mut changed));
    let mut empty: Vec<String> = Vec::new();
    assert!(!canonicalize_target_values(&mut empty));
}
