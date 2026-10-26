// Issue #580 (item 4, reported by BuKyungBuKyung): `#{pane_start_command}`
// answered `app.default_shell` for EVERY pane in the server, so 24 panes gave
// ONE distinct value and a pane created with an explicit command reported the
// shell instead of that command. Tools that verify pane ownership through the
// variable (oh-my-codex embeds a marker in its HUD pane's command and gates
// adopt/resize/kill on `#{m:*<marker>*,#{pane_start_command}}`) could never
// match, so their cleanup never ran and a pane leaked per prompt.
//
// tmux semantics this pins (verified against tmux 3.4 and the source):
//
//   format.c:874  /* Callback for pane_start_command. */
//                 static void *format_cb_start_command(struct format_tree *ft)
//                 { ... return (cmd_stringify_argv(wp->argc, wp->argv)); }
//   cmd.c:370     if (argc == 0) return (xstrdup(""));   <- default shell = ""
//   spawn.c:384   /* Replace the stored arguments if there are new ones. */
//                 if (argc > 0) { ... new_wp->argv = cmd_copy_argv(...); }
//
// i.e. the value is the pane's OWN spawn command, the empty string for a pane
// running the plain default shell, and a respawn replaces it only when that
// respawn carried a command of its own.
//
// Registered from src/format.rs.

use crate::pane::{start_command_display, start_command_raw, start_command_raw_argv};

// ── What gets STORED on the pane (must round-trip back through
//    build_command, because a bare respawn re-executes it) ─────────────

#[test]
fn issue580_default_shell_stores_nothing() {
    // The bug: this used to be reported as `app.default_shell`.
    assert_eq!(start_command_raw(None), "");
    // A blank operand is not a command either.
    assert_eq!(start_command_raw(Some("   ")), "");
    // A lone `--` marker carries no argv.
    assert_eq!(start_command_raw(Some("--")), "");
}

#[test]
fn issue580_string_command_is_stored_verbatim() {
    // Stored form is byte-exact so a respawn re-runs exactly this.
    assert_eq!(start_command_raw(Some("cat")), "cat");
    assert_eq!(
        start_command_raw(Some("pwsh -NoLogo -File C:\\tools\\hud.ps1")),
        "pwsh -NoLogo -File C:\\tools\\hud.ps1"
    );
    // Surrounding whitespace is not part of the command.
    assert_eq!(start_command_raw(Some("  cat  ")), "cat");
}

#[test]
fn issue580_argv_form_keeps_its_marker() {
    // `new-window -- prog args` (#582 direct exec): the `--` marker has to
    // survive into storage or a later respawn would re-parse the argv as a
    // shell string.
    assert_eq!(
        start_command_raw(Some("-- pwsh -NoLogo -File C:\\tools\\hud.ps1")),
        "-- pwsh -NoLogo -File C:\\tools\\hud.ps1"
    );
    let argv = vec![
        "pwsh".to_string(),
        "-NoLogo".to_string(),
        "-File".to_string(),
        "C:\\tools\\hud.ps1".to_string(),
    ];
    assert_eq!(
        start_command_raw_argv(&argv),
        "-- pwsh -NoLogo -File C:\\tools\\hud.ps1"
    );
    // A word with a space is quoted so the argv boundaries survive. The
    // stored encoding is internal (#794 made it the exact inverse of
    // decode_argv), so the contract is the round trip and the rendering.
    let spaced = vec!["pwsh".to_string(), "-File".to_string(), "C:\\my tools\\hud.ps1".to_string()];
    let stored = start_command_raw_argv(&spaced);
    let tail = stored.strip_prefix("--").expect("argv form keeps its marker");
    assert_eq!(crate::pane::decode_argv(tail), spaced);
    assert_eq!(start_command_display(&stored), "pwsh -File \"C:\\my tools\\hud.ps1\"");
    assert_eq!(start_command_raw_argv(&[]), "");
}

// ── What `#{pane_start_command}` RENDERS ────────────────────────────────

#[test]
fn issue580_default_shell_pane_renders_empty() {
    // tmux cmd.c:370 — argc == 0 stringifies to "". This is the contract a
    // marker predicate relies on to tell a shell pane from a command pane.
    assert_eq!(start_command_display(""), "");
    assert_eq!(start_command_display("   "), "");
    assert_eq!(start_command_display("--"), "");
}

#[test]
fn issue580_single_word_command_renders_bare() {
    // tmux 3.4 live: `new-window -d cat` -> pane_start_command = `cat`
    // (regress/format-variables.sh:347 asserts the same).
    assert_eq!(start_command_display("cat"), "cat");
    assert_eq!(start_command_display("pwsh.exe"), "pwsh.exe");
}

#[test]
fn issue580_string_command_with_spaces_renders_quoted() {
    // tmux 3.4 live: `new-window -d "sleep 300"` -> `"sleep 300"`, because
    // args_escape quotes a word containing a space.
    assert_eq!(start_command_display("sleep 300"), "\"sleep 300\"");
    // Windows backslashes stay literal: tmux's vis() would double them, which
    // would corrupt the very path a tool matches on.
    assert_eq!(
        start_command_display("pwsh -NoLogo -File C:\\tools\\hud.ps1"),
        "\"pwsh -NoLogo -File C:\\tools\\hud.ps1\""
    );
}

#[test]
fn issue580_argv_form_renders_as_its_token_list() {
    // tmux 3.4 live: `new-window -d sleep 500` (two argv words) -> `sleep 500`
    // with no quoting, because each word is escaped separately.
    assert_eq!(
        start_command_display("-- pwsh -NoLogo -File C:\\tools\\hud.ps1"),
        "pwsh -NoLogo -File C:\\tools\\hud.ps1"
    );
    assert_eq!(start_command_display("-- sleep 500"), "sleep 500");
}

#[test]
fn issue580_a_word_starting_with_dashdash_is_not_the_argv_marker() {
    // tmux's marker is the standalone `--`; `--flagish` is an ordinary word.
    assert_eq!(start_command_display("--version"), "--version");
    assert_eq!(start_command_raw(Some("--version")), "--version");
}

// ── The reporter's predicate ────────────────────────────────────────────

#[test]
fn issue580_marker_predicate_separates_hud_pane_from_shell_pane() {
    const MARKER: &str = "9f3a1c-omx-marker";
    let hud = format!("pwsh -NoLogo -File C:\\tools\\hud_{MARKER}.ps1");
    let hud_rendered = start_command_display(&start_command_raw(Some(&hud)));
    let shell_rendered = start_command_display(&start_command_raw(None));
    // `#{m:*MARKER*,#{pane_start_command}}` is a glob, so the quoting tmux
    // applies does not stop the match; the empty shell value never matches.
    assert!(hud_rendered.contains(MARKER), "HUD pane must carry the marker, got {hud_rendered}");
    assert!(!shell_rendered.contains(MARKER), "default-shell pane must not carry it");
    assert!(shell_rendered.is_empty());
    // Two panes created differently must not collapse to one value (the bug
    // was 24 panes, 1 distinct value).
    assert_ne!(hud_rendered, shell_rendered);
}

// ── Respawn semantics (tmux spawn.c:384) ────────────────────────────────
//
// The stored value is replaced ONLY when the respawn carried a command.
// `respawn_active_pane` implements this as
// `if let Some(c) = new_start_command { pane.start_command = c; }` over
// `command.map(|c| start_command_raw(Some(c)))`, so the decision is exactly
// the `Option` below.

fn respawn_recorded(existing: &str, respawn_command: Option<&str>) -> String {
    let new_start_command = respawn_command.map(|c| start_command_raw(Some(c)));
    let mut stored = existing.to_string();
    if let Some(c) = new_start_command {
        stored = c;
    }
    stored
}

#[test]
fn issue580_respawn_with_a_command_replaces_the_record() {
    assert_eq!(respawn_recorded("cat", Some("sleep 600")), "sleep 600");
    assert_eq!(respawn_recorded("", Some("cat")), "cat");
    assert_eq!(
        start_command_display(&respawn_recorded("cat", Some("sleep 600"))),
        "\"sleep 600\""
    );
}

#[test]
fn issue580_bare_respawn_keeps_the_original_record() {
    // tmux 3.4 live: respawn-pane -k on a pane started with `cat` still
    // reports `cat` afterwards.
    assert_eq!(respawn_recorded("cat", None), "cat");
    // And a default-shell pane stays empty rather than acquiring the shell.
    assert_eq!(respawn_recorded("", None), "");
    assert_eq!(start_command_display(&respawn_recorded("", None)), "");
}
