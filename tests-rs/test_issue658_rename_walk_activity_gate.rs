// #658 follow up: the automatic rename walk runs inside the dump-state request
// handler, and the #658 idle floor makes an attached client send one request per
// second. Without an activity gate every one of those requests walked the
// process table for every window (T7 of test_perf_vs_terminals: 3.7 percent of a
// core idle against 0.78 the same morning). tmux only re-evaluates a window's
// name when the active pane changed since the last check (names.c:66,
// PANE_CHANGED) and at most once per NAME_INTERVAL. These tests pin that rule
// on the pure decision function.

use super::window_name_check_due;
use std::time::{Duration, Instant};

#[test]
fn no_output_since_last_check_is_never_due() {
    let now = Instant::now();
    let last_check = now;
    let last_output = now - Duration::from_secs(30);
    assert!(!window_name_check_due(last_output, last_check, 1000));
}

#[test]
fn output_equal_to_last_check_is_not_due() {
    // The activity stamp and the check stamp can coincide when both are taken in
    // the same request; equality counts as "already checked".
    let t = Instant::now() - Duration::from_secs(5);
    assert!(!window_name_check_due(t, t, 1000));
}

#[test]
fn output_after_last_check_and_throttle_elapsed_is_due() {
    let now = Instant::now();
    let last_check = now - Duration::from_millis(1500);
    let last_output = now - Duration::from_millis(200);
    assert!(window_name_check_due(last_output, last_check, 1000));
}

#[test]
fn output_after_last_check_but_inside_throttle_waits() {
    let now = Instant::now();
    let last_check = now - Duration::from_millis(300);
    let last_output = now - Duration::from_millis(100);
    assert!(!window_name_check_due(last_output, last_check, 1000));
}

#[test]
fn first_check_after_creation_is_due() {
    // A fresh pane carries an epoch style last_check far in the past and the
    // window's creation stamp as its last output, so the first walk happens.
    let now = Instant::now();
    let last_check = now - Duration::from_secs(3600);
    let last_output = now - Duration::from_millis(50);
    assert!(window_name_check_due(last_output, last_check, 1000));
}

#[test]
fn idle_floor_requests_do_not_re_arm_the_walk() {
    // Simulate one second of idle floor requests after a single check: the
    // output stamp never moves, so none of the later requests is due, however
    // long the throttle has been satisfied.
    let now = Instant::now();
    let last_output = now - Duration::from_secs(10);
    let last_check = now - Duration::from_secs(9);
    for _ in 0..10 {
        assert!(!window_name_check_due(last_output, last_check, 1000));
    }
}
