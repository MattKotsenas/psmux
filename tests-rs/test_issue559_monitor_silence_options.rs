// Issue #559: monitor-silence was invisible to every option-inspection path
// even though the value was stored:
//   - absent from the full `show-options -g` dump (looked "silently dropped")
//   - not classified as a window option, so `show-options -w monitor-silence`
//     returned an empty value even after a successful set (tmux: window scope)
// These tests pin the option plumbing; the live show-options output is covered
// by tests/test_issue559_family.ps1.

use super::*;

fn mock_app() -> AppState {
    AppState::new("silence559opt".to_string())
}

#[test]
fn apply_set_option_stores_monitor_silence() {
    let mut app = mock_app();
    apply_set_option(&mut app, "monitor-silence", "10", false);
    assert_eq!(app.monitor_silence, 10, "set-option must store the interval");
}

#[test]
fn get_option_value_round_trips() {
    let mut app = mock_app();
    apply_set_option(&mut app, "monitor-silence", "42", false);
    assert_eq!(
        get_option_value(&app, "monitor-silence"),
        "42",
        "show-options -v monitor-silence must report the stored value"
    );
}

#[test]
fn monitor_silence_is_a_window_option() {
    // tmux classifies monitor-silence as a window option; before #559 psmux
    // did not, so the -w query path returned an empty string.
    assert!(is_window_option("monitor-silence"));
}

#[test]
fn window_scoped_query_returns_value() {
    let mut app = mock_app();
    apply_set_option(&mut app, "monitor-silence", "7", false);
    assert_eq!(
        get_window_option_value(&app, "monitor-silence"),
        "7",
        "show-options -w monitor-silence must return the effective value, not empty"
    );
}

#[test]
fn render_window_options_lists_monitor_silence() {
    let mut app = mock_app();
    apply_set_option(&mut app, "monitor-silence", "15", false);
    let dump = render_window_options(&app);
    assert!(
        dump.lines().any(|l| l.trim() == "monitor-silence 15"),
        "full -w dump must include monitor-silence, got:\n{}",
        dump
    );
}
