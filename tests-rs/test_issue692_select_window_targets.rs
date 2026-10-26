// Issue #692: `select-window -t 0` did nothing, while `-t :0` worked.
//
// The reproduction, three runs on each of four routes:
//
//     psmux -L h new-session -d -s s -x 80 -y 24
//     psmux -L h new-window -t s ; psmux -L h new-window -t s
//     psmux -L h select-window -t s:2
//     psmux -L h select-window -t 0
//         psmux: no server running on session 'h__0'      (rc 1, window 2 -> 2)
//
// and from a binding, the control socket and the `:` prompt the same command
// was silent: the binding was stored, the key arrived, the window did not
// change (2/@3 -> 2/@3, three runs of three on each route).
//
// The cause is one sentence in cli.rs `parse_target`: "A bare string without
// ':' or '.' is always a session name, even if numeric".  So `0` was looked up
// as a SESSION and the window number never reached the window resolver.
//
// tmux resolves a window command's -t through cmd_find_get_window
// (cmd-find.c:328).  It sets `fs->s = fs->current->s`, the CURRENT session,
// and calls cmd_find_get_window_with_session first (:344); that tries an @id
// (:382), then the offsets and symbols from cmd_find_window_table (:389,
// :418), then "First see if this is a valid window index in this session"
// (:443, `strtonum` + `winlink_find_by_index`), then a window NAME.  Only when
// all of that fails does it try the token as a session itself (:348).  The
// index wins over a session of the same name.
//
// The second half of the report, `select-window -t @1` not switching while
// `@2` and `@3` did, did NOT reproduce: a 16 case matrix (2 and 4 window
// fixtures, parking on each window in turn, selecting every id) came back OK
// on all 16, three runs, on the CLI, the socket, a binding and the prompt.
// Window ids start at @1, so in the fixture that produced the report `@1` was
// the window already active and "did not switch" is what selecting it looks
// like.  `@0` never exists and correctly exits 1 with "can't find window: @0".
// The walk from `@0` to `@3` is in tests\test_issue692_select_window_targets.ps1
// so a real regression there would be caught.

use super::*;

#[test]
fn issue692_a_bare_number_is_a_window_for_select_window() {
    // The reporter's target.  cmd-find.c:443.
    assert_eq!(coerce_bare_window_target("select-window", "0"), ":0");
    assert_eq!(coerce_bare_window_target("selectw", "0"), ":0");
    assert_eq!(coerce_bare_window_target("select-window", "12"), ":12");
}

#[test]
fn issue692_an_explicit_form_is_left_exactly_as_written() {
    // Anything that already says which part it names must survive untouched,
    // or `-t s:0` would become `-t :s:0`.
    for t in [":0", "s:0", "@1", "%4", "s:0.1", ":.+", "$2:1", "work"] {
        assert_eq!(
            coerce_bare_window_target("select-window", t), t,
            "{} is already explicit and must not be rewritten", t
        );
    }
}

#[test]
fn issue692_a_bare_name_still_means_a_session() {
    // tmux's own resolution is ambiguous here (a window NAME in the current
    // session wins in cmd-find.c, a session name is the fallback), and psmux
    // has always read a bare name as a session.  #692 is about the number.
    assert_eq!(coerce_bare_window_target("select-window", "work"), "work");
    assert_eq!(coerce_bare_window_target("select-window", "0abc"), "0abc");
    assert_eq!(coerce_bare_window_target("select-window", "my.session"), "my.session");
}

#[test]
fn issue692_only_a_window_target_command_is_coerced() {
    // `attach -t 0`, `kill-session -t 0` and `switch-client -t 0` name a
    // SESSION.  Coercing them would break every one of them.
    for cmd in ["attach-session", "attach", "kill-session", "switch-client", "new-session",
                "has-session", "rename-session", "select-pane", "kill-window", "break-pane"] {
        assert_eq!(
            coerce_bare_window_target(cmd, "0"), "0",
            "{} -t 0 is not a window target and must be left alone", cmd
        );
        assert!(!window_target_command(cmd), "{} is not a window target command", cmd);
    }
    for cmd in ["select-window", "selectw", "move-window", "movew", "swap-window", "swapw"] {
        assert!(window_target_command(cmd), "{} resolves a window target", cmd);
    }
}

#[test]
fn issue692_move_and_swap_window_keep_their_symbolic_forms() {
    // Issue #602 gave these the relative and symbolic forms, which a server
    // side resolver understands.  That must not regress.
    for t in ["+", "-", "+2", "-3", "!", "^", "$", "{end}", "{last}"] {
        assert_eq!(
            coerce_bare_window_target("move-window", t), format!(":{}", t),
            "move-window -t {} is a window spec (#602)", t
        );
        assert!(bare_target_names_a_window(t), "{} is window shaped", t);
    }
    // When #692 landed, select-window took only the plain index, because
    // nothing resolved the other forms for it and coercing them would have
    // turned a loud CLI error into a silent no-op.  Issue #693 item 4 routed
    // select-window through that same resolver on every route, so it now takes
    // the whole shape too; tmux maps the braced spellings in
    // `cmd_find_window_table` (cmd-find.c:51-58) and resolves the offsets at
    // cmd-find.c:390-417, for every window command alike.
    for t in ["+", "-", "+2", "-3", "!", "^", "$", "{end}", "{last}"] {
        assert_eq!(
            coerce_bare_window_target("select-window", t), format!(":{}", t),
            "select-window -t {} is a window spec too (#693 item 4)", t
        );
    }
}

#[test]
fn issue692_the_exact_match_marker_survives_the_coercion() {
    // `-t =0` is tmux's exact-match marker (#558).  The marker carries no
    // information for a window index, and the colon must land on the plain
    // token, not in front of the '='.
    assert_eq!(coerce_bare_window_target("select-window", "=0"), ":0");
}

#[test]
fn issue692_a_coerced_target_parses_as_the_window_it_names() {
    // End to end through the real parser: this is what the server sees.
    let pt = parse_target(&coerce_bare_window_target("select-window", "0"));
    assert_eq!(pt.window, Some(0), "a coerced bare 0 must parse as window 0");
    assert_eq!(pt.session, None, "and must not name a session any more");
    assert!(!pt.window_is_id);

    let pt3 = parse_target(&coerce_bare_window_target("select-window", "3"));
    assert_eq!(pt3.window, Some(3));

    // The pre fix reading, still what a session target command gets.
    let session = parse_target(&coerce_bare_window_target("attach-session", "0"));
    assert_eq!(session.session.as_deref(), Some("0"));
    assert_eq!(session.window, None);
}

#[test]
fn issue692_a_window_id_target_parses_for_every_id() {
    // The half of the report that did not reproduce, pinned anyway: every
    // `@N` must parse as window id N, `@0` included (it simply never exists,
    // since ids start at @1).
    for n in 0usize..8 {
        let pt = parse_target(&format!("@{}", n));
        assert_eq!(pt.window, Some(n), "@{} must parse as a window id", n);
        assert!(pt.window_is_id, "@{} must keep its id flag, never become an index", n);
    }
}
