// Issue #766 follow up: `ESC ESC` written to the client in one write reached
// the pane as a single ESC on the console input route.
//
// conhost's input parser turns an ESC in front of another key into the Alt
// prefix, so `ESC ESC` arrives at the client as ONE Alt+Escape key record
// (measured: vk 0x1b, LEFT_ALT_PRESSED, wrapped in Alt down/up, exactly like
// `ESC a` becomes Alt+a).  The client named it "esc" and the Alt was lost.
// tmux reads those bytes as M-Escape (tty-keys.c) and writes M-Escape to the
// pane as the meta prefix plus Escape, `\033\033` (input-keys.c).

use crate::client::escape_key_name;
use crate::input::{encode_key_event, is_meta_escape_name};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};

fn esc(mods: KeyModifiers) -> KeyEvent {
    KeyEvent { code: KeyCode::Esc, modifiers: mods, kind: KeyEventKind::Press, state: KeyEventState::NONE }
}

#[test]
fn alt_escape_keeps_its_meta_on_the_wire() {
    assert_eq!(escape_key_name(KeyModifiers::ALT), "M-Escape",
        "BUG #766: Alt+Escape (a front end's ESC ESC) was sent as plain esc");
}

#[test]
fn bare_escape_is_still_esc() {
    assert_eq!(escape_key_name(KeyModifiers::NONE), "esc");
}

#[test]
fn ctrl_and_shift_escape_stay_plain_like_tmux() {
    // tmux has no legacy encoding for Ctrl or Shift on Escape.
    assert_eq!(escape_key_name(KeyModifiers::CONTROL), "esc");
    assert_eq!(escape_key_name(KeyModifiers::SHIFT), "esc");
    assert_eq!(escape_key_name(KeyModifiers::CONTROL | KeyModifiers::ALT), "M-Escape");
}

#[test]
fn the_wire_name_is_recognised_by_the_server() {
    assert!(is_meta_escape_name(escape_key_name(KeyModifiers::ALT)));
    assert!(!is_meta_escape_name(escape_key_name(KeyModifiers::NONE)));
}

#[test]
fn meta_escape_spellings() {
    for name in ["M-Escape", "M-escape", "m-escape", "M-Esc", "M-esc", "C-M-Escape", "M-S-Escape", "S-M-esc"] {
        assert!(is_meta_escape_name(name), "{} must be M-Escape", name);
    }
    for name in ["esc", "escape", "Escape", "C-Escape", "S-Escape", "M-e", "M-x", "M-Enter", "M-", "M-Escapes", ""] {
        assert!(!is_meta_escape_name(name), "{} must not be M-Escape", name);
    }
}

#[test]
fn encoder_writes_meta_escape_as_two_escapes() {
    assert_eq!(encode_key_event(&esc(KeyModifiers::ALT)).unwrap(), b"\x1b\x1b".to_vec(),
        "BUG #766: Alt+Escape must reach the pane as ESC ESC (tmux input-keys.c)");
    assert_eq!(encode_key_event(&esc(KeyModifiers::NONE)).unwrap(), b"\x1b".to_vec());
}
