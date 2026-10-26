// Issue #362: detect a top-level `new-session` directive in the user's config
// so `attach-session` can bootstrap a session when no server is running, matching
// tmux (which runs new-session from the config at server start).

fn with_config<T>(content: &str, f: impl FnOnce() -> T) -> T {
    // The shared lock, not a private one: PSMUX_CONFIG_FILE is process wide, so
    // a mutex of our own serialises these tests against each other and against
    // nothing else (src/util.rs).
    let _g = crate::util::lock_test_env();
    let tmp = std::env::temp_dir().join(format!("psmux_test362_{}.conf", std::process::id()));
    std::fs::write(&tmp, content).unwrap();
    let prev = std::env::var("PSMUX_CONFIG_FILE").ok();
    std::env::set_var("PSMUX_CONFIG_FILE", &tmp);
    let r = f();
    match prev {
        Some(v) => std::env::set_var("PSMUX_CONFIG_FILE", v),
        None => std::env::remove_var("PSMUX_CONFIG_FILE"),
    }
    let _ = std::fs::remove_file(&tmp);
    r
}

#[test]
fn bare_new_session_detected() {
    with_config("set -g mouse on\nnew-session\n", || {
        assert_eq!(crate::config::config_new_session_args(), Some(vec![]));
    });
}

#[test]
fn new_session_with_args_preserved() {
    with_config("new-session -s work -c C:/tmp\n", || {
        assert_eq!(
            crate::config::config_new_session_args(),
            Some(vec!["-s".to_string(), "work".to_string(), "-c".to_string(), "C:/tmp".to_string()])
        );
    });
}

#[test]
fn new_alias_detected() {
    with_config("new -s main\n", || {
        assert_eq!(
            crate::config::config_new_session_args(),
            Some(vec!["-s".to_string(), "main".to_string()])
        );
    });
}

#[test]
fn no_new_session_returns_none() {
    with_config("set -g mouse on\nset -g history-limit 5000\n", || {
        assert_eq!(crate::config::config_new_session_args(), None);
    });
}

#[test]
fn new_session_as_argument_not_matched() {
    // `new-session` appearing as a bound command, not a top-level directive.
    with_config("bind-key x new-session\n", || {
        assert_eq!(crate::config::config_new_session_args(), None);
    });
}

#[test]
fn commented_new_session_ignored() {
    with_config("# new-session\nset -g mouse on\n", || {
        assert_eq!(crate::config::config_new_session_args(), None);
    });
}

#[test]
fn bom_prefixed_bare_new_session_detected() {
    // Windows editors / PowerShell Set-Content -Encoding UTF8 prepend a BOM;
    // a bare new-session on the first line must still be recognised (#362).
    with_config("\u{FEFF}new-session\n", || {
        assert_eq!(crate::config::config_new_session_args(), Some(vec![]));
    });
}

#[test]
fn leading_whitespace_new_session_detected() {
    with_config("   new-session -s indented\n", || {
        assert_eq!(
            crate::config::config_new_session_args(),
            Some(vec!["-s".to_string(), "indented".to_string()])
        );
    });
}
