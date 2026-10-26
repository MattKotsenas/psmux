//! Issue #642: a `C-j` prefix is dead on the VT input path.
//!
//! Measured first, against the shipped 3.3.8 release (`66cf613`) under WezTerm
//! on Windows 11 26200, with only the prefix changed between runs:
//!
//! ```text
//!   prefix C-b       prefix + c splits        OK
//!   prefix C-Space   prefix + c splits        OK
//!   prefix C-a       prefix + c splits        OK
//!   prefix C-j       nothing happens          the prefix never arms
//! ```
//!
//! `PSMUX_SSH_DEBUG=1` shows the working and broken cases producing records of
//! identical shape — the only difference is which C0 byte arrives:
//!
//! ```text
//!   Ctrl+B: KEY vk=0x0000 u_char=0x0002 ctrl=0x00000000
//!             -> emit(char): Key(code: Char('b'), modifiers: CONTROL)
//!   Ctrl+J: KEY vk=0x0000 u_char=0x000A ctrl=0x00000000
//!             -> emit(char): Key(code: Enter,     modifiers: 0x0)
//! ```
//!
//! WezTerm and ConPTY both deliver the byte. It was psmux that lost the key:
//! `on_ground` read `'\r' | '\n' => Enter`, so 0x0a never reached the
//! `Ctrl+A..Ctrl+Z` arm that turns 0x02 into `C-b`.
//!
//! ## Why 0x0a is C-j and not Enter
//!
//! Ctrl+<letter> puts the letter's low five bits on the wire, so Ctrl+J IS LF,
//! the way Ctrl+I is Tab and Ctrl+M is CR. Those two collisions have a named
//! key on the other side, and tmux treats each pair as one key — which is why
//! the `'\t'` and `'\r'` arms are correct and are left alone here. 0x0a has no
//! such name. Enter is 0x0d, so the only key 0x0a can be is C-j.
//!
//! Measured against tmux 3.6a under WSL, same keyboard: with `prefix C-b` and
//! `bind -n C-j display-message`, pressing Ctrl+J fires the message; with
//! `prefix C-j`, Ctrl+J then `c` creates a window and the root-table message
//! correctly does not fire, because the prefix takes precedence. psmux's own
//! native input path agrees (conhost reports `VK_J` + CONTROL, which is why the
//! same prefix works under Windows Terminal), and so does psmux's own output
//! encoder: `send-key C-j` writes 0x0a and `Enter` writes 0x0d.
//!
//! ## The one thing that cannot be fixed
//!
//! Ctrl+J and Ctrl+Enter are the same byte — Windows Terminal sends 0x0a for
//! Ctrl+Enter too, which psmux relies on in the output direction (#409). So
//! 0x0a can only ever mean one of them. It did not mean Ctrl+Enter before this
//! change either: it arrived as a plain Enter with the modifier already gone.
//!
//! ## Scope
//!
//! Only the BARE byte moves. `on_escape` keeps `'\r' | '\n' => Alt+Enter`; see
//! `esc_lf_is_left_as_alt_enter` for the measurement that ruled out changing it
//! here.
//!
//! Verified after the change, WezTerm on the same machine, prefix `C-j`:
//! `prefix + c` splits, Enter and the other Ctrl+letters are unchanged, and a
//! byte logger in the pane shows `0a` for Ctrl+J, `0d` for Enter and `1b 0d`
//! for a `SendString '\x1b\r'` binding.

use super::*;
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};

fn parse_vt(s: &str) -> Vec<Event> {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    for ch in s.chars() {
        p.feed(ch, &mut |evt| events.push(evt));
    }
    events
}

fn one_key(s: &str) -> KeyEvent {
    let events = parse_vt(s);
    assert_eq!(events.len(), 1, "{:?} produced {:?}", s, events);
    match &events[0] {
        Event::Key(k) => *k,
        other => panic!("{:?} produced {:?}, not a key", s, other),
    }
}

// ── The reported key ─────────────────────────────────────────────────────────

#[test]
fn lf_is_ctrl_j() {
    let k = one_key("\n");
    assert_eq!(k.code, KeyCode::Char('j'));
    assert_eq!(k.modifiers, KeyModifiers::CONTROL);
}

/// The user-visible claim: a `C-j` prefix can now match. The client compares
/// the tuple it gets from the input source against the one `parse_key_name`
/// produced from the config, so that is what this asserts.
#[test]
fn the_decoded_key_matches_a_c_j_prefix_from_config() {
    let k = one_key("\n");
    let configured = crate::config::parse_key_name("C-j").expect("`C-j` must parse");
    assert_eq!((k.code, k.modifiers), configured);
}

/// 0x0a on this path used to become the same event as 0x0d. Two different
/// bytes must not produce one key.
#[test]
fn lf_and_cr_are_different_keys() {
    let lf = one_key("\n");
    let cr = one_key("\r");
    assert_eq!(cr.code, KeyCode::Enter, "CR is still Enter");
    assert_eq!(cr.modifiers, KeyModifiers::NONE);
    assert_ne!((lf.code, lf.modifiers), (cr.code, cr.modifiers));
}

/// The neighbouring collisions are NOT in question. Ctrl+I is Tab and Ctrl+M is
/// Enter in tmux too, so those arms stay exactly as they were.
#[test]
fn tab_and_cr_keep_their_named_keys() {
    assert_eq!(one_key("\t").code, KeyCode::Tab);
    assert_eq!(one_key("\t").modifiers, KeyModifiers::NONE);
    assert_eq!(one_key("\r").code, KeyCode::Enter);
    assert_eq!(one_key("\r").modifiers, KeyModifiers::NONE);
}

/// Every other Ctrl+<letter> already worked and must keep working — this is the
/// arm 0x0a now falls through to.
#[test]
fn the_other_control_letters_are_unchanged() {
    for (byte, letter) in [(0x01u8, 'a'), (0x02, 'b'), (0x07, 'g'), (0x0b, 'k'), (0x1a, 'z')] {
        let s = (byte as char).to_string();
        let k = one_key(&s);
        assert_eq!(k.code, KeyCode::Char(letter), "byte {:#04x}", byte);
        assert_eq!(k.modifiers, KeyModifiers::CONTROL, "byte {:#04x}", byte);
    }
}

/// Bare LF round-trips: `send-key C-j` is 0x0a, so the byte the terminal sent
/// is the byte the pane's child receives.
#[cfg(windows)]
#[test]
fn bare_lf_round_trips_to_the_same_byte() {
    let bytes = crate::input::encode_key_event(&one_key("\n")).expect("C-j must encode");
    assert_eq!(bytes, b"\n".to_vec(), "got {:02x?}", bytes);
}

// ── What is deliberately NOT changed ─────────────────────────────────────────

/// ESC+CR is the pair #396 is about, and Shift+Enter must still reach a TUI app
/// as `\x1b\r`. Measured after this change under WezTerm with a `SendString
/// '\x1b\r'` binding and a byte logger in the pane: `1b 0d` arrives, unchanged.
#[test]
fn esc_cr_is_still_alt_enter() {
    let k = one_key("\x1b\r");
    assert_eq!(k.code, KeyCode::Enter);
    assert_eq!(k.modifiers, KeyModifiers::ALT);
}

#[cfg(windows)]
#[test]
fn esc_cr_still_encodes_to_esc_cr() {
    let bytes = crate::input::encode_key_event(&one_key("\x1b\r")).unwrap();
    assert_eq!(bytes, b"\x1b\r".to_vec(), "got {:02x?}", bytes);
}

/// ESC+LF keeps sharing the ESC+CR arm, so it is still Alt+Enter — deliberately
/// asymmetric with the bare byte above, and out of scope here.
///
/// Decoding it as M-C-j looked like the consistent thing to do, and a first cut
/// of this fix did exactly that. Measuring it end to end under WezTerm killed
/// the idea: a named `C-M-<letter>` never reaches `encode_key_event`, because
/// `write_named_key_to_pane` injects a console record first and ConPTY drops
/// the Alt from it. `\x1b\n` in gave `0a` out, where the old decode gives
/// `1b 0d`. Neither is what the terminal sent, so ESC+LF needs a fix in the
/// OUTPUT path, and that is not #642.
#[test]
fn esc_lf_is_left_as_alt_enter() {
    let k = one_key("\x1b\n");
    assert_eq!(k.code, KeyCode::Enter);
    assert_eq!(k.modifiers, KeyModifiers::ALT);
}

// ── The parser keeps working around the change ───────────────────────────────

/// After a bare LF the parser is back in Ground and reads what follows.
#[test]
fn the_parser_returns_to_ground() {
    let mut p = VtParser::new();
    let mut events = Vec::new();
    for ch in "\nhi".chars() {
        p.feed(ch, &mut |e| events.push(e));
    }
    assert_eq!(p.state, PS::Ground);
    assert_eq!(events.len(), 3, "produced {:?}", events);
    match &events[0] {
        Event::Key(k) => {
            assert_eq!(k.code, KeyCode::Char('j'));
            assert_eq!(k.modifiers, KeyModifiers::CONTROL);
        }
        other => panic!("{:?}", other),
    }
    assert!(matches!(&events[1], Event::Key(k) if k.code == KeyCode::Char('h')));
    assert!(matches!(&events[2], Event::Key(k) if k.code == KeyCode::Char('i')));
}

/// A run of newlines — pasted text arriving as raw LF, for instance — produces
/// one key each and never stalls the parser.
#[test]
fn repeated_newlines_stay_one_key_each() {
    let events = parse_vt("\n\n\n");
    assert_eq!(events.len(), 3, "got {:?}", events);
    for e in &events {
        match e {
            Event::Key(k) => {
                assert_eq!(k.code, KeyCode::Char('j'));
                assert_eq!(k.modifiers, KeyModifiers::CONTROL);
            }
            other => panic!("{:?}", other),
        }
    }
}
