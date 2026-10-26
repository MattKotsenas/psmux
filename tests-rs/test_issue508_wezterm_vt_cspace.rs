//! Issue #508: `C-Space` prefix dead under WezTerm on Windows (VT input path).
//!
//! Measured first, with the code unread.  With `ENABLE_VIRTUAL_TERMINAL_INPUT`
//! set, conhost re-encodes the record WezTerm delivers for Ctrl+Space
//! (`vk=VK_SPACE u_char=0x20 ctrl=CTRL`) into the single KEY_EVENT
//!
//! ```text
//! vk=0x0032  u_char=0x0000  ctrl=0x18 (CTRL|SHIFT)
//! ```
//!
//! (trace: `~/.psmux/ssh_input.log` with `PSMUX_SSH_DEBUG=1`).  The reader's
//! `u_char == 0` branch cannot feed a character to the VT parser, and
//! `vk_to_keycode` has no `VK_2` entry, so the key evaporated: no event, no
//! fold, dead prefix.  These tests pin the `vk_nul_to_ctrl_space` fold that
//! now catches that record, mirroring tmux's `tty-keys.c` ("C-Space is
//! special": `key = ' ' | KEYC_CTRL | (key & KEYC_META)`).

use super::*;

const VK_2: u16 = 0x32;
const VK_SPACE: u16 = 0x20;
const VK_1: u16 = 0x31;

// ── The measured WezTerm/ConPTY record must fold ─────────────────────────────

#[test]
fn conpty_nul_record_folds_to_ctrl_space() {
    // The exact record measured under the WezTerm env: VK_2, u_char 0,
    // CTRL|SHIFT.  vk_modifiers(0x18) == CONTROL|SHIFT.
    let mods = KeyModifiers::CONTROL | KeyModifiers::SHIFT;
    let folded = vk_nul_to_ctrl_space(VK_2, mods);
    assert_eq!(
        folded,
        Some((KeyCode::Char(' '), KeyModifiers::CONTROL)),
        "the ConPTY NUL record (VK_2 + CTRL|SHIFT, u_char 0) must fold to C-Space"
    );
}

#[test]
fn nul_record_with_ctrl_only_folds() {
    // Some hosts report the NUL without SHIFT.
    let folded = vk_nul_to_ctrl_space(VK_2, KeyModifiers::CONTROL);
    assert_eq!(folded, Some((KeyCode::Char(' '), KeyModifiers::CONTROL)));
}

#[test]
fn fold_preserves_alt_exclusion_shift_strip() {
    // SHIFT is noise on a NUL (Ctrl+Shift+2 IS Ctrl+@); it must be stripped so
    // the raw is_prefix tuple comparison matches a `C-Space` prefix (#504).
    let folded = vk_nul_to_ctrl_space(VK_2, KeyModifiers::CONTROL | KeyModifiers::SHIFT).unwrap();
    assert!(!folded.1.contains(KeyModifiers::SHIFT), "SHIFT must be stripped");
    assert!(folded.1.contains(KeyModifiers::CONTROL), "CONTROL must be kept");
}

// ── Guards: the fold must not be greedy ──────────────────────────────────────

#[test]
fn plain_vk2_does_not_fold() {
    // A '2' keypress arrives with u_char='2' and never reaches this branch,
    // but even a hypothetical modifier-less VK_2 record must not fold.
    assert_eq!(vk_nul_to_ctrl_space(VK_2, KeyModifiers::empty()), None);
}

#[test]
fn shift_only_vk2_does_not_fold() {
    assert_eq!(vk_nul_to_ctrl_space(VK_2, KeyModifiers::SHIFT), None);
}

#[test]
fn altgr_vk2_does_not_fold() {
    // CTRL|ALT is AltGr on many layouts; the native fold excludes it and the
    // VT fold must match (a layout may put a real glyph on AltGr+2).
    assert_eq!(
        vk_nul_to_ctrl_space(VK_2, KeyModifiers::CONTROL | KeyModifiers::ALT),
        None
    );
    assert_eq!(
        vk_nul_to_ctrl_space(
            VK_2,
            KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SHIFT
        ),
        None
    );
}

#[test]
fn ctrl_1_does_not_fold() {
    // Ctrl+1 also arrives with u_char==0 but is NOT a NUL; it must stay dead
    // rather than wrongly arming a C-Space prefix.
    assert_eq!(vk_nul_to_ctrl_space(VK_1, KeyModifiers::CONTROL), None);
}

#[test]
fn vk_space_is_left_to_vk_to_keycode() {
    // A zero-u_char VK_SPACE record already resolves via vk_to_keycode to
    // Char(' ') and keeps its CONTROL modifier; the NUL fold must not claim it
    // (and must not strip a real SHIFT from Shift+Space).
    assert_eq!(vk_nul_to_ctrl_space(VK_SPACE, KeyModifiers::CONTROL), None);
    assert_eq!(vk_to_keycode(VK_SPACE), Some(KeyCode::Char(' ')));
}

// ── The measured control-key-state decodes as expected ──────────────────────

#[test]
fn measured_control_state_decodes_to_ctrl_shift() {
    // ctrl=0x18 from the trace: LEFT_CTRL_PRESSED (0x8) | SHIFT_PRESSED (0x10).
    let m = vk_modifiers(0x18);
    assert!(m.contains(KeyModifiers::CONTROL));
    assert!(m.contains(KeyModifiers::SHIFT));
    assert!(!m.contains(KeyModifiers::ALT));
}

#[test]
fn end_to_end_record_shape_folds_like_the_trace() {
    // Compose the two stages exactly as the reader does for the traced record:
    // vk_modifiers(0x18) then vk_nul_to_ctrl_space(0x32, ..).
    let folded = vk_nul_to_ctrl_space(VK_2, vk_modifiers(0x18));
    assert_eq!(folded, Some((KeyCode::Char(' '), KeyModifiers::CONTROL)));
}

// ── Parity: the VT parser's Ground state already folds a raw NUL char ────────

#[test]
fn ground_state_nul_char_still_emits_ctrl_space() {
    // The pipe-mode / raw-byte route: a literal '\0' fed to the parser must
    // keep emitting C-Space (tmux tty-keys.c parity).  Guards against this
    // fix ever regressing the other NUL route.
    let mut p = VtParser::new();
    let mut got: Vec<Event> = Vec::new();
    p.feed('\0', &mut |e| got.push(e));
    assert_eq!(got.len(), 1, "NUL char must emit exactly one event");
    match &got[0] {
        Event::Key(k) => {
            assert_eq!(k.code, KeyCode::Char(' '));
            assert_eq!(k.modifiers, KeyModifiers::CONTROL);
        }
        other => panic!("expected key event, got {:?}", other),
    }
}
