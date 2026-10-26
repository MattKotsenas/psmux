// Tests for issue #459: runaway process spawn from unbounded hook accumulation.
//
// Root cause: `set-hook -ga <hook> '<cmd>'` (append mode) blind-pushed the
// command onto the hook list every time it ran. A config that registers a
// `status-interval` run-shell handler and is re-sourced repeatedly (e.g. a
// plugin panel firing "Configuration reloaded" on every navigation) would
// accumulate one duplicate handler per reload. Each status-interval tick then
// fired ALL accumulated copies, spawning N processes per tick and climbing
// without bound (the reporter saw ~400 pwsh.exe).
//
// Fix: dedup on append. An identical command already present in the hook list
// is not appended again, mirroring the replace-path dedup added for issue #133.
// Distinct handlers (different command strings) still append, preserving the
// tmux multi-handler semantics.

use super::*;

fn mock_app() -> AppState {
    AppState::new("test_session".to_string())
}

// The exact psmux-cpu plugin shape: a status-interval hook that run-shells a
// pwsh stats script, plus an append.
const CPU_HOOK: &str =
    r#"set-hook -ga status-interval 'run-shell "pwsh -NoProfile -File stats.ps1"'"#;

// ═══════════════════════════════════════════════════════════════════
//  Core regression: re-sourcing must NOT accumulate duplicate handlers
// ═══════════════════════════════════════════════════════════════════

#[test]
fn append_same_command_does_not_accumulate_on_resource() {
    let mut app = mock_app();
    // Simulate 25 config reloads of the same plugin line.
    for _ in 0..25 {
        parse_config_line(&mut app, CPU_HOOK);
    }
    let handlers = app.hooks.get("status-interval").expect("hook registered");
    assert_eq!(
        handlers.len(),
        1,
        "BUG #459: {} duplicate status-interval handlers accumulated across 25 reloads (each fires a process per tick)",
        handlers.len()
    );
}

#[test]
fn append_via_parse_config_content_bounded() {
    let mut app = mock_app();
    // Whole-config re-source, 50 times.
    let content = format!("{}\n", CPU_HOOK);
    for _ in 0..50 {
        parse_config_content(&mut app, &content);
    }
    let handlers = app.hooks.get("status-interval").unwrap();
    assert_eq!(handlers.len(), 1, "status-interval handler must stay deduped across whole-config reloads");
}

// ═══════════════════════════════════════════════════════════════════
//  Distinct handlers must STILL append (multi-plugin tmux semantics)
// ═══════════════════════════════════════════════════════════════════

#[test]
fn distinct_handlers_still_append() {
    let mut app = mock_app();
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "cpu.ps1"'"#);
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "mem.ps1"'"#);
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "net.ps1"'"#);
    let handlers = app.hooks.get("status-interval").unwrap();
    assert_eq!(handlers.len(), 3, "three distinct handlers should all register");
}

#[test]
fn distinct_handlers_survive_resource_but_no_dupes() {
    let mut app = mock_app();
    let content = concat!(
        "set-hook -ga status-interval 'run-shell \"cpu.ps1\"'\n",
        "set-hook -ga status-interval 'run-shell \"mem.ps1\"'\n",
    );
    for _ in 0..10 {
        parse_config_content(&mut app, content);
    }
    let handlers = app.hooks.get("status-interval").unwrap();
    assert_eq!(handlers.len(), 2, "two distinct handlers, no dupes after 10 reloads");
}

// ═══════════════════════════════════════════════════════════════════
//  Replace mode (-g without -a) still fully replaces
// ═══════════════════════════════════════════════════════════════════

#[test]
fn replace_mode_stays_single() {
    let mut app = mock_app();
    for _ in 0..10 {
        parse_config_line(&mut app, r#"set-hook -g status-interval 'run-shell "cpu.ps1"'"#);
    }
    let handlers = app.hooks.get("status-interval").unwrap();
    assert_eq!(handlers.len(), 1, "replace mode must keep exactly one handler");
}

#[test]
fn append_then_replace_collapses_to_one() {
    let mut app = mock_app();
    // Append three distinct, then a replace wipes back to one.
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "a.ps1"'"#);
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "b.ps1"'"#);
    parse_config_line(&mut app, r#"set-hook -g status-interval 'run-shell "only.ps1"'"#);
    let handlers = app.hooks.get("status-interval").unwrap();
    assert_eq!(handlers.len(), 1);
    assert!(handlers[0].contains("only.ps1"), "replace should install just the new handler");
}

// ═══════════════════════════════════════════════════════════════════
//  Generalizes to any hook name, not just status-interval
// ═══════════════════════════════════════════════════════════════════

#[test]
fn client_attached_hook_also_deduped() {
    let mut app = mock_app();
    for _ in 0..15 {
        parse_config_line(
            &mut app,
            r#"set-hook -ga client-attached 'run-shell "pwsh -File stats.ps1"'"#,
        );
    }
    let handlers = app.hooks.get("client-attached").unwrap();
    assert_eq!(handlers.len(), 1, "client-attached append must dedup too");
}

// ═══════════════════════════════════════════════════════════════════
//  unset (-u) still clears the hook entirely
// ═══════════════════════════════════════════════════════════════════

#[test]
fn unset_clears_accumulated_hook() {
    let mut app = mock_app();
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "cpu.ps1"'"#);
    parse_config_line(&mut app, r#"set-hook -ga status-interval 'run-shell "mem.ps1"'"#);
    assert!(app.hooks.contains_key("status-interval"));
    parse_config_line(&mut app, "set-hook -gu status-interval");
    assert!(
        !app.hooks.contains_key("status-interval"),
        "unset should remove the whole hook"
    );
}
