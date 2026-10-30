use super::*;

fn server_app() -> (AppState, std::net::TcpListener) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut app = AppState::new("A".to_string());
    app.control_port = Some(listener.local_addr().unwrap().port());
    app.session_key = "key".to_string();
    (app, listener)
}

fn nothing_sent(listener: &std::net::TcpListener) -> bool {
    std::thread::sleep(std::time::Duration::from_millis(100));
    matches!(listener.accept(), Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock)
}

fn worth_waiting(error: &std::io::Error, deadline: std::time::Instant) -> bool {
    error.kind() == std::io::ErrorKind::WouldBlock && std::time::Instant::now() < deadline
}

fn pause() {
    std::thread::sleep(std::time::Duration::from_millis(10));
}

fn accept_within_a_second(listener: &std::net::TcpListener) -> std::net::TcpStream {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
    loop {
        match listener.accept() {
            Ok((stream, _)) => return stream,
            Err(e) if worth_waiting(&e, deadline) => pause(),
            Err(e) => panic!("no connection reached the session's own port: {e}"),
        }
    }
}

fn received_lines(listener: &std::net::TcpListener) -> Vec<String> {
    let mut stream = accept_within_a_second(listener);
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(1)))
        .unwrap();
    let mut text = String::new();
    std::io::Read::read_to_string(&mut stream, &mut text)
        .expect("reading the sent lines timed out or failed");
    text.lines().map(str::to_string).collect()
}

fn assert_kill_sent(listener: &std::net::TcpListener) {
    assert_eq!(
        received_lines(listener),
        vec!["AUTH key".to_string(), "kill-session".to_string()]
    );
    assert!(
        nothing_sent(listener),
        "a second connection reached the session's own port"
    );
}

fn assert_not_found(app: &AppState, listener: &std::net::TcpListener, name: &str) {
    assert!(
        nothing_sent(listener),
        "kill-session was sent to the session's own port"
    );
    let message = app
        .status_message
        .as_ref()
        .map(|(text, _, _)| text.as_str());
    assert_eq!(
        message,
        Some(format!("can't find session: {name}").as_str())
    );
}

#[test]
fn other_session_name_sends_nothing() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session -t D").unwrap();
    assert_not_found(&app, &listener, "D");
}

#[test]
fn alias_kill_ses_with_other_name_sends_nothing() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-ses -t D").unwrap();
    assert_not_found(&app, &listener, "D");
}

#[test]
fn empty_pane_part_is_dropped_before_the_message() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session -t D:1.").unwrap();
    assert_not_found(&app, &listener, "D:1");
}

#[test]
fn exact_marker_and_empty_pane_part_are_dropped() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session -t =D:1.").unwrap();
    assert_not_found(&app, &listener, "D:1");
}

#[test]
fn own_window_target_is_not_own_name() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session -t A:1.").unwrap();
    assert_not_found(&app, &listener, "A:1");
}

#[test]
fn other_name_shapes_send_nothing() {
    for value in ["ns__D", "$3", "a", "A:"] {
        let (mut app, listener) = server_app();
        execute_command_string(&mut app, &format!("kill-session -t {value}")).unwrap();
        assert_not_found(&app, &listener, value);
    }
}

#[test]
fn exact_marker_on_other_name_sends_nothing() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session -t =D").unwrap();
    assert_not_found(&app, &listener, "D");
}

#[test]
fn own_name_sends_kill_session() {
    for command in ["kill-session -t A", "kill-session -t =A"] {
        let (mut app, listener) = server_app();
        execute_command_string(&mut app, command).unwrap();
        assert_kill_sent(&listener);
        assert!(app.status_message.is_none());
    }
}

#[test]
fn no_arguments_sends_kill_session() {
    let (mut app, listener) = server_app();
    execute_command_string(&mut app, "kill-session").unwrap();
    assert_kill_sent(&listener);
}

#[test]
fn other_flag_shapes_keep_sending_kill_session() {
    for command in [
        "kill-session -a",
        "kill-session -a -t D",
        "kill-session -tD",
    ] {
        let (mut app, listener) = server_app();
        execute_command_string(&mut app, command).unwrap();
        assert_kill_sent(&listener);
    }
}

#[test]
fn without_a_server_other_name_sets_the_message() {
    let mut app = AppState::new("A".to_string());
    execute_command_string(&mut app, "kill-session -t D").unwrap();
    let message = app
        .status_message
        .as_ref()
        .map(|(text, _, _)| text.as_str());
    assert_eq!(message, Some("can't find session: D"));
}
