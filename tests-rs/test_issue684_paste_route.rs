//! Issue #684: the paste route gate, and the `paste-buffer` flags the in
//! server dispatch used to throw away.
//!
//! The route half is pure by construction (`choose_paste_route` takes the four
//! facts as arguments) so the 19045 branch, which is unreachable on any modern
//! host, can still be pinned here.

use crate::commands::{apply_separator, parse_paste_buffer_args, PasteBufferArgs};
use crate::input::{choose_paste_route, PasteRoute, PASTE_PIPE_BRACKET_MIN_BUILD};

const OLD: Option<u32> = Some(19045);
const NEW: Option<u32> = Some(26200);

#[test]
fn gate_constant_matches_the_mouse_gate() {
    // Both describe the same defect in the same direction on the same channel:
    // the inbox conhost below this build does not hand VT written into a ConPTY
    // input pipe to the child.  Documented in input.rs; pinned here so a change
    // to one is a deliberate change, not a silent drift.
    assert_eq!(
        PASTE_PIPE_BRACKET_MIN_BUILD,
        crate::ssh_input::CONPTY_MOUSE_MIN_BUILD
    );
}

#[test]
fn unbracketed_paste_always_takes_the_pipe() {
    // Nothing to protect, so never pay for an AttachConsole round trip.
    for build in [OLD, NEW, None] {
        for vt in [true, false] {
            for forced in [None, Some(true), Some(false)] {
                assert_eq!(
                    choose_paste_route(false, build, vt, forced, false),
                    PasteRoute::Pipe,
                    "build={:?} vt={} forced={:?}",
                    build,
                    vt,
                    forced
                );
            }
        }
    }
}

#[test]
fn old_build_with_a_vt_byte_reader_injects() {
    assert_eq!(
        choose_paste_route(true, OLD, true, None, false),
        PasteRoute::Inject
    );
}

#[test]
fn old_build_with_a_record_reader_keeps_the_pipe() {
    // Issue #98: injected marker bytes reach an INPUT_RECORD reader as the
    // literal characters [ 2 0 0 ~.  The guard holds on every build and under
    // every override.
    assert_eq!(choose_paste_route(true, OLD, false, None, false), PasteRoute::Pipe);
    assert_eq!(
        choose_paste_route(true, OLD, false, Some(true), false),
        PasteRoute::Pipe
    );
    assert_eq!(
        choose_paste_route(true, NEW, false, Some(true), false),
        PasteRoute::Pipe
    );
}

#[test]
fn new_build_keeps_the_pipe_because_it_carries_the_markers() {
    assert_eq!(choose_paste_route(true, NEW, true, None, false), PasteRoute::Pipe);
}

#[test]
fn an_unknown_build_keeps_todays_behaviour() {
    assert_eq!(choose_paste_route(true, None, true, None, false), PasteRoute::Pipe);
}

#[test]
fn the_boundary_build_is_on_the_pipe_side() {
    assert_eq!(
        choose_paste_route(true, Some(PASTE_PIPE_BRACKET_MIN_BUILD), true, None, false),
        PasteRoute::Pipe
    );
    assert_eq!(
        choose_paste_route(true, Some(PASTE_PIPE_BRACKET_MIN_BUILD - 1), true, None, false),
        PasteRoute::Inject
    );
}

#[test]
fn the_override_moves_the_build_half_in_both_directions() {
    // =1 makes a modern host behave like 19045, which is how the route is
    // testable at all on 26200.
    assert_eq!(
        choose_paste_route(true, NEW, true, Some(true), false),
        PasteRoute::Inject
    );
    // =0 pins the pipe on a host the build check would have sent to injection.
    assert_eq!(
        choose_paste_route(true, OLD, true, Some(false), false),
        PasteRoute::Pipe
    );
}

#[test]
fn a_supplied_host_takes_the_pipe_on_an_old_build() {
    // #597: OpenConsole 1.24 under PSMUX_CONPTY_DIR on 19045 carries the
    // markers on the pipe (502 bytes, both markers, wide payload byte exact,
    // measured with PSMUX_PASTE_INJECT=0).  The build number describes the
    // inbox host, so it must not send such a pane through AttachConsole.
    assert_eq!(choose_paste_route(true, OLD, true, None, true), PasteRoute::Pipe);
    assert_eq!(
        choose_paste_route(true, Some(PASTE_PIPE_BRACKET_MIN_BUILD - 1), true, None, true),
        PasteRoute::Pipe
    );
    // Unknown build under a supplied host: still the pipe.
    assert_eq!(choose_paste_route(true, None, true, None, true), PasteRoute::Pipe);
}

#[test]
fn a_supplied_host_never_relaxes_the_other_guards() {
    // =1 still wins, for a supplied host that turns out to strip the markers.
    assert_eq!(
        choose_paste_route(true, OLD, true, Some(true), true),
        PasteRoute::Inject
    );
    // The #98 record reader guard is untouched by the host.
    assert_eq!(
        choose_paste_route(true, OLD, false, Some(true), true),
        PasteRoute::Pipe
    );
    // An unbracketed paste is the pipe under every host.
    assert_eq!(choose_paste_route(false, OLD, true, None, true), PasteRoute::Pipe);
}

// ── paste-buffer flags ────────────────────────────────────────────────────

#[test]
fn bare_paste_buffer_parses_to_defaults() {
    assert_eq!(parse_paste_buffer_args(&[]), PasteBufferArgs::default());
}

#[test]
fn every_flag_is_picked_up() {
    let pb = parse_paste_buffer_args(&["-p", "-d", "-b", "named", "-s", "::", "-t", "sess:1.0"]);
    assert!(pb.bracket);
    assert!(pb.delete);
    assert_eq!(pb.buffer.as_deref(), Some("named"));
    assert_eq!(pb.separator.as_deref(), Some("::"));
    assert_eq!(pb.target.as_deref(), Some("sess:1.0"));
}

#[test]
fn a_flag_value_is_never_read_as_another_flag() {
    // `-b -p` names a buffer called "-p"; it does not switch bracketing on.
    let pb = parse_paste_buffer_args(&["-b", "-p"]);
    assert_eq!(pb.buffer.as_deref(), Some("-p"));
    assert!(!pb.bracket);
}

#[test]
fn dash_r_implies_a_newline_separator_and_dash_s_wins() {
    assert_eq!(parse_paste_buffer_args(&["-r"]).separator.as_deref(), Some("\n"));
    assert_eq!(
        parse_paste_buffer_args(&["-r", "-s", "|"]).separator.as_deref(),
        Some("|")
    );
    assert_eq!(
        parse_paste_buffer_args(&["-s", "|", "-r"]).separator.as_deref(),
        Some("|")
    );
}

#[test]
fn dash_capital_s_is_accepted_and_changes_nothing() {
    assert_eq!(parse_paste_buffer_args(&["-S"]), PasteBufferArgs::default());
}

#[test]
fn no_separator_means_the_pane_writer_decides() {
    assert!(parse_paste_buffer_args(&["-p"]).separator.is_none());
}

#[test]
fn separator_replaces_every_newline() {
    // cmd-paste-buffer.c walks the buffer, writes each line, then the
    // separator, so a trailing newline becomes a trailing separator.
    assert_eq!(apply_separator("a\nb\n", "|"), "a|b|");
    assert_eq!(apply_separator("a\nb", "|"), "a|b");
    assert_eq!(apply_separator("nolines", "|"), "nolines");
    assert_eq!(apply_separator("", "|"), "");
    assert_eq!(apply_separator("\n\n", "-"), "--");
    // Issue #719: a CRLF is ONE line break.  tmux's memchr('\n') split would
    // keep the CR, which on Windows (a CRLF file through load-buffer, a
    // clipboard paste) submits every line twice once the default CR
    // separator is applied.  A lone CR is still data.
    assert_eq!(apply_separator("a\r\nb", "|"), "a|b");
    assert_eq!(apply_separator("a\rb", "|"), "a\rb");
}

// ── the default binding ───────────────────────────────────────────────────

#[test]
fn the_default_bracket_binding_is_paste_buffer_dash_p() {
    // tmux key-bindings.c:422.
    let bind = crate::help::PREFIX_DEFAULTS
        .iter()
        .find(|(k, _)| *k == "]")
        .expect("] must have a default binding");
    assert_eq!(bind.1, "paste-buffer -p");
}

#[test]
fn a_flagged_paste_buffer_binding_keeps_its_whole_command_line() {
    // Action::Paste is a unit variant, so a binding that parsed to it would
    // drop -p on the floor.  That is what made the default binding unbracketed.
    match crate::commands::parse_command_to_action("paste-buffer -p") {
        Some(crate::types::Action::Command(s)) => assert_eq!(s, "paste-buffer -p"),
        _ => panic!("`paste-buffer -p` must keep its command line, not collapse to Action::Paste"),
    }
    assert!(matches!(
        crate::commands::parse_command_to_action("paste-buffer"),
        Some(crate::types::Action::Paste)
    ));
}
