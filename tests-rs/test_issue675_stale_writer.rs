//! Issue #675: a client that reconnected in a millisecond and then vanished.
//!
//! The reconnect trace of the failing rounds read, in one millisecond:
//!
//! ```text
//! connection dropped, spawning reconnect thread
//! run_remote returning (panicking=false)
//! run_remote returned Ok (switch pending=false)
//! attempt 1/5 CONNECTED in 0ms
//! ```
//!
//! The reader thread noticed the drop and started the reconnect, and in the
//! same loop iteration a write to the old socket failed and `break` ended the
//! main loop: `run_remote` returned Ok, the process exited 0, and the reconnect
//! it had just started connected into a process that no longer existed. It
//! only happened when the server's close reached the client as a reset before
//! that write (2 of 30 rounds under load, 0 of 10 quiet).
//!
//! Every place that notices a lost connection now goes through
//! `on_connection_lost`, whose contract these tests pin: a pending reconnect
//! is waited for, never abandoned; a missing port file is the one thing that
//! turns a drop into a quit; a detach already under way is left alone; and a
//! first notice starts exactly one reconnect.

use super::*;

fn temp_port_file(tag: &str, present: bool) -> String {
    let p = std::env::temp_dir().join(format!("psmux_issue675_{}_{}.port", tag, std::process::id()));
    let s = p.display().to_string();
    if present {
        std::fs::write(&p, "1\n").unwrap();
    } else {
        let _ = std::fs::remove_file(&p);
    }
    s
}

/// A pending receiver that stands in for a reconnect thread still running.
fn pending() -> (std::sync::mpsc::Sender<Option<Connection>>, Option<std::sync::mpsc::Receiver<Option<Connection>>>) {
    let (tx, rx) = std::sync::mpsc::channel();
    (tx, Some(rx))
}

#[test]
fn a_write_failure_while_a_reconnect_is_pending_does_not_quit() {
    // The exact #675 shape: the reader already started a reconnect, then the
    // stale writer fails. The loop must keep waiting for that reconnect.
    let port = temp_port_file("pending", true);
    let (_tx, mut rp) = pending();
    let mut quit = false;
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "dump-state write failed");
    assert!(!quit, "a stale write must not end the client while a reconnect is in flight");
    assert!(rp.is_some(), "the pending reconnect must be kept, not replaced");
    let _ = std::fs::remove_file(&port);
}

#[test]
fn the_pending_receiver_is_the_same_one_afterwards() {
    // Keeping "a" receiver is not enough: it has to be the one the running
    // thread will answer on, or its result is lost and the client hangs on a
    // channel nobody writes to.
    let port = temp_port_file("same", true);
    let (tx, mut rp) = pending();
    let mut quit = false;
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "client-size write failed");
    tx.send(None).unwrap();
    let got = rp.as_ref().unwrap().try_recv();
    assert!(matches!(got, Ok(None)), "the original reconnect thread's answer must still arrive: {:?}", got.is_ok());
    let _ = std::fs::remove_file(&port);
}

#[test]
fn a_missing_port_file_turns_the_drop_into_an_intentional_quit() {
    // Clean server shutdown removes the port file before closing clients; that
    // and only that makes a drop a reason to leave.
    let port = temp_port_file("gone", false);
    let mut rp: Option<std::sync::mpsc::Receiver<Option<Connection>>> = None;
    let mut quit = false;
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "connection dropped");
    assert!(quit, "a drop with no port file is the server leaving on purpose");
    assert!(rp.is_none(), "no reconnect may be started against a server that has gone");
}

#[test]
fn a_detach_already_under_way_is_left_alone() {
    let port = temp_port_file("quit", true);
    let mut rp: Option<std::sync::mpsc::Receiver<Option<Connection>>> = None;
    let mut quit = true;
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "connection dropped");
    assert!(quit);
    assert!(rp.is_none(), "a client that is detaching must not reconnect");
    let _ = std::fs::remove_file(&port);
}

#[test]
fn the_first_notice_starts_exactly_one_reconnect() {
    // Whoever notices first (reader or writer) starts the reconnect; the second
    // notice in the same iteration finds it pending and waits.
    let port = temp_port_file("first", true);
    let mut rp: Option<std::sync::mpsc::Receiver<Option<Connection>>> = None;
    let mut quit = false;
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "connection dropped");
    assert!(!quit);
    assert!(rp.is_some(), "the first notice must start the reconnect");
    let first = rp.as_ref().map(|r| r as *const _);
    on_connection_lost(&mut rp, &mut quit, &port, "127.0.0.1:1", "k", "dump-state write failed");
    assert!(!quit);
    let second = rp.as_ref().map(|r| r as *const _);
    assert_eq!(first, second, "the second notice must not replace the pending reconnect");
    // The reconnect against port 1 gives up on its own (5 refused attempts);
    // its answer arrives on the receiver that was kept.
    let got = rp.as_ref().unwrap().recv_timeout(std::time::Duration::from_secs(20));
    assert!(matches!(got, Ok(None)), "the kept receiver must carry the thread's give up");
    let _ = std::fs::remove_file(&port);
}
