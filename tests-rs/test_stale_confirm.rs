// A one shot `psmux confirm-before -t A kill-pane` with no client attached
// returned rc 0 and left a ConfirmMode in the server that no client drew. The
// next client to attach was greeted by it and answered it no with the first
// key it pressed, so its own `prefix : confirm-before kill-pane`, `y` killed
// nothing. tmux resolves the target client first (cmd-queue.c:604) and fails
// with `no current client` (cmd-find.c:1298) before any prompt exists, and a
// prompt goes with its client (status_prompt_set is per client).

use super::*;
use crate::types::{AppState, Mode};

fn app() -> AppState {
    AppState::new("A".to_string())
}

fn confirm_command(app: &AppState) -> Option<String> {
    match &app.mode {
        Mode::ConfirmMode { command, .. } => Some(command.clone()),
        _ => None,
    }
}

#[test]
fn no_attached_client_is_refused_and_opens_nothing() {
    let mut a = app();
    let got = open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string());
    assert_eq!(got, Err("no current client".to_string()));
    assert!(confirm_command(&a).is_none(), "BUG: a prompt nobody draws was opened");
    assert!(matches!(a.mode, Mode::Passthrough));
}

#[test]
fn a_control_client_alone_is_no_client_to_prompt() {
    let mut a = app();
    a.register_client(7, true);
    let got = open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string());
    assert_eq!(got, Err("no current client".to_string()));
    assert!(confirm_command(&a).is_none());
}

#[test]
fn an_attached_client_gets_the_prompt() {
    let mut a = app();
    a.register_client(1, false);
    let got = open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string());
    assert_eq!(got, Ok(()));
    assert_eq!(confirm_command(&a).as_deref(), Some("kill-pane"));
    match &a.mode {
        Mode::ConfirmMode { prompt, .. } => assert_eq!(prompt, "Confirm 'kill-pane'? (y/n)"),
        _ => unreachable!(),
    }
}

#[test]
fn a_newer_prompt_replaces_the_one_showing() {
    let mut a = app();
    a.register_client(1, false);
    open_confirm_prompt(&mut a, &Default::default(), "kill-window".to_string()).unwrap();
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert_eq!(confirm_command(&a).as_deref(), Some("kill-pane"));
}

#[test]
fn the_prompt_goes_with_the_last_client_that_could_answer_it() {
    let mut a = app();
    a.register_client(1, false);
    a.register_client(2, false);
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert!(a.reap_client(1));
    assert!(confirm_command(&a).is_some(), "another client can still answer it");
    a.register_client(9, true);
    assert!(a.reap_client(2));
    assert!(
        confirm_command(&a).is_none(),
        "BUG: the prompt outlived every client that could answer it"
    );
    assert!(matches!(a.mode, Mode::Passthrough));
}

#[test]
fn reaping_a_client_leaves_other_modes_alone() {
    let mut a = app();
    a.register_client(1, false);
    a.mode = Mode::ClockMode;
    assert!(a.reap_client(1));
    assert!(matches!(a.mode, Mode::ClockMode));
}
