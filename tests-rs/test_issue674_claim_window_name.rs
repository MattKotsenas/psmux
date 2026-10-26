// Issue #674: "new-session -n NAME can lose the name on the warm claim path
// (window 0 renamed by the shell)".
//
// The claim wire carried the session name, the client cwd, the priority and
// the environment file, but not the window name. `-n NAME` was applied after
// the claim by a separate `rename-window` whose result the CLI discarded, so
// the claimed session was observable under the standby's pool name, and any
// claim whose follow up request did not land kept that pool name with
// `manual_rename` false, which is what let the automatic rename walk name the
// window after its shell and produced the sweep's `0:pwsh` where the rig had
// asked for `0:main`.
//
// tmux has no equivalent gap: cmd-new-session.c names the initial window and
// turns automatic-rename off for it before the session is linked, so the name
// is never a second step that can fail. psmux's cold spawn path already
// matched that (run_server applies -n before the server loop starts).
//
// What these tests pin:
//
//   * the wire carries `-n`, and its value never slides into a positional
//     (the client cwd is optional, so a stray positional would be read as the
//     directory, the same trap `-p` and `-e` are written against)
//   * a claim line without `-n` parses exactly as it did before
//   * applying the name sets `manual_rename` with it, so `automatic-rename`
//     reads `off` for that window immediately, which is the state the claim
//     handler is in when it answers OK
//   * no name asked for means no name pinned, so the rename walk still gets to
//     name the window after its shell

use super::*;
use crate::commands::parse_command_line;
use crate::types::Window;

fn make_window(name: &str) -> Window {
    Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id: 0,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

/// A standby as the claim finds it: one window still carrying the pool's
/// automatically assigned shell name, automatic-rename on.
fn parked_standby() -> AppState {
    let mut app = AppState::new("__warm__".to_string());
    app.windows.push(make_window("pwsh"));
    app.window_indices = vec![0];
    app.active_idx = 0;
    app
}

/// Re-tokenize a claim line exactly as the server does, so the test reads the
/// real wire rather than a hand split argument list.
fn wire(line: &str) -> crate::util::ClaimArgs {
    let parts = parse_command_line(line);
    assert_eq!(parts.first().map(String::as_str), Some("claim-session"));
    let args: Vec<&str> = parts[1..].iter().map(String::as_str).collect();
    crate::util::parse_claim_args_full(&args)
}

#[test]
fn claim_line_carries_the_window_name_alongside_cwd_priority_and_env() {
    let line = format!(
        "claim-session {} {} -p normal -e {} -n {}",
        crate::util::quote_arg("my session"),
        crate::util::quote_arg("C:\\Users\\My Name\\Documents"),
        crate::util::quote_arg("C:\\tmp\\env file.txt"),
        crate::util::quote_arg("my window"),
    );
    let parsed = wire(&line);
    assert_eq!(parsed.positionals, vec!["my session", "C:\\Users\\My Name\\Documents"]);
    assert_eq!(parsed.priority.as_deref(), Some("normal"));
    assert_eq!(parsed.env_file.as_deref(), Some("C:\\tmp\\env file.txt"));
    assert_eq!(parsed.window_name.as_deref(), Some("my window"));
}

#[test]
fn a_window_name_is_never_mistaken_for_the_client_cwd() {
    // The cwd is optional. Before -n was a known flag its value was not
    // consumed as a pair, so `claim-session S -n main` handed the server
    // "main" as positional 1, the directory.
    let parsed = wire("claim-session S -n main");
    assert_eq!(parsed.positionals, vec!["S"]);
    assert_eq!(parsed.window_name.as_deref(), Some("main"));
}

#[test]
fn a_claim_without_a_window_name_parses_exactly_as_before() {
    // Encoded the way the CLI encodes it, so the trailing backslash is escaped
    // rather than eating the closing quote (#547).
    let line = format!(
        "claim-session sess {} -p above-normal",
        crate::util::quote_arg("D:\\Projects\\"),
    );
    let parsed = wire(&line);
    assert_eq!(parsed.positionals, vec!["sess", "D:\\Projects\\"]);
    assert_eq!(parsed.priority.as_deref(), Some("above-normal"));
    assert_eq!(parsed.window_name, None);
    assert_eq!(parsed.env_file, None);
}

#[test]
fn applying_the_name_also_turns_automatic_rename_off_for_that_window() {
    let mut app = parked_standby();
    assert_eq!(
        options::get_window_option_value_for(&app, "automatic-rename", Some(0)),
        "on",
        "a parked standby's window is renamed by its shell, that is how it got the name 'pwsh'",
    );

    let applied = apply_initial_window_name(&mut app, Some("main"));

    assert!(applied, "the claim must report that it applied the name");
    assert_eq!(app.windows[0].name, "main");
    assert!(
        app.windows[0].manual_rename,
        "without manual_rename the rename walk names the window after its shell, which is issue #674",
    );
    assert_eq!(
        options::get_window_option_value_for(&app, "automatic-rename", Some(0)),
        "off",
        "tmux turns automatic-rename off for a window created with -n before the session is visible",
    );
}

#[test]
fn no_window_name_leaves_the_automatic_rename_alone() {
    let mut app = parked_standby();

    let applied = apply_initial_window_name(&mut app, None);

    assert!(!applied);
    assert_eq!(app.windows[0].name, "pwsh");
    assert!(!app.windows[0].manual_rename);
    assert_eq!(
        options::get_window_option_value_for(&app, "automatic-rename", Some(0)),
        "on",
        "new-session without -n must still let the shell name the window (tmux behaviour)",
    );
}

#[test]
fn the_applied_name_is_sanitized_the_same_way_the_cold_path_sanitizes_it() {
    // Both paths run the name through clean_name (#647), so a claim cannot
    // smuggle a control byte into a format or a status line where the cold
    // spawn would have encoded it.
    let mut app = parked_standby();
    apply_initial_window_name(&mut app, Some("we\tird"));
    assert_eq!(app.windows[0].name, crate::util::clean_name("we\tird"));
    assert_ne!(app.windows[0].name, "we\tird");
}

#[test]
fn a_claim_that_finds_no_window_reports_that_it_applied_nothing() {
    // Defensive: a standby always has its initial window by the time a claim
    // reaches the control loop, but the helper must not panic if that ever
    // stops being true.
    let mut app = AppState::new("__warm__".to_string());
    assert!(!apply_initial_window_name(&mut app, Some("main")));
}
