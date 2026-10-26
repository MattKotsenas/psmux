//! Keystroke latency regression: the interactive path must run on a 1ms timer
//! period, not Windows' default 15.6ms per-process tick.
//!
//! Since Windows 10 2004 the tick is per process. A process that never calls
//! timeBeginPeriod rounds every sub-tick wait up to 15.6ms even when the
//! machine's global resolution is already 1ms, which turned the pane parser's
//! 1ms coalescing tick and the server loop's 1ms recv_timeout into two 15.6ms
//! stalls in series on every echoed character: 31ms of keystroke to screen
//! latency, measured against a 1.07ms bare conhost baseline.
//!
//! These tests pin the mechanism rather than a wall clock number, so they do
//! not flake on a loaded machine. The end to end distributions live in
//! tests/test_keystroke_latency_bench.ps1.

use super::{is_high, set_high};

/// `set_high` and `is_high` act on ONE process wide timer period (`HELD` in
/// timer_res.rs), so these tests cannot run on parallel threads: one test's
/// `set_high(true)` lands between another's `set_high(false)` and its
/// `assert!(!is_high())`, and the release test fails about one run in thirty.
/// Measured on 2026-09-12: 1 of 30 parallel runs failed, 0 of 30 serialised.
static PERIOD: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn hold() -> std::sync::MutexGuard<'static, ()> {
    PERIOD.lock().unwrap_or_else(|e| e.into_inner())
}

/// A sub-tick sleep must actually be sub-tick while the period is held. This is
/// the whole point of the module: without the period, this sleep measures
/// ~15.6ms on stock Windows.
#[test]
#[cfg(windows)]
fn one_ms_sleep_is_not_quantised_to_the_default_tick() {
    let _period = hold();
    let was = is_high();
    set_high(true);
    assert!(is_high(), "period should be held after set_high(true)");

    // Median of a handful: one sample can be stretched by any scheduler hiccup
    // on a busy box, but the default tick would stretch ALL of them.
    let mut samples = Vec::new();
    for _ in 0..9 {
        let t = std::time::Instant::now();
        std::thread::sleep(std::time::Duration::from_millis(1));
        samples.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = samples[samples.len() / 2];

    if !was {
        set_high(false);
    }

    assert!(
        median < 8.0,
        "a 1ms sleep took {median:.2}ms: the process is running on the default \
         15.6ms tick, so every keystroke echo pays a full tick in the pane \
         parser and another in the server loop"
    );
}

/// The period is released when the last client detaches, so a background server
/// does not hold the machine on a high resolution timer forever.
#[test]
#[cfg(windows)]
fn period_is_released_again() {
    let _period = hold();
    set_high(true);
    assert!(is_high());
    set_high(false);
    assert!(!is_high(), "set_high(false) must release the period");
}

/// Repeated calls must not stack timeBeginPeriod/timeEndPeriod: the server loop
/// calls set_high every iteration, and an unbalanced pair would either leak a
/// period reference forever or release one it never took.
#[test]
#[cfg(windows)]
fn set_high_is_idempotent() {
    let _period = hold();
    set_high(false);
    for _ in 0..5 {
        set_high(true);
    }
    assert!(is_high());
    for _ in 0..5 {
        set_high(false);
    }
    assert!(!is_high());
    // A release with nothing held is a no-op, not an unbalanced timeEndPeriod.
    set_high(false);
    assert!(!is_high());
}
