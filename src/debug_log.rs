//! Centralized debug logging for psmux.
//!
//! All logs write to `~/.psmux/` and are gated by environment variables.
//! Nothing is stored in the repo or source tree — only in the user's
//! home directory under `.psmux/`.
//!
//! ## Environment Variables
//!
//! | Variable               | Log file                          | Description                          |
//! |------------------------|-----------------------------------|--------------------------------------|
//! | `PSMUX_CLIENT_DEBUG=1` | `~/.psmux/client_debug.log`       | Client TUI rendering, draw, status   |
//! | `PSMUX_STYLE_DEBUG=1`  | `~/.psmux/style_debug.log`        | Style/theme parsing, inline styles   |/// | `PSMUX_INPUT_DEBUG=1`  | `~/.psmux/input_debug.log`        | Every crossterm event + console mode |//! | `PSMUX_MOUSE_DEBUG=1`  | `~/.psmux/mouse_debug.log`        | Mouse injection (existing)           |
//! | `PSMUX_SSH_DEBUG=1`    | `~/.psmux/ssh_input.log`          | SSH input handling (existing)        |
//! | `PSMUX_LATENCY_LOG=1`  | `~/.psmux/latency.log`            | Keypress-to-render latency (existing)|
//! | `PSMUX_SESSION_DEBUG=1`| `~/.psmux/session_debug.log`      | Session-registry stale-port cleanup  |
//! | `PSMUX_AUTO_RENAME_DEBUG=1` | `~/.psmux/auto_rename_debug.log` | Auto-rename per-decision trace - input signals, throttle, format result, final action |
//!
//! All loggers are:
//! - **Off by default** — zero overhead when disabled (one atomic load per call)
//! - **Capped** — auto-stop after N entries to prevent disk fill
//! - **Thread-safe** — use `LazyLock<Mutex<Option<File>>>`
//! - **Timestamped** — `[HH:MM:SS.mmm]` prefix on every line
//! - **Truncated on startup** — fresh log each session (no stale data)

use std::io::Write;
use std::sync::{LazyLock, Mutex};
use std::sync::atomic::{AtomicU32, Ordering};

/// Resolve the psmux data directory (`~/.psmux/`).
fn psmux_dir() -> String {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default();
    format!("{}/.psmux", home)
}

/// Open a log file in the psmux data directory, creating the directory if needed.
/// Returns `None` if the file cannot be created.
fn open_log(filename: &str) -> Option<std::fs::File> {
    let dir = psmux_dir();
    let _ = std::fs::create_dir_all(&dir);
    std::fs::OpenOptions::new()
        .create(true)
        .truncate(true) // fresh log each session
        .write(true)
        .open(format!("{}/{}", dir, filename))
        .ok()
}

/// Check if an env var is set to a truthy value ("1" or "true").
fn env_enabled(var: &str) -> bool {
    std::env::var(var).map_or(false, |v| v == "1" || v.eq_ignore_ascii_case("true"))
}

// ─── Client debug log ───────────────────────────────────────────────────────

/// Client debug log file, gated by `PSMUX_CLIENT_DEBUG=1`.
/// Covers: frame receive, JSON parse, draw lifecycle, status bar rendering.
static CLIENT_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_CLIENT_DEBUG") { return Mutex::new(None); }
    Mutex::new(open_log("client_debug.log"))
});

static CLIENT_LOG_COUNT: AtomicU32 = AtomicU32::new(0);

/// Maximum log entries per session to prevent disk fill.
const CLIENT_LOG_CAP: u32 = 5000;

/// Log a client debug message. No-op unless `PSMUX_CLIENT_DEBUG=1`.
///
/// # Arguments
/// * `component` — short tag like `"frame"`, `"draw"`, `"status"`, `"parse"`
/// * `msg` — the log message (should not contain newlines)
pub fn client_log(component: &str, msg: &str) {
    let n = CLIENT_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= CLIENT_LOG_CAP {
        if n == CLIENT_LOG_CAP {
            // Log one final "cap reached" message
            if let Ok(mut guard) = CLIENT_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ({} entries), further logging suppressed ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"), CLIENT_LOG_CAP);
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = CLIENT_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if client debug logging is active.
pub fn client_log_enabled() -> bool {
    CLIENT_LOG.lock().ok().map_or(false, |g| g.is_some())
}

// ─── Style debug log ────────────────────────────────────────────────────────

/// Style/theme parsing debug log, gated by `PSMUX_STYLE_DEBUG=1`.
/// Covers: inline style parsing, unclosed directives, color mapping.
static STYLE_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_STYLE_DEBUG") { return Mutex::new(None); }
    Mutex::new(open_log("style_debug.log"))
});

static STYLE_LOG_COUNT: AtomicU32 = AtomicU32::new(0);
const STYLE_LOG_CAP: u32 = 2000;

/// Log a style debug message. No-op unless `PSMUX_STYLE_DEBUG=1`.
pub fn style_log(component: &str, msg: &str) {
    let n = STYLE_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= STYLE_LOG_CAP {
        if n == STYLE_LOG_CAP {
            if let Ok(mut guard) = STYLE_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"));
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = STYLE_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if style debug logging is active.
pub fn style_log_enabled() -> bool {
    STYLE_LOG.lock().ok().map_or(false, |g| g.is_some())
}

// ─── Input debug log ────────────────────────────────────────────────────────

/// Input event debug log, gated by `PSMUX_INPUT_DEBUG=1`.
/// Traces every crossterm event + console input mode at startup.
static INPUT_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_INPUT_DEBUG") { return Mutex::new(None); }
    Mutex::new(open_log("input_debug.log"))
});

static INPUT_LOG_COUNT: AtomicU32 = AtomicU32::new(0);
const INPUT_LOG_CAP: u32 = 10000;

/// Log an input debug message. No-op unless `PSMUX_INPUT_DEBUG=1`.
pub fn input_log(component: &str, msg: &str) {
    let n = INPUT_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= INPUT_LOG_CAP {
        if n == INPUT_LOG_CAP {
            if let Ok(mut guard) = INPUT_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"));
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = INPUT_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if input debug logging is active.
pub fn input_log_enabled() -> bool {
    INPUT_LOG.lock().ok().map_or(false, |g| g.is_some())
}

// ─── Server debug log ───────────────────────────────────────────────────────

/// Server debug log, gated by `PSMUX_SERVER_DEBUG=1`.
/// Traces active_idx changes, command dispatch, etc.
static SERVER_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_SERVER_DEBUG") { return Mutex::new(None); }
    Mutex::new(open_log("server_debug.log"))
});

static SERVER_LOG_COUNT: AtomicU32 = AtomicU32::new(0);
const SERVER_LOG_CAP: u32 = 10000;

/// Log a server debug message. No-op unless `PSMUX_SERVER_DEBUG=1`.
pub fn server_log(component: &str, msg: &str) {
    let n = SERVER_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= SERVER_LOG_CAP {
        if n == SERVER_LOG_CAP {
            if let Ok(mut guard) = SERVER_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"));
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = SERVER_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if server debug logging is active.
pub fn server_log_enabled() -> bool {
    SERVER_LOG.lock().ok().map_or(false, |g| g.is_some())
}

// ─── Session-registry debug log ─────────────────────────────────────────────

/// Session-registry lifecycle log, gated by `PSMUX_SESSION_DEBUG=1`.
/// Covers stale-port cleanup decisions: boot-time reaps, auth-rejected
/// (reused-port) reaps, unparseable port files, and live/inconclusive
/// probe verdicts — exactly the path that decided whether a session shows
/// up as a `(not responding)` zombie.
///
/// Unlike the other loggers this **appends** rather than truncates, because
/// registry cleanup runs in many short-lived CLI processes (every `psmux`
/// invocation calls it at startup); truncating on open would clobber the
/// log before it could be read.
static SESSION_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_SESSION_DEBUG") { return Mutex::new(None); }
    let dir = psmux_dir();
    let _ = std::fs::create_dir_all(&dir);
    let f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}/session_debug.log", dir))
        .ok();
    Mutex::new(f)
});

static SESSION_LOG_COUNT: AtomicU32 = AtomicU32::new(0);
const SESSION_LOG_CAP: u32 = 5000;

/// Log a session-registry message. No-op unless `PSMUX_SESSION_DEBUG=1`.
pub fn session_log(component: &str, msg: &str) {
    let n = SESSION_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= SESSION_LOG_CAP {
        if n == SESSION_LOG_CAP {
            if let Ok(mut guard) = SESSION_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"));
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = SESSION_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if session-registry debug logging is active.
pub fn session_log_enabled() -> bool {
    SESSION_LOG.lock().ok().map_or(false, |g| g.is_some())
}

// ─── Auto-rename debug log ──────────────────────────────────────────────────

/// Auto-rename decision trace, gated by `PSMUX_AUTO_RENAME_DEBUG=1`.
/// One entry per auto-rename evaluation, recording:
///
///   - the input signals (foreground command, pane.title, current win.name)
///   - the throttle/change-detection verdict (ran or skipped, why)
///   - the format-expansion result
///   - the final action (renamed, no-op, kept-current)
///
/// Used to diagnose flicker, sticky values, hostname leakage from OSC titles,
/// and any other "why is my window named X" question. Mirrors tmux's
/// `log_debug("@%u ...")` calls in `names.c::check_window_name`.
static AUTO_RENAME_LOG: LazyLock<Mutex<Option<std::fs::File>>> = LazyLock::new(|| {
    if !env_enabled("PSMUX_AUTO_RENAME_DEBUG") { return Mutex::new(None); }
    Mutex::new(open_log("auto_rename_debug.log"))
});

static AUTO_RENAME_LOG_COUNT: AtomicU32 = AtomicU32::new(0);
const AUTO_RENAME_LOG_CAP: u32 = 10000;

/// Log an auto-rename decision. No-op unless `PSMUX_AUTO_RENAME_DEBUG=1`.
pub fn auto_rename_log(component: &str, msg: &str) {
    let n = AUTO_RENAME_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
    if n >= AUTO_RENAME_LOG_CAP {
        if n == AUTO_RENAME_LOG_CAP {
            if let Ok(mut guard) = AUTO_RENAME_LOG.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "[{}][log] --- log cap reached ---",
                        chrono::Local::now().format("%H:%M:%S%.3f"));
                    let _ = f.flush();
                }
            }
        }
        return;
    }
    if let Ok(mut guard) = AUTO_RENAME_LOG.lock() {
        if let Some(ref mut f) = *guard {
            let _ = writeln!(f, "[{}][{}] {}",
                chrono::Local::now().format("%H:%M:%S%.3f"), component, msg);
            let _ = f.flush();
        }
    }
}

/// Returns `true` if auto-rename debug logging is active.
pub fn auto_rename_log_enabled() -> bool {
    AUTO_RENAME_LOG.lock().ok().map_or(false, |g| g.is_some())
}
