//! Issue #597: the wheel stopped reaching pane apps on Windows 10, and Claude
//! Code reported "Scroll wheel is sending arrow keys, use PgUp/PgDn to scroll".
//!
//! Measured on the platform, not inferred (see tests/test_issue597_mouse_keepalive.ps1
//! for the end to end proof):
//!
//!   * Under ConPTY a client's OWN mouse DECSET bytes never reach the terminal.
//!     Writing `\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h` to stdout, by
//!     `WriteFile` on the raw console handle exactly as much as by
//!     `WriteConsoleW`, produced ZERO private-mode bytes on the pty output pipe.
//!   * `SetConsoleMode(hIn, ENABLE_MOUSE_INPUT)` produced `\x1b[?1003;1006h`,
//!     and clearing the flag produced `\x1b[?1003;1006l`.
//!
//! So the Win32 console flag is the ONLY mouse registration channel a local
//! client has, and `send_mouse_keepalive`'s re-assert of that flag is the only
//! code that can restore it after Windows Terminal drops it. That re-assert sat
//! behind the issue #457 build gate, so on every build below
//! `CONPTY_MOUSE_MIN_BUILD` the loss was permanent: the terminal, told
//! `\x1b[?1003;1006l`, falls back to alternate-scroll and sends Up/Down arrow
//! keys for the wheel, which psmux forwards straight into the pane.
//!
//! The #457 hazard is a different path: SGR reports arriving as VT bytes on the
//! ConPTY INPUT pipe, fed only by `send_mouse_enable` on the VT input route.
//! The DECSET byte writes stay gated; the console flag no longer is.

use super::*;

struct EnvRestore {
    build: Option<String>,
    force: Option<String>,
}

impl Drop for EnvRestore {
    fn drop(&mut self) {
        set_or_clear("PSMUX_FAKE_WIN_BUILD", self.build.as_deref());
        set_or_clear(FORCE_MOUSE_ENV, self.force.as_deref());
    }
}

fn set_or_clear(key: &str, value: Option<&str>) {
    match value {
        Some(v) => std::env::set_var(key, v),
        None => std::env::remove_var(key),
    }
}

fn with_env<T>(build: Option<&str>, force: Option<&str>, f: impl FnOnce() -> T) -> T {
    let _lock = crate::util::lock_test_env();
    let _restore = EnvRestore {
        build: std::env::var("PSMUX_FAKE_WIN_BUILD").ok(),
        force: std::env::var(FORCE_MOUSE_ENV).ok(),
    };
    set_or_clear("PSMUX_FAKE_WIN_BUILD", build);
    set_or_clear(FORCE_MOUSE_ENV, force);
    f()
}

#[test]
fn win10_keepalive_reasserts_the_console_mouse_flag() {
    // The reporter's platform. Before the fix this build returned early from
    // send_mouse_keepalive and the registration never came back.
    with_env(Some("19045"), None, || {
        assert_eq!(windows_build_number(), Some(19045));
        assert!(
            !conpty_mouse_supported(),
            "the #457 gate on the DECSET byte writes must stay in place for 19045"
        );
        assert!(
            keepalive_reasserts_mouse_input(),
            "BUG #597: the keep-alive must still re-assert ENABLE_MOUSE_INPUT on 19045, \
             it is the only channel that re-registers mouse with the terminal"
        );
    });
}

#[test]
fn server_2022_keepalive_reasserts_the_console_mouse_flag() {
    // Build 20348 is the other host class the #457 gate silently disarmed
    // (issue #573 documents it losing mouse outright).
    with_env(Some("20348"), None, || {
        assert!(!conpty_mouse_supported());
        assert!(keepalive_reasserts_mouse_input());
    });
}

#[test]
fn modern_build_keepalive_still_reasserts() {
    // Unchanged behaviour above the threshold: both halves stay on.
    with_env(Some("22631"), None, || {
        assert!(conpty_mouse_supported());
        assert!(keepalive_reasserts_mouse_input());
    });
}

#[test]
fn force_mouse_off_still_pins_the_keepalive_silent() {
    // The explicit opt-out keeps working: a user whose host genuinely must not
    // report mouse can still pin it dead, on any build.
    for build in ["19045", "22631"] {
        with_env(Some(build), Some("0"), || {
            assert!(!conpty_mouse_supported());
            assert!(
                !keepalive_reasserts_mouse_input(),
                "PSMUX_FORCE_MOUSE=0 must silence the whole keep-alive on build {build}"
            );
        });
    }
}

#[test]
fn force_mouse_on_enables_both_halves_on_a_gated_build() {
    with_env(Some("19045"), Some("1"), || {
        assert!(conpty_mouse_supported());
        assert!(keepalive_reasserts_mouse_input());
    });
}

#[test]
fn no_override_still_reasserts_the_console_flag() {
    // With no env seams set at all, whatever this host's build is, the console
    // flag half must be armed. #457's "when in doubt do not poke VT" choice
    // applies to the byte writes only and must never take mouse registration
    // down with it.
    with_env(None, None, || {
        assert!(
            keepalive_reasserts_mouse_input(),
            "the default configuration must never disable mouse re-registration"
        );
    });
}
