//! Issue #623: Ctrl + digit must keep its modifier on the way to a pane that
//! reads `INPUT_RECORD`s.
//!
//! What was measured before anything changed, with a pane child configured in
//! Far Manager's own console input mode (`0x01B8`) and real keystrokes injected
//! into the attached client's console:
//!
//! ```text
//!   injected Ctrl+1  ->  KEY down vk=0x31 sc=0x02 ch=0x0031 ctrl=0x0000
//!   injected Ctrl+0  ->  KEY down vk=0x30 sc=0x0B ch=0x0030 ctrl=0x0000
//!   injected Ctrl+2  ->  KEY down vk=0x20 sc=0x39 ch=0x0020 ctrl=0x0000
//! ```
//!
//! An unmodified `1`, an unmodified `0` and a literal SPACE.  In Far's drives
//! menu `1` is the hotkey of the Temporary panel plugin, which is exactly the
//! reported "left pane opens temporary panel".
//!
//! The cause is tmux parity taken one step too far.  `ctrl_char_send_keys_byte`
//! is a port of tmux's `standard_map` (input-keys.c:487), where a terminal that
//! has not asked for extended keys gets `C-1` as the character `1`, `C-0` as
//! `0`, and `C-2` as NUL, because no C0 code for Ctrl + a digit exists.  A pane
//! reading bytes is fine with that.  A pane reading records is not: the
//! modifier is simply gone.
//!
//! The ConPTY contract, measured one byte sequence at a time under a bare
//! pseudoconsole hosting that same child:
//!
//! ```text
//!   31                                 -> vk=0x31 ch=0x0031 ctrl=0x0000
//!   1b 5b 32 37 3b 35 3b 34 39 7e      -> nothing        (CSI 27;5;49~)
//!   1b 5b 34 39 3b 35 75               -> nothing        (CSI 49;5u)
//!   1b 5b 34 39 3b 32 3b 30 3b 31 3b 38 3b 31 5f
//!                                      -> vk=0x31 ch=0x0000 ctrl=0x0008
//! ```
//!
//! Neither xterm extended key format survives ConPTY, so win32 input mode is
//! the only encoding left, and these tests pin its exact wire form.

use crate::input::{
    ctrl_char_send_keys_byte, ctrl_key_win32_seq, ctrl_modifier_is_lost_in_vt,
    win32_input_key_seq,
};

const LEFT_CTRL: u32 = 0x0008;
const SHIFT: u32 = 0x0010;

/// Every digit, plus the space that Ctrl+2 folds onto, loses the modifier in
/// the legacy encoding; nothing else in the printable range does.
#[test]
fn only_digits_and_space_lose_ctrl_in_vt() {
    for c in '0'..='9' {
        assert!(
            ctrl_modifier_is_lost_in_vt(c),
            "Ctrl+{c} has no faithful VT encoding and must be flagged"
        );
    }
    assert!(ctrl_modifier_is_lost_in_vt(' '));

    // Letters survive: ConPTY rebuilds VK + LEFT_CTRL_PRESSED from the C0 byte,
    // which is why psmux must NOT also inject a record for them (issue #363).
    for c in 'a'..='z' {
        assert!(!ctrl_modifier_is_lost_in_vt(c), "Ctrl+{c} is carried by its C0 byte");
    }
    // Punctuation whose Ctrl form IS a C0 code keeps the byte path too.
    for c in ['/', '-', '?', '[', ']', '\\', '@', '^', '_'] {
        assert!(!ctrl_modifier_is_lost_in_vt(c), "Ctrl+{c} is carried by its C0 byte");
    }
}

/// The legacy table is what it is: this pins the loss the fix exists for, so a
/// future edit to `ctrl_char_send_keys_byte` cannot quietly make this test
/// meaningless.
#[test]
fn legacy_table_really_does_drop_the_modifier() {
    assert_eq!(ctrl_char_send_keys_byte('1'), Some(b'1'));
    assert_eq!(ctrl_char_send_keys_byte('9'), Some(b'9'));
    assert_eq!(ctrl_char_send_keys_byte('0'), Some(b'0'));
    // tmux standard_map sends NUL for both C-2 and C-Space.
    assert_eq!(ctrl_char_send_keys_byte('2'), Some(0x00));
    assert_eq!(ctrl_char_send_keys_byte(' '), Some(0x00));
    // C-3..C-7 collapse onto unrelated C0 codes: a record reader would see
    // Escape for Ctrl+3.
    assert_eq!(ctrl_char_send_keys_byte('3'), Some(0x1b));
    assert_eq!(ctrl_char_send_keys_byte('7'), Some(0x1f));
    assert_eq!(ctrl_char_send_keys_byte('8'), Some(0x7f));
    // Letters are correct and must stay on that path.
    assert_eq!(ctrl_char_send_keys_byte('w'), Some(0x17));
}

/// The exact bytes that produced `vk=0x31 ch=0x0000 ctrl=0x0008` under a real
/// pseudoconsole: `ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` for the press and the
/// release.
#[test]
fn ctrl_one_is_the_measured_win32_sequence() {
    let seq = ctrl_key_win32_seq('1', false).expect("Ctrl+1 needs a record encoding");
    assert_eq!(seq, "\x1b[49;2;0;1;8;1_\x1b[49;2;0;0;8;1_");
    // Same thing, built from the primitive, as a cross check on the field order.
    assert_eq!(seq, win32_input_key_seq(0x31, 0x02, 0, LEFT_CTRL));
}

/// Every digit gets its own virtual key, and the character stays NUL because a
/// real Ctrl+digit press reports none.
#[test]
fn every_ctrl_digit_carries_its_own_virtual_key() {
    for (c, vk) in [
        ('0', 0x30u16), ('1', 0x31), ('2', 0x32), ('3', 0x33), ('4', 0x34),
        ('5', 0x35), ('6', 0x36), ('7', 0x37), ('8', 0x38), ('9', 0x39),
    ] {
        let seq = ctrl_key_win32_seq(c, false).expect("digit needs a record encoding");
        let press = seq.split('_').next().unwrap();
        let fields: Vec<&str> = press.trim_start_matches("\x1b[").split(';').collect();
        assert_eq!(fields[0], vk.to_string(), "Ctrl+{c} must carry VK 0x{vk:02X}");
        assert_eq!(fields[2], "0", "Ctrl+{c} must carry no character");
        assert_eq!(fields[3], "1", "first record is the press");
        assert_eq!(fields[4], LEFT_CTRL.to_string(), "Ctrl+{c} must carry LEFT_CTRL_PRESSED");
    }
}

/// Ctrl+Shift+digit (Far's folder shortcuts) adds SHIFT_PRESSED and nothing
/// else.
#[test]
fn shift_is_added_to_the_control_key_state() {
    let seq = ctrl_key_win32_seq('5', true).expect("Ctrl+Shift+5 needs a record encoding");
    assert_eq!(seq, win32_input_key_seq(0x35, 0x06, 0, LEFT_CTRL | SHIFT));
    assert!(seq.contains(&format!(";{};", LEFT_CTRL | SHIFT)));
}

/// Ctrl+Space, which is where a physical Ctrl+2 and Ctrl+Shift+2 land after
/// `fold_nul_to_ctrl_space`, carries VK_SPACE rather than a literal space
/// character.  Before the fix the client delivered 0x20 here.
#[test]
fn ctrl_space_carries_vk_space_and_no_character() {
    let seq = ctrl_key_win32_seq(' ', false).expect("Ctrl+Space needs a record encoding");
    let press = seq.split('_').next().unwrap();
    let fields: Vec<&str> = press.trim_start_matches("\x1b[").split(';').collect();
    assert_eq!(fields[0], "32", "VK_SPACE is 0x20");
    assert_eq!(fields[2], "0", "no character: this key IS NUL");
    assert_eq!(fields[4], LEFT_CTRL.to_string());
}

/// Anything with a faithful VT encoding is refused, so the byte path keeps it
/// and nothing about Ctrl+<letter> or Ctrl+/ changes.
#[test]
fn keys_with_a_real_vt_encoding_are_refused() {
    for c in ['a', 'w', 'c', '/', '-', '?', '[', '@'] {
        assert!(
            ctrl_key_win32_seq(c, false).is_none(),
            "Ctrl+{c} must stay on the legacy byte path"
        );
        assert!(ctrl_key_win32_seq(c, true).is_none());
    }
}

/// The release record mirrors the press with `Kd` flipped to 0; conhost needs
/// both or the key stays logically held.
#[test]
fn press_and_release_are_both_emitted() {
    let seq = ctrl_key_win32_seq('4', false).unwrap();
    let parts: Vec<&str> = seq.split('_').filter(|s| !s.is_empty()).collect();
    assert_eq!(parts.len(), 2, "one press and one release");
    assert!(parts[0].ends_with(";1;8;1"), "press has Kd=1: {}", parts[0]);
    assert!(parts[1].ends_with(";0;8;1"), "release has Kd=0: {}", parts[1]);
    assert!(seq.ends_with('_'), "a win32 sequence is terminated by _");
}
