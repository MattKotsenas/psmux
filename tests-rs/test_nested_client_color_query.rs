// Follow-up to #537: a psmux client running inside psmux must never put an OSC
// color query on the wire.
//
// Symptom: attaching a client from inside a psmux pane or popup typed escape
// garbage into the session it attached to:
//
//   PS C:\...> ]10;rgb:cccc/cccc/cccc\]11;rgb:0c0c/0c0c/0c0c\]4;0;rgb:...
//
// and the shell there then tried to execute `rgb:3b3b/7878/ffff\]4` as a
// command. Proven by experiment to be the nested client's own startup burst:
// with PSMUX_HOST_COLORS present on the CLIENT (so the burst is skipped) the
// garbage disappeared; with it absent the garbage returned, while everything
// else in the setup was held constant. A plain non-nested attach never showed
// it.
//
// Mechanism: psmux answers those queries by injecting the replies as console
// KEY_EVENT records (answer_color_queries -> send_vt_response) on a later
// server tick, after the client's 500ms drain window has expired, so the
// leftovers are read by the client's input pump and forwarded as keystrokes.
//
// These tests pin the two halves of the fix: the query is suppressed inside
// psmux, and the parent hands its known colors down instead so the palette
// still survives one level of nesting.

use super::*;

/// Snapshot/restore every env var these tests touch.
struct GuardEnv {
    saved: Vec<(&'static str, Option<String>)>,
}

impl GuardEnv {
    fn new() -> Self {
        let keys = [
            "PSMUX_ACTIVE",
            "PSMUX_SESSION",
            "PSMUX_HOST_COLORS",
            POPUP_CHILD_ENV,
        ];
        let saved = keys
            .iter()
            .map(|k| (*k, std::env::var(k).ok()))
            .collect::<Vec<_>>();
        for (k, _) in &saved {
            std::env::remove_var(k);
        }
        Self { saved }
    }
    fn set(&self, key: &str, value: &str) {
        std::env::set_var(key, value);
    }
}

impl Drop for GuardEnv {
    fn drop(&mut self) {
        for (k, v) in &self.saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
}

fn colors_with_fg() -> crate::types::HostColors {
    crate::types::HostColors::from_spec("fg=010203,bg=040506,dark=1")
}

// ── the predicate that decides whether a query may be issued ────────────

#[test]
fn plain_terminal_is_not_a_psmux_terminal() {
    let _lock = crate::util::lock_test_env();
    let _env = GuardEnv::new();
    assert!(
        !crate::util::psmux_drawn_terminal(),
        "a real terminal must still be queried, that is where colors come from"
    );
}

#[test]
fn pane_child_is_a_psmux_terminal() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    assert!(crate::util::psmux_drawn_terminal());
}

#[test]
fn popup_child_is_a_psmux_terminal() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set(POPUP_CHILD_ENV, "1");
    assert!(
        crate::util::psmux_drawn_terminal(),
        "a popup's terminal is psmux too. inside_psmux_pane() excludes popups \
         for the NESTING guard, but a color query in a popup leaks exactly the \
         same way, which is how #537 surfaced this"
    );
}

/// The trap this predicate exists to avoid.
///
/// `main()` sets PSMUX_ACTIVE=1 on the client process itself (main.rs ~4117)
/// BEFORE it queries the terminal (~4141). If PSMUX_ACTIVE counted as "psmux
/// draws my terminal", every top-level client would skip the query and #473
/// would be silently dead for everyone, with no leak test failing to show it.
#[test]
fn client_process_alone_must_still_query_its_real_terminal() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_ACTIVE", "1");
    assert!(
        !crate::util::psmux_drawn_terminal(),
        "PSMUX_ACTIVE says 'I am a psmux client', NOT 'psmux draws my terminal'. \
         The top-level client sets it on itself before querying the real \
         terminal, so counting it here would suppress host-color detection \
         everywhere and undo #473."
    );
    assert!(
        crate::util::inside_psmux_pane(),
        "it must still count for the NESTING guard, which is a different question"
    );
}

/// The two predicates must disagree on exactly one case: a popup.
#[test]
fn popup_splits_the_two_predicates() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    env.set(POPUP_CHILD_ENV, "1");
    assert!(
        !crate::util::inside_psmux_pane(),
        "#537: a popup is not a nested session, attach must be allowed"
    );
    assert!(
        crate::util::psmux_drawn_terminal(),
        "but a popup IS a psmux terminal, so it must not be queried"
    );
}

// ── the query suppression itself ───────────────────────────────────────

#[test]
fn no_query_is_issued_inside_a_pane() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    assert_eq!(
        crate::platform::query_host_terminal_colors(),
        None,
        "BUG: a nested client queried psmux for colors. The reply is injected \
         as console input later and gets typed into the attached session."
    );
}

#[test]
fn no_query_is_issued_inside_a_popup() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set(POPUP_CHILD_ENV, "1");
    assert_eq!(crate::platform::query_host_terminal_colors(), None);
}

/// The escape hatch and the inheritance path are the same variable, so a nested
/// client that was handed colors reports THOSE rather than querying or going
/// blank.
#[test]
fn planted_colors_are_used_instead_of_querying() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();
    env.set("PSMUX_SESSION", "work");
    env.set("PSMUX_HOST_COLORS", "fg=010203,bg=040506,dark=1");
    let got = crate::platform::query_host_terminal_colors();
    assert!(got.is_some(), "planted colors must be adopted, not discarded");
    let spec = got.unwrap();
    assert!(spec.contains("fg=010203"), "expected planted fg, got {}", spec);
    assert!(spec.contains("bg=040506"), "expected planted bg, got {}", spec);
}

// ── handing the colors down to children ────────────────────────────────

#[test]
fn pane_child_receives_the_parents_colors() {
    let mut builder = portable_pty::CommandBuilder::new("pwsh");
    crate::pane::set_host_colors_env(&mut builder, Some(&colors_with_fg()));
    let got = builder
        .get_env("PSMUX_HOST_COLORS")
        .and_then(|v| v.to_str())
        .unwrap_or("");
    assert!(got.contains("fg=010203"), "child should inherit fg, got {}", got);
    assert!(got.contains("bg=040506"), "child should inherit bg, got {}", got);
}

/// When the parent knows nothing, the variable must be CLEARED, not left at
/// whatever this process happened to inherit. A stale palette outliving the
/// terminal it was measured on is worse than no palette.
#[test]
fn unknown_colors_clear_the_variable_on_the_child() {
    let mut builder = portable_pty::CommandBuilder::new("pwsh");
    builder.env("PSMUX_HOST_COLORS", "fg=ffffff,bg=000000");
    crate::pane::set_host_colors_env(&mut builder, None);
    assert!(
        builder.get_env("PSMUX_HOST_COLORS").is_none(),
        "an unknown palette must not be inherited from a previous terminal"
    );
}

#[test]
fn empty_colors_clear_the_variable_on_the_child() {
    let mut builder = portable_pty::CommandBuilder::new("pwsh");
    builder.env("PSMUX_HOST_COLORS", "fg=ffffff");
    let empty = crate::types::HostColors::from_spec("");
    crate::pane::set_host_colors_env(&mut builder, Some(&empty));
    assert!(
        builder.get_env("PSMUX_HOST_COLORS").is_none(),
        "a HostColors carrying nothing is the same as knowing nothing"
    );
}

/// Round trip: what the parent plants is what a nested client would read back,
/// so one level of nesting keeps the real terminal's palette.
#[test]
fn planted_colors_round_trip_through_a_nested_client() {
    let _lock = crate::util::lock_test_env();
    let env = GuardEnv::new();

    let mut builder = portable_pty::CommandBuilder::new("pwsh");
    let parent = crate::types::HostColors::from_spec("fg=112233,bg=445566,0=778899,dark=0");
    crate::pane::set_host_colors_env(&mut builder, Some(&parent));
    let planted = builder
        .get_env("PSMUX_HOST_COLORS")
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_string();

    // Now stand in the child's shoes: pane env set, reading the planted value.
    env.set("PSMUX_SESSION", "work");
    env.set("PSMUX_HOST_COLORS", &planted);
    let child = crate::platform::query_host_terminal_colors().unwrap_or_default();
    let hc = crate::types::HostColors::from_spec(&child);
    assert_eq!(hc.fg, Some((0x11, 0x22, 0x33)), "fg lost across nesting");
    assert_eq!(hc.bg, Some((0x44, 0x55, 0x66)), "bg lost across nesting");
    assert_eq!(hc.palette[0], Some((0x77, 0x88, 0x99)), "palette lost across nesting");
    assert_eq!(hc.dark, Some(false), "scheme flag lost across nesting");
}
