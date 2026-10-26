// A one shot `psmux confirm-before -t A kill-pane` with no client attached
// leaves a prompt in the server. Scripts rely on that: they read it from
// dump-state and answer it with send-keys or confirm-respond. But the next
// client to attach was greeted by it and answered it no with the first key it
// pressed, so its own `prefix : confirm-before kill-pane`, `y` killed nothing.
// The prompt now stays for scripts while nobody is attached and is dropped
// when the first client attaches. (tmux refuses such a confirm-before with
// `no current client`, cmd-find.c:1298; psmux keeps the detached ability.)

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
fn no_attached_client_still_opens_the_prompt_for_scripts() {
    let mut a = app();
    let got = open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string());
    assert_eq!(got, Ok(()));
    assert_eq!(confirm_command(&a).as_deref(), Some("kill-pane"));
}

#[test]
fn an_attached_client_gets_the_prompt() {
    let mut a = app();
    a.register_client(1, false);
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    match &a.mode {
        Mode::ConfirmMode { prompt, command, .. } => {
            assert_eq!(command, "kill-pane");
            assert_eq!(prompt, "Confirm 'kill-pane'? (y/n)");
        }
        _ => panic!("no prompt opened"),
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
fn the_first_client_to_attach_drops_a_prompt_nobody_saw() {
    let mut a = app();
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert!(a.register_client(1, false));
    assert!(
        confirm_command(&a).is_none(),
        "BUG: the prompt opened with nobody attached greeted the client that attached"
    );
    assert!(matches!(a.mode, Mode::Passthrough));
}

#[test]
fn a_control_client_attaching_keeps_the_prompt() {
    let mut a = app();
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert!(a.register_client(7, true));
    assert_eq!(confirm_command(&a).as_deref(), Some("kill-pane"));
}

#[test]
fn a_second_client_attaching_keeps_the_prompt_the_first_one_sees() {
    let mut a = app();
    a.register_client(1, false);
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert!(a.register_client(2, false));
    assert_eq!(confirm_command(&a).as_deref(), Some("kill-pane"));
}

#[test]
fn a_prompt_left_by_its_client_stays_answerable_until_a_client_attaches() {
    let mut a = app();
    a.register_client(1, false);
    open_confirm_prompt(&mut a, &Default::default(), "kill-pane".to_string()).unwrap();
    assert!(a.reap_client(1));
    assert_eq!(
        confirm_command(&a).as_deref(),
        Some("kill-pane"),
        "a script can still answer it with send-keys or confirm-respond"
    );
    assert!(a.register_client(2, false));
    assert!(
        confirm_command(&a).is_none(),
        "BUG: the prompt of a client that left greeted the next client"
    );
}

#[test]
fn attaching_leaves_other_modes_alone() {
    let mut a = app();
    a.mode = Mode::ClockMode;
    assert!(a.register_client(1, false));
    assert!(matches!(a.mode, Mode::ClockMode));
}
