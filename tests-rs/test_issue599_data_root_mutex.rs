// Regression tests for issue #599: the single-server name mutex ignored
// PSMUX_DATA_DIR, so two isolated registries could not both hold a session of
// the same name.
//
// The guard's object name used to be `Local\psmux-session-{base}`, where
// `base` is `{socket_name}__{session_name}` under `-L` and the bare session
// name otherwise. A kernel object name is machine-wide, but the registry the
// guard protects (`.port`/`.key`/`.sid`/`.pid`) is rooted at PSMUX_DATA_DIR.
// The mismatch had two measured consequences on 3.3.8:
//
//   1. `new-session -s X` in a second data root exited 1 with
//      "psmux: failed to create session 'X'" while a live X existed in the
//      first root, even though the two share no registry file, port or key.
//   2. `__warm__` is a fixed name, so only the FIRST data root on the box ever
//      published a warm server; every other root silently lost warm start.
//
// The fix folds a tag derived from the RESOLVED data root into the object
// name. These tests lock the resulting contract at the name level, which is
// where the collision lived; tests/test_issue599_data_dir_mutex.ps1 covers the
// same ground end to end with real servers.
//
// Env is process-global, so every test here serializes on the CRATE-WIDE
// crate::util::lock_test_env() and restores the previous value on drop, for
// the same reason spelled out in test_data_dir_override.rs.

use super::session_mutex_name;
use crate::paths::{data_root_tag, psmux_dir};

/// Restores a mutated env var on drop, so a failure mid-test cannot leak the
/// value into other tests.
struct EnvGuard {
    var: &'static str,
    prev: Option<std::ffi::OsString>,
}

impl EnvGuard {
    fn set(var: &'static str, value: &str) -> EnvGuard {
        let prev = std::env::var_os(var);
        std::env::set_var(var, value);
        EnvGuard { var, prev }
    }

    fn remove(var: &'static str) -> EnvGuard {
        let prev = std::env::var_os(var);
        std::env::remove_var(var);
        EnvGuard { var, prev }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        match &self.prev {
            Some(value) => std::env::set_var(self.var, value),
            None => std::env::remove_var(self.var),
        }
    }
}

/// THE BUG: one session name, two data roots, one mutex name. Before the fix
/// both roots produced `Local\psmux-session-X`, so the second root's server
/// saw the first root's mutex and exited as a duplicate cold-spawn.
#[test]
fn same_session_name_in_two_data_roots_gets_two_mutex_names() {
    let _lock = crate::util::lock_test_env();

    let one = {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\one");
        session_mutex_name("dupname")
    };
    let two = {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\two");
        session_mutex_name("dupname")
    };

    assert_ne!(
        one, two,
        "two isolated registries must not collide on one guard name"
    );
}

/// The warm server arm of the same bug. `__warm__` is chosen by psmux, not the
/// caller, so the collision hit every user of a second data root even when no
/// session name was ever repeated.
#[test]
fn warm_name_is_publishable_from_every_data_root() {
    let _lock = crate::util::lock_test_env();

    let one = {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\one");
        session_mutex_name("__warm__")
    };
    let two = {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\two");
        session_mutex_name("__warm__")
    };

    assert_ne!(
        one, two,
        "each data root publishes its own __warm__.port, so each needs its own guard name"
    );
}

/// The other half of the contract: the tag must key on the RESOLVED root, not
/// the raw variable. Pointing PSMUX_DATA_DIR at the default `~\.psmux` names
/// the SAME registry, so it must name the same mutex; keying on the raw value
/// would split one registry across two guards and reintroduce the duplicate
/// servers the guard exists to prevent.
#[test]
fn explicit_default_root_keys_identically_to_unset() {
    let _lock = crate::util::lock_test_env();

    let (implicit, resolved) = {
        let _g = EnvGuard::remove("PSMUX_DATA_DIR");
        (session_mutex_name("sess"), psmux_dir())
    };
    let explicit = {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", &resolved);
        session_mutex_name("sess")
    };

    assert_eq!(
        implicit, explicit,
        "one registry must yield one guard name however the root was spelled"
    );
}

/// Windows treats `C:/Foo`, `C:\Foo` and `c:\foo` as one directory, so the tag
/// has to as well, for the same "one registry, one guard" reason.
#[test]
fn separator_and_case_variants_of_one_root_agree() {
    let _lock = crate::util::lock_test_env();

    let mut names = Vec::new();
    for raw in [
        "C:\\psmux599\\Root",
        "C:/psmux599/Root",
        "c:\\psmux599\\root",
        "C:\\psmux599\\Root\\",
    ] {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", raw);
        names.push((raw, session_mutex_name("sess")));
    }

    for (raw, name) in &names[1..] {
        assert_eq!(
            &names[0].1, name,
            "{raw:?} names the same directory as {:?}",
            names[0].0
        );
    }
}

/// Isolating by root must not weaken the guard inside a root: distinct session
/// names, and distinct `-L` bases, still get distinct mutex names.
#[test]
fn names_still_separate_within_one_data_root() {
    let _lock = crate::util::lock_test_env();
    let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\one");

    let a = session_mutex_name("alpha");
    let b = session_mutex_name("beta");
    let l = session_mutex_name("ns__alpha"); // what port_file_base() builds under -L
    assert_ne!(a, b, "two sessions in one root still guard separately");
    assert_ne!(a, l, "-L keeps namespacing through the base name");
}

/// Shape guards. The object stays in the per-logon-session `Local\` namespace,
/// keeps its historical prefix, and carries exactly one backslash: the
/// namespace separator. Path characters in the base are still mapped out,
/// because a backslash in the leaf name would make CreateMutexW fail and the
/// guard fail open.
#[test]
fn object_name_stays_a_legal_local_kernel_object() {
    let _lock = crate::util::lock_test_env();
    let _g = EnvGuard::set("PSMUX_DATA_DIR", "C:\\psmux599\\one");

    let name = session_mutex_name("a\\b/c");
    assert!(
        name.starts_with("Local\\psmux-session-"),
        "unexpected prefix: {name}"
    );
    assert_eq!(
        name.matches('\\').count(),
        1,
        "the only backslash may be the Local\\ separator: {name}"
    );
    assert!(name.ends_with("-a_b_c"), "path chars must be mapped out: {name}");

    let tag = data_root_tag();
    assert_eq!(tag.len(), 16, "tag is a 16-hex digest: {tag}");
    assert!(
        tag.chars().all(|c| c.is_ascii_hexdigit()),
        "tag must be name-safe: {tag}"
    );
    assert!(name.contains(&tag), "the root tag belongs in the name: {name}");
}
