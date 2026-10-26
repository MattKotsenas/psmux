// Issue #712: a byte budgeted cut of text must land on a char boundary.
// The -CC relay thread logged `&line[..line.len().min(200)]` and panicked on
// a box drawing line, which silenced the control channel for good.

use super::str_prefix_within;

#[test]
fn empty_string_stays_empty() {
    assert_eq!(str_prefix_within("", 0), "");
    assert_eq!(str_prefix_within("", 200), "");
}

#[test]
fn shorter_than_limit_is_returned_whole() {
    assert_eq!(str_prefix_within("abc", 200), "abc");
    assert_eq!(str_prefix_within("\u{2500}\u{2500}", 6), "\u{2500}\u{2500}");
    assert_eq!(str_prefix_within("abc", 3), "abc");
}

#[test]
fn zero_budget_gives_empty_prefix() {
    assert_eq!(str_prefix_within("\u{2500}", 0), "");
    assert_eq!(str_prefix_within("abc", 0), "");
}

#[test]
fn ascii_cut_is_exact() {
    let s = "a".repeat(300);
    assert_eq!(str_prefix_within(&s, 200).len(), 200);
}

// For each width: the limit lands just before a character, on its first
// byte, and inside it. The result never exceeds the budget and never splits.
fn check_width(glyph: char) {
    let w = glyph.len_utf8();
    let s: String = std::iter::repeat(glyph).take(10).collect();
    for k in 0..10 {
        let start = k * w;
        // on a boundary: exactly k glyphs
        assert_eq!(str_prefix_within(&s, start), &s[..start], "on boundary {}", start);
        // inside the k-th glyph: still exactly k glyphs, no panic
        for inside in 1..w {
            let got = str_prefix_within(&s, start + inside);
            assert_eq!(got, &s[..start], "width {} offset {}", w, start + inside);
        }
        // one byte before the boundary of glyph k+1 (last byte of glyph k)
        let before_next = start + w - 1;
        assert_eq!(str_prefix_within(&s, before_next), &s[..start]);
    }
}

#[test]
fn two_byte_character() {
    check_width('\u{0416}'); // Cyrillic
}

#[test]
fn three_byte_character() {
    check_width('\u{2500}'); // box drawing, the reported trigger
    check_width('\u{4E2D}'); // CJK
}

#[test]
fn four_byte_character() {
    check_width('\u{1F600}'); // emoji
}

#[test]
fn reported_case_byte_200_inside_box_drawing() {
    // 100 box drawing characters: byte 200 is the third byte of the 67th.
    let line: String = std::iter::repeat('\u{2500}').take(100).collect();
    assert!(!line.is_char_boundary(200));
    let got = str_prefix_within(&line, 200);
    assert_eq!(got.len(), 198);
    assert_eq!(got.chars().count(), 66);
}

#[test]
fn the_old_byte_slice_panics_where_the_helper_does_not() {
    // The expression the relay thread used before #712, kept here as proof.
    let line: String = std::iter::repeat('\u{2500}').take(100).collect();
    let old = std::panic::catch_unwind(|| line[..line.len().min(200)].len());
    assert!(old.is_err(), "byte slice at 200 inside a 3 byte char must panic");
    assert_eq!(str_prefix_within(&line, 200).len(), 198);
}
