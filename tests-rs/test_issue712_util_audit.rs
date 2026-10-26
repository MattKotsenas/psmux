// #712 audit: util helpers that cut or edit text by byte offset.

use super::{parse_cat_file_sink, str_prefix_within_cols, str_remove_char_before};

// pipe-pane `caé foo`: byte 3 is inside the é. The server used to die here.
#[test]
fn cat_sink_check_survives_a_multibyte_third_byte() {
    assert_eq!(parse_cat_file_sink("ca\u{e9} foo"), None);
    assert_eq!(parse_cat_file_sink("\u{e9}\u{e9}"), None);
    assert_eq!(parse_cat_file_sink("\u{65e5}\u{672c}"), None);
}

#[test]
fn cat_sink_still_recognised() {
    assert!(parse_cat_file_sink("cat > out.txt").is_some());
    assert!(parse_cat_file_sink("CAT >> out.txt").is_some());
    assert_eq!(parse_cat_file_sink("ca"), None);
    assert_eq!(parse_cat_file_sink(""), None);
}

#[test]
fn cols_prefix_counts_display_width() {
    assert_eq!(str_prefix_within_cols("abcdef", 3), "abc");
    assert_eq!(str_prefix_within_cols("abc", 10), "abc");
    assert_eq!(str_prefix_within_cols("", 5), "");
    // CJK is 2 columns each: 5 columns hold 2 of them, never half of one.
    assert_eq!(str_prefix_within_cols("\u{65e5}\u{672c}\u{8a9e}", 5), "\u{65e5}\u{672c}");
    assert_eq!(str_prefix_within_cols("\u{65e5}\u{672c}\u{8a9e}", 1), "");
    // Box drawing is 1 column, 3 bytes.
    let boxes: String = std::iter::repeat('\u{2500}').take(50).collect();
    assert_eq!(str_prefix_within_cols(&boxes, 17).chars().count(), 17);
}

// Customize mode Backspace: the cursor sits at edit_buffer.len() (bytes).
#[test]
fn backspace_removes_a_whole_multibyte_char() {
    let mut s = String::from("ab\u{e9}");
    let cur = s.len();
    assert!(str_remove_char_before(&mut s, cur));
    assert_eq!(s, "ab");

    let mut s = String::from("x\u{1f600}");
    let cur = s.len();
    assert!(str_remove_char_before(&mut s, cur));
    assert_eq!(s, "x");

    let mut s = String::from("\u{2500}\u{2500}");
    assert!(str_remove_char_before(&mut s, 3));
    assert_eq!(s, "\u{2500}");
}

#[test]
fn backspace_edge_cases() {
    let mut s = String::new();
    assert!(!str_remove_char_before(&mut s, 0));
    let mut s = String::from("abc");
    assert!(!str_remove_char_before(&mut s, 0));
    assert!(str_remove_char_before(&mut s, 99)); // past the end clamps
    assert_eq!(s, "ab");
    // A cursor inside a character floors to the boundary before it.
    let mut s = String::from("a\u{e9}");
    assert!(str_remove_char_before(&mut s, 2));
    assert_eq!(s, "\u{e9}");
}

#[test]
fn the_old_backspace_panicked() {
    let r = std::panic::catch_unwind(|| {
        let mut s = String::from("ab\u{e9}");
        let cur = s.len();
        s.remove(cur - 1);
    });
    assert!(r.is_err());
}
