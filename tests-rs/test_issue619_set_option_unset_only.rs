// Issue #619 item 2: `set-option -o` after `set-option -u` was silently
// ignored for every option except the two that PR #617 repaired.
//
// psmux tracks "the user set this explicitly" in `AppState::user_set_options`,
// and `-o` (only set if not already set) consults that set. The unset branch
// erased the entry only for `window-style` and `window-active-style`, so for
// every other non `@` option the key survived `-u` and the `-o` guard kept
// reading the option as set. The sequence
//
//     set -g escape-time 5
//     set -gu escape-time
//     set -go escape-time 77
//
// therefore left escape-time at its 500 ms default and dropped the 77.
//
// tmux semantics being matched, from cmd-set-option.c:
//
//     /* With -o, check this option is not already set. */
//     if (!args_has(args, 'u') && args_has(args, 'o')) {
//             if (array_key == NULL)
//                     already = (o != NULL);
//             ...
//             if (already) {
//                     if (args_has(args, 'q'))
//                             goto out;
//                     cmdq_error(item, "already set: %s", argument);
//                     goto fail;
//             }
//     }
//
// with `o = options_get_only(oo, name)`, so `-o` is judged purely on whether
// anything is set at that scope. `-u` runs options_remove_or_default first
// (same file), which clears the option there, so a following `-o` finds
// nothing and applies. Note also that the guard is skipped entirely when `-u`
// is present, so `-uo` in one token is an unset, never a set.
//
// A `@user` option carries no options table entry, so options.c
// options_remove_or_default takes its `options_remove(o)` branch and deletes
// the key outright rather than restoring a default. psmux now does the same:
// `-o` tests user options with `user_options.contains_key`, so an entry left
// holding an empty string would have read as set for ever.
//
// The live CLI, TCP, config-file and attached-client routes are covered by
// tests/test_issue619_set_option_unset_only.ps1.

#[allow(unused_imports)]
use super::*;

use crate::commands::execute_command_string;
use crate::config::{parse_config_content, parse_config_line};
use crate::server::options::get_option_value;
use crate::types::AppState;

fn mock_app() -> AppState {
    AppState::new("srv619".to_string())
}

// ---------------------------------------------------------------------------
// The reported sequence, one representative option per value type.
// ---------------------------------------------------------------------------

#[test]
fn unset_then_only_if_unset_applies_for_integer_option() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g escape-time 5\nset -gu escape-time\nset -go escape-time 77\n",
    );
    assert_eq!(
        app.escape_time_ms, 77,
        "set -go after set -gu must apply; it used to be swallowed and leave the old value"
    );
}

#[test]
fn unset_then_only_if_unset_applies_for_string_option() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g status-left AAA\nset -gu status-left\nset -go status-left ZZZ\n",
    );
    assert_eq!(app.status_left, "ZZZ");
}

#[test]
fn unset_then_only_if_unset_applies_for_boolean_option() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g mouse on\nset -gu mouse\n");
    assert!(
        !app.user_set_options.contains("mouse"),
        "the unset must drop the explicit-set mark, or -go below is refused"
    );
    parse_config_line(&mut app, "set -go mouse off");
    assert!(
        !app.mouse_enabled,
        "the boolean must take the -go value, not stay at its default"
    );

    // The other direction, where the -go value differs from the default, is
    // what the CLI repro showed: mouse defaults to on, so `-go off` staying on
    // was the visible symptom.
    let mut app2 = mock_app();
    parse_config_content(
        &mut app2,
        "set -g mouse off\nset -gu mouse\nset -go mouse on\n",
    );
    assert!(app2.mouse_enabled, "-go on after -gu must apply");
}

#[test]
fn unset_then_only_if_unset_applies_for_style_option() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g status-style fg=red\nset -gu status-style\nset -go status-style fg=blue\n",
    );
    assert_eq!(app.status_style, "fg=blue");
}

#[test]
fn unset_then_only_if_unset_applies_for_history_limit() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g history-limit 1234\nset -gu history-limit\nset -go history-limit 4321\n",
    );
    assert_eq!(app.history_limit, 4321);
}

// ---------------------------------------------------------------------------
// Every scope spelling: -g, session scope with no -g, setw, -s (#618).
// ---------------------------------------------------------------------------

#[test]
fn unset_then_only_if_unset_applies_without_the_global_flag() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set escape-time 5\nset -u escape-time\nset -o escape-time 66\n",
    );
    assert_eq!(app.escape_time_ms, 66, "session scope must behave like -g");
}

#[test]
fn unset_then_only_if_unset_applies_for_window_option_via_setw() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "setw -g window-status-separator XX\n\
         setw -gu window-status-separator\n\
         setw -go window-status-separator YY\n",
    );
    assert_eq!(app.window_status_separator, "YY");
}

#[test]
fn unset_then_only_if_unset_applies_for_set_window_option_spelling() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set-window-option -g window-status-separator XX\n\
         set-window-option -gu window-status-separator\n\
         set-window-option -go window-status-separator ZZ\n",
    );
    assert_eq!(app.window_status_separator, "ZZ");
}

#[test]
fn unset_then_only_if_unset_applies_for_server_scope() {
    // -s is the server scope #618 added; it resolves to the same single store
    // as -g in psmux, so it must clear the explicit-set mark the same way.
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -s default-terminal xterm-256color\n\
         set -su default-terminal\n\
         set -so default-terminal screen-256color\n",
    );
    assert_eq!(get_option_value(&app, "default-terminal"), "screen-256color");
}

// ---------------------------------------------------------------------------
// `@user` options: the issue expected these to work already. They did on the
// server route, but NOT through the config parser, because `-u` blanked the
// entry in place and left the key for `-o` to trip over.
// ---------------------------------------------------------------------------

#[test]
fn unset_then_only_if_unset_applies_for_user_option() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g @i619u one\nset -gu @i619u\nset -go @i619u two\n");
    assert_eq!(
        app.user_options.get("@i619u").map(|s| s.as_str()),
        Some("two"),
        "a @user option must be settable again after -u"
    );
}

#[test]
fn unset_removes_the_user_option_key_rather_than_blanking_it() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g @i619gone one\nset -gu @i619gone\n");
    assert!(
        app.user_options.get("@i619gone").is_none(),
        "tmux removes a user option on -u because it has no table default"
    );
}

// ---------------------------------------------------------------------------
// The #617 pair must keep working: the generic erase subsumes the special case.
// ---------------------------------------------------------------------------

#[test]
fn window_style_still_settable_after_unset() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g window-style bg=black\n\
         set -gu window-style\n\
         set -go window-style bg=colour235\n",
    );
    assert_eq!(
        app.user_options.get("window-style").map(|s| s.as_str()),
        Some("bg=colour235"),
        "#617 must not regress"
    );
}

#[test]
fn window_active_style_still_settable_after_unset() {
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g window-active-style bg=black\n\
         set -gu window-active-style\n\
         set -go window-active-style bg=colour236\n",
    );
    assert_eq!(
        app.user_options.get("window-active-style").map(|s| s.as_str()),
        Some("bg=colour236")
    );
}

// ---------------------------------------------------------------------------
// The guard itself must stay armed: -o on an option that IS set is a no-op.
// ---------------------------------------------------------------------------

#[test]
fn only_if_unset_is_still_a_no_op_when_the_option_is_set() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g escape-time 11\nset -go escape-time 22\n");
    assert_eq!(
        app.escape_time_ms, 11,
        "-o must not overwrite a value the user already set"
    );
}

#[test]
fn only_if_unset_is_still_a_no_op_for_a_set_user_option() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g @i619keep first\nset -go @i619keep second\n");
    assert_eq!(
        app.user_options.get("@i619keep").map(|s| s.as_str()),
        Some("first")
    );
}

#[test]
fn only_if_unset_applies_on_a_never_set_option() {
    let mut app = mock_app();
    parse_config_line(&mut app, "set -go @i619fresh freshvalue");
    assert_eq!(
        app.user_options.get("@i619fresh").map(|s| s.as_str()),
        Some("freshvalue")
    );
}

// ---------------------------------------------------------------------------
// tmux skips the -o guard entirely when -u is also present, so `-uo` unsets.
// ---------------------------------------------------------------------------

#[test]
fn unset_wins_over_only_if_unset_in_one_token() {
    let mut app = mock_app();
    parse_config_content(&mut app, "set -g status-left PRE\nset -guo status-left NEVER\n");
    assert_ne!(
        app.status_left, "NEVER",
        "-u present means the command is an unset, never a set (cmd-set-option.c)"
    );
}

// ---------------------------------------------------------------------------
// The same sequence through the TUI command prompt / command dispatch route,
// which forwards set-option into the config parser (src/commands.rs).
// ---------------------------------------------------------------------------

#[test]
fn command_dispatch_unset_then_only_if_unset_applies() {
    let mut app = mock_app();
    execute_command_string(&mut app, "set-option -g escape-time 5").unwrap();
    execute_command_string(&mut app, "set-option -gu escape-time").unwrap();
    execute_command_string(&mut app, "set-option -go escape-time 77").unwrap();
    assert_eq!(app.escape_time_ms, 77);
}

#[test]
fn command_dispatch_unset_then_only_if_unset_applies_for_user_option() {
    let mut app = mock_app();
    execute_command_string(&mut app, "set-option -g @i619cmd one").unwrap();
    execute_command_string(&mut app, "set-option -gu @i619cmd").unwrap();
    execute_command_string(&mut app, "set-option -go @i619cmd two").unwrap();
    assert_eq!(
        app.user_options.get("@i619cmd").map(|s| s.as_str()),
        Some("two")
    );
}

#[test]
fn command_dispatch_unset_clears_the_explicit_set_mark() {
    // The tracker is the mechanism under test, so assert on it directly: the
    // key used to survive -u for everything but the #617 pair.
    let mut app = mock_app();
    for opt in [
        "escape-time",
        "status-left",
        "history-limit",
        "status-style",
        "window-status-separator",
    ] {
        execute_command_string(&mut app, &format!("set-option -g {} 1", opt)).unwrap();
        assert!(
            app.user_set_options.contains(opt),
            "{} should be marked as explicitly set",
            opt
        );
        execute_command_string(&mut app, &format!("set-option -gu {}", opt)).unwrap();
        assert!(
            !app.user_set_options.contains(opt),
            "{} kept its explicit-set mark through -u, so -o would be ignored",
            opt
        );
    }
}

#[test]
fn unset_alias_capital_u_also_clears_the_mark() {
    // -U is the unset alias added for #553; it must clear the mark too.
    let mut app = mock_app();
    parse_config_content(
        &mut app,
        "set -g escape-time 5\nset -gU escape-time\nset -go escape-time 88\n",
    );
    assert_eq!(app.escape_time_ms, 88);
}
