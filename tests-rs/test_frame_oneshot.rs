// A frame's one shot clipboard write (OSC 52) and bell survive the frame
// being superseded. Before, the server's frame slot, the client's line queue
// and the client's drain each replaced an unread frame with the newer one and
// the events it carried were gone: 20 OSC 52 writes from a pane reached the
// host terminal 0 times (tests/test_frame_oneshot_delivery.ps1).

use super::*;

fn frame(body: &str) -> String {
    format!("{{\"layout\":{}}}", body)
}

fn shots(clip: Option<&str>, bell: bool) -> OneShots {
    OneShots { clip_b64: clip.map(str::to_string), bell, image_blobs: String::new() }
}

#[test]
fn append_then_take_round_trips() {
    for s in [shots(Some("T1NDTUFSSzE="), false), shots(None, true), shots(Some("YQ=="), true)] {
        let mut f = frame("1");
        append(&mut f, &s);
        assert!(f.ends_with('}'));
        assert_eq!(take(&mut f), s);
        assert_eq!(f, frame("1"), "take leaves the frame as it was");
    }
}

#[test]
fn append_writes_the_fields_the_client_parses() {
    let mut f = frame("1");
    append(&mut f, &shots(Some("YQ=="), true));
    let v: serde_json::Value = serde_json::from_str(&f).unwrap();
    assert_eq!(v["clipboard_osc52"], "YQ==");
    assert_eq!(v["bell"], true);
}

#[test]
fn newline_terminated_lines_from_the_client_reader() {
    // The client's socket reader hands lines on WITH their newline.
    let mut f = frame("1");
    append(&mut f, &shots(Some("YQ=="), true));
    f.push('\n');
    assert_eq!(take(&mut f), shots(Some("YQ=="), true));
    assert_eq!(f, frame("1"));
    let mut older = frame("1");
    append(&mut older, &shots(Some("YQ=="), false));
    older.push_str("\r\n");
    let mut newer = format!("{}\n", frame("2"));
    supersede(&mut older, &mut newer);
    assert_eq!(take(&mut newer), shots(Some("YQ=="), false));
}

#[test]
fn take_ignores_frames_without_one_shots() {
    for raw in [frame("1"), "NC".to_string(), "DETACH".to_string(), "{\"x\":\"a\\\"}\"}".to_string()] {
        let mut f = raw.clone();
        assert!(take(&mut f).is_empty());
        assert_eq!(f, raw);
    }
}

#[test]
fn take_does_not_read_pane_text_as_a_field() {
    // Escaped pane content can never end the frame with the field's spelling.
    let raw = "{\"text\":\",\\\"clipboard_osc52\\\":\\\"YQ==\\\"\"}".to_string();
    let mut f = raw.clone();
    assert!(take(&mut f).is_empty());
    assert_eq!(f, raw);
}

#[test]
fn supersede_carries_clipboard_and_bell() {
    let mut older = frame("1");
    append(&mut older, &shots(Some("b2xk"), true));
    let mut newer = frame("2");
    supersede(&mut older, &mut newer);
    let mut got = newer.clone();
    assert_eq!(take(&mut got), shots(Some("b2xk"), true));
    assert_eq!(got, frame("2"), "the screen is the newer frame's");
}

#[test]
fn supersede_keeps_the_newer_clipboard_write() {
    let mut older = frame("1");
    append(&mut older, &shots(Some("b2xk"), true));
    let mut newer = frame("2");
    append(&mut newer, &shots(Some("bmV3"), false));
    supersede(&mut older, &mut newer);
    assert_eq!(take(&mut newer), shots(Some("bmV3"), true));
}

#[test]
fn supersede_of_a_plain_frame_changes_nothing() {
    let mut older = frame("1");
    let mut newer = frame("2");
    append(&mut newer, &shots(None, true));
    let before = newer.clone();
    supersede(&mut older, &mut newer);
    assert_eq!(newer, before);
}

#[test]
fn client_queue_keeps_one_shots_of_a_replaced_frame() {
    let (tx, rx) = crate::client_frame_queue::frame_queue();
    let mut f1 = frame("1");
    append(&mut f1, &shots(Some("T1NDTUFSSzE="), false));
    let mut f2 = frame("2");
    append(&mut f2, &shots(None, true));
    assert!(tx.send(f1 + "\n"));
    assert!(tx.send(f2 + "\n"));
    assert!(tx.send(frame("3") + "\n"));
    assert_eq!(tx.queued(), 1, "frames still coalesce");
    let mut got = rx.try_recv().unwrap();
    assert_eq!(take(&mut got), shots(Some("T1NDTUFSSzE="), true));
    assert_eq!(got.trim_end(), frame("3"));
}

#[test]
fn server_frame_slot_keeps_one_shots_of_a_replaced_frame() {
    let (poke, _wake) = std::sync::mpsc::channel();
    let id = u64::MAX - 0x6f73_6335;
    let slot = crate::types::register_frame_channel(id, poke);
    let mut f1 = frame("1");
    append(&mut f1, &shots(Some("T1NDTUFSSzE="), true));
    crate::types::push_frame(&f1);
    crate::types::push_frame(&frame("2"));
    let held = slot.lock().unwrap().take();
    crate::types::deregister_frame_channel(id);
    let mut got = held.expect("a frame is waiting");
    assert_eq!(take(&mut got), shots(Some("T1NDTUFSSzE="), true));
    assert_eq!(got, frame("2"));
}

// Sixel image blobs (#431) are shipped once per id, so a superseded frame
// that held one left the client naming an image it never received.

/// A frame shaped like the server's: `image_blobs` ends the builder's text.
fn sixel_frame(layout: &str, blobs: &str) -> String {
    format!("{{\"layout\":{},\"sixel\":true,\"image_blobs\":{{{}}}}}", layout, blobs)
}

fn blob_map(frame: &str) -> std::collections::HashMap<String, String> {
    let v: serde_json::Value = serde_json::from_str(frame).unwrap();
    serde_json::from_value(v["image_blobs"].clone()).unwrap_or_default()
}

#[test]
fn supersede_carries_image_blobs() {
    let mut older = sixel_frame("1", "\"5\":\"QUJD\"");
    let mut newer = sixel_frame("2", "");
    supersede(&mut older, &mut newer);
    assert_eq!(newer.matches("\"image_blobs\"").count(), 1, "{newer}");
    let v: serde_json::Value = serde_json::from_str(&newer).unwrap();
    assert_eq!(v["layout"], 2, "the screen is the newer frame's");
    assert_eq!(blob_map(&newer).get("5").map(String::as_str), Some("QUJD"));
}

#[test]
fn supersede_keeps_the_blobs_of_both_frames() {
    let mut older = sixel_frame("1", "\"5\":\"QUJD\"");
    let mut newer = sixel_frame("2", "\"6\":\"REVG\"");
    supersede(&mut older, &mut newer);
    let m = blob_map(&newer);
    assert_eq!(m.len(), 2);
    assert_eq!(m["5"], "QUJD");
    assert_eq!(m["6"], "REVG");
}

#[test]
fn supersede_over_three_frames_keeps_the_first_blob() {
    // The client's line queue supersedes into the same slot again and again.
    let mut slot = sixel_frame("1", "\"5\":\"QUJD\"");
    for n in 2..5 {
        let mut next = sixel_frame(&n.to_string(), "");
        supersede(&mut slot, &mut next);
        slot = next;
    }
    assert_eq!(blob_map(&slot).get("5").map(String::as_str), Some("QUJD"));
}

#[test]
fn blobs_clipboard_and_bell_travel_together() {
    let mut older = sixel_frame("1", "\"5\":\"QUJD\"");
    append(&mut older, &shots(Some("b2xk"), true));
    let mut newer = sixel_frame("2", "");
    append(&mut newer, &shots(Some("bmV3"), false));
    supersede(&mut older, &mut newer);
    let v: serde_json::Value = serde_json::from_str(&newer).unwrap();
    assert_eq!(v["clipboard_osc52"], "bmV3", "the newer write wins");
    assert_eq!(v["bell"], true);
    assert_eq!(blob_map(&newer)["5"], "QUJD");
    let got = take(&mut newer);
    assert_eq!(got.image_blobs, "\"5\":\"QUJD\"");
    assert_eq!(got.image_blob_map()["5"], "QUJD");
    assert_eq!(newer, "{\"layout\":2,\"sixel\":true}");
}

#[test]
fn take_removes_an_empty_image_blobs() {
    let mut f = sixel_frame("1", "");
    assert!(take(&mut f).is_empty());
    assert_eq!(f, "{\"layout\":1,\"sixel\":true}");
}

#[test]
fn take_does_not_read_pane_text_as_image_blobs() {
    let raw = "{\"text\":\",\\\"image_blobs\\\":{\\\"5\\\":\\\"QUJD\\\"}\"}".to_string();
    let mut f = raw.clone();
    assert!(take(&mut f).is_empty());
    assert_eq!(f, raw);
}

#[test]
fn a_superseded_frame_without_one_shots_changes_nothing() {
    let mut older = sixel_frame("1", "");
    let mut newer = sixel_frame("2", "");
    supersede(&mut older, &mut newer);
    assert_eq!(newer, sixel_frame("2", ""));
}
