//! Issue #647 (WIN-02): `show-options -p -v` must print the value alone.
//!
//! The reporter drives psmux from a gateway controller that compares the
//! stdout of `show-options -p -v -t %0 remain-on-exit` with `on` / `off`.
//! psmux answered `remain-on-exit on` because the pane scope branch ignored
//! both the option name and `-v` and simply echoed the whole pane store.
//!
//! tmux resolves the single entry and then prints the value alone under `-v`:
//!
//!   cmd-show-options.c:192-194
//!       value = options_to_string(o, array_key, 0);
//!       if (args_has(args, 'v'))
//!               cmdq_print(item, "%s", value);
//!
//! and prints nothing at all when the option is not present in that scope's
//! own store, unless `-A` asks for the inherited value, which is then marked
//! with a `*` (cmd-show-options.c:195-207). Measured against tmux 3.4 in WSL:
//!
//!   show-options -p -v -t %0 remain-on-exit   => [] rc=0        (unset)
//!   show-options -pA -v -t %0 remain-on-exit  => [off] rc=0     (inherited)
//!   show-options -p -v -t %0 remain-on-exit   => [on] rc=0      (after set -p)
//!   show-options -p -t %0 remain-on-exit      => [remain-on-exit on]

use crate::server::options::select_pane_option_line;

fn none(_: &str) -> Option<String> {
    None
}

#[test]
fn value_only_under_v() {
    let listing = "remain-on-exit on";
    assert_eq!(
        select_pane_option_line(listing, "remain-on-exit", true, false, none),
        "on\n"
    );
}

#[test]
fn name_and_value_without_v() {
    let listing = "remain-on-exit on";
    assert_eq!(
        select_pane_option_line(listing, "remain-on-exit", false, false, none),
        "remain-on-exit on\n"
    );
}

#[test]
fn other_entries_are_not_printed() {
    // The pane store holds both supported options; a named query answers with
    // exactly one line, never the whole store.
    let listing = "@mouse-force on\nremain-on-exit failed";
    assert_eq!(
        select_pane_option_line(listing, "remain-on-exit", true, false, none),
        "failed\n"
    );
    assert_eq!(
        select_pane_option_line(listing, "@mouse-force", true, false, none),
        "on\n"
    );
}

#[test]
fn unset_option_prints_nothing() {
    // tmux: `show-options -p -v -t %0 remain-on-exit` before any `set -p`
    // prints an empty line count, exit 0.
    assert_eq!(
        select_pane_option_line("", "remain-on-exit", true, false, none),
        ""
    );
    assert_eq!(
        select_pane_option_line("@mouse-force on", "remain-on-exit", false, false, none),
        ""
    );
}

#[test]
fn dash_a_falls_back_to_the_inherited_value() {
    let inherited = |name: &str| {
        assert_eq!(name, "remain-on-exit");
        Some("off".to_string())
    };
    assert_eq!(
        select_pane_option_line("", "remain-on-exit", true, true, inherited),
        "off\n"
    );
    let inherited = |_: &str| Some("off".to_string());
    assert_eq!(
        select_pane_option_line("", "remain-on-exit", false, true, inherited),
        "remain-on-exit* off\n"
    );
}

#[test]
fn dash_a_prefers_the_pane_value_when_it_is_set() {
    let inherited = |_: &str| Some("off".to_string());
    assert_eq!(
        select_pane_option_line("remain-on-exit on", "remain-on-exit", true, true, inherited),
        "on\n"
    );
}

#[test]
fn an_empty_inherited_value_is_not_printed() {
    let inherited = |_: &str| None;
    assert_eq!(
        select_pane_option_line("", "@mouse-force", true, true, inherited),
        ""
    );
}

#[test]
fn a_server_refusal_is_handed_back_untouched() {
    // `show-options -p -t %99` against a pane that does not exist must still
    // report the refusal rather than being swallowed by the name filter.
    assert_eq!(
        select_pane_option_line("ERROR: can't find pane: %99", "remain-on-exit", true, false, none),
        "ERROR: can't find pane: %99\n"
    );
}

#[test]
fn a_value_with_spaces_survives_the_split() {
    let listing = "@mouse-force on off";
    assert_eq!(
        select_pane_option_line(listing, "@mouse-force", true, false, none),
        "on off\n"
    );
}

#[test]
fn a_name_prefix_does_not_match() {
    // `remain` must not answer for `remain-on-exit`: tmux matches the resolved
    // option name exactly once options_match has expanded any abbreviation.
    assert_eq!(
        select_pane_option_line("remain-on-exit on", "remain", true, false, none),
        ""
    );
}
