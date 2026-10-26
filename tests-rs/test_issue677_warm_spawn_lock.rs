//! Issue #677: a warm-spawn lock left behind by a holder that is gone must not
//! keep the standby missing.
//!
//! The lock guards the check-then-spawn window in `spawn_warm_server` so two
//! callers cannot both decide "there is no standby" and spawn one each. It has
//! always named its holder in the file; what it did not do was ask whether that
//! holder still exists. Staleness was judged by the file's age alone, so a lock
//! written by a process that died mid spawn blocked every spawn for the whole
//! window.
//!
//! Measured on the installed build before the fix, in an isolated data root: a
//! lock naming pid 999999, which does not exist, left a session creation with
//! no standby after 12 s; a further 25 s of waiting produced none, because
//! nothing retries; and the next creation produced one instantly, once the age
//! rule finally allowed the steal. So the lock is the block and the age rule is
//! the reason it lasts.
//!
//! These cases pin the decision itself. `lock_older_than` is left to the age
//! path, which only an unidentifiable holder reaches now.

use super::*;

fn tmp_lock(tag: &str, body: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "psmux_i677_{}_{}_{}.spawnlock",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::write(&p, body).expect("write lock");
    p
}

/// The reported case: a fresh lock naming a pid that does not exist.
#[test]
fn a_lock_naming_a_dead_pid_is_abandoned_at_once() {
    // 0xFFFFFFF0 is far above any live pid on Windows and is not a valid
    // process; the point is a pid nothing owns.
    let p = tmp_lock("deadpid", "4294967280");
    assert!(
        warm_spawn_lock_is_abandoned(&p),
        "a lock whose holder is not running must be takeable without waiting out its age"
    );
    let _ = std::fs::remove_file(&p);
}

/// The same, in the anchored form the lock is written in now.
#[test]
fn a_lock_naming_a_dead_pid_with_a_creation_time_is_abandoned_at_once() {
    let p = tmp_lock("deadanchor", "4294967280:132000000000000000");
    assert!(
        warm_spawn_lock_is_abandoned(&p),
        "the anchored form must reach the same verdict as the bare pid form"
    );
    let _ = std::fs::remove_file(&p);
}

/// A live holder that really is this process is a spawn in progress, and a
/// fresh one must be respected or two standbys get spawned.
#[test]
fn a_fresh_lock_held_by_a_live_process_is_respected() {
    let pid = std::process::id();
    let creation = crate::platform::process_kill::process_creation_time(pid).unwrap_or(0);
    let p = tmp_lock("live", &crate::session::format_pid_file_contents(pid, creation));
    assert!(
        !warm_spawn_lock_is_abandoned(&p),
        "a spawn that is actually running must keep its lock"
    );
    let _ = std::fs::remove_file(&p);
}

/// A live pid carrying a different creation time is a recycled number, not the
/// holder, so the lock is abandoned.
#[test]
fn a_live_pid_with_the_wrong_creation_time_is_a_recycled_pid() {
    let pid = std::process::id();
    let body = crate::session::format_pid_file_contents(pid, 1);
    let p = tmp_lock("recycled", &body);
    let real = crate::platform::process_kill::process_creation_time(pid);
    if real == Some(1) || real.is_none() {
        // Cannot tell the two apart on this platform; the case is meaningless
        // rather than failing.
        let _ = std::fs::remove_file(&p);
        return;
    }
    assert!(
        warm_spawn_lock_is_abandoned(&p),
        "a pid that has been reused is not the holder, so the lock is free"
    );
    let _ = std::fs::remove_file(&p);
}

/// A body that names nobody usable falls back to the age rule, which keeps
/// locks written by older builds working.
#[test]
fn an_unreadable_holder_falls_back_to_the_age_rule() {
    let p = tmp_lock("garbage", "not-a-pid");
    assert!(
        !warm_spawn_lock_is_abandoned(&p),
        "a fresh lock is respected even when its holder cannot be identified"
    );
    let _ = std::fs::remove_file(&p);

    let missing = std::env::temp_dir().join(format!("psmux_i677_absent_{}.spawnlock", std::process::id()));
    let _ = std::fs::remove_file(&missing);
    assert!(
        !warm_spawn_lock_is_abandoned(&missing),
        "a lock that cannot be read at all is respected rather than stolen"
    );
}

/// Acquiring writes the holder in the anchored form, so the next caller can
/// reach a verdict about it at all.
#[test]
fn acquiring_records_a_holder_the_next_caller_can_identify() {
    let path = std::env::temp_dir().join(format!(
        "psmux_i677_acquire_{}_{}.spawnlock",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    let _ = std::fs::remove_file(&path);
    let guard = acquire_warm_spawn_lock(&path.display().to_string())
        .expect("an unheld lock must be acquirable");
    let body = std::fs::read_to_string(&path).expect("the lock records its holder");
    let parsed = crate::session::parse_pid_file_contents(&body);
    assert_eq!(
        parsed.map(|(pid, _)| pid),
        Some(std::process::id()),
        "the body must name this process, got {body:?}"
    );
    assert!(
        parsed.and_then(|(_, c)| c).is_some(),
        "the body must carry a creation time so a recycled pid can be told apart, got {body:?}"
    );
    // While held by this live process, a second caller must not take it.
    assert!(
        acquire_warm_spawn_lock(&path.display().to_string()).is_none(),
        "a lock held by a running spawn must not be handed to a second caller"
    );
    drop(guard);
    assert!(!path.exists(), "dropping the guard releases the lock");
}

/// And a lock left behind by a holder that is gone is taken by the next caller
/// rather than blocking it, which is the whole of #677's first half.
#[test]
fn a_caller_takes_over_a_lock_whose_holder_died() {
    let path = std::env::temp_dir().join(format!(
        "psmux_i677_takeover_{}_{}.spawnlock",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    std::fs::write(&path, "4294967280").expect("plant a lock from a dead holder");
    let guard = acquire_warm_spawn_lock(&path.display().to_string())
        .expect("a lock whose holder is gone must be takeable");
    let body = std::fs::read_to_string(&path).expect("read back");
    assert_eq!(
        crate::session::parse_pid_file_contents(&body).map(|(pid, _)| pid),
        Some(std::process::id()),
        "the new holder must be recorded, got {body:?}"
    );
    drop(guard);
    let _ = std::fs::remove_file(&path);
}
