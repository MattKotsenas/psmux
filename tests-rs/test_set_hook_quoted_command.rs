// `set-hook -g name 'cmd args'` on the control mode and raw TCP routes kept
// the quotes around its one command argument, so the hook ran a command
// literally named `cmd args` and did nothing. tmux takes that argument as
// the command string. Registered from src/server/connection.rs.

use super::*;

fn stored(args: &[&str]) -> Option<(String, String, bool)> {
    match set_hook_request(args)? {
        CtrlReq::SetHook(n, c) => Some((n, c, false)),
        CtrlReq::AppendHook(n, c) => Some((n, c, true)),
        CtrlReq::RemoveHook(n) => Some((n, String::new(), false)),
        _ => None,
    }
}

#[test]
fn one_argument_is_the_command_string() {
    assert_eq!(stored(&["-g", "after-split-window", "new-window -d -n x"]),
        Some(("after-split-window".into(), "new-window -d -n x".into(), false)));
    assert_eq!(stored(&["-g", "h", "rename-window 'two words'"]),
        Some(("h".into(), "rename-window 'two words'".into(), false)));
}

#[test]
fn several_words_are_requoted() {
    let (_, c, _) = stored(&["-g", "h", "new-window", "-n", "a b"]).unwrap();
    assert_eq!(parse_command_line(&c), vec!["new-window", "-n", "a b"]);
}

#[test]
fn flags_only_before_the_name() {
    assert_eq!(stored(&["-ga", "h", "x"]), Some(("h".into(), "x".into(), true)));
    assert!(matches!(set_hook_request(&["-gu", "h"]), Some(CtrlReq::RemoveHook(n)) if n == "h"));
    // A dash token after the name is part of the command (#583).
    assert_eq!(stored(&["-g", "h", "-u"]), Some(("h".into(), "-u".into(), false)));
    assert_eq!(stored(&["-g", "-t", "%1", "h", "cmd"]), Some(("h".into(), "cmd".into(), false)));
    assert!(set_hook_request(&["-g", "h"]).is_none());
}
