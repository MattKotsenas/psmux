// Issue #345: Panic when entering Chinese text in command-prompt
//
// Bug: command_cursor was advanced by 1 per char regardless of UTF-8 width,
// so inserting a multi-byte char left the cursor inside the byte sequence,
// causing String::insert/remove to panic on the next keystroke.

// Mirror of the (fixed) command-prompt editor mutation logic. Keep this in
// sync with src/client.rs command_input handlers.
fn insert_char(buf: &mut String, cursor: &mut usize, c: char) {
    buf.insert(*cursor, c);
    *cursor += c.len_utf8();
}

fn backspace(buf: &mut String, cursor: &mut usize) {
    if *cursor > 0 {
        let prev_len = buf[..*cursor].chars().next_back().map(|c| c.len_utf8()).unwrap_or(1);
        let new_cursor = *cursor - prev_len;
        buf.replace_range(new_cursor..*cursor, "");
        *cursor = new_cursor;
    }
}

fn move_left(buf: &str, cursor: &mut usize) {
    if *cursor > 0 {
        let prev_len = buf[..*cursor].chars().next_back().map(|c| c.len_utf8()).unwrap_or(1);
        *cursor -= prev_len;
    }
}

fn move_right(buf: &str, cursor: &mut usize) {
    if *cursor < buf.len() {
        let next_len = buf[*cursor..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
        *cursor += next_len;
    }
}

#[test]
fn typing_chinese_does_not_panic() {
    let mut buf = String::from("#W");
    let mut cur = buf.len();
    insert_char(&mut buf, &mut cur, '中');
    insert_char(&mut buf, &mut cur, '文');
    insert_char(&mut buf, &mut cur, '窗');
    insert_char(&mut buf, &mut cur, '口');
    assert_eq!(buf, "#W中文窗口");
    assert_eq!(cur, buf.len());
}

#[test]
fn backspace_removes_full_char() {
    let mut buf = String::from("中文");
    let mut cur = buf.len();
    backspace(&mut buf, &mut cur);
    assert_eq!(buf, "中");
    assert_eq!(cur, 3);
    backspace(&mut buf, &mut cur);
    assert_eq!(buf, "");
    assert_eq!(cur, 0);
    backspace(&mut buf, &mut cur);
    assert_eq!(buf, "");
    assert_eq!(cur, 0);
}

#[test]
fn arrow_keys_traverse_char_boundaries() {
    let buf = String::from("a中b");
    let mut cur = 0;
    move_right(&buf, &mut cur); assert_eq!(cur, 1);
    move_right(&buf, &mut cur); assert_eq!(cur, 4);
    move_right(&buf, &mut cur); assert_eq!(cur, 5);
    move_right(&buf, &mut cur); assert_eq!(cur, 5);
    move_left(&buf, &mut cur); assert_eq!(cur, 4);
    move_left(&buf, &mut cur); assert_eq!(cur, 1);
    move_left(&buf, &mut cur); assert_eq!(cur, 0);
}

#[test]
fn insert_inside_string_is_safe() {
    let mut buf = String::from("ab");
    let mut cur = 1;
    insert_char(&mut buf, &mut cur, '中');
    assert_eq!(buf, "a中b");
    assert_eq!(cur, 4);
    insert_char(&mut buf, &mut cur, 'X');
    assert_eq!(buf, "a中Xb");
    assert_eq!(cur, 5);
}

#[test]
fn old_buggy_behavior_panicked() {
    let result = std::panic::catch_unwind(|| {
        let mut buf = String::from("#W");
        let mut cur = buf.len();
        buf.insert(cur, '中');
        cur += 1; // BUG: should be c.len_utf8()
        buf.insert(cur, '文'); // panics: cur=3 is inside the 3-byte sequence of '中'
        buf
    });
    assert!(result.is_err(), "old logic must panic on multi-byte input");
}
