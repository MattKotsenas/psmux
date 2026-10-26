//! Issue #647 (WIN-03): control bytes in formatted output.
//!
//! Every expectation here was measured against tmux 3.4 running under WSL with
//! `LANG=C.UTF-8`, and cross checked against the tmux sources in
//! C:\Users\godwin\Documents\workspace\tmux.
//!
//! Two separate tmux mechanisms are involved and psmux had neither:
//!
//!   1. `display-message -p` prints through `server_client_print(tc, 0, evb)`
//!      (cmd-display-message.c:152). The `parse == 0` arm always encodes the
//!      result with `utf8_stravisx(&msg, data, size,
//!      VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH)` (server-client.c:3089-3091), so ESC,
//!      CR, BEL and every other control byte come out as printable escapes.
//!      `VIS_TAB` and `VIS_NL` are NOT in that set, so a tab or a newline still
//!      reaches stdout literally.
//!
//!   2. Window, session and buffer names go through `clean_name`
//!      (tmux.c:303-317) at the moment they are set, with
//!      `VIS_OCTAL|VIS_CSTYLE|VIS_TAB|VIS_NL`. A name therefore can never hold
//!      a raw control byte, which is what makes `#{window_name}` safe to drop
//!      into a tab separated record.
//!
//! The `list-*` commands are deliberately NOT covered by either: tmux 3.6
//! stopped visually encoding command output (commit 5fd45b38 "Do not strvis
//! output to terminal from commands.", first released in 3.6), so on tmux 3.7
//! a `-F` format reaches stdout byte for byte for a UTF-8 client. Measured:
//! `list-panes -F "#{pane_id}<TAB>#{window_name}"` => `25 30 09 7A ...`.

use crate::util::{clean_name, visual_escape_message};

fn hex(s: &str) -> String {
    s.as_bytes()
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join("-")
}

// ---------------------------------------------------------------------------
// display-message -p: VIS_OCTAL | VIS_CSTYLE | VIS_NOSLASH
// ---------------------------------------------------------------------------

#[test]
fn tab_reaches_stdout_literally() {
    // tmux: display-message -p "A<TAB>B" => 41 09 42. VIS_TAB is not set.
    assert_eq!(hex(&visual_escape_message("A\tB")), "41-09-42");
}

#[test]
fn newline_reaches_stdout_literally() {
    // tmux: an option holding "L1\nL2" prints as two lines through
    // display-message -p, because VIS_NL is not set either.
    assert_eq!(visual_escape_message("L1\nL2"), "L1\nL2");
}

#[test]
fn carriage_return_becomes_a_c_escape() {
    // tmux: display-message -p "A<CR>B" => 41 5C 72 42, i.e. `A\rB`.
    assert_eq!(visual_escape_message("A\rB"), "A\\rB");
    assert_eq!(hex(&visual_escape_message("A\rB")), "41-5C-72-42");
}

#[test]
fn escape_becomes_a_three_digit_octal_escape() {
    // tmux: display-message -p "A<ESC>B" => `A\033B`. ESC is not one of the
    // VIS_CSTYLE names, so VIS_OCTAL produces \033.
    assert_eq!(visual_escape_message("A\u{1b}B"), "A\\033B");
}

#[test]
fn bell_becomes_backslash_a() {
    // tmux: display-message -p "A<BEL>B" => `A\aB`.
    assert_eq!(visual_escape_message("A\u{7}B"), "A\\aB");
}

#[test]
fn delete_becomes_octal_177() {
    // tmux: display-message -p "a<DEL>b" => `a\177b`.
    assert_eq!(visual_escape_message("a\u{7f}b"), "a\\177b");
}

#[test]
fn nul_becomes_backslash_zero() {
    assert_eq!(visual_escape_message("A\0B"), "A\\0B");
    // compat/vis.c:104-107 pads to three digits when an octal digit follows,
    // so the reader cannot mistake the digit for part of the escape.
    assert_eq!(visual_escape_message("A\u{0}7B"), "A\\0007B");
}

#[test]
fn the_other_cstyle_names_are_used() {
    assert_eq!(visual_escape_message("\u{8}"), "\\b");
    assert_eq!(visual_escape_message("\u{b}"), "\\v");
    assert_eq!(visual_escape_message("\u{c}"), "\\f");
}

#[test]
fn valid_utf8_passes_through_untouched() {
    // tmux: display-message -p "A<U+2713>B" => 41 E2 9C 93 42. utf8.c:690-709
    // copies a complete UTF-8 character verbatim.
    assert_eq!(hex(&visual_escape_message("A\u{2713}B")), "41-E2-9C-93-42");
    assert_eq!(visual_escape_message("héllo \u{1f600}"), "héllo \u{1f600}");
}

#[test]
fn printable_ascii_and_spaces_are_untouched() {
    let s = "%0 zero pwsh -F #{pane_id} \"quoted\" 'single' a|b";
    assert_eq!(visual_escape_message(s), s);
}

#[test]
fn a_backslash_is_not_doubled_on_the_message_path() {
    // VIS_NOSLASH. tmux: display-message -p 'a\b' => `a\b`.
    assert_eq!(visual_escape_message("a\\b"), "a\\b");
    assert_eq!(visual_escape_message("C:\\src\\psmux"), "C:\\src\\psmux");
}

#[test]
fn an_empty_message_stays_empty() {
    assert_eq!(visual_escape_message(""), "");
}

// ---------------------------------------------------------------------------
// clean_name: VIS_OCTAL | VIS_CSTYLE | VIS_TAB | VIS_NL
// ---------------------------------------------------------------------------

#[test]
fn a_name_can_never_hold_a_tab() {
    // tmux: rename-window "w<TAB>x" then #{window_name} => `w\tx` (5 bytes),
    // which is what keeps a tab separated -F record parseable.
    assert_eq!(clean_name("w\tx"), "w\\tx");
    assert_eq!(hex(&clean_name("w\tx")), "77-5C-74-78");
}

#[test]
fn a_name_can_never_hold_a_newline() {
    assert_eq!(clean_name("one\ntwo"), "one\\ntwo");
}

#[test]
fn a_name_can_never_hold_a_carriage_return_or_escape() {
    // tmux: rename-window "w<ESC>y" then #{window_name} => `w\033y`.
    assert_eq!(clean_name("w\u{1b}y"), "w\\033y");
    assert_eq!(clean_name("w\ry"), "w\\ry");
}

#[test]
fn a_name_can_never_hold_a_nul() {
    assert_eq!(clean_name("a\0b"), "a\\0b");
}

#[test]
fn a_name_keeps_valid_utf8() {
    assert_eq!(clean_name("日本語"), "日本語");
    assert_eq!(clean_name("gate\u{2713}way"), "gate\u{2713}way");
}

#[test]
fn a_windows_path_name_is_left_alone() {
    // Deliberate deviation from tmux, which doubles the backslash here
    // (measured: rename-window 'C:\foo' => `C:\\foo`). On Windows a window
    // name is very often a path, and doubling every separator would corrupt
    // the common case while doing nothing for #647, which is about control
    // bytes. Everything else in clean_name matches tmux exactly.
    assert_eq!(clean_name("C:\\Users\\godwin"), "C:\\Users\\godwin");
}

#[test]
fn a_plain_name_is_unchanged() {
    for name in ["zero", "one", "gateway", "pwsh", "my window 2", "@svc-1"] {
        assert_eq!(clean_name(name), name, "clean_name changed {name}");
    }
}

#[test]
fn the_reporters_record_survives_a_tab_in_the_window_name() {
    // The shape from the issue: a tab separated record where the separators
    // are the caller's and the values can no longer smuggle one in.
    let record = format!(
        "{}\t{}\t{}",
        "%2",
        clean_name("zero\tinjected"),
        clean_name("pwsh")
    );
    assert_eq!(record, "%2\tzero\\tinjected\tpwsh");
    assert_eq!(record.matches('\t').count(), 2, "record gained a field");
}
