//! Issue #598: a fragmented paste reached the pane as several bracketed pastes.
//!
//! larroy pastes from iTerm2 on a Mac, over plain ssh, into an attached psmux.
//! Driven from a real Unix ssh client under a real pty
//! (`tests/test_issue598_ssh_paste_unix_client.ps1`), a three line clipboard
//! fed to the pty five bytes at a time, twenty milliseconds apart, reached the
//! pane's program like this on `0af98f6`:
//!
//! ```text
//!   ESC[200~ line one CR ESC[201~ LF ESC[200~ line two CR ESC[201~ LF ESC[200~ line three ESC[201~
//! ```
//!
//! Three separate bracketed pastes with a literal LF between them. A shell with
//! bracketed paste on ends its paste at each `ESC[201~` and runs the LF, so the
//! clipboard executes line by line instead of landing as a block. On `66cf613`,
//! the release larroy came from, the same input produced ONE gesture.
//!
//! Bisected to `5e16dcf` (#642), "the VT input path reads 0x0a as C-j, not as a
//! plain Enter": `d69c310` one gesture, `5e16dcf` three, two runs each.
//!
//! ## Why that commit did it, and why it was still right
//!
//! Ctrl+J IS the byte 0x0a, so decoding a bare one as `C-j` is correct and is
//! what made a `C-j` prefix work over SSH. Inside a paste, though, 0x0a is the
//! LF of a CRLF, and a DECODED KEY ENDS THE CLIENT'S TEXT RUN: the client
//! flushes what it has as one `send-paste`, sends `C-j` on its own, and opens a
//! fresh paste for the next line. One paste per line.
//!
//! psmux only has to make this decision at all because sshd's ConPTY destroys
//! the `ESC[200~` marker when the paste arrives in small enough pieces. The
//! client trace shows `ESC [ 0 n ESC [ 0 n ~` arriving in place of
//! `ESC [ 2 0 0 ~`, so the VT parser never enters its Paste state and the
//! text-burst heuristic is all that is left. That mangling is a ConPTY defect
//! and is out of psmux's reach; delivering the clipboard as one gesture anyway
//! is not.
//!
//! ## The rule
//!
//! An LF is the tail of a line ending, not a keypress, when either holds:
//!
//!   * a CR came immediately before it. This is timing free on purpose, and it
//!     is the half that carries the reproduction: the 20 ms text window cannot
//!     decide a CRLF whose two bytes land in separate console reads, which is
//!     exactly what a fragmented paste does.
//!   * ordinary text arrived within `TEXT_BURST_MS`. This catches a paste
//!     carrying BARE LFs, the shape a Unix file gives a Mac clipboard.
//!
//! Anything else is `C-j`, so #642 keeps everything it asked for: a real
//! keypress opens its own burst and has no CR in front of it.
//!
//! This is the same rule #654 already applies to the `[` of an extended key, on
//! the same window and for the same reason: a decoder must not eat the user's
//! own clipboard.

use super::*;
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use std::thread::sleep;
use std::time::Duration;

/// Feed a string one character at a time, as fast as the loop goes, which is
/// how a paste arrives.
fn parse_vt(s: &str) -> Vec<Event> {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    for ch in s.chars() {
        p.feed(ch, &mut |evt| events.push(evt));
    }
    events
}

fn keys(events: &[Event]) -> Vec<KeyEvent> {
    events
        .iter()
        .filter_map(|e| match e {
            Event::Key(k) => Some(*k),
            _ => None,
        })
        .collect()
}

fn is_ctrl_j(k: &KeyEvent) -> bool {
    k.code == KeyCode::Char('j') && k.modifiers == KeyModifiers::CONTROL
}

fn enter() -> KeyEvent {
    KeyEvent::new(KeyCode::Enter, KeyModifiers::empty())
}

// ── The regression ───────────────────────────────────────────────────────────

/// The reported shape: a CRLF inside pasted text must not produce a key that
/// ends the run.
#[test]
fn crlf_in_pasted_text_produces_no_ctrl_j() {
    let ks = keys(&parse_vt("line one\r\nline two\r\nline three"));
    assert!(
        !ks.iter().any(is_ctrl_j),
        "a pasted CRLF decoded as C-j, which splits the paste: {:?}",
        ks
    );
}

/// And it produces exactly ONE line ending per CRLF, not two.
///
/// Before #642 the `'\r' | '\n'` arm gave an Enter for each half, so a three
/// line paste carried four line endings into the pane. The recorder saw
/// `line one CR CR line two CR CR line three`.
#[test]
fn each_crlf_collapses_to_one_enter() {
    let ks = keys(&parse_vt("a\r\nb\r\nc"));
    let enters = ks.iter().filter(|k| k.code == KeyCode::Enter).count();
    assert_eq!(enters, 2, "expected one Enter per CRLF, got {:?}", ks);
    let text: String = ks
        .iter()
        .filter_map(|k| match k.code {
            KeyCode::Char(c) => Some(c),
            _ => None,
        })
        .collect();
    assert_eq!(text, "abc", "characters were lost or added: {:?}", ks);
}

/// A paste with BARE LFs, the shape a Unix file gives a Mac clipboard. The CR
/// pairing cannot help here, so the text window has to.
#[test]
fn bare_lf_inside_a_text_run_is_a_line_ending() {
    let ks = keys(&parse_vt("line one\nline two"));
    assert!(
        !ks.iter().any(is_ctrl_j),
        "a bare LF in a text run decoded as C-j: {:?}",
        ks
    );
    assert_eq!(ks.iter().filter(|k| k.code == KeyCode::Enter).count(), 1);
}

/// The CRLF rule must hold however the two bytes are split, because the whole
/// point is that a fragmented paste puts them in different console reads. The
/// gap here is longer than the 20 ms text window, so only the CR pairing can
/// carry this one.
#[test]
fn crlf_split_across_reads_still_pairs() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    for ch in "line one\r".chars() {
        p.feed(ch, &mut |evt| events.push(evt));
    }
    sleep(Duration::from_millis(TEXT_BURST_MS + 10));
    p.feed('\n', &mut |evt| events.push(evt));

    let ks = keys(&events);
    assert!(
        !ks.iter().any(is_ctrl_j),
        "an LF that arrived a read later than its CR decoded as C-j: {:?}",
        ks
    );
    assert_eq!(
        ks.iter().filter(|k| k.code == KeyCode::Enter).count(),
        1,
        "expected exactly one Enter for the split CRLF: {:?}",
        ks
    );
}

// ── What #642 must keep ──────────────────────────────────────────────────────

/// The key the #642 reporter could not use. A lone 0x0a opens its own burst
/// with no CR in front of it, so it is still `C-j`.
#[test]
fn lone_lf_is_still_ctrl_j() {
    let ks = keys(&parse_vt("\n"));
    assert_eq!(ks.len(), 1, "{:?}", ks);
    assert!(is_ctrl_j(&ks[0]), "a lone 0x0a must stay C-j: {:?}", ks[0]);
}

/// A `C-j` pressed after typing, once the typing has stopped. The window has
/// closed and no CR came before it, so it decodes.
#[test]
fn lf_after_the_text_run_has_expired_is_ctrl_j() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    for ch in "abc".chars() {
        p.feed(ch, &mut |evt| events.push(evt));
    }
    sleep(Duration::from_millis(TEXT_BURST_MS + 15));
    p.feed('\n', &mut |evt| events.push(evt));

    let ks = keys(&events);
    assert!(
        is_ctrl_j(ks.last().unwrap()),
        "C-j pressed after typing stopped must still decode: {:?}",
        ks
    );
}

/// Two `C-j` presses in a row both decode. A decoded key does not refresh the
/// text run, which is what keeps a held key repeating.
#[test]
fn repeated_ctrl_j_keeps_decoding() {
    let ks = keys(&parse_vt("\n\n\n"));
    assert_eq!(ks.len(), 3, "{:?}", ks);
    assert!(ks.iter().all(is_ctrl_j), "a repeat stopped decoding: {:?}", ks);
}

/// A CR on its own is still a plain Enter, and once the pairing window has
/// closed it does not swallow a later LF: `C-j` after Enter still decodes.
#[test]
fn cr_alone_is_enter_and_does_not_swallow_a_later_lf() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    p.feed('\r', &mut |evt| events.push(evt));
    sleep(Duration::from_millis(CRLF_PAIR_MS + 30));
    p.feed('\n', &mut |evt| events.push(evt));

    let ks = keys(&events);
    assert_eq!(ks.len(), 2, "{:?}", ks);
    assert_eq!(ks[0], enter());
    assert!(
        is_ctrl_j(&ks[1]),
        "an LF a whole burst after a CR is its own key: {:?}",
        ks[1]
    );
}

/// The CR flag is consumed once. `CR LF LF` is one line ending and then a key.
#[test]
fn the_cr_pairing_is_consumed_by_one_lf() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    p.feed('\r', &mut |evt| events.push(evt));
    p.feed('\n', &mut |evt| events.push(evt));
    sleep(Duration::from_millis(CRLF_PAIR_MS + 30));
    p.feed('\n', &mut |evt| events.push(evt));

    let ks = keys(&events);
    assert_eq!(ks.len(), 2, "{:?}", ks);
    assert_eq!(ks[0], enter(), "the CRLF should give one Enter: {:?}", ks);
    assert!(
        is_ctrl_j(&ks[1]),
        "the second LF is a key of its own: {:?}",
        ks[1]
    );
}

/// Any character between a CR and an LF breaks the pairing.
#[test]
fn a_character_between_cr_and_lf_breaks_the_pairing() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    p.feed('\r', &mut |evt| events.push(evt));
    p.feed('x', &mut |evt| events.push(evt));
    sleep(Duration::from_millis(CRLF_PAIR_MS + 30));
    p.feed('\n', &mut |evt| events.push(evt));

    let ks = keys(&events);
    assert!(
        is_ctrl_j(ks.last().unwrap()),
        "an LF separated from its CR by text is not a line ending: {:?}",
        ks
    );
}

/// Tab and the other Ctrl+letters are untouched by any of this.
#[test]
fn other_control_bytes_are_unchanged() {
    let ks = keys(&parse_vt("\t"));
    assert_eq!(ks[0].code, KeyCode::Tab);

    let ks = keys(&parse_vt("\u{2}"));
    assert_eq!(ks[0].code, KeyCode::Char('b'));
    assert_eq!(ks[0].modifiers, KeyModifiers::CONTROL);

    // 0x08 stays C-h (issue #610).
    let ks = keys(&parse_vt("\u{8}"));
    assert_eq!(ks[0].code, KeyCode::Char('h'));
    assert_eq!(ks[0].modifiers, KeyModifiers::CONTROL);
}

/// A real bracketed paste, where the markers DID survive, is accumulated by the
/// parser and never reaches `on_ground` at all, so its CRLFs are carried
/// verbatim into the paste text.
#[test]
fn a_marked_paste_carries_its_crlf_verbatim() {
    let events = parse_vt("\u{1b}[200~one\r\ntwo\u{1b}[201~");
    let pastes: Vec<&String> = events
        .iter()
        .filter_map(|e| match e {
            Event::Paste(s) => Some(s),
            _ => None,
        })
        .collect();
    assert_eq!(pastes.len(), 1, "expected one paste event: {:?}", events);
    assert_eq!(pastes[0], "one\r\ntwo");
    assert!(
        keys(&events).is_empty(),
        "a marked paste must emit no keys: {:?}",
        events
    );
}
