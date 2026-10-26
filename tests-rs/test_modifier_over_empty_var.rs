//! A modifier over an empty-but-real variable must render nothing, not the
//! variable's own name.
//!
//! `expand_var` returned `""` both for "this is not a variable" and for "this
//! is a variable whose value is currently empty". `expand_var_or_format`
//! treated any empty result as the former and fell back to echoing the target
//! as a literal, so `#{b:pane_path}` rendered the text `pane_path` whenever the
//! shell had not yet announced a path via OSC 7.
//!
//! That made every optional variable unusable behind a modifier, and it failed
//! in the worst possible way: not blank, not an error, but plausible-looking
//! text sitting in the status bar. A bare `#{pane_path}` was always correct, so
//! the bug only surfaced once a modifier was added.
//!
//! The literal-echo fallback is deliberate tmux-ish behaviour for genuinely
//! unknown names and is kept — these tests pin the boundary between the two.

use super::*;

fn app() -> AppState {
    let mut a = AppState::new("modvar".to_string());
    a.window_base_index = 0;
    a
}

/// The realistic case: a live server always has at least one window, so this is
/// the path the status bar actually takes.
fn app_with_window() -> AppState {
    let mut a = app();
    a.windows.push(crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: "shell".to_string(),
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
    });
    a
}

/// The exact reported case. `pane_path` is pure OSC 7; with no window and no
/// pane it is legitimately empty.
#[test]
fn basename_of_an_empty_pane_path_is_empty() {
    let out = expand_expression("b:pane_path", &app(), 0);
    assert_eq!(
        out, "",
        "#{{b:pane_path}} rendered {:?} — an empty variable behind a modifier \
         must render nothing, not its own name",
        out
    );
}

/// Same shape, other modifiers: the fix belongs in the shared target-resolution
/// step, not in one modifier.
#[test]
fn other_modifiers_over_an_empty_var_are_also_empty() {
    let a = app();
    for expr in ["d:pane_path", "q:pane_path", "=3:pane_path"] {
        let out = expand_expression(expr, &a, 0);
        assert_eq!(
            out, "",
            "#{{{}}} rendered {:?}; expected empty",
            expr, out
        );
    }
}

/// A bare reference was always correct — pin it so a fix to the modifier path
/// cannot regress the simple case.
#[test]
fn a_bare_empty_var_is_still_empty() {
    assert_eq!(expand_expression("pane_path", &app(), 0), "");
}

/// A variable with a real value must still flow through the modifier.
#[test]
fn a_modifier_over_a_populated_var_still_works() {
    assert_eq!(
        expand_expression("=3:session_name", &app(), 0),
        "mod",
        "trim modifier over a populated variable"
    );
}

/// The literal-echo fallback for genuinely unknown names is intentional and
/// must survive: it is how `#{=3:some literal}` style usage degrades. Checked
/// on the windowed path, which is the one a live server always takes.
#[test]
fn a_genuinely_unknown_name_still_echoes_as_a_literal() {
    let out = expand_expression("b:definitely_not_a_psmux_variable", &app_with_window(), 0);
    assert_eq!(
        out, "definitely_not_a_psmux_variable",
        "unknown names should still fall back to the literal target"
    );
}

/// With NO window, an unresolvable name renders empty rather than echoing
/// itself.
///
/// This is a deliberate narrowing. Previously the no-window path could not tell
/// "real pane variable, no pane to read it from" apart from "not a variable",
/// so BOTH echoed the name — which is how a transient windowless moment could
/// paint the text `pane_path` into the status bar. Erring toward empty is the
/// safe direction: a blank pill is a non-event, a pill containing the words
/// `pane_current_path` looks like a corrupted config.
#[test]
fn with_no_window_an_unresolvable_name_renders_empty() {
    assert_eq!(expand_expression("b:pane_path", &app(), 0), "");
    assert_eq!(expand_expression("b:definitely_not_a_psmux_variable", &app(), 0), "");
}

/// The windowed path must also get the empty-variable case right — this is the
/// actual reported bug, on the actual code path.
#[test]
fn basename_of_an_empty_pane_path_is_empty_with_a_window_too() {
    let out = expand_expression("b:pane_path", &app_with_window(), 0);
    assert_eq!(
        out, "",
        "#{{b:pane_path}} rendered {:?} on the windowed path",
        out
    );
}

/// The sentinel used to carry "unknown" out of the resolver must never reach a
/// caller. It contains a NUL, which would be visible corruption in the bar.
#[test]
fn the_unknown_sentinel_never_leaks_into_output() {
    let a = app();
    for expr in [
        "pane_path",
        "b:pane_path",
        "not_a_variable",
        "b:not_a_variable",
        "session_name",
    ] {
        let out = expand_expression(expr, &a, 0);
        assert!(
            !out.contains('\u{0}'),
            "#{{{}}} leaked the unknown-variable sentinel: {:?}",
            expr,
            out
        );
    }
    assert!(!expand_var("not_a_variable", &a, 0).contains('\u{0}'));
}

/// End-to-end through the real status-bar entry point, in the shape the
/// reported config actually uses.
#[test]
fn a_status_right_style_format_renders_cleanly_with_no_osc7() {
    let out = expand_format("[#{b:pane_path}]", &app());
    assert_eq!(
        out, "[]",
        "a cwd pill with no OSC 7 yet must render empty, not {:?}",
        out
    );
}
