use std::fs;
use std::io;
use std::net::TcpListener;
use std::process::Command;

#[test]
fn kill_window_missing_target_fails_before_dispatch() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock control port");
    let port = listener.local_addr().unwrap().port();
    let profile = std::env::current_dir()
        .unwrap()
        .join("target")
        .join("test-data")
        .join(format!(
            "required-option-values-{}-{port}",
            std::process::id()
        ));
    let psmux_dir = profile.join(".psmux");
    fs::create_dir_all(&psmux_dir).unwrap();
    fs::write(psmux_dir.join("probe.port"), port.to_string()).unwrap();
    fs::write(psmux_dir.join("probe.key"), "test-key").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_psmux"))
        .args(["killw", "-t"])
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
    drop(listener);
    fs::remove_dir_all(&profile).unwrap();

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1), "stderr: {stderr}");
    assert!(
        stderr.contains("psmux: -t expects an argument"),
        "stderr: {stderr}"
    );
    assert!(
        no_connection,
        "missing operand must not reach command dispatch"
    );
}
