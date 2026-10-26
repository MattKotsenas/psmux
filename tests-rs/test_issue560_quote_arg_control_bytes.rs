// Issue #560: quote_arg must escape the line-terminator bytes 0x0A/0x0D so a
// send-keys payload containing a newline cannot cut the wire line and have its
// tail executed as a separate psmux command. These tests pin the encoder.
use super::*;

#[test]
fn quote_arg_escapes_newline() {
    let out = quote_arg("TEST_HEAD\nrename-window pwned");
    assert!(!out.contains('\n'), "raw 0x0A must not survive into the wire form: {:?}", out);
    assert!(out.contains("\\n"), "newline must be escaped to \\n: {:?}", out);
}

#[test]
fn quote_arg_escapes_carriage_return() {
    let out = quote_arg("CRHEAD\rCRTAIL");
    assert!(!out.contains('\r'), "raw 0x0D must not survive: {:?}", out);
    assert!(out.contains("\\r"), "carriage return must be escaped to \\r: {:?}", out);
}

#[test]
fn quote_arg_still_escapes_quotes_and_backslashes() {
    // Backslash is escaped first so the escape bytes we introduce are not doubled.
    let out = quote_arg("a\"b\\c");
    assert_eq!(out, "\"a\\\"b\\\\c\"");
}

#[test]
fn quote_arg_if_needed_quotes_a_newline_payload() {
    // A payload with a raw newline is whitespace, so it must be quoted (and thus
    // escaped) rather than passed through untouched.
    let out = quote_arg_if_needed("a\nb");
    assert!(out.starts_with('"') && out.ends_with('"'), "must be quoted: {:?}", out);
    assert!(!out.contains('\n'), "no raw newline on the wire: {:?}", out);
}

#[test]
fn windows_path_without_newline_is_unaffected() {
    // A value with no whitespace/quote/control bytes is passed through byte-exact,
    // so Windows paths keep their single backslashes on the wire.
    assert_eq!(quote_arg_if_needed("C:\\node_modules"), "C:\\node_modules");
}
