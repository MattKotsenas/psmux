//! Issue #573: mouse stopped working after 3.3.6 -> 3.3.7 on Windows Server 2022.
//!
//! The #457 gate refuses mouse on every build under `CONPTY_MOUSE_MIN_BUILD`,
//! but the crash it exists to prevent was only ever measured on Win10-era
//! conhost (19041/19045). Build 20348 (Server 2022) sits under the threshold
//! while, by the reporter's account, happily running mouse for the whole 3.3.6
//! era. On such a host 3.3.7 removed the raw-WriteFile bypass that was the only
//! thing putting the terminal into mouse reporting, and left no way to get it
//! back: `mouse` still reads `on`, and nothing the user can set changes the
//! outcome. `PSMUX_FORCE_MOUSE` is that way back.
//!
//! The gate itself is deliberately left alone. Lowering the threshold on
//! inference would risk reintroducing a fast-fail that kills the pane process,
//! which is strictly worse than a dead mouse. These tests pin the override's
//! semantics, and the #457 tests continue to pin the default behaviour.

use super::*;

/// Restores both env seams on drop, so a failing assertion inside the closure
/// still cleans up. Restoring after the call instead would skip the restore on
/// unwind and leak `PSMUX_FORCE_MOUSE=1` into the #457 tests, turning one real
/// failure into two confusing ones.
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

/// Set both env seams for the duration of the closure and restore them after.
/// Uses the shared env lock so this never races other env-touching tests.
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
fn server_2022_is_gated_off_by_default() {
    // The reporter's build. Without an override it stays suppressed: that is
    // #457's deliberate choice and this fix does not change it.
    with_env(Some("20348"), None, || {
        assert_eq!(windows_build_number(), Some(20348));
        assert!(
            !conpty_mouse_supported(),
            "default behaviour on 20348 must remain unchanged by the #573 fix"
        );
    });
}

#[test]
fn force_mouse_restores_mouse_on_a_gated_build() {
    // The actual fix: the reporter can get his mouse back without downgrading.
    with_env(Some("20348"), Some("1"), || {
        assert!(
            conpty_mouse_supported(),
            "BUG #573: PSMUX_FORCE_MOUSE=1 must re-enable mouse on a gated build"
        );
    });
}

#[test]
fn the_override_is_consulted_before_the_build_is_read() {
    // conpty_mouse_supported() also fails closed when the build cannot be read
    // at all, so a host where RtlGetVersion fails loses mouse the same way. That
    // case cannot be emulated here: an unparseable PSMUX_FAKE_WIN_BUILD falls
    // through to the real RtlGetVersion, which succeeds on this host. What IS
    // testable, and what makes the unknown-build case work, is that the override
    // short-circuits ahead of the build lookup entirely.
    with_env(Some("not-a-number"), Some("1"), || {
        assert_eq!(
            forced_mouse_setting(),
            Some(true),
            "the override must resolve without reference to any build number"
        );
        assert!(conpty_mouse_supported(), "and it must win");
    });
    // Same override, a build that would otherwise refuse: proves the
    // short-circuit is what decides, not the build happening to be modern.
    with_env(Some("19045"), Some("1"), || {
        assert!(
            conpty_mouse_supported(),
            "the override must win over even the crash-confirmed 19045"
        );
    });
}

#[test]
fn force_mouse_off_pins_it_off_on_a_modern_build() {
    // The other direction, for a host above the threshold whose conhost still
    // misbehaves: without this such a user would have no lever at all.
    with_env(Some("26200"), Some("0"), || {
        assert!(
            !conpty_mouse_supported(),
            "PSMUX_FORCE_MOUSE=0 must suppress mouse even on a modern build"
        );
    });
}

#[test]
fn every_documented_spelling_is_accepted() {
    for v in ["1", "on", "true", "yes", "ON", " Yes ", "TRUE"] {
        with_env(Some("20348"), Some(v), || {
            assert_eq!(
                forced_mouse_setting(),
                Some(true),
                "'{}' must parse as an explicit yes",
                v
            );
        });
    }
    for v in ["0", "off", "false", "no", "OFF", " No ", "FALSE"] {
        with_env(Some("26200"), Some(v), || {
            assert_eq!(
                forced_mouse_setting(),
                Some(false),
                "'{}' must parse as an explicit no",
                v
            );
        });
    }
}

#[test]
fn an_unrecognised_value_falls_back_to_the_build_check() {
    // Never guess. A typo must not silently flip a crash-safety gate either way.
    for v in ["", "  ", "maybe", "2", "enable"] {
        with_env(Some("20348"), Some(v), || {
            assert_eq!(
                forced_mouse_setting(),
                None,
                "'{}' must not be read as a decision",
                v
            );
            assert!(
                !conpty_mouse_supported(),
                "'{}' must leave the build check in charge (gated at 20348)",
                v
            );
        });
        with_env(Some("26200"), Some(v), || {
            assert!(
                conpty_mouse_supported(),
                "'{}' must leave the build check in charge (allowed at 26200)",
                v
            );
        });
    }
}

#[test]
fn the_override_does_not_disturb_the_457_boundary() {
    // With the override absent, every #457 boundary must land exactly where it
    // did before. This is the regression guard for the fix itself.
    for (build, expected) in [
        ("19045", false),
        ("20348", false),
        ("22522", false),
        ("22523", true),
        ("26200", true),
    ] {
        with_env(Some(build), None, || {
            assert_eq!(
                conpty_mouse_supported(),
                expected,
                "build {} must be unchanged by the #573 fix",
                build
            );
        });
    }
}
