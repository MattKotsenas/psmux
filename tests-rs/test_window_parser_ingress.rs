use super::*;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, RwLock};
use std::thread;

fn start_connection(
    aliases: HashMap<String, String>,
) -> (TcpStream, mpsc::Receiver<CtrlReq>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (request_tx, request_rx) = mpsc::channel();
    let aliases = Arc::new(RwLock::new(aliases));
    let handle = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        handle_connection(stream, request_tx, "test-key", aliases);
    });
    let stream = TcpStream::connect(address).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    (stream, request_rx, handle)
}

fn read_line(reader: &mut BufReader<TcpStream>) -> String {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    line.trim_end().to_string()
}

fn authenticate(stream: &mut TcpStream, reader: &mut BufReader<TcpStream>) {
    stream.write_all(b"AUTH test-key\n").unwrap();
    stream.flush().unwrap();
    assert_eq!(read_line(reader), "OK");
}

fn assert_no_requests(requests: &mpsc::Receiver<CtrlReq>) {
    assert!(matches!(
        requests.try_recv(),
        Err(mpsc::TryRecvError::Disconnected)
    ));
}

fn assert_no_control_command_dispatch(requests: &mpsc::Receiver<CtrlReq>) {
    let mut saw_registration = false;
    for request in requests.try_iter() {
        match request {
            CtrlReq::ControlRegister { .. } => saw_registration = true,
            CtrlReq::KillWindow
            | CtrlReq::KillWindowTarget { .. }
            | CtrlReq::NewWindow(..)
            | CtrlReq::NewWindowPrint(..)
            | CtrlReq::BindKey(..)
            | CtrlReq::ConfirmBefore(..)
            | CtrlReq::SetHook(..)
            | CtrlReq::AppendHook(..) => panic!("invalid command was dispatched"),
            _ => {}
        }
    }
    assert!(saw_registration);
}

#[test]
fn simple_connection_rejects_missing_target_without_dispatch() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"kill-window -t\n").unwrap();
    stream.flush().unwrap();

    assert_eq!(read_line(&mut reader), "psmux: -t expects an argument");
    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
    assert_no_requests(&requests);
}

#[test]
fn command_alias_rejects_missing_target_without_dispatch() {
    let aliases = HashMap::from([("close".to_string(), "kill-window".to_string())]);
    let (mut stream, requests, handle) = start_connection(aliases);
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"close -t\n").unwrap();
    stream.flush().unwrap();

    assert_eq!(read_line(&mut reader), "psmux: -t expects an argument");
    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
    assert_no_requests(&requests);
}

#[test]
fn simple_connection_rejects_missing_new_window_values_without_dispatch() {
    for option in ["-c", "-e", "-F", "-n", "-T", "-t"] {
        let (mut stream, requests, handle) = start_connection(HashMap::new());
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        authenticate(&mut stream, &mut reader);

        writeln!(stream, "new-window {option}").unwrap();
        stream.flush().unwrap();

        assert_eq!(
            read_line(&mut reader),
            format!("psmux: {option} expects an argument")
        );
        stream.shutdown(Shutdown::Both).unwrap();
        handle.join().unwrap();
        assert_no_requests(&requests);
    }
}

#[test]
fn new_window_alias_uses_the_same_parser() {
    let aliases = HashMap::from([("launch".to_string(), "new-window".to_string())]);
    let (mut stream, requests, handle) = start_connection(aliases);
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"launch -n\n").unwrap();
    stream.flush().unwrap();

    assert_eq!(read_line(&mut reader), "psmux: -n expects an argument");
    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
    assert_no_requests(&requests);
}

#[test]
fn new_window_alias_unquotes_server_values() {
    let aliases = HashMap::from([(
        "launch".to_string(),
        r##"new-window -P -n "mail" -c "C:\logs" -F "#{window_id}" -T "inbox" -e "A=1" "tool""##
            .to_string(),
    )]);
    let (mut stream, requests, handle) = start_connection(aliases);
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"launch\n").unwrap();
    stream.flush().unwrap();

    let CtrlReq::NewWindowPrint(
        command,
        name,
        _,
        start_dir,
        format,
        response,
        title,
        _,
        environment,
    ) =
        requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window print request");
    };
    assert_eq!(command.as_deref(), Some("tool"));
    assert_eq!(name.as_deref(), Some("mail"));
    assert_eq!(start_dir.as_deref(), Some(r"C:\logs"));
    assert_eq!(format.as_deref(), Some("#{window_id}"));
    assert_eq!(title.as_deref(), Some("inbox"));
    assert_eq!(environment, [("A".to_string(), "1".to_string())]);
    response.send(String::new()).unwrap();

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn simple_connection_preserves_new_window_options_and_argv() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(
            b"new-window -dPS -n first -n second -c one -c two -F firstfmt -F secondfmt -T first-title -T second-title -e A=1 -e B=two -- tool -r \"wide arg\"\n",
        )
        .unwrap();
    stream.flush().unwrap();

    let request = loop {
        let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
        if matches!(request, CtrlReq::ControlRegister { .. }) {
            continue;
        }
        break request;
    };
    let CtrlReq::NewWindowPrint(
        command,
        name,
        detached,
        start_dir,
        format,
        response,
        title,
        empty,
        environment,
    ) = request
    else {
        panic!("expected new-window print request");
    };
    assert_eq!(command.as_deref(), Some("-- tool -r 'wide arg'"));
    assert_eq!(name.as_deref(), Some("first"));
    assert!(detached);
    assert_eq!(start_dir.as_deref(), Some("one"));
    assert_eq!(format.as_deref(), Some("firstfmt"));
    assert_eq!(title.as_deref(), Some("first-title"));
    assert!(!empty);
    assert_eq!(
        environment,
        [
            ("A".to_string(), "1".to_string()),
            ("B".to_string(), "two".to_string())
        ]
    );
    response.send("created".to_string()).unwrap();
    assert_eq!(read_line(&mut reader), "created");

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn simple_connection_rejects_invalid_deferred_commands() {
    for command in [
        "bind-key x kill-window -t\n",
        "confirm-before kill-window -t\n",
        "confirm-before 'kill-window -t'\n",
        "set-hook pane-died kill-window -t\n",
    ] {
        let (mut stream, requests, handle) = start_connection(HashMap::new());
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        authenticate(&mut stream, &mut reader);

        stream.write_all(command.as_bytes()).unwrap();
        stream.flush().unwrap();

        assert_eq!(read_line(&mut reader), "psmux: -t expects an argument");
        stream.shutdown(Shutdown::Both).unwrap();
        handle.join().unwrap();
        assert_no_requests(&requests);
    }
}

#[test]
fn command_target_overrides_transport_target_after_alias_expansion() {
    let aliases = HashMap::from([(
        "close".to_string(),
        "kill-window -t :1".to_string(),
    )]);
    let (mut stream, requests, handle) = start_connection(aliases);
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"TARGET :0\nclose -t:2\n")
        .unwrap();
    stream.flush().unwrap();

    let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    let CtrlReq::KillWindowTarget {
        win,
        win_is_id,
        name,
        resp,
    } = request
    else {
        panic!("expected targeted kill-window request");
    };
    assert_eq!(win, Some(2));
    assert!(!win_is_id);
    assert_eq!(name, None);
    resp.send(Ok(())).unwrap();

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn transport_target_is_used_when_command_has_no_target() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"TARGET :3\nkill-window\n").unwrap();
    stream.flush().unwrap();

    let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    let CtrlReq::KillWindowTarget {
        win,
        win_is_id,
        name,
        resp,
    } = request
    else {
        panic!("expected targeted kill-window request");
    };
    assert_eq!(win, Some(3));
    assert!(!win_is_id);
    assert_eq!(name, None);
    resp.send(Ok(())).unwrap();

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn attached_new_window_target_overrides_transport_target() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"TARGET :1\nnew-window -t:2 -d\n")
        .unwrap();
    stream.flush().unwrap();

    let CtrlReq::FocusTargetTemp {
        win,
        win_is_id,
        win_name,
        pane,
        pane_is_id,
        resp,
    } = requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected target validation");
    };
    assert_eq!(win, Some(2));
    assert!(!win_is_id);
    assert_eq!(win_name, None);
    assert_eq!(pane, None);
    assert!(!pane_is_id);
    resp.send(Ok(())).unwrap();

    let CtrlReq::NewWindow(command, name, detached, start_dir, title, empty, environment) =
        requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window request");
    };
    assert_eq!(command, None);
    assert_eq!(name, None);
    assert!(detached);
    assert_eq!(start_dir, None);
    assert_eq!(title, None);
    assert!(!empty);
    assert!(environment.is_empty());

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn session_only_new_window_target_keeps_transport_window() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"TARGET work:1\nnew-window -t work\n")
        .unwrap();
    stream.flush().unwrap();

    let CtrlReq::FocusTargetTemp {
        win,
        win_name,
        resp,
        ..
    } = requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected target validation");
    };
    assert_eq!(win, Some(1));
    assert_eq!(win_name, None);
    resp.send(Ok(())).unwrap();

    assert!(matches!(
        requests.recv_timeout(Duration::from_secs(2)).unwrap(),
        CtrlReq::NewWindow(..)
    ));

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn target_after_new_window_command_operand_remains_command_text() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"TARGET :1\nnew-window tool -t child\n")
        .unwrap();
    stream.flush().unwrap();

    let CtrlReq::FocusTargetTemp { win, resp, .. } =
        requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected transport target validation");
    };
    assert_eq!(win, Some(1));
    resp.send(Ok(())).unwrap();

    let CtrlReq::NewWindow(command, ..) = requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window request");
    };
    assert_eq!(command.as_deref(), Some("tool"));

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn target_after_double_dash_option_value_remains_command_text() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"new-window -n -- -t child tool\n")
        .unwrap();
    stream.flush().unwrap();

    let CtrlReq::NewWindow(command, name, ..) =
        requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window request without target validation");
    };
    assert_eq!(name.as_deref(), Some("--"));
    assert_eq!(command.as_deref(), Some("-- -t child tool"));

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn bare_command_target_does_not_discard_the_transport_window() {
    for target in ["2", "work.2"] {
        let (mut stream, requests, handle) = start_connection(HashMap::new());
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        authenticate(&mut stream, &mut reader);

        stream
            .write_all(format!("TARGET work:1\nkill-window -t {target}\n").as_bytes())
            .unwrap();
        stream.flush().unwrap();

        let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
        let CtrlReq::KillWindowTarget {
            win,
            win_is_id,
            name,
            resp,
        } = request
        else {
            panic!("expected targeted kill-window request");
        };
        assert_eq!(win, Some(1));
        assert!(!win_is_id);
        assert_eq!(name, None);
        resp.send(Ok(())).unwrap();

        stream.shutdown(Shutdown::Both).unwrap();
        handle.join().unwrap();
    }
}

#[test]
fn valid_deferred_command_is_still_dispatched() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream
        .write_all(b"bind-key x kill-window -t :1\n")
        .unwrap();
    stream.flush().unwrap();

    let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    let CtrlReq::BindKey(table, key, command, repeat) = request else {
        panic!("expected bind-key request");
    };
    assert_eq!(table, "prefix");
    assert_eq!(key, "x");
    assert_eq!(command, "kill-window -t :1");
    assert!(!repeat);

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn control_connection_reports_missing_target_and_stays_usable() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"CONTROL_NOECHO\n").unwrap();
    stream.flush().unwrap();
    assert!(read_line(&mut reader).starts_with("\u{1b}P1000p%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    for command in [
        "killw -t\n",
        "bind-key x kill-window -t\n",
        "confirm-before kill-window -t\n",
        "set-hook pane-died kill-window -t\n",
    ] {
        stream.write_all(command.as_bytes()).unwrap();
        stream.flush().unwrap();
        assert!(read_line(&mut reader).starts_with("%begin "));
        assert_eq!(read_line(&mut reader), "psmux: -t expects an argument");
        assert!(read_line(&mut reader).starts_with("%error "));
    }

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
    assert_no_control_command_dispatch(&requests);
}

#[test]
fn control_connection_rejects_missing_new_window_values_and_stays_usable() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"CONTROL_NOECHO\n").unwrap();
    stream.flush().unwrap();
    assert!(read_line(&mut reader).starts_with("\u{1b}P1000p%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    for option in ["-c", "-e", "-F", "-n", "-T", "-t"] {
        writeln!(stream, "neww {option}").unwrap();
        stream.flush().unwrap();
        assert!(read_line(&mut reader).starts_with("%begin "));
        assert_eq!(
            read_line(&mut reader),
            format!("psmux: {option} expects an argument")
        );
        assert!(read_line(&mut reader).starts_with("%error "));
    }

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
    assert_no_control_command_dispatch(&requests);
}

#[test]
fn control_connection_preserves_new_window_options_and_argv() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"CONTROL_NOECHO\n").unwrap();
    stream.flush().unwrap();
    assert!(read_line(&mut reader).starts_with("\u{1b}P1000p%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    stream
        .write_all(
            b"new-window -dPS -n first -n second -c one -c two -F firstfmt -F secondfmt -T first-title -T second-title -e A=1 -e B=two -- tool -r \"wide arg\"\n",
        )
        .unwrap();
    stream.flush().unwrap();

    let request = loop {
        let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
        if matches!(request, CtrlReq::ControlRegister { .. }) {
            continue;
        }
        break request;
    };
    let CtrlReq::NewWindowPrint(
        command,
        name,
        detached,
        start_dir,
        format,
        response,
        title,
        empty,
        environment,
    ) = request
    else {
        panic!("expected new-window print request");
    };
    assert_eq!(command.as_deref(), Some("-- tool -r 'wide arg'"));
    assert_eq!(name.as_deref(), Some("first"));
    assert!(detached);
    assert_eq!(start_dir.as_deref(), Some("one"));
    assert_eq!(format.as_deref(), Some("firstfmt"));
    assert_eq!(title.as_deref(), Some("first-title"));
    assert!(!empty);
    assert_eq!(
        environment,
        [
            ("A".to_string(), "1".to_string()),
            ("B".to_string(), "two".to_string())
        ]
    );
    response.send("created".to_string()).unwrap();

    assert!(read_line(&mut reader).starts_with("%begin "));
    assert_eq!(read_line(&mut reader), "created");
    assert!(read_line(&mut reader).starts_with("%end "));

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}

#[test]
fn control_connection_uses_typed_new_window_targets() {
    let (mut stream, requests, handle) = start_connection(HashMap::new());
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    authenticate(&mut stream, &mut reader);

    stream.write_all(b"CONTROL_NOECHO\n").unwrap();
    stream.flush().unwrap();
    assert!(read_line(&mut reader).starts_with("\u{1b}P1000p%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    stream.write_all(b"new-window -t:2 -d\n").unwrap();
    stream.flush().unwrap();

    let request = loop {
        let request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
        if matches!(request, CtrlReq::ControlRegister { .. }) {
            continue;
        }
        break request;
    };
    let CtrlReq::FocusTargetTemp { win, resp, .. } = request else {
        panic!("expected target validation");
    };
    assert_eq!(win, Some(2));
    resp.send(Ok(())).unwrap();

    let CtrlReq::NewWindow(_, _, detached, ..) =
        requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window request");
    };
    assert!(detached);
    assert!(read_line(&mut reader).starts_with("%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    stream.write_all(b"new-window tool -t child\n").unwrap();
    stream.flush().unwrap();

    let CtrlReq::NewWindow(command, ..) = requests.recv_timeout(Duration::from_secs(2)).unwrap()
    else {
        panic!("expected new-window request");
    };
    assert_eq!(command.as_deref(), Some("tool"));
    assert!(read_line(&mut reader).starts_with("%begin "));
    assert!(read_line(&mut reader).starts_with("%end "));

    stream.shutdown(Shutdown::Both).unwrap();
    handle.join().unwrap();
}
