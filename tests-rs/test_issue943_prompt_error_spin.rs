// Issue #943: a command that fails at prefix + : must not be run again on
// every turn of the connection loop. The attached client sends what is typed
// at the prompt over its PERSISTENT connection; four arms left the line in
// `line` when they ended with `continue`, so the loop ran the same command
// for ever, never read the client's next line, and never saw it go away.
//
// Real authenticated ingress, without starting a psmux server or a shell:
// every request the handler sends is counted and dropped, so a reply it
// waits for fails at once.
use super::*;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};

/// Runs `command` on a persistent connection, then closes the client's write
/// half. Returns whether the handler read that EOF and returned in time, and
/// how many requests it sent the server meanwhile.
fn run_on_persistent_connection(command: &str) -> (bool, usize) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<CtrlReq>();
    let requests = Arc::new(AtomicUsize::new(0));
    let counted = requests.clone();
    // Dropping each request drops its reply sender, so a handler waiting on
    // one gets an error at once instead of its timeout.
    std::thread::spawn(move || {
        while let Ok(req) = rx.recv() {
            counted.fetch_add(1, Ordering::SeqCst);
            drop(req);
        }
    });
    let (done_tx, done_rx) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        handle_connection(stream, tx, "test943", Arc::new(RwLock::new(Default::default())));
        let _ = done_tx.send(());
    });
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
    stream.write_all(b"AUTH test943\n").unwrap();
    let mut reply = String::new();
    reader.read_line(&mut reply).unwrap();
    assert_eq!(reply, "OK\n");
    write!(stream, "PERSISTENT\n{command}\n").unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    // A handler that spins never reads the EOF. It is left running: there
    // is no way to stop a thread, and the test fails either way.
    let returned = done_rx.recv_timeout(Duration::from_secs(5)).is_ok();
    (returned, requests.load(Ordering::SeqCst))
}

fn assert_runs_once(command: &str) {
    let (returned, requests) = run_on_persistent_connection(command);
    assert!(
        returned,
        "`{command}` on a persistent connection: the handler never read the client's next line \
         (it sent {requests} requests in 5 s, running the command again on every turn)"
    );
    // Once, not once per turn: a spinning loop sends thousands.
    assert!(requests < 20, "`{command}` sent {requests} requests; it ran more than once");
}

#[test]
fn show_options_of_an_unknown_name_runs_once() {
    assert_runs_once("show-options codepoint-width");
}

#[test]
fn show_options_of_an_unset_user_option_runs_once() {
    assert_runs_once("show-options @nope");
}

#[test]
fn display_message_with_an_unknown_flag_runs_once() {
    assert_runs_once("display-message -x hi");
}

#[test]
fn show_options_p_runs_once() {
    assert_runs_once("show-options -p");
}

/// The comparison: a failure that was already handled the same way.
#[test]
fn set_option_with_a_bad_flag_runs_once() {
    assert_runs_once("set-option -Z x y");
}

/// The same four arms reached with other flags, and through a line that
/// if-shell feeds back into the loop: each one ran for ever on master.
#[test]
fn other_flags_and_an_if_shell_branch_run_once() {
    for command in [
        "show-options -g nosuch",
        "show-options -gv nosuch",
        "show-options -A nosuch",
        "show-window-options nosuch",
        "show-options -w @nope",
        "show-options -s @nope",
        "display-message -Z",
        "if-shell -F 1 \"show-options @nope\"",
    ] {
        assert_runs_once(command);
    }
}

/// Every other kind of failure at the prompt already read the next line;
/// this keeps it so. None of these starts a process.
#[test]
fn every_failing_command_kind_reads_the_next_line() {
    for command in [
        "nosuchcommand a b",
        "set-option nosuch x",
        "set-option -g @x",
        "set-window-option nosuch x",
        "set-hook nosuch x",
        "show-options -t nosuch",
        "show -p -t %999",
        "show-hooks nosuch",
        "show-environment NOSUCH",
        "display-message -t nosuch hi",
        "display -c nosuch hi",
        "select-window -t 99",
        "select-pane -t %999",
        "kill-window -t 99",
        "rename-window -t 99 x",
        "swap-pane -s %998 -t %999",
        "show-buffer -b nosuch",
        "delete-buffer -b nosuch",
        "unbind-key -T nosuch x",
        "list-keys -T nosuch",
        "if-shell",
        "bind-key",
        "wait-for",
        "command-prompt -Z",
        "show-options codepoint-width ; set -g @chain 1",
        "set -g @a 1 ; show-options @nope ; set -g @b 1",
    ] {
        assert_runs_once(command);
    }
}
