// Issue #431: the shared server's frame carries the sixel fields too.
//
// The per-session server builds its frame in two places in server/mod.rs and
// both append `sixel` and `image_blobs`; the shared server builds its own in
// shared::frame::build_frame, which had neither, so a client of a shared
// server never received an image.

use super::{build_frame, FrameCache};

fn frame_json(app: &mut crate::types::AppState, cache: &mut FrameCache) -> serde_json::Value {
    let mut meta_dirty = true;
    build_frame(app, cache, &mut meta_dirty).expect("build_frame");
    serde_json::from_str(&cache.combined_buf).expect("the frame is JSON")
}

#[test]
fn shared_frame_ships_the_blob_once_and_the_option() {
    let mut app = crate::server::test_issue431_m4_blobs::app_with_sixel_pane();
    let mut cache = FrameCache::new();

    let first = frame_json(&mut app, &mut cache);
    assert_eq!(first["sixel"], serde_json::Value::Bool(true), "the sixel option rides on the frame");
    let blobs = first["image_blobs"].as_object().expect("image_blobs is an object");
    assert_eq!(blobs.len(), 1, "the visible image's blob is shipped: {blobs:?}");

    let second = frame_json(&mut app, &mut cache);
    let blobs = second["image_blobs"].as_object().expect("image_blobs is an object");
    assert!(blobs.is_empty(), "an already shipped blob is not sent again: {blobs:?}");

    app.sixel = false;
    let third = frame_json(&mut app, &mut cache);
    assert_eq!(third["sixel"], serde_json::Value::Bool(false));
}
