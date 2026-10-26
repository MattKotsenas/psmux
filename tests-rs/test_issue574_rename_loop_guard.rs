// Issue #574: "session renaming fails again in 3.3.7".
//
// The reporter runs `new-session -d` (auto-named "0") then `rename-session -t 0
// test-N` in a loop. On the 3.3.7 release the first two cycles pass and every
// cycle from the third on dies with `failed to create session '0'`.
//
// This is #505's leaked name guard, seen from a different angle. The tests in
// test_issue505_rename_session_guard.rs all follow ONE guard through its renames.
// The loop's real shape is different and is what this file covers: the name "0"
// is acquired by one owner, renamed away, and then acquired again by the NEXT
// owner, over and over. Each iteration is a separate server process taking the
// name the auto-namer just re-picked, so what matters is that the release is
// complete enough for a fresh acquirer, not merely that the original guard
// stopped pointing at it.
//
// Ownership probes run on spawned threads throughout: a Windows mutex is
// recursive for its owning thread, so an in-thread probe reports "free" even
// while this process holds the name and could never catch a stale hold.

use super::*;

/// Try to take `name` from a fresh thread. `true` means no live owner.
fn name_is_free(name: &str) -> bool {
    let owned = name.to_string();
    std::thread::spawn(move || crate::platform::acquire_session_mutex(&owned).is_some())
        .join()
        .expect("probe thread panicked")
}

/// Unique per-test key so a parallel test run never collides on a shared name.
fn key(suffix: &str) -> String {
    format!("psmux-t574-{}-{}", std::process::id(), suffix)
}

#[test]
#[cfg(windows)]
fn the_auto_named_slot_survives_ten_rename_cycles() {
    // The mutex name carries a tag of the data directory, and other tests
    // repoint PSMUX_DATA_DIR for a moment under this lock. Without it an
    // acquire and its probe can run under two different tags.
    let _env = crate::util::lock_test_env();
    // "0" stands in for the name the auto-namer keeps re-picking.
    let slot = key("slot");

    for i in 1..=10 {
        // A fresh server starts up and takes the auto-named slot.
        let mut guard = crate::platform::acquire_session_mutex(&slot);
        assert!(
            guard.is_some(),
            "iteration {}: could not acquire the auto-named slot '{}'. \
             This is the failure the reporter sees as `failed to create session '0'`",
            i,
            slot
        );

        // rename-session -t 0 test-N
        let renamed = key(&format!("renamed-{}", i));
        rekey_session_guard(&mut guard, &renamed);

        assert!(
            name_is_free(&slot),
            "iteration {}: the slot '{}' is still locked after the rename, \
             so the next new-session under that name will die as a duplicate",
            i,
            slot
        );
        assert!(
            !name_is_free(&renamed),
            "iteration {}: renamed session '{}' lost its duplicate-server guard",
            i,
            renamed
        );

        // The renamed session stays alive for the rest of the run, exactly as in
        // the report, where all ten survive to the final list-sessions. Leaking
        // the guard on purpose models that; the process owns it until exit.
        std::mem::forget(guard);
    }
}

#[test]
#[cfg(windows)]
fn a_freed_slot_is_reacquirable_by_a_different_owner() {
    // The mutex name carries a tag of the data directory, and other tests
    // repoint PSMUX_DATA_DIR for a moment under this lock. Without it an
    // acquire and its probe can run under two different tags.
    let _env = crate::util::lock_test_env();
    // The release has to be visible to a DIFFERENT acquirer, not just to the
    // thread that performed the rename. Windows mutex ownership is per thread,
    // so a release that only satisfies the owning thread would still fail the
    // next server, which is a separate process entirely.
    let slot = key("handoff-slot");
    let renamed = key("handoff-renamed");

    let mut guard = crate::platform::acquire_session_mutex(&slot);
    assert!(guard.is_some(), "setup: should have acquired '{}'", slot);
    rekey_session_guard(&mut guard, &renamed);

    // Take the freed name from another thread and hold it, the way the next
    // server in the loop would, then confirm the two coexist.
    let slot_owned = slot.clone();
    let (took_tx, took_rx) = std::sync::mpsc::channel::<bool>();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let successor = std::thread::spawn(move || {
        let held = crate::platform::acquire_session_mutex(&slot_owned);
        took_tx.send(held.is_some()).unwrap();
        release_rx.recv().unwrap();
        drop(held);
    });

    assert!(
        took_rx.recv().expect("successor thread died"),
        "the next server could not take the freed slot '{}'",
        slot
    );
    assert!(
        !name_is_free(&renamed),
        "the renamed session must keep its own guard while the slot is reused"
    );

    release_tx.send(()).unwrap();
    successor.join().unwrap();
    drop(guard);
}

#[test]
#[cfg(windows)]
fn interleaved_sessions_each_keep_their_own_guard() {
    // The mutex name carries a tag of the data directory, and other tests
    // repoint PSMUX_DATA_DIR for a moment under this lock. Without it an
    // acquire and its probe can run under two different tags.
    let _env = crate::util::lock_test_env();
    // The loop leaves every renamed session running, so by iteration ten there
    // are ten live guards plus a free slot. Nothing may collide.
    let slot = key("multi-slot");
    let mut held = Vec::new();

    for i in 1..=5 {
        let mut guard = crate::platform::acquire_session_mutex(&slot);
        assert!(guard.is_some(), "iteration {}: slot '{}' was not free", i, slot);
        let renamed = key(&format!("multi-{}", i));
        rekey_session_guard(&mut guard, &renamed);
        assert!(guard.is_some(), "iteration {}: rename lost the guard", i);
        held.push((renamed, guard));
    }

    // Every earlier session must still hold its own name.
    for (name, _) in &held {
        assert!(
            !name_is_free(name),
            "'{}' lost its guard while later iterations ran",
            name
        );
    }
    assert!(name_is_free(&slot), "the slot '{}' must end up free", slot);

    for (name, guard) in held {
        drop(guard);
        assert!(name_is_free(&name), "dropping the guard must free '{}'", name);
    }
}
