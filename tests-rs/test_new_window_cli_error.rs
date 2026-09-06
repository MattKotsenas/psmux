use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn missing_option_values_fail_before_cli_dispatch() {
    for option in ["-c", "-e", "-F", "-n", "-T", "-t"] {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock control port");
        let port = listener.local_addr().unwrap().port();
        let profile = std::env::temp_dir().join(format!(
            "psmux_new_window_cli_error_{}_{}_{}",
            std::process::id(),
            option.trim_start_matches('-'),
            port
        ));
        let psmux_dir = profile.join(".psmux");
        fs::create_dir_all(&psmux_dir).unwrap();
        fs::write(psmux_dir.join("probe.port"), port.to_string()).unwrap();
        fs::write(psmux_dir.join("probe.key"), "test-key").unwrap();

        let output = Command::new(env!("CARGO_BIN_EXE_psmux"))
            .args(["neww", option])
            .env("USERPROFILE", &profile)
            .env("PSMUX_TARGET_SESSION", "probe")
            .env_remove("PSMUX_TARGET_FULL")
            .env_remove("TMUX")
            .output()
            .expect("run psmux CLI");

        listener.set_nonblocking(true).unwrap();
        let no_connection = matches!(
            listener.accept(),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock
        );
        fs::remove_dir_all(&profile).unwrap();

        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "{option}: {stderr}");
        assert_eq!(
            stderr,
            format!("psmux: {option} expects an argument\n"),
            "{option}"
        );
        assert!(
            no_connection,
            "{option} must fail before startup health probes or command dispatch"
        );
    }
}

#[test]
fn compatibility_flag_does_not_consume_the_window_name() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock control port");
    let port = listener.local_addr().unwrap().port();
    let profile = std::env::temp_dir().join(format!(
        "psmux_new_window_cli_flag_{}_{port}",
        std::process::id()
    ));
    let psmux_dir = profile.join(".psmux");
    fs::create_dir_all(&psmux_dir).unwrap();
    fs::write(psmux_dir.join("probe.port"), port.to_string()).unwrap();
    fs::write(psmux_dir.join("probe.key"), "test-key").unwrap();
    let server = thread::spawn(move || {
        listener.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut requests = String::new();
        while Instant::now() < deadline {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut auth = String::new();
                    reader.read_line(&mut auth).unwrap();
                    stream.write_all(b"OK\n").unwrap();
                    stream.flush().unwrap();
                    let mut request = String::new();
                    let _ = reader.read_to_string(&mut request);
                    requests.push_str(&auth);
                    requests.push_str(&request);
                    if request.lines().any(|line| line.starts_with("new-window ")) {
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept CLI request: {error}"),
            }
        }
        requests
    });

    let output = Command::new(env!("CARGO_BIN_EXE_psmux"))
        .args(["-t", "probe", "neww", "-S", "-n", "mail"])
        .env("USERPROFILE", &profile)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .output()
        .expect("run psmux CLI");

    let request = server.join().unwrap();
    fs::remove_dir_all(&profile).unwrap();
    assert!(
        output.status.success(),
        "stderr: {}\nrequest: {request:?}",
        String::from_utf8_lossy(&output.stderr)
    );
    let command = request
        .lines()
        .find(|line| line.starts_with("new-window "))
        .unwrap_or_else(|| panic!("new-window request missing from {request:?}"));

    assert!(command.contains("-n \"mail\""), "{command}");
    assert!(!command.contains("-S"), "{command}");
}
