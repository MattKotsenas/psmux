//! Issue #623 follow up: the record-reader gate must not match the console mode
//! a pane child INHERITS.
//!
//! `ensure_vti` forces `ENABLE_VIRTUAL_TERMINAL_INPUT` on a pane console before
//! writing an SGR mouse report, because conhost drops those bytes otherwise
//! (#277/#245).  #623 taught it to skip that flip for an application that reads
//! `INPUT_RECORD`s, since the flip destroys ConPTY's key translation and Far
//! Manager lost every other F1 to it.
//!
//! The first version of that gate asked only "is `ENABLE_MOUSE_INPUT` set", and
//! that bit is part of Windows' documented DEFAULT console input mode `0x01F7`.
//! Every freshly spawned pane app therefore matched it, including the very apps
//! `ensure_vti` exists for: one that writes DECSET 1000/1002/1003/1006 and then
//! reads the SGR bytes itself never calls `SetConsoleMode`, so it still carries
//! the inherited word.  The flip was skipped, conhost dropped the report, and
//! the injected `MOUSE_EVENT` record was no use to a byte reader, so the wheel
//! stopped reaching it entirely.
//!
//! Every mode word below was MEASURED from a live pane child on this tree with
//! `GetConsoleMode` on its `CONIN$` (see tests/test_issue277_default_mode_vti.ps1
//! and tests/test_issue623_far_f1.ps1).

use crate::window_ops::mode_is_deliberate_record_reader as is_record_reader;

/// Windows' documented default console input mode, inherited by every pane
/// child before it configures anything: PROCESSED|LINE|ECHO|MOUSE|INSERT|
/// QUICK_EDIT|EXTENDED|AUTO_POSITION.  Measured on a pwsh pane app that only
/// wrote DECSETs and read with `[Console]::ReadKey`.
const INHERITED_DEFAULT: u32 = 0x01F7;
/// The same pwsh reader after `[Console]::TreatControlCAsInput = $true` cleared
/// ENABLE_PROCESSED_INPUT.  Still cooked, still a byte reader.
const PWSH_VT_READER: u32 = 0x01F6;
/// The same pane after psmux injected one wheel record: `send_mouse_event` sets
/// ENABLE_MOUSE_INPUT|ENABLE_EXTENDED_FLAGS and clears ENABLE_QUICK_EDIT_MODE
/// on the child console and restores nothing.  This is why quick edit cannot be
/// the discriminator, and why the cooked pair has to be.
const PWSH_VT_READER_AFTER_PSMUX_INJECTION: u32 = 0x01B6;
/// Far Manager, the #623 reporter's application.
const FAR_MANAGER: u32 = 0x01B8;
/// pstop, a crossterm/ratatui record reader.
const PSTOP_CROSSTERM: u32 = 0x0098;
/// A pwsh pane sitting at its prompt (PSReadLine has cleared PROCESSED|LINE).
const SHELL_PROMPT: u32 = 0x01E4;

#[test]
fn inherited_default_console_mode_is_not_a_record_reader() {
    // The whole regression in one assertion: this is the mode of a #277 app,
    // and treating it as a record reader is what silenced the wheel.
    assert!(
        !is_record_reader(INHERITED_DEFAULT),
        "the inherited default 0x{:04X} must never be classified as a record reader",
        INHERITED_DEFAULT
    );
    assert!(!is_record_reader(PWSH_VT_READER));
}

#[test]
fn psmux_own_mouse_injection_cannot_turn_a_byte_reader_into_a_record_reader() {
    // Quick edit is cleared by psmux itself, so the classification must not
    // change across a forwarded wheel notch.
    assert_eq!(
        is_record_reader(PWSH_VT_READER),
        is_record_reader(PWSH_VT_READER_AFTER_PSMUX_INJECTION),
        "0x{:04X} -> 0x{:04X} (psmux's own send_mouse_event) changed the verdict",
        PWSH_VT_READER,
        PWSH_VT_READER_AFTER_PSMUX_INJECTION
    );
    assert!(!is_record_reader(PWSH_VT_READER_AFTER_PSMUX_INJECTION));
}

#[test]
fn real_record_readers_still_match_so_623_stays_fixed() {
    assert!(
        is_record_reader(FAR_MANAGER),
        "Far Manager 0x{:04X} must keep its ConPTY key translation (#623)",
        FAR_MANAGER
    );
    assert!(is_record_reader(PSTOP_CROSSTERM));
}

#[test]
fn a_shell_prompt_is_not_a_record_reader() {
    // It has no ENABLE_MOUSE_INPUT at all, so it fails the first term.
    assert!(!is_record_reader(SHELL_PROMPT));
}

#[test]
fn quick_edit_alone_would_have_misclassified_and_the_cooked_pair_does_not() {
    const ENABLE_QUICK_EDIT_MODE: u32 = 0x0040;
    let quick_edit_verdict = |m: u32| m & 0x0010 != 0 && m & ENABLE_QUICK_EDIT_MODE == 0;
    // Quick edit separates the two families before psmux touches the console...
    assert!(!quick_edit_verdict(PWSH_VT_READER));
    assert!(quick_edit_verdict(FAR_MANAGER));
    // ...and stops separating them the moment psmux injects one record.
    assert!(quick_edit_verdict(PWSH_VT_READER_AFTER_PSMUX_INJECTION));
    assert!(!is_record_reader(PWSH_VT_READER_AFTER_PSMUX_INJECTION));
}
