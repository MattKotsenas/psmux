// `psmux command-prompt` run from the command line, or from a hook, opens its
// prompt on an attached client (#789 follow up).
//
// The command line kept only -I and opened a prompt in the server that no
// client drew; -p, the template, -k, -1, -N, -T, -F and -b were dropped on the
// way. tmux opens the prompt on the target client (status_prompt_set,
// cmd-command-prompt.c:170): -t names it, else the best client. Without -b the
// command waits until the prompt closes (:174). A client that has a prompt
// already ignores a new one (:93). Measured in tmux 3.4 from a plain shell
// against a session with one attached client:
//   -b -p name 'rename-window %%', TEST Enter     window TEST
//   -b 'rename-window %%'                          label (rename-window)
//   -b (no template)                               label :, the line runs
//   -I init -p name 'rename-window %%', Enter      window init
//   -p a,b 'rename-window %1-%2', x Enter y Enter  window x-y
//   -k Left / -1 z / -N 1 2 a                      Left / Oz / N12
//   -F "set -g @k '#{session_name}-%%'", q Enter   <session>-q
//   -T search, HIST Enter, then -T search, Up      HIST
//   no -b                                          returns when answered, rc 0
//   a second prompt while one is open              the first stays
//   -t /nonexistent                                rc 1
//   no client attached                             "no current client", rc 1
//
// Registered from src/server/helpers.rs.

use crate::server::helpers::{best_prompt_client, request_client_prompt, PromptRequestOutcome};
use crate::types::AppState;

fn app_with_clients(pids: &[u32]) -> AppState {
    let mut app = AppState::new("cps".to_string());
    for (n, pid) in pids.iter().enumerate() {
        let cid = n as u64 + 1;
        assert!(app.register_client_with_pid(cid, false, Some(*pid)));
    }
    app
}

fn queued(app: &mut AppState, args: &str) -> crate::types::PromptRequest {
    match request_client_prompt(app, args) {
        Ok(PromptRequestOutcome::Queued(id)) => {
            let req = app.prompt_request.clone().expect("a queued request is pending");
            assert_eq!(req.id, id);
            req
        }
        other => panic!("{args:?} was not queued: {other:?}"),
    }
}

// ───────────────────────── the shared parse ─────────────────────────

#[test]
fn every_flag_reaches_the_parse() {
    let s = crate::client::parse_command_prompt_args("-b -N -F -T search -t /dev/pts/7 -p n \"rename-window %%\"");
    assert!(s.background && s.numeric && s.format && s.search);
    assert_eq!(s.target.as_deref(), Some("/dev/pts/7"));
    assert_eq!(s.prompt_type.as_deref(), Some("search"));
    assert_eq!(s.label.as_deref(), Some("n"));
    assert_eq!(s.template.as_deref(), Some("rename-window %%"));
}

#[test]
fn p_and_i_split_on_commas_unless_l() {
    let s = crate::client::parse_command_prompt_args("-p a,b -I x,y \"rename-window %1-%2\"");
    assert_eq!(s.prompts(), vec![(Some("a".into()), "x".into()), (Some("b".into()), "y".into())]);
    let s = crate::client::parse_command_prompt_args("-p a,b -I x \"rename-window %1-%2\"");
    assert_eq!(s.prompts(), vec![(Some("a".into()), "x".into()), (Some("b".into()), String::new())]);
    let s = crate::client::parse_command_prompt_args("-l -p a,b -I x,y \"rename-window %%\"");
    assert_eq!(s.prompts(), vec![(Some("a,b".into()), "x,y".into())]);
}

// ───────────────────────── which client ─────────────────────────

#[test]
fn no_client_is_no_current_client() {
    let mut app = app_with_clients(&[]);
    assert_eq!(request_client_prompt(&mut app, "-p x \"rename-window %%\""), Err("no current client".to_string()));
    assert!(app.prompt_request.is_none());
}

#[test]
fn the_most_recently_active_client_gets_it() {
    let mut app = app_with_clients(&[100, 200]);
    let now = std::time::Instant::now();
    app.client_registry.get_mut(&1).unwrap().last_activity = now;
    app.client_registry.get_mut(&2).unwrap().last_activity = now - std::time::Duration::from_secs(5);
    assert_eq!(best_prompt_client(&app), Some(1));
    let req = queued(&mut app, "-p x \"rename-window %%\"");
    assert_eq!((req.client_id, req.pid), (1, 100));
}

#[test]
fn a_control_mode_client_has_no_screen_for_it() {
    let mut app = AppState::new("cps".to_string());
    assert!(app.register_client_with_pid(1, true, Some(100)));
    assert_eq!(request_client_prompt(&mut app, "-p x \"rename-window %%\""), Err("no current client".to_string()));
}

#[test]
fn t_names_the_client() {
    let mut app = app_with_clients(&[100, 200]);
    let req = queued(&mut app, "-t /dev/pts/200 -p x \"rename-window %%\"");
    assert_eq!((req.client_id, req.pid), (2, 200));
    app.finish_prompt_request(req.id);
    let req = queued(&mut app, "-t %100 -p x \"rename-window %%\"");
    assert_eq!(req.pid, 100);
    app.finish_prompt_request(req.id);
    assert_eq!(
        request_client_prompt(&mut app, "-t /dev/pts/999 -p x \"rename-window %%\""),
        Err("can't find client: /dev/pts/999".to_string())
    );
}

#[test]
fn a_second_prompt_for_the_same_client_is_dropped() {
    let mut app = app_with_clients(&[100]);
    let first = queued(&mut app, "-p first \"rename-window F%%\"");
    assert_eq!(request_client_prompt(&mut app, "-p second \"rename-window S%%\""), Ok(PromptRequestOutcome::Ignored));
    assert_eq!(app.prompt_request.as_ref().map(|r| r.id), Some(first.id));
}

#[test]
fn an_unknown_type_is_refused() {
    let mut app = app_with_clients(&[100]);
    assert_eq!(request_client_prompt(&mut app, "-T nope \"rename-window %%\""), Err("unknown type: nope".to_string()));
    for t in ["command", "search", "target", "window-target"] {
        let req = queued(&mut app, &format!("-T {t} \"rename-window %%\""));
        assert_eq!(req.search, t == "search");
        app.finish_prompt_request(req.id);
    }
}

// ───────────────────────── what the client is told ─────────────────────────

#[test]
fn labels_inputs_template_and_flags_travel() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-p a,b -I x,y \"rename-window %1-%2\"");
    assert_eq!(req.prompts, vec![(Some("a".into()), "x".into()), (Some("b".into()), "y".into())]);
    assert_eq!(req.template.as_deref(), Some("rename-window %1-%2"));
    assert!(!req.key && !req.single && !req.numeric && !req.search);
}

#[test]
fn single_beats_numeric_beats_key() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-1 -N -k \"x %%\"");
    assert!(req.single && !req.numeric && !req.key);
    app.finish_prompt_request(req.id);
    let req = queued(&mut app, "-N -k \"x %%\"");
    assert!(!req.single && req.numeric && !req.key);
    app.finish_prompt_request(req.id);
    let req = queued(&mut app, "-k \"x %%\"");
    assert!(!req.single && !req.numeric && req.key);
}

#[test]
fn f_expands_the_template_and_keeps_the_placeholder() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-F -p f \"set -g @k '#{session_name}-%%'\"");
    assert_eq!(req.template.as_deref(), Some("set -g @k 'cps-%%'"));
    app.finish_prompt_request(req.id);
    // Without -F the template is left alone (tmux 3.4: `#{session_name}-q`).
    let req = queued(&mut app, "-p f \"set -g @k '#{session_name}-%%'\"");
    assert_eq!(req.template.as_deref(), Some("set -g @k '#{session_name}-%%'"));
}

#[test]
fn i_is_expanded_as_a_format() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-I '#{session_name}' -p n \"rename-window %%\"");
    assert_eq!(req.prompts, vec![(Some("n".into()), "cps".into())]);
}

#[test]
fn the_wire_form_round_trips_without_the_connection_id() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-k -p key \"set -g @k '%%'\"");
    let json = serde_json::to_string(&req).unwrap();
    assert!(!json.contains("client_id"), "{json}");
    let back: crate::types::PromptRequest = serde_json::from_str(&json).unwrap();
    assert_eq!(back.id, req.id);
    assert_eq!(back.pid, 100);
    assert!(back.key);
    assert_eq!(back.prompts, req.prompts);
}

// ───────────────────────── waiting ─────────────────────────

#[test]
fn prompt_done_releases_the_waiting_command_line() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-p w \"rename-window %%\"");
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    app.prompt_waiters.push((req.id, tx));
    assert!(rx.try_recv().is_err(), "nothing until the prompt closes");
    app.finish_prompt_request(req.id);
    assert_eq!(rx.try_recv(), Ok(String::new()));
    assert!(app.prompt_request.is_none());
    assert!(app.prompt_waiters.is_empty());
}

#[test]
fn a_client_that_goes_away_releases_it_too() {
    let mut app = app_with_clients(&[100]);
    let req = queued(&mut app, "-p w \"rename-window %%\"");
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    app.prompt_waiters.push((req.id, tx));
    assert!(app.reap_client(req.client_id));
    assert_eq!(rx.try_recv(), Ok(String::new()));
    assert!(app.prompt_request.is_none());
}

#[test]
fn a_stale_done_leaves_a_newer_request_alone() {
    let mut app = app_with_clients(&[100]);
    let first = queued(&mut app, "-p a \"x %%\"");
    app.finish_prompt_request(first.id);
    let second = queued(&mut app, "-p b \"x %%\"");
    app.finish_prompt_request(first.id);
    assert_eq!(app.prompt_request.as_ref().map(|r| r.id), Some(second.id));
}

// ───────────────────────── a hook, a server side binding ─────────────────────────

#[test]
fn the_in_process_route_asks_the_client() {
    let mut app = app_with_clients(&[100]);
    crate::commands::execute_command_string(&mut app, "command-prompt -p hk \"rename-window %%\"").unwrap();
    let req = app.prompt_request.clone().expect("the client is asked");
    assert_eq!(req.prompts, vec![(Some("hk".into()), String::new())]);
    assert!(!matches!(app.mode, crate::types::Mode::CommandPrompt { .. }), "no prompt in the server");
}

#[test]
fn with_nobody_attached_the_server_prompt_stays() {
    let mut app = app_with_clients(&[]);
    crate::commands::execute_command_string(&mut app, "command-prompt -I abc").unwrap();
    assert!(matches!(app.mode, crate::types::Mode::CommandPrompt { ref input, .. } if input == "abc"));
}

// ───────────────────────── substitution, as tmux ─────────────────────────

#[test]
fn the_client_substitutes_like_tmux() {
    use crate::copy_prompt::final_command_tmux;
    assert_eq!(final_command_tmux(Some("rename-window %1-%2"), &["x".into(), "y".into()]), "rename-window x-y");
    // A typed ' inside '%%' is put in raw, as tmux does: the parser then
    // drops it, `its` (the copy mode prompt escapes it on purpose).
    assert_eq!(final_command_tmux(Some("rename-window '%%'"), &["it's".into()]), "rename-window 'it's'");
    // Only the first %% (cmd.c:861).
    assert_eq!(final_command_tmux(Some("a %% b %%"), &["x".into()]), "a x b %%");
    // %%% is the double quoted spelling.
    assert_eq!(final_command_tmux(Some("x \"%%%\""), &["a\"b".into()]), "x \"a\\\"b\"");
}
