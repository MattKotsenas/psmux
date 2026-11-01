// #957: the CLI reads the alias table back from `show -s command-alias`
// text (from_show_output). tmux prints a named key as it is, spaces and
// quotes included (cmd-show-options.c:172), so a line like
// `command-alias[a b] "ab=display -p AB"` must keep its key whole. Split
// into words it was three words and the alias was lost to `psmux ab`.

use super::*;

#[test]
fn a_named_key_with_a_space_or_quote_reads_back() {
    let mut a = CommandAliases::with_defaults();
    for (key, value) in [
        ("command-alias[a b]", "ab=display -p AB"),
        ("command-alias[q\"t]", "qt=display -p QT"),
        ("command-alias[s'q]", "sq=display -p SQ"),
        ("command-alias[#h]", "hh=display -p HH"),
        ("command-alias[b[c]", "bc=display -p BC"),
        ("command-alias[foo]", "zz=display -p ZZ"),
        ("command-alias[10]", "ten=display -p \"a b\""),
    ] {
        a.set(key, value, false).unwrap();
    }
    let back = from_show_output(&a.show_lines(false));
    assert_eq!(back, a);
    assert_eq!(back.get("ab").as_deref(), Some("display -p AB"));
    assert_eq!(back.get("qt").as_deref(), Some("display -p QT"));
    assert_eq!(back.get("sq").as_deref(), Some("display -p SQ"));
}

#[test]
fn lines_that_are_no_element_are_skipped() {
    for text in ["command-alias\n", "command-alias[x\n", "command-alias[x]\n", "status-format[0] x\n", "command-alias[] x\n"] {
        assert_eq!(from_show_output(text), CommandAliases::default(), "{text:?}");
    }
}
