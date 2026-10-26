//! Issue #729: an Ink based TUI (dsh-TUI) in a psmux pane read the Up arrow
//! as a lone Escape followed by the text `[A`.
//!
//! psmux wrote `ESC [ A` in ONE write; the split happened in the pane's
//! conhost.  A child that reads VT input gets the VT bytes psmux writes as one
//! character record each, and a child that also asked its console for win32
//! input mode (`CSI ?9001h`, which dsh-TUI does on Windows) reads every record
//! in that form.  Measured with a raw mode node reader in a psmux pane:
//!
//! ```text
//!   before: ESC[0;0;27;1;0;1_ ESC[0;0;91;1;0;1_ ESC[0;0;65;1;0;1_   (Esc, '[', 'A')
//!   after:  ESC[38;72;0;1;256;1_ ESC[38;72;0;0;256;1_               (VK_UP)
//! ```
//!
//! The second line is what the same child reads in Windows Terminal, which
//! sends every key as a win32 input mode record because conhost asks it to.
//! Under a bare pseudoconsole a VT reader WITHOUT win32 input mode gets the
//! exact VT bytes psmux used to write back from each record below, so these
//! tables are the contract: the key a VT sequence names, and the record that
//! stands for it.

use crate::input::{encode_key_event, named_key_record, win32_input_key_seq};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};

const ENH: u32 = 0x0100;
const SHIFT: u32 = 0x0010;
const ALT: u32 = 0x0002;
const CTRL: u32 = 0x0008;

fn rec(seq: &str) -> Option<(u16, u16, u32)> {
    named_key_record(seq.as_bytes())
}

#[test]
fn up_arrow_becomes_the_record_windows_terminal_sends() {
    let (vk, uc, cs) = rec("\x1b[A").expect("Up is a named key");
    assert_eq!((vk, uc, cs), (0x26, 0, ENH));
    // Scan 72 is what MapVirtualKeyW(VK_UP) gives and what WT sends.
    assert_eq!(
        win32_input_key_seq(vk, 72, uc, cs),
        "\x1b[38;72;0;1;256;1_\x1b[38;72;0;0;256;1_"
    );
}

#[test]
fn cursor_and_navigation_keys_are_enhanced() {
    for (seq, vk) in [
        ("\x1b[A", 0x26), ("\x1b[B", 0x28), ("\x1b[C", 0x27), ("\x1b[D", 0x25),
        ("\x1b[H", 0x24), ("\x1b[F", 0x23),
        ("\x1b[2~", 0x2D), ("\x1b[3~", 0x2E), ("\x1b[5~", 0x21), ("\x1b[6~", 0x22),
    ] {
        assert_eq!(rec(seq), Some((vk, 0, ENH)), "{:?}", seq);
    }
}

#[test]
fn decckm_cursor_keys_map_to_the_same_record() {
    // write_key_seq turns CSI into SS3 under DECCKM before the pane write;
    // conhost applies DECCKM itself when it turns the record back into VT.
    for (seq, vk) in [("\x1bOA", 0x26), ("\x1bOB", 0x28), ("\x1bOC", 0x27),
                      ("\x1bOD", 0x25), ("\x1bOH", 0x24), ("\x1bOF", 0x23)] {
        assert_eq!(rec(seq), Some((vk, 0, ENH)), "{:?}", seq);
    }
}

#[test]
fn function_keys_follow_tmux_input_key_defaults() {
    let table = [
        ("\x1bOP", 0x70), ("\x1bOQ", 0x71), ("\x1bOR", 0x72), ("\x1bOS", 0x73),
        ("\x1b[15~", 0x74), ("\x1b[17~", 0x75), ("\x1b[18~", 0x76), ("\x1b[19~", 0x77),
        ("\x1b[20~", 0x78), ("\x1b[21~", 0x79), ("\x1b[23~", 0x7A), ("\x1b[24~", 0x7B),
    ];
    for (seq, vk) in table {
        assert_eq!(rec(seq), Some((vk, 0, 0)), "{:?}", seq);
    }
    // ...and these are exactly what psmux writes for F1..F12.
    for n in 1..=12u8 {
        assert!(rec(crate::input::function_key_seq(n)).is_some(), "F{}", n);
    }
}

#[test]
fn xterm_modifier_parameter_maps_to_control_key_state() {
    assert_eq!(rec("\x1b[1;2A"), Some((0x26, 0, ENH | SHIFT)));
    assert_eq!(rec("\x1b[1;3A"), Some((0x26, 0, ENH | ALT)));
    assert_eq!(rec("\x1b[1;5C"), Some((0x27, 0, ENH | CTRL)));
    assert_eq!(rec("\x1b[1;6D"), Some((0x25, 0, ENH | CTRL | SHIFT)));
    assert_eq!(rec("\x1b[1;8H"), Some((0x24, 0, ENH | CTRL | ALT | SHIFT)));
    assert_eq!(rec("\x1b[3;5~"), Some((0x2E, 0, ENH | CTRL)));
    assert_eq!(rec("\x1b[15;2~"), Some((0x74, 0, SHIFT)));
    assert_eq!(rec("\x1b[1;5P"), Some((0x70, 0, CTRL)));
    assert_eq!(rec("\x1b[Z"), Some((0x09, 0x09, SHIFT)));
}

#[test]
fn every_named_key_psmux_encodes_has_a_record() {
    let codes = [
        KeyCode::Up, KeyCode::Down, KeyCode::Left, KeyCode::Right, KeyCode::Home, KeyCode::End,
        KeyCode::Insert, KeyCode::Delete, KeyCode::PageUp, KeyCode::PageDown,
        KeyCode::F(1), KeyCode::F(4), KeyCode::F(5), KeyCode::F(12),
    ];
    let mods = [
        KeyModifiers::NONE, KeyModifiers::SHIFT, KeyModifiers::ALT, KeyModifiers::CONTROL,
        KeyModifiers::SHIFT | KeyModifiers::CONTROL,
        KeyModifiers::SHIFT | KeyModifiers::ALT | KeyModifiers::CONTROL,
    ];
    for code in codes {
        for m in mods {
            let key = KeyEvent { code, modifiers: m, kind: KeyEventKind::Press, state: KeyEventState::NONE };
            let bytes = encode_key_event(&key).expect("encodes");
            let (_, _, cs) = named_key_record(&bytes)
                .unwrap_or_else(|| panic!("{:?}+{:?} wrote {:?} with no record", code, m, bytes));
            assert_eq!(cs & SHIFT != 0, m.contains(KeyModifiers::SHIFT), "{:?}+{:?}", code, m);
            assert_eq!(cs & ALT != 0, m.contains(KeyModifiers::ALT), "{:?}+{:?}", code, m);
            assert_eq!(cs & CTRL != 0, m.contains(KeyModifiers::CONTROL), "{:?}+{:?}", code, m);
        }
    }
}

#[test]
fn anything_that_is_not_exactly_one_named_key_is_left_alone() {
    for seq in [
        "", "a", "\x1b", "\x1ba", "\x1b\r", "\r", "\x7f",
        "\x1b[A\x1b[A",       // two keys in one write
        "/\x1b[A",            // text then a key
        "\x1b[200~",          // paste start
        "\x1b[201~",          // paste end
        "\x1b[<64;10;5M",     // SGR mouse report
        "\x1b[I", "\x1b[O",   // focus reports
        "\x1b[2A",            // cursor movement count, not a key
        "\x1b[1A",            // `1;` without a modifier
        "\x1b[1;1A",          // modifier 1 is "none" and never written
        "\x1b[1;9A",          // meta, which a console record cannot carry
        "\x1b[13;5~",         // modified Enter
        "\x1b[9;5~",          // modified Tab
        "\x1b[4~", "\x1b[16~", "\x1b[22~", "\x1b[25~",
        "\x1bOx", "\x1b[38;72;0;1;256;1_",
    ] {
        assert_eq!(rec(seq), None, "{:?}", seq);
    }
}
