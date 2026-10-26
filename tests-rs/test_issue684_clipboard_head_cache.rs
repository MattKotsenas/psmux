// Issue #684: the client caches the clipboard's head per clipboard sequence
// number so a keystroke costs no OpenClipboard.  A read that could not open the
// clipboard (another window holding it for a moment) used to be cached as "no
// text" for that sequence number, so every later paste of the same clipboard
// was flushed as typing one character at a time until the clipboard changed.
use super::*;
use crate::clipboard::ClipboardBusy;
use std::cell::Cell;

#[test]
fn a_busy_read_is_retried_on_the_same_sequence_number() {
    let mut cache = ClipboardHeadCache::default();
    assert_eq!(cache.get_with(7, || Err(ClipboardBusy)), None);
    let reads = Cell::new(0);
    let head = cache
        .get_with(7, || {
            reads.set(reads.get() + 1);
            Ok(Some("Microsoft Windows".to_string()))
        })
        .map(str::to_string);
    assert_eq!(reads.get(), 1, "the clipboard was not read again after a busy read");
    assert_eq!(head.as_deref(), Some("Microsoft Windows"));
}

#[test]
fn a_successful_read_is_cached_until_the_sequence_number_moves() {
    let mut cache = ClipboardHeadCache::default();
    assert_eq!(cache.get_with(3, || Ok(Some("abc".into()))), Some("abc"));
    // Same number: served from the cache, the reader is not called.
    assert_eq!(cache.get_with(3, || panic!("re-read on an unchanged clipboard")), Some("abc"));
    assert_eq!(cache.get_with(4, || Ok(Some("xyz".into()))), Some("xyz"));
}

#[test]
fn a_clipboard_without_text_is_cached_as_none() {
    // Ok(None) is a fact about the clipboard (an image, empty), unlike Busy,
    // so it is cached and does not cost an OpenClipboard per keystroke.
    let mut cache = ClipboardHeadCache::default();
    assert_eq!(cache.get_with(9, || Ok(None)), None);
    assert_eq!(cache.get_with(9, || panic!("re-read a clipboard known to hold no text")), None);
}

#[test]
fn a_busy_read_forgets_an_older_head() {
    // The clipboard changed and the new contents could not be read: the old
    // head must not keep matching what is no longer on the clipboard.
    let mut cache = ClipboardHeadCache::default();
    assert_eq!(cache.get_with(1, || Ok(Some("old".into()))), Some("old"));
    assert_eq!(cache.get_with(2, || Err(ClipboardBusy)), None);
}

#[test]
fn the_head_is_capped() {
    let mut cache = ClipboardHeadCache::default();
    let long = "x".repeat(1000);
    let head = cache.get_with(5, || Ok(Some(long))).unwrap();
    assert_eq!(head.chars().count(), ClipboardHeadCache::HEAD_CHARS);
}
