use super::*;

/// Serialize backpressure tests: push_frame broadcasts to ALL registered
/// channels globally, so concurrent tests cross-contaminate each other.
static BP_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Proof that push_frame now delivers the newest frame when the channel is full.
/// Previously (before PR #267 fix), the newest frame was silently dropped.
#[test]
fn push_frame_drops_newest_when_channel_full() {
    let _guard = BP_TEST_LOCK.lock().unwrap();
    let client_id = u64::MAX - 9990;
    // Clean up any prior registration
    shutdown_client_stream(client_id);

    let channel = register_frame_channel(client_id);

    // Fill channel to capacity with stale frames
    for idx in 0..FRAME_CHANNEL_CAPACITY {
        push_frame(&format!("stale-{idx}"));
    }

    // Now push a new frame while channel is full
    push_frame("NEWEST_CRITICAL_FRAME");

    // Drain everything from the channel
    let rx = channel.rx.lock().expect("frame receiver lock");
    let mut frames = Vec::new();
    while let Ok(frame) = rx.try_recv() {
        frames.push(frame);
    }
    drop(rx);
    shutdown_client_stream(client_id);

    // After the fix, the stale frames should be drained and
    // ONLY the newest frame should be in the queue.
    assert_eq!(frames, vec!["NEWEST_CRITICAL_FRAME".to_string()],
        "Expected only the newest frame after backpressure drain");
}

/// PR #267's original test: saturated frame queue delivers latest snapshot.
#[test]
fn push_frame_replaces_stale_backlog_when_full() {
    let _guard = BP_TEST_LOCK.lock().unwrap();
    let client_id = u64::MAX - 246;
    shutdown_client_stream(client_id);

    let channel = register_frame_channel(client_id);
    for idx in 0..FRAME_CHANNEL_CAPACITY {
        push_frame(&format!("stale-{idx}"));
    }
    push_frame("newest");

    let rx = channel.rx.lock().expect("frame receiver lock");
    let mut frames = Vec::new();
    while let Ok(frame) = rx.try_recv() {
        frames.push(frame);
    }

    shutdown_client_stream(client_id);
    assert_eq!(frames, vec!["newest".to_string()]);
}
