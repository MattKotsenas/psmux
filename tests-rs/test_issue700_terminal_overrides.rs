// Issue #700: `set -ga terminal-overrides ',*:smcup@:rmcup@'` must keep the
// attached client on the host terminal's main screen, as it does in tmux.
//
// These cover the parser (tmux tty_term_override_next / tty_term_apply), the
// fnmatch on TERM, the array semantics of set -g / set -ga on the config and
// runtime routes, the show-options rendering, the wire field, and the exact
// bytes the client emits on start and stop. The E2E counterpart that counts
// ESC[?1049h in a real client's output is
// tests/test_issue700_terminal_overrides_smcup.ps1.

use super::*;
use crate::types::AppState;

fn app() -> AppState {
    AppState::new("test_700".to_string())
}

// ── parser ──────────────────────────────────────────────────────────────────

#[test]
fn split_array_drops_empty_elements_like_options_array_assign() {
    assert_eq!(split_array(",*:smcup@:rmcup@"), vec!["*:smcup@:rmcup@"]);
    assert_eq!(split_array("a:x@,,b:y@,"), vec!["a:x@", "b:y@"]);
    assert!(split_array("").is_empty());
}

#[test]
fn double_colon_is_a_literal_colon() {
    assert_eq!(split_fields("xterm*:Ss=\\E[%p1%d q:Se::x"), vec!["xterm*", "Ss=\\E[%p1%d q", "Se:x"]);
}

#[test]
fn parse_entry_reads_remove_set_and_flag_fields() {
    let e = parse_entry("xterm*:smcup@:Tc:Ss=\\E[5 q").unwrap();
    assert_eq!(e.pattern, "xterm*");
    assert_eq!(
        e.caps,
        vec![
            ("smcup".to_string(), CapOp::Remove),
            ("Tc".to_string(), CapOp::Set(String::new())),
            ("Ss".to_string(), CapOp::Set("\x1b[5 q".to_string())),
        ]
    );
}

#[test]
fn unescape_handles_terminfo_escapes() {
    assert_eq!(unescape("\\E[?1049h"), "\x1b[?1049h");
    assert_eq!(unescape("\\033[m"), "\x1b[m");
    assert_eq!(unescape("a\\\\b"), "a\\b");
    assert_eq!(unescape("\\q"), "\\q");
}

// ── fnmatch ─────────────────────────────────────────────────────────────────

#[test]
fn fnmatch_matches_like_libc() {
    assert!(fnmatch("*", "xterm-256color"));
    assert!(fnmatch("*", ""), "an unset TERM is the empty string and * matches it");
    assert!(fnmatch("xterm*", "xterm-256color"));
    assert!(!fnmatch("xterm*", ""));
    assert!(!fnmatch("screen*", "xterm-256color"));
    assert!(fnmatch("xterm-?56color", "xterm-256color"));
    assert!(fnmatch("[sx]term*", "xterm"));
    assert!(fnmatch("[!s]term", "xterm"));
    assert!(!fnmatch("[!x]term", "xterm"));
    assert!(fnmatch("xterm-[0-9]*", "xterm-256color"));
    assert!(fnmatch("a\\*b", "a*b"));
    assert!(!fnmatch("a\\*b", "axxb"));
    assert!(fnmatch("xterm-256color", "xterm-256color"));
    assert!(!fnmatch("xterm", "xterm-256color"), "fnmatch anchors the whole name");
}

// ── smcup / rmcup decision ─────────────────────────────────────────────────

#[test]
fn no_overrides_keeps_the_alternate_screen() {
    let none: Vec<String> = Vec::new();
    assert_eq!(alt_screen_caps(&none, "xterm-256color"), AltScreenCaps { smcup: true, rmcup: true });
}

#[test]
fn star_smcup_rmcup_removal_disables_both() {
    let o = split_array(",*:smcup@:rmcup@");
    assert_eq!(alt_screen_caps(&o, "xterm-256color"), AltScreenCaps { smcup: false, rmcup: false });
    assert_eq!(alt_screen_caps(&o, ""), AltScreenCaps { smcup: false, rmcup: false });
}

#[test]
fn non_matching_pattern_is_ignored() {
    let o = split_array("screen*:smcup@:rmcup@");
    assert_eq!(alt_screen_caps(&o, "xterm-256color"), AltScreenCaps { smcup: true, rmcup: true });
    let o = split_array("xterm*:smcup@:rmcup@");
    assert_eq!(alt_screen_caps(&o, ""), AltScreenCaps { smcup: true, rmcup: true },
        "xterm* does not match a console with no TERM");
}

#[test]
fn later_entries_win_and_caps_are_independent() {
    let o = split_array("*:smcup@:rmcup@,xterm*:smcup=\\E[?1049h");
    assert_eq!(alt_screen_caps(&o, "xterm-256color"), AltScreenCaps { smcup: true, rmcup: false });
    let o = split_array("*:rmcup@");
    assert_eq!(alt_screen_caps(&o, "xterm"), AltScreenCaps { smcup: true, rmcup: false });
    // An empty value emits nothing in tmux, so it counts as removed.
    let o = split_array("*:smcup=");
    assert_eq!(alt_screen_caps(&o, "xterm"), AltScreenCaps { smcup: false, rmcup: true });
    // Other capabilities are parsed and ignored.
    let o = split_array("xterm*:Tc:RGB:Ss=\\E[%p1%d q");
    assert_eq!(alt_screen_caps(&o, "xterm"), AltScreenCaps { smcup: true, rmcup: true });
}

// ── set -g / set -ga, config and runtime ────────────────────────────────────

#[test]
fn config_set_ga_appends_and_set_g_replaces() {
    let mut a = app();
    crate::config::parse_config_content(&mut a, "set -ga terminal-overrides ',*:smcup@:rmcup@'\n");
    assert_eq!(a.terminal_overrides, vec!["*:smcup@:rmcup@"]);
    crate::config::parse_config_content(&mut a, "set -ga terminal-overrides 'xterm*:Tc'\n");
    assert_eq!(a.terminal_overrides, vec!["*:smcup@:rmcup@", "xterm*:Tc"],
        "-a without a leading comma still adds a new element");
    crate::config::parse_config_content(&mut a, "set -ga terminal-overrides ',screen*:Tc'\n");
    assert_eq!(a.terminal_overrides.len(), 3);
    crate::config::parse_config_content(&mut a, "set -g terminal-overrides 'foo:smcup@'\n");
    assert_eq!(a.terminal_overrides, vec!["foo:smcup@"], "set -g replaces the whole array");
    crate::config::parse_config_content(&mut a, "set -gu terminal-overrides\n");
    assert!(a.terminal_overrides.is_empty(), "-u restores the empty default");
    assert!(!a.environment.contains_key("terminal-overrides"));
    assert!(!a.user_options.contains_key("terminal-overrides"));
}

#[test]
fn runtime_set_option_replaces_the_array() {
    let mut a = app();
    crate::server::options::apply_set_option(&mut a, "terminal-overrides", "a:smcup@,b:rmcup@", false).unwrap();
    assert_eq!(a.terminal_overrides, vec!["a:smcup@", "b:rmcup@"]);
    assert_eq!(crate::server::options::get_option_value(&a, "terminal-overrides"), "a:smcup@,b:rmcup@");
    assert!(!a.user_options.contains_key("terminal-overrides"));
}

// ── show-options rendering ─────────────────────────────────────────────────

#[test]
fn show_prints_array_lines_like_tmux() {
    assert_eq!(
        show_array_lines("terminal-overrides", "a:smcup@,b:rmcup@", false).as_deref(),
        Some("terminal-overrides[0] a:smcup@\nterminal-overrides[1] b:rmcup@\n")
    );
    assert_eq!(
        show_array_lines("terminal-overrides", "a:smcup@,b:rmcup@", true).as_deref(),
        Some("a:smcup@\nb:rmcup@\n")
    );
    assert_eq!(show_array_lines("terminal-overrides", "", false).as_deref(), Some("terminal-overrides\n"));
    assert_eq!(show_array_lines("terminal-overrides", "", true).as_deref(), Some(""));
    assert_eq!(show_array_lines("status-left", "x", false), None);
}

// ── wire ───────────────────────────────────────────────────────────────────

#[test]
fn render_options_carry_overrides_only_when_set() {
    let mut a = app();
    let json = serde_json::to_string(&crate::server::helpers::expand_status_formats(&a, "").client_render_options).unwrap();
    assert!(!json.contains("\"tov\""), "default config adds nothing to the frame: {json}");
    a.terminal_overrides = vec!["*:smcup@:rmcup@".to_string()];
    let json = serde_json::to_string(&crate::server::helpers::expand_status_formats(&a, "").client_render_options).unwrap();
    assert!(json.contains("\"tov\":[\"*:smcup@:rmcup@\"]"), "{json}");
    let back: crate::render_state::ClientRenderOptions = serde_json::from_str(&json).unwrap();
    assert_eq!(back.terminal_overrides.as_deref(), Some(&["*:smcup@:rmcup@".to_string()][..]));
}

// ── client bytes ────────────────────────────────────────────────────────────

#[test]
fn client_start_and_stop_bytes() {
    let _env = crate::util::lock_test_env();
    let saved = std::env::var("TERM").ok();
    std::env::set_var("TERM", "xterm-256color");

    // Default: exactly the alternate screen pair, nothing else.
    arm_client_screen();
    let mut out: Vec<u8> = Vec::new();
    client_screen_start(&mut out, &[]);
    client_screen_start(&mut out, &[]); // later frames are no-ops
    client_screen_stop(&mut out);
    client_screen_stop(&mut out);
    assert_eq!(String::from_utf8_lossy(&out), "\x1b[?1049h\x1b[?1049l");

    // smcup@ rmcup@: never touch the alternate screen; clear on both ends
    // the way tmux's tty_start_tty / tty_stop_tty do.
    arm_client_screen();
    let mut out: Vec<u8> = Vec::new();
    let o = split_array(",*:smcup@:rmcup@");
    client_screen_start(&mut out, &o);
    client_screen_stop(&mut out);
    let s = String::from_utf8_lossy(&out).to_string();
    assert!(!s.contains("\x1b[?1049"), "{s:?}");
    assert_eq!(s, "\x1b[H\x1b[2J\x1b[H\x1b[2J");

    // Unset TERM matches `*` as the empty string.
    std::env::remove_var("TERM");
    arm_client_screen();
    let mut out: Vec<u8> = Vec::new();
    client_screen_start(&mut out, &o);
    client_screen_stop(&mut out);
    assert!(!String::from_utf8_lossy(&out).contains("\x1b[?1049"));

    // A client that never drew a frame emits nothing on exit.
    arm_client_screen();
    let mut out: Vec<u8> = Vec::new();
    client_screen_stop(&mut out);
    assert!(out.is_empty());

    match saved {
        Some(v) => std::env::set_var("TERM", v),
        None => std::env::remove_var("TERM"),
    }
}
