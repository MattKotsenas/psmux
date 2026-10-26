//! `new-session` readiness poll backoff.
//!
//! The client waits for a freshly spawned or warm-claimed server by polling,
//! and the sleep between probes is pure launch latency: whatever is left of it
//! when the session actually becomes usable is time the user waits for nothing.
//!
//! The interval used to be a flat 20ms. Measured on a warm-claimed
//! `new-session -d` whose server was reachable at ~29.5ms, that cost ~19.6ms of
//! median dead sleep — 40% of the whole ~49ms launch — and quantised the launch
//! time into visible 20ms steps (51 / 68 / 88 / 104ms, decided purely by where
//! the sleep boundary fell). An interleaved A/B of the two builds measured the
//! before arm at a 68.0ms median with that staircase and the after arm flat at
//! 53.4ms.
//!
//! These tests pin the two properties that make the ramp both fast and safe:
//! it starts fine enough to catch a warm claim, and it backs off to the old
//! ceiling so a genuinely slow cold start never becomes a poll storm against a
//! server that is still spawning its shell.

use super::{next_ready_poll_step_ms, READY_POLL_FIRST_MS, READY_POLL_MAX_MS};

/// Walk the backoff from its first value, returning the sleep sequence.
fn steps(count: usize) -> Vec<u64> {
    let mut out = Vec::with_capacity(count);
    let mut s = READY_POLL_FIRST_MS;
    for _ in 0..count {
        out.push(s);
        s = next_ready_poll_step_ms(s);
    }
    out
}

#[test]
fn first_probe_is_fine_grained() {
    // A warm claim is reachable in tens of milliseconds. The first sleep has to
    // be small enough that the client notices promptly rather than sleeping
    // through most of the remaining wait.
    assert_eq!(READY_POLL_FIRST_MS, 1);
    assert!(READY_POLL_FIRST_MS < READY_POLL_MAX_MS);
}

#[test]
fn backoff_doubles_then_caps_at_the_old_flat_interval() {
    assert_eq!(steps(8), vec![1, 2, 4, 8, 16, 20, 20, 20]);
    // The ceiling is exactly the interval this used to poll at, so a slow start
    // is never polled more aggressively than the previous behaviour.
    assert_eq!(next_ready_poll_step_ms(READY_POLL_MAX_MS), READY_POLL_MAX_MS);
    assert_eq!(next_ready_poll_step_ms(READY_POLL_MAX_MS * 4), READY_POLL_MAX_MS);
}

#[test]
fn never_returns_zero_so_the_loop_cannot_spin() {
    // A zero sleep would turn the readiness wait into a busy loop hammering the
    // server with connects while it is trying to spawn a shell.
    for prev in [0u64, 1, 2, 3, 7, 19, 20, 21, 1000, u64::MAX] {
        assert!(
            next_ready_poll_step_ms(prev) >= 1,
            "step from {prev} must never be 0"
        );
    }
    // saturating_mul: a pathological huge previous value must not overflow.
    assert_eq!(next_ready_poll_step_ms(u64::MAX), READY_POLL_MAX_MS);
}

#[test]
fn a_warm_claim_is_detected_within_one_ceiling_interval() {
    // A warm-claimed server becomes reachable around 30ms. Under the ramp the
    // probe that follows must land within a single old-interval window of that
    // moment, which is the whole point of the change.
    let mut elapsed = 0u64;
    let mut s = READY_POLL_FIRST_MS;
    let ready_at = 30u64;
    while elapsed < ready_at {
        elapsed += s;
        s = next_ready_poll_step_ms(s);
    }
    assert!(
        elapsed - ready_at < READY_POLL_MAX_MS,
        "detected {elapsed}ms after a session ready at {ready_at}ms"
    );
    // The flat 20ms interval would have woken at 40ms; the ramp wakes at 31ms.
    assert_eq!(elapsed, 31);
}

#[test]
fn a_slow_cold_start_stays_cheap() {
    // Backing off matters as much as starting fine: reaching a full second of
    // waiting must cost a probe count in the same league as the flat interval
    // did (1000 / 20 = 50), not hundreds.
    let mut elapsed = 0u64;
    let mut s = READY_POLL_FIRST_MS;
    let mut probes = 0usize;
    while elapsed < 1000 {
        elapsed += s;
        s = next_ready_poll_step_ms(s);
        probes += 1;
    }
    assert!(probes <= 60, "1s of waiting cost {probes} probes");
    // And the full 15s deadline stays bounded well under a thousand wakeups.
    while elapsed < 15_000 {
        elapsed += s;
        s = next_ready_poll_step_ms(s);
        probes += 1;
    }
    assert!(probes <= 800, "15s of waiting cost {probes} probes");
}
