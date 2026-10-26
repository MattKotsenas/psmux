// Issue #441: zero-width combining marks (Thai/Arabic etc) miscounted as width 1.
// Feed raw UTF-8 bytes straight into the emulator and read the cursor column.
// This isolates psmux's grid width computation from ConPTY entirely.

fn cursor_col_after(s: &str) -> u16 {
    let mut p = vt100_psmux::Parser::new(24, 200, 0);
    p.process(s.as_bytes());
    p.screen().cursor_position().1
}

#[test]
fn thai_and_cjk_widths() {
    // U+0E01 base consonant KO KAI (width 1)
    assert_eq!(cursor_col_after("\u{0E01}"), 1, "base consonant should be 1 cell");

    // base + MAI EK tone mark (Mn, width 0) -> still 1 cell
    assert_eq!(cursor_col_after("\u{0E01}\u{0E48}"), 1, "base + tone mark should be 1 cell");

    // base + SARA I above vowel (Mn) -> 1 cell
    assert_eq!(cursor_col_after("\u{0E01}\u{0E34}"), 1, "base + above vowel should be 1 cell");

    // base + MAI HAN-AKAT U+0E31 (Mn) -> 1 cell
    assert_eq!(cursor_col_after("\u{0E01}\u{0E31}"), 1, "base + hanakat should be 1 cell");

    // full repro word "ก่อน" = 0E01 0E48 0E2D 0E19 -> 3 base cells
    assert_eq!(cursor_col_after("\u{0E01}\u{0E48}\u{0E2D}\u{0E19}"), 3, "kaawn should be 3 cells");

    // Arabic base + fatha (Mn) -> 1 cell
    assert_eq!(cursor_col_after("\u{0627}\u{064E}"), 1, "arabic base + fatha should be 1 cell");

    // CJK ideograph U+4E00 (wide) -> 2 cells
    assert_eq!(cursor_col_after("\u{4E00}"), 2, "CJK ideograph should be 2 cells");

    // ASCII sanity
    assert_eq!(cursor_col_after("abc"), 3, "ascii sanity");
}

#[test]
fn full_repro_string_width() {
    // "ปฏิบัติการ ก่อน ก้าว ที่ ๓"
    let s = "\u{0E1B}\u{0E0F}\u{0E34}\u{0E1A}\u{0E31}\u{0E15}\u{0E34}\u{0E01}\u{0E32}\u{0E23}\
             \u{0020}\u{0E01}\u{0E48}\u{0E2D}\u{0E19}\
             \u{0020}\u{0E01}\u{0E49}\u{0E32}\u{0E27}\
             \u{0020}\u{0E17}\u{0E35}\u{0E48}\
             \u{0020}\u{0E53}";
    // ปฏิบัติการ = 7 spacing cells (3 combining marks are width 0), then
    // " ก่อน"=1+3, " ก้าว"=1+3, " ที่"=1+1, " ๓"=1+1  => 7+4+4+2+2 = 19
    assert_eq!(cursor_col_after(s), 19, "full repro string should be 19 cells");
}

#[test]
fn per_cluster_widths() {
    let cases: &[(&str, u16)] = &[
        ("\u{0E1B}\u{0E0F}\u{0E34}\u{0E1A}\u{0E31}\u{0E15}\u{0E34}\u{0E01}\u{0E32}\u{0E23}", 7), // ปฏิบัติการ (7 spacing + 3 marks)
        ("\u{0E01}\u{0E48}\u{0E2D}\u{0E19}", 3), // ก่อน
        ("\u{0E01}\u{0E49}\u{0E32}\u{0E27}", 3), // ก้าว
        ("\u{0E17}\u{0E35}\u{0E48}", 1),         // ที่  (base + above-vowel + tone)
        ("\u{0E53}", 1),                          // ๓ thai digit three
    ];
    for (s, want) in cases {
        assert_eq!(cursor_col_after(s), *want, "cluster {:?} width", s);
    }
}
