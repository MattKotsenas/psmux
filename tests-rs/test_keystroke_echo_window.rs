//! Regression tests for the client's keystroke-echo fast-poll window.
//!
//! The defect these pin: after psmux wrote a keystroke to a pane, the client
//! polled console input at 1ms so the frame carrying the echo would be picked
//! up the moment it landed on the socket. That window was closed by the first
//! CHANGED FRAME to arrive, on the assumption that a changed frame meant the
//! echo had arrived.
//!
//! At a pwsh prompt it does not. PSReadLine answers one keystroke with two
//! separate ConPTY writes: a bare cursor-hide straight away, and the echoed
//! character about 15ms later. Measured with tests/conpty_echolat.cs against a
//! raw pseudoconsole, with no psmux anywhere in the picture, the character was
//! in the first chunk 0 times out of 40. So the cursor-hide closed the window
//! about 10ms before the character it was opened for turned up, and the client
//! fell back to the `dump_in_flight` 5ms or `typing_active` 10ms console poll
//! with the character's frame already sitting unread on the socket.
//!
//! End to end that cost roughly 5ms of the median keystroke-to-screen time and
//! most of its spread: n=60 at an idle pwsh prompt went from median 23.01ms
//! p90 31.65ms to median 18.44ms p90 19.87ms.

use crate::client::{input_poll_ms, key_echo_window_expired, KEY_ECHO_WINDOW_MS};

/// The old 30ms bound expired while a pwsh echo was still in flight. The echo
/// needs ~15ms to leave the shell's ConPTY before psmux has any bytes to
/// render, so the window has to still be open well past 30ms.
#[test]
fn window_outlasts_a_pwsh_echo() {
    assert!(!key_echo_window_expired(0));
    assert!(!key_echo_window_expired(16), "still inside PSReadLine's own wait");
    assert!(!key_echo_window_expired(30), "the old bound closed here");
    assert!(!key_echo_window_expired(45));
    assert!(!key_echo_window_expired(KEY_ECHO_WINDOW_MS));
    assert!(key_echo_window_expired(KEY_ECHO_WINDOW_MS + 1));
}

/// The regression itself: a key is out and its echo has not been drawn yet, so
/// the poll must be 1ms even though sending the key also set `force_dump` and
/// left `dump_in_flight` true. This is the case the old code lost when a
/// cursor-hide frame cleared the window early, dropping it to the 5ms arm.
#[test]
fn key_echo_window_beats_dump_in_flight() {
    for elapsed in [0u128, 5, 16, 20, 30, 45, 59] {
        assert_eq!(
            input_poll_ms(false, false, Some(elapsed), true, true, true, 0),
            1,
            "a key sent {elapsed}ms ago must still poll at 1ms"
        );
    }
}

/// Once the window really has expired the coarser arms take over again, so the
/// fix cannot leave the client spinning at 1ms forever.
#[test]
fn expired_window_falls_back_to_the_coarse_arms() {
    let expired = Some(KEY_ECHO_WINDOW_MS + 1);
    assert_eq!(input_poll_ms(false, false, expired, true, false, true, 0), 5);
    assert_eq!(input_poll_ms(false, false, expired, false, true, true, 0), 0);
    assert_eq!(input_poll_ms(false, false, expired, false, false, true, 0), 10);
    assert_eq!(input_poll_ms(false, false, expired, false, false, true, 4), 6);
    assert_eq!(input_poll_ms(false, false, expired, false, false, false, 0), 16);
    assert_eq!(input_poll_ms(false, false, None, false, false, false, 0), 16);
}

/// Arms above the echo window keep their priority.
#[test]
fn pending_paste_and_a_fresh_frame_still_win() {
    assert_eq!(input_poll_ms(true, false, None, true, false, true, 0), 1);
    assert_eq!(input_poll_ms(false, true, Some(0), true, false, true, 0), 0);
}

/// `typing_active` never yields a negative interval when a dump is overdue.
#[test]
fn typing_arm_saturates() {
    let expired = Some(KEY_ECHO_WINDOW_MS + 1);
    assert_eq!(input_poll_ms(false, false, expired, false, false, true, 50), 0);
}
