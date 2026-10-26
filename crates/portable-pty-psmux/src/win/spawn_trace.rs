//! Env gated per step timing of a ConPTY pane spawn.
//!
//! `PSMUX_SPAWN_TRACE=1` appends one line per step to
//! `%TEMP%\psmux_spawn_trace.log` (or `PSMUX_SPAWN_TRACE_FILE`).  Each line
//! carries the step's start and its duration in microseconds on a clock shared
//! by every thread of the process, plus the thread id, so spawns that started
//! together read as a timeline and a step that waits on another shows as a
//! late start or a long duration.  Inert unless set: one relaxed load.

use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Instant;

static ENABLED: AtomicU8 = AtomicU8::new(0);

pub(crate) fn enabled() -> bool {
    match ENABLED.load(Ordering::Relaxed) {
        1 => false,
        2 => true,
        _ => {
            let on = std::env::var("PSMUX_SPAWN_TRACE").map(|v| v == "1").unwrap_or(false);
            ENABLED.store(if on { 2 } else { 1 }, Ordering::Relaxed);
            on
        }
    }
}

fn origin() -> Instant {
    static ORIGIN: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    *ORIGIN.get_or_init(Instant::now)
}

/// Microseconds since the process trace origin.
pub(crate) fn now_us() -> u64 {
    origin().elapsed().as_micros() as u64
}

/// One step: started at `start_us`, ended now.  `what` is only built when
/// the trace is on, so a spawn with the trace off formats nothing.
pub(crate) fn step<S: AsRef<str>>(start_us: u64, what: impl FnOnce() -> S) {
    if !enabled() {
        return;
    }
    let end = now_us();
    let tid = unsafe { winapi::um::processthreadsapi::GetCurrentThreadId() };
    let path = std::env::var("PSMUX_SPAWN_TRACE_FILE").unwrap_or_else(|_| {
        let tmp = std::env::var("TEMP").unwrap_or_else(|_| ".".to_string());
        format!("{}\\psmux_spawn_trace.log", tmp)
    });
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = std::io::Write::write_all(
            &mut f,
            format!(
                "pid={} tid={} start={} dur={} {}\n",
                std::process::id(),
                tid,
                start_us,
                end.saturating_sub(start_us),
                what().as_ref()
            )
            .as_bytes(),
        );
    }
}
