// Issue #597 (follow up): where a reply goes when console injection fails.
//
// A reporter on Windows 10 19045 measured every reply psmux injects into a pane
// arriving as zero bytes, with `AttachConsole FAILED err=5` in the mouse debug
// log, and read the OSC colour path's pipe fallback as a second channel that
// was also broken.  It was never a second channel on Windows.  Measured on
// build 26200 by writing each shape straight into a live pane's ConPTY input
// pipe and dumping the child's stdin:
//
//   payload                                  what the child received
//   "A"                                      "A"
//   CSI  ESC [ ? 997 ; 1 n                   ESC [ ? 997 ; 1 n   (byte exact)
//   OSC  ESC ] 4 ; 2 ; rgb:... ESC \         nothing at all
//   DCS  ESC P > | tmux 9.9.9 ESC \          a bare ESC, body eaten
//
// So a CSI reply survives the pipe and an OSC does not, which is why the
// colour path injects in the first place; and a DCS is worse than lost,
// because a lone ESC is an Escape keypress to whatever is reading the pane.
// The rule below follows those measurements: keep the pipe where it is the
// only channel and is known to carry the bytes, and say the reply was lost
// where it is not.

use crate::server::helpers::{osc_delivery_fallback, OscFallback};

#[test]
fn windows_with_a_known_pid_has_no_second_channel() {
    // Injection was attempted and failed.  ConPTY eats an OSC on the pipe, so
    // writing it there delivers nothing; the reply is lost and says so.
    let got = osc_delivery_fallback(true);
    if cfg!(windows) {
        assert_eq!(got, OscFallback::Lost);
    } else {
        assert_eq!(got, OscFallback::Pipe);
    }
}

#[test]
fn no_child_pid_still_uses_the_pipe() {
    // psmux never learned the pane child's process id, so injection was never
    // attempted.  The pipe is all there is, and on a host whose ConPTY does
    // forward it, it works.
    assert_eq!(osc_delivery_fallback(false), OscFallback::Pipe);
}

#[test]
fn the_decision_depends_only_on_whether_a_pid_was_known() {
    // Two calls with the same input must agree: nothing here reads global
    // state, so a pane cannot get a different answer on a later query.
    assert_eq!(osc_delivery_fallback(true), osc_delivery_fallback(true));
    assert_eq!(osc_delivery_fallback(false), osc_delivery_fallback(false));
}

#[test]
fn a_pipe_only_platform_never_loses_a_reply() {
    // The non-Windows arm must never choose Lost: there is no ConPTY in front
    // of the pipe there, so the fallback is a real delivery.
    if !cfg!(windows) {
        assert_eq!(osc_delivery_fallback(true), OscFallback::Pipe);
        assert_eq!(osc_delivery_fallback(false), OscFallback::Pipe);
    }
}
