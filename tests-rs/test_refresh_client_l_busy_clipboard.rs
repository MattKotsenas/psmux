// refresh-client -l reads the Windows clipboard on a connection thread. Another
// window (a clipboard history listener, an RDP clipboard bridge) holding the
// clipboard open for more than the ~10 ms the plain read retries made the
// command store nothing at all (full sweeps 2026-10-22, 10-23, 10-24, 10-28:
// test_mouse_key_bindings "top buffer []"). The waiting read keeps trying
// until the clipboard is free, up to tmux's TTY_QUERY_TIMEOUT.

use super::*;
use std::cell::Cell;

#[test]
fn a_busy_clipboard_is_waited_for_and_then_read() {
    let calls = Cell::new(0u32);
    let pauses = Cell::new(0u32);
    let got = wait_for_clipboard(
        Duration::from_secs(5),
        || {
            calls.set(calls.get() + 1);
            // Busy for the first 30 attempts: about 300 ms of a real holder.
            if calls.get() <= 30 { Err(ClipboardBusy) } else { Ok(Some("CLIP".to_string())) }
        },
        || pauses.set(pauses.get() + 1),
    );
    assert_eq!(got.as_deref(), Some("CLIP"));
    assert_eq!(calls.get(), 31);
    assert_eq!(pauses.get(), 30);
}

#[test]
fn a_free_clipboard_is_read_at_once() {
    let pauses = Cell::new(0u32);
    let got = wait_for_clipboard(
        Duration::from_secs(5),
        || Ok(Some("NOW".to_string())),
        || pauses.set(pauses.get() + 1),
    );
    assert_eq!(got.as_deref(), Some("NOW"));
    assert_eq!(pauses.get(), 0);
}

#[test]
fn a_clipboard_with_no_text_is_not_retried() {
    let calls = Cell::new(0u32);
    let got = wait_for_clipboard(
        Duration::from_secs(5),
        || { calls.set(calls.get() + 1); Ok(None) },
        || {},
    );
    assert_eq!(got, None);
    assert_eq!(calls.get(), 1, "no text is an answer, not a busy clipboard");
}

#[test]
fn a_clipboard_held_past_the_timeout_gives_up() {
    let start = std::time::Instant::now();
    let got = wait_for_clipboard(
        Duration::from_millis(60),
        || Err(ClipboardBusy),
        || std::thread::sleep(Duration::from_millis(5)),
    );
    assert_eq!(got, None);
    let took = start.elapsed();
    assert!(took >= Duration::from_millis(60) && took < Duration::from_secs(2), "took {:?}", took);
}

#[test]
fn the_wait_is_tmux_query_timeout() {
    // tty.c: #define TTY_QUERY_TIMEOUT 5 (seconds), used by tty_clipboard_query.
    assert_eq!(CLIPBOARD_QUERY_TIMEOUT, Duration::from_secs(5));
}
