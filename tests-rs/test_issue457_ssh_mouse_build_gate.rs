//! Issue #457: SSH attach must NOT enable mouse reporting on ConPTY builds
//! that cannot safely accept VT mouse input (< 22523).
//!
//! On Win10 / early Win11 (< 22523), enabling mouse reporting over SSH is
//! actively dangerous: the first click sends an SGR mouse report back into
//! ConPTY input, where the old conhost VT parser fast-fails (0xc0000409) and
//! kills the pane process. The build check must therefore GATE the
//! mouse-enable send, not merely warn about it.
//!
//! These tests exercise the pure gating decision (`conpty_mouse_supported`)
//! by pinning the reported build via `PSMUX_FAKE_WIN_BUILD`.

use super::*;

/// Restores `PSMUX_FAKE_WIN_BUILD` on drop so a failing assertion inside the
/// closure still cleans up. Restoring after the call instead skips the restore
/// on unwind, leaking a pinned build into every later test in the file.
struct BuildRestore(Option<String>);

impl Drop for BuildRestore {
    fn drop(&mut self) {
        match &self.0 {
            Some(v) => std::env::set_var("PSMUX_FAKE_WIN_BUILD", v),
            None => std::env::remove_var("PSMUX_FAKE_WIN_BUILD"),
        }
    }
}

/// Set `PSMUX_FAKE_WIN_BUILD` for the duration of the closure, restoring the
/// previous value afterwards. Uses the shared env lock so it never races other
/// env-touching tests.
fn with_fake_build<T>(build: Option<&str>, f: impl FnOnce() -> T) -> T {
    let _lock = crate::util::lock_test_env();
    let _restore = BuildRestore(std::env::var("PSMUX_FAKE_WIN_BUILD").ok());
    match build {
        Some(v) => std::env::set_var("PSMUX_FAKE_WIN_BUILD", v),
        None => std::env::remove_var("PSMUX_FAKE_WIN_BUILD"),
    }
    f()
}

#[test]
fn old_win10_build_19045_is_not_mouse_supported() {
    // The reporter's exact build. This is the regression guard: 19045 must
    // report unsupported so send_mouse_enable() suppresses.
    with_fake_build(Some("19045"), || {
        assert_eq!(windows_build_number(), Some(19045));
        assert!(
            !conpty_mouse_supported(),
            "BUG #457: build 19045 must NOT be treated as mouse-capable"
        );
    });
}

#[test]
fn boundary_build_22522_is_not_supported() {
    with_fake_build(Some("22522"), || {
        assert!(
            !conpty_mouse_supported(),
            "one below the threshold must be unsupported"
        );
    });
}

#[test]
fn threshold_build_22523_is_supported() {
    with_fake_build(Some("22523"), || {
        assert!(
            conpty_mouse_supported(),
            "exactly the threshold build must be supported"
        );
    });
}

#[test]
fn modern_build_26200_is_supported() {
    // The dev/test host. Fix must NOT regress mouse on modern builds.
    with_fake_build(Some("26200"), || {
        assert!(
            conpty_mouse_supported(),
            "modern build must keep mouse-over-SSH enabled"
        );
    });
}

#[test]
fn threshold_constant_matches_documented_value() {
    assert_eq!(CONPTY_MOUSE_MIN_BUILD, 22523);
}

#[test]
fn fake_build_override_parses_and_wins() {
    with_fake_build(Some("  30000  "), || {
        // whitespace-padded value still parses
        assert_eq!(windows_build_number(), Some(30000));
    });
}
