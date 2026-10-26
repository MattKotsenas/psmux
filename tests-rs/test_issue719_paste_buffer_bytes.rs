//! Issue #719: the exact bytes `paste-buffer` writes, pinned against tmux's
//! cmd-paste-buffer.c.
//!
//! tmux replaces every LF in the buffer with a separator (`-s`, else LF for
//! `-r`, else CR, cmd-paste-buffer.c:88 to :95) and touches nothing else.  The
//! brackets of `-p` go around the result only when the pane has bracketed paste
//! on (:97 and :124).  Measured on master 7f070fe with a byte recorder in the
//! pane, psmux wrote LF for a plain `paste-buffer` and CR for `-p -r`; both are
//! the wrong way round.

use crate::commands::{paste_buffer_payload, parse_paste_buffer_args, PasteBufferArgs};

fn payload(text: &str, args: &[&str]) -> String {
    paste_buffer_payload(text, &parse_paste_buffer_args(args))
}

#[test]
fn default_separator_is_carriage_return() {
    assert_eq!(PasteBufferArgs::default().effective_separator(), "\r");
    assert_eq!(payload("a\nb\nc", &[]), "a\rb\rc");
}

#[test]
fn bracket_flag_does_not_change_the_separator() {
    assert_eq!(payload("a\nb\nc", &["-p"]), "a\rb\rc");
}

#[test]
fn r_flag_keeps_linefeed_with_and_without_p() {
    assert_eq!(payload("a\nb\nc", &["-r"]), "a\nb\nc");
    assert_eq!(payload("a\nb\nc", &["-p", "-r"]), "a\nb\nc");
}

#[test]
fn s_flag_wins_and_is_written_as_given() {
    assert_eq!(payload("a\nb\nc", &["-s", "X"]), "aXbXc");
    assert_eq!(payload("a\nb\nc", &["-p", "-s", "X"]), "aXbXc");
    assert_eq!(payload("a\nb", &["-r", "-s", "::"]), "a::b");
}

#[test]
fn only_linefeeds_are_replaced() {
    // tmux walks the buffer with memchr('\n').  A CRLF (a Windows file loaded
    // with load-buffer, a clipboard paste) is one line break here, or every
    // line would be submitted twice; a lone CR is data and stays.
    assert_eq!(payload("a\r\nb", &[]), "a\rb");
    assert_eq!(payload("a\r\nb\r\n", &["-r"]), "a\nb\n");
    assert_eq!(payload("a\r\nb", &["-s", "|"]), "a|b");
    assert_eq!(payload("a\rb", &[]), "a\rb");
    assert_eq!(payload("tab\there\x1bend", &[]), "tab\there\x1bend");
    assert_eq!(payload("no newline", &[]), "no newline");
    assert_eq!(payload("trailing\n", &[]), "trailing\r");
    assert_eq!(payload("", &[]), "");
}

#[test]
fn verbatim_writer_keeps_the_payload_and_brackets_it() {
    let mut buf: Vec<u8> = Vec::new();
    super::write_paste_bytes(&mut buf, b"a\nb\rc", true, false);
    assert_eq!(buf, b"\x1b[200~a\nb\rc\x1b[201~".to_vec());
}

#[test]
fn normalising_writer_is_unchanged_for_terminal_pastes() {
    let mut buf: Vec<u8> = Vec::new();
    super::write_paste_bytes(&mut buf, b"a\r\nb\nc", false, true);
    assert_eq!(buf, b"a\rb\rc".to_vec());
}
