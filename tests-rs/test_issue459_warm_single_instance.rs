// Issue #459: "psmux spawns an unbounded, continuously-growing number of
// psmux.exe processes".
//
// Every real session is protected by the single-server-per-name mutex (issue
// #2): a second server that finds the name already owned exits immediately
// instead of running as a duplicate. Warm (`__warm__`) servers were explicitly
// exempted from that guard, on the stated rationale that "the warm pool
// intentionally runs several at once".
//
// There is no pool. `spawn_warm_server` early-returns when it verifies a live
// warm, and the handoff is a SINGLE file per namespace (`__warm__.port`), so a
// namespace can only ever publish one warm server no matter how many are
// running. Everything past the first is unreachable and immortal: nothing
// attaches to it, nothing claims it, and nothing ever kills it.
//
// The only exclusion left for warm was `acquire_warm_spawn_lock`, which is
// strictly weaker than a mutex in three ways that all showed up in the field:
//
//   * it is advisory and time-boxed — held for at most ~3s while waiting for the
//     new warm's `.port` to appear, then released whether or not it ever did;
//   * it is a plain file whose `Drop` never runs when the owner is killed, so a
//     dead owner leaves a lock that is only cleared by a 20s staleness steal;
//   * it guards the check->spawn window only, so *sequential* spawns seconds
//     apart — exactly what was observed — sail straight through it.
//
// The captured evidence was a five-deep parent chain of live `server -s __warm__`
// processes in the default namespace, spawned 1-4s apart, with NO `__warm__.port`
// present at all: each one failed to register, so the next caller saw "no warm
// exists" and started another.
//
// These tests assert the guard now covers warm names, and that the guard is
// still handed off on claim so a namespace does not end up with no warm at all.
// Ownership probes run on a SPAWNED THREAD because a Windows mutex is recursive
// for its owning thread: probing from the holder would always report "free".

use super::*;

/// Try to take `name` from a fresh thread. `true` means no live owner.
fn name_is_free(name: &str) -> bool {
    let owned = name.to_string();
    std::thread::spawn(move || crate::platform::acquire_session_mutex(&owned).is_some())
        .join()
        .expect("probe thread panicked")
}

/// Unique per-test namespace so a parallel run never collides, and so these
/// tests never contend with a real warm server on the developer's machine.
fn warm_base(suffix: &str) -> String {
    format!("psmux-t459-{}-{}____warm__", std::process::id(), suffix)
}

// Every test below computes a kernel object name through
// `platform::session_mutex_name`, which embeds `paths::data_root_tag()`. That
// tag resolves PSMUX_DATA_DIR and then falls back to USERPROFILE/HOME, and
// three other test files (plugin paths, startup log, home resolution) repoint
// HOME while holding `util::lock_test_env()`. Without taking the same lock a
// home swap could land BETWEEN an acquire and its probe, so the two calls
// named different objects and the probe reported the name free: the #459
// guard then failed for a reason that has nothing to do with warm servers.
// The pid in `warm_base` makes the name unique across the three concurrent
// bin targets; the lock is what makes it stable across threads.
#[test]
#[cfg(windows)]
fn a_second_warm_server_cannot_take_the_warm_name() {
    let _lock = crate::util::lock_test_env();
    let warm = warm_base("dup");

    let first = crate::platform::acquire_session_mutex(&warm);
    assert!(first.is_some(), "first warm should acquire '{}'", warm);

    // This is the #459 regression guard. Before the fix the warm name was never
    // locked, so this probe succeeded and the second warm ran on as an immortal,
    // unreachable process — repeated once per failed registration.
    assert!(
        !name_is_free(&warm),
        "BUG #459: a second warm server was able to take '{}'",
        warm
    );

    drop(first);
    assert!(name_is_free(&warm), "dropping the warm guard must free '{}'", warm);
}

#[test]
#[cfg(windows)]
fn warm_names_are_isolated_per_namespace() {
    let _lock = crate::util::lock_test_env();
    // `-L` namespaces must not block each other: jefe runs one warm per agent
    // namespace concurrently and all of them are legitimate.
    let a = warm_base("ns-a");
    let b = warm_base("ns-b");

    let held_a = crate::platform::acquire_session_mutex(&a);
    assert!(held_a.is_some(), "should acquire '{}'", a);

    assert!(
        name_is_free(&b),
        "namespace '{}' must not be blocked by a warm in '{}'",
        b,
        a
    );
    drop(held_a);
}

#[test]
#[cfg(windows)]
fn claiming_a_warm_frees_the_warm_name_for_its_replacement() {
    let _lock = crate::util::lock_test_env();
    let warm = warm_base("handoff");
    let claimed = format!("psmux-t459-{}-claimed", std::process::id());

    // A warm server now starts holding the warm name.
    let mut guard = crate::platform::acquire_session_mutex(&warm);
    assert!(guard.is_some(), "warm should hold '{}'", warm);

    // `new-session` claims it: the server renames itself, and rekey_session_guard
    // moves the guard onto the claimed name. This ordering matters — the server
    // spawns its replacement warm AFTER the rekey (see CtrlReq::ClaimSession), so
    // the warm name must already be free by then or the namespace would be left
    // with no warm server at all and every later open would be a cold start.
    rekey_session_guard(&mut guard, &claimed);

    assert!(guard.is_some(), "claimed name '{}' must be guarded", claimed);
    assert!(
        name_is_free(&warm),
        "claim must release '{}' so the replacement warm can start",
        warm
    );

    // The replacement warm starts and takes the name back.
    let replacement = crate::platform::acquire_session_mutex(&warm);
    assert!(
        replacement.is_some(),
        "replacement warm should acquire '{}'",
        warm
    );

    drop(replacement);
    drop(guard);
}

#[test]
#[cfg(windows)]
fn warm_and_claimed_names_do_not_alias() {
    let _lock = crate::util::lock_test_env();
    // `port_file_base()` for a namespaced warm is `<ns>____warm__`; a real session
    // in the same namespace is `<ns>__<session>`. A warm guard must not
    // accidentally block a legitimate session name in its own namespace.
    let ns = format!("psmux-t459-{}-alias", std::process::id());
    let warm = format!("{}____warm__", ns);
    let session = format!("{}__work", ns);

    let held = crate::platform::acquire_session_mutex(&warm);
    assert!(held.is_some(), "should acquire '{}'", warm);

    assert!(
        name_is_free(&session),
        "warm guard on '{}' must not block session '{}'",
        warm,
        session
    );
    drop(held);
}
