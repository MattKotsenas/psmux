// Issue #691: the hook table promised hooks that never fired, and one command
// fired the wrong hook.
//
// The reproduction is a hook body that makes a buffer and a buffer count,
// because `set-buffer` with no `-b` makes a NEW buffer every run:
//
//     psmux -L h new-session -d -s s -x 80 -y 24
//     psmux -L h split-window -d -t s:0
//     psmux -L h select-pane -t s:0.0
//     psmux -L h set-hook -g after-select-pane "set-buffer HOOKFIRED"
//     psmux -L h select-pane -t s:0.1
//     psmux -L h list-buffers          <- EMPTY, three runs of three
//
// and the same fixture with `after-select-window` on the hook counted ONE,
// for a command tmux never gives that hook.  The pane really moved: the
// `(active)` marker in list-panes went 0 -> 1 every time.
//
// The carrier was the generic `-t` focus block in connection.rs.  For a focus
// command it sent a permanent `FocusWindow` for the window part of the target
// and a `FocusPane`/`FocusPaneByIndex` for the pane part.  `FocusWindow` names
// `after-select-window` in its hook slot; the pane requests name nothing.  So
// `select-pane -t s:0.1` fired the window hook and never its own.
//
// tmux fires the command's own hook, once: cmd-select-pane.c:276
// `cmdq_insert_hook(s, item, current, "after-select-pane")`, reached only
// through the activation at :274, which line :269 skips when the target pane
// is already active (`if (wp == w->active) return`).  `-m`/`-M` return at
// :100, `-e`/`-d` and `-l` at :164-:190, `-T`/`-P` at :247, so none of those
// forms fires it at all.  The general rule is cmd-queue.c:635:
// `cmdq_insert_hook(fsp->s, item, fsp, "after-%s", entry->name)`, once per
// command, with the command's OWN name.
//
// These tests pin the decision the fix put in one function, the #690 shape:
// a `select-pane` emits exactly ONE request for its whole `-t`, and that
// request knows whether it owes the hook.  The end to end counts, every hook
// in the docs table on every route, live in tests\test_issue691_hook_table.ps1.

use super::*;

fn reqs(args: &[&str], raw: Option<&str>, win: Option<usize>, is_id: bool,
        name: Option<&str>, pane: Option<usize>, pane_is_id: bool) -> Vec<CtrlReq> {
    select_pane_requests(args, raw, win, is_id, name, pane, pane_is_id)
}

#[test]
fn issue691_pane_target_emits_one_request() {
    // `select-pane -t s:0.1`, the reporter's command.  The outer -t is gone by
    // the time the arm sees the args, so window 0 / pane 1 is what it gets.
    let r = reqs(&[], Some("s:0.1"), Some(0), false, None, Some(1), false);
    assert_eq!(r.len(), 1, "one select-pane must emit one request, not a window focus plus a pane focus");
    match &r[0] {
        CtrlReq::SelectPaneTarget { win, pane, fire_hook, .. } => {
            assert_eq!(*win, Some(0));
            assert_eq!(*pane, Some(1));
            assert!(*fire_hook, "a plain -t select-pane owes after-select-pane (cmd-select-pane.c:276)");
        }
        other => panic!("expected SelectPaneTarget, got {:?}", std::mem::discriminant(other)),
    }
}

#[test]
fn issue691_pane_target_never_focuses_the_window_on_its_own() {
    // This is the bug: a FocusWindow for the window part of a PANE target,
    // which names after-select-window.  No form may produce one.
    for (args, raw, win, pane) in [
        (&[][..], Some("s:0.1"), Some(0usize), Some(1usize)),
        (&[][..], Some("s:2.0"), Some(2), Some(0)),
        (&["-Z"][..], Some("s:1.3"), Some(1), Some(3)),
    ] {
        let r = reqs(args, raw, win, false, None, pane, false);
        assert!(
            !r.iter().any(|q| matches!(q,
                CtrlReq::FocusWindow(_) | CtrlReq::FocusWindowById(_) | CtrlReq::FocusWindowByName(_))),
            "select-pane -t {:?} sent a window focus, which fires after-select-window (#691)", raw
        );
    }
}

#[test]
fn issue691_a_window_only_target_still_emits_one_request() {
    // `select-pane -t s:1` has no pane part.  tmux still resolves it (the
    // window's active pane) and still runs one command.
    let r = reqs(&[], Some("s:1"), Some(1), false, None, None, false);
    assert_eq!(r.len(), 1);
    assert!(matches!(&r[0], CtrlReq::SelectPaneTarget { win: Some(1), pane: None, .. }));
}

#[test]
fn issue691_an_id_target_stays_an_id() {
    // `select-pane -t %4` and `select-pane -t @2.%4`: an id must never be
    // re-sent as an index (the #545/#497 rule).
    let by_pane = reqs(&[], Some("%4"), None, false, None, Some(4), true);
    assert!(matches!(&by_pane[0], CtrlReq::SelectPaneTarget { pane: Some(4), pane_is_id: true, .. }));
    let by_both = reqs(&[], Some("@2.%4"), Some(2), true, None, Some(4), true);
    assert!(matches!(&by_both[0],
        CtrlReq::SelectPaneTarget { win: Some(2), win_is_id: true, pane: Some(4), pane_is_id: true, .. }));
}

#[test]
fn issue691_a_window_name_target_is_carried_as_a_name() {
    let r = reqs(&[], Some("s:logs.1"), None, false, Some("logs"), Some(1), false);
    assert_eq!(r.len(), 1);
    match &r[0] {
        CtrlReq::SelectPaneTarget { win, win_name, pane, .. } => {
            assert_eq!(*win, None);
            assert_eq!(win_name.as_deref(), Some("logs"));
            assert_eq!(*pane, Some(1));
        }
        _ => panic!("expected SelectPaneTarget"),
    }
}

#[test]
fn issue691_no_target_emits_nothing() {
    // `select-pane -U` carries its whole operation in CtrlReq::SelectPane; the
    // -t path must stay quiet or the command would send two requests.
    assert!(reqs(&["-U"], None, None, false, None, None, false).is_empty());
    assert!(reqs(&[], None, None, false, None, None, false).is_empty());
}

#[test]
fn issue691_a_command_with_its_own_operation_does_not_also_owe_the_hook() {
    // One command fires its after hook ONCE (#690, cmd-queue.c:635).  When a
    // direction or -l/-m/-M/-e/-d follows, CtrlReq::SelectPane performs the
    // operation and fires the hook, so the -t request must not.
    for flag in ["-U", "-D", "-L", "-R", "-l", "-m", "-M", "-e", "-d"] {
        let r = reqs(&[flag], Some("s:0.1"), Some(0), false, None, Some(1), false);
        assert_eq!(r.len(), 1, "{} still emits one -t request", flag);
        match &r[0] {
            CtrlReq::SelectPaneTarget { fire_hook, .. } => assert!(
                !*fire_hook,
                "select-pane {} -t would have fired after-select-pane twice", flag
            ),
            _ => panic!("expected SelectPaneTarget"),
        }
    }
}

#[test]
fn issue691_a_relative_pane_target_leaves_the_hook_to_select_pane() {
    // `-t :.+` and `-t :.-` are the whole operation too (CtrlReq::SelectPane
    // "next"/"prev"), so the -t request owes nothing.
    for raw in [":.+", ":.-", "s:0.+", "+", "-"] {
        assert!(
            select_pane_has_own_operation(&[], Some(raw)),
            "{} is a relative pane move, which CtrlReq::SelectPane performs", raw
        );
    }
    // A plain index is NOT relative, however it is spelled.
    for raw in ["s:0.1", ":.1", "%4", "s:1"] {
        assert!(
            !select_pane_has_own_operation(&[], Some(raw)),
            "{} is a plain target, so the -t request owes the hook", raw
        );
    }
}

#[test]
fn issue691_every_shape_emits_at_most_one_request() {
    // The sweep #690 added for select-window, for select-pane: no combination
    // of flags and target parts may produce two requests from the -t path.
    let flag_sets: [&[&str]; 6] = [&[], &["-Z"], &["-U"], &["-l"], &["-m"], &["-U", "-Z"]];
    let targets: [(Option<usize>, bool, Option<&str>, Option<usize>, bool); 6] = [
        (Some(0), false, None, Some(1), false),
        (Some(2), true, None, Some(4), true),
        (None, false, Some("logs"), Some(0), false),
        (Some(1), false, None, None, false),
        (None, false, None, Some(3), false),
        (None, false, None, None, false),
    ];
    for args in flag_sets {
        for (win, is_id, name, pane, pane_is_id) in targets {
            let r = reqs(args, None, win, is_id, name, pane, pane_is_id);
            assert!(r.len() <= 1, "args {:?} target {:?} emitted {} requests", args, win, r.len());
        }
    }
}
