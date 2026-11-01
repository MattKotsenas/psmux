// A command that fails at the command prompt shows its error on the status
// line, as tmux's cmdq_error does for a command whose client has a session
// (cmd-queue.c:880-882 at tag 3.8): the first letter in upper case, and a
// command line that does not parse worded `command NAME: ...` first
// (cmd.c:534). The attached client sends what is typed at the prompt over
// its PERSISTENT connection; an error there used to be written to that
// socket, where the client read it as a frame and dropped it, or opened a
// popup.
//
// Real authenticated ingress, without starting a psmux server or a shell:
// every request the handler sends is kept, and the reply it may wait for
// fails at once because the request is dropped after it is looked at.
use super::*;
use std::io::Read;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Mutex, RwLock};

/// Runs `command` on a connection, PERSISTENT or one-shot, and returns what
/// the handler wrote back after AUTH and the status messages it sent.
fn run(command: &str, persistent: bool) -> (String, Vec<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<CtrlReq>();
    let messages = Arc::new(Mutex::new(Vec::new()));
    let kept = messages.clone();
    // Ends once every sender is gone, the handler's and the ones its reply
    // stream holds, so every message it sent has been kept by then.
    let (closed_tx, closed_rx) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        while let Ok(req) = rx.recv() {
            if let CtrlReq::StatusMessage(message) = req {
                kept.lock().unwrap().push(message);
            }
        }
        let _ = closed_tx.send(());
    });
    let (done_tx, done_rx) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        handle_connection(stream, tx, "testpe", Arc::new(RwLock::new(Default::default())));
        let _ = done_tx.send(());
    });
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
    stream.write_all(b"AUTH testpe\n").unwrap();
    let mut reply = String::new();
    reader.read_line(&mut reply).unwrap();
    assert_eq!(reply, "OK\n");
    if persistent {
        writeln!(stream, "PERSISTENT\n{command}").unwrap();
    } else {
        writeln!(stream, "{command}").unwrap();
    }
    stream.shutdown(Shutdown::Write).unwrap();
    assert!(done_rx.recv_timeout(Duration::from_secs(10)).is_ok(), "`{command}`: the handler did not return");
    let mut written = String::new();
    let _ = reader.read_to_string(&mut written);
    let _ = closed_rx.recv_timeout(Duration::from_secs(5));
    let messages = messages.lock().unwrap().clone();
    (written, messages)
}

#[track_caller]
fn assert_status_line(command: &str, want: &str) {
    let (written, messages) = run(command, true);
    assert!(!written.contains("ERROR"), "`{command}` wrote its error to the socket: {written:?}");
    assert_eq!(messages.last().map(String::as_str), Some(want), "`{command}`: {messages:?}");
}

#[test]
fn a_flag_error_is_worded_with_the_command_name() {
    assert_status_line("display-message -x hi", "Command display-message: unknown flag -x");
    // tmux gives the full name whatever the command was typed as.
    assert_status_line("display -Z", "Command display-message: unknown flag -Z");
}

#[test]
fn an_unknown_command_is_reported() {
    assert_status_line("nosuchcommand a b", "Unknown command: nosuchcommand");
}

#[test]
fn a_hook_that_is_none_is_an_invalid_option() {
    assert_status_line("set-hook nosuch x", "Invalid option: nosuch");
    assert_status_line("set-hook -u nosuch", "Invalid option: nosuch");
    assert_status_line("show-hooks nosuch", "Invalid option: nosuch");
    assert_status_line("show-hooks -g nosuch", "Invalid option: nosuch");
}

#[test]
fn a_one_shot_connection_still_gets_its_error_line() {
    let (written, messages) = run("nosuchcommand a b ; display -p x", false);
    assert!(written.contains("ERROR: unknown command: nosuchcommand"), "{written:?}");
    assert!(messages.is_empty(), "a one-shot command's error is the CLI's to print: {messages:?}");
    let (written, messages) = run("display-message -x hi", false);
    assert!(written.contains("ERROR: unknown flag -x"), "{written:?}");
    assert!(messages.is_empty(), "{messages:?}");
}

#[test]
fn the_reply_line_of_an_error_reads_as_tmux_shows_it() {
    use crate::server::helpers::prompt_error_message as message;
    assert_eq!(message(Some("display"), "ERROR: unknown flag -x\n").as_deref(), Some("Command display-message: unknown flag -x"));
    assert_eq!(message(Some("select-window"), "ERROR: -t expects an argument").as_deref(), Some("Command select-window: -t expects an argument"));
    assert_eq!(message(Some("show-options"), "ERROR: invalid option: @nope").as_deref(), Some("Invalid option: @nope"));
    // switch-client answers `ERROR <message>`, without the colon.
    assert_eq!(message(None, "ERROR can't find session: x").as_deref(), Some("Can't find session: x"));
    assert_eq!(message(None, "ERROR: ").as_deref(), None);
    assert_eq!(message(None, "some output").as_deref(), None);
}

#[test]
fn a_popup_that_is_an_error_alone_goes_to_the_status_line() {
    use crate::server::helpers::popup_prompt_error as popup;
    assert_eq!(popup("ERROR: invalid option: @nope\n").as_deref(), Some("Invalid option: @nope"));
    assert_eq!(popup("ERROR: a\n\nERROR: b\n").as_deref(), Some("B"), "the last error wins");
    // Output, or pane text that happens to hold an ERROR line, stays a popup.
    assert_eq!(popup("status on\nERROR: invalid option: x\n"), None);
    assert_eq!(popup("build log\nERROR: link failed\n"), None);
    assert_eq!(popup(""), None);
}

#[test]
fn unbind_key_names_a_table_that_exists() {
    let mut app = crate::types::AppState::new("test_pe".to_string());
    let missing = crate::server::helpers::unbind_key_request(&mut app, "x", Some("nosuch".to_string()));
    assert_eq!(missing, Err("table nosuch doesn't exist".to_string()));
    for table in ["root", "prefix", "copy-mode", "copy-mode-vi"] {
        assert_eq!(crate::server::helpers::unbind_key_request(&mut app, "x", Some(table.to_string())), Ok(()), "{table}");
    }
    assert_eq!(crate::server::helpers::unbind_key_request(&mut app, "x", None), Ok(()), "no table is the prefix table");
}

#[test]
fn hook_names_are_tmux_options_or_psmux_hooks() {
    for name in ["after-new-window", "client-attached", "after-swap-window", "after-break-pane", "before-select-window", "@mine", "after-new-window[3]"] {
        assert!(is_hook_name(name), "{name}");
    }
    for name in ["nosuch", "", "after-nosuch", "before-"] {
        assert!(!is_hook_name(name), "{name}");
    }
    // Every hook psmux fires that its tmux option list does not carry.
    for name in [
        "after-break-pane", "after-join-pane", "after-respawn-pane", "after-rotate-window",
        "after-swap-pane", "after-swap-window", "before-kill-pane", "before-new-window",
        "before-rename-session", "before-rename-window", "before-select-pane",
        "before-select-window", "before-split-window",
    ] {
        assert!(is_hook_name(name), "{name}");
    }
    assert_eq!(show_hooks_name(&["-g", "nosuch"]), Some("nosuch"));
    assert_eq!(show_hooks_name(&["-t", "s", "pane-exited"]), Some("pane-exited"));
    assert_eq!(show_hooks_name(&["-g"]), None);
}
