// Issue #509: no stable per-namespace server identity.
//
// psmux runs one `psmux.exe server` process per session, so `#{pid}` (and its
// alias `#{server_pid}`) resolve to whichever session's server answered the
// request. Creating a session therefore changes the value for the whole
// namespace, which a supervisor following the tmux idiom reads as "the server
// restarted" — marking every already-running session as having lost its server.
//
// The fix is a namespace-scoped instance token: minted by the first server in a
// namespace, read (never re-minted) by every later server, and re-minted only
// when the namespace has genuinely gone away and come back. Because every server
// in the namespace reads the SAME file, it does not matter which one answers the
// query — they all report the same token.
//
// These tests exercise the pure decision logic and the on-disk format against
// the real production code. Peer liveness is injected, so there is no OS process
// enumeration and the tests are deterministic and cross-platform. The end-to-end
// proof (the issue's own three-session reproduction) lives in the PowerShell E2E.

use super::*;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static TMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

fn temp_dir() -> PathBuf {
    let mut p = std::env::temp_dir();
    let n = TMP_COUNTER.fetch_add(1, Ordering::SeqCst);
    p.push(format!("psmux_issue509_{}_{}", std::process::id(), n));
    let _ = std::fs::create_dir_all(&p);
    p
}

/// Write a `.pid` registry entry for `base` naming `pid` with `creation_ft`.
fn write_pid_entry(dir: &Path, base: &str, pid: u32, creation_ft: u64) {
    let _ = std::fs::write(
        dir.join(format!("{}.pid", base)),
        format_pid_file_contents(pid, creation_ft),
    );
}

/// A liveness oracle: every pid in the list is alive with the given creation time.
fn alive(entries: &[(u32, u64)]) -> impl Fn(u32) -> Option<u64> + '_ {
    move |pid| entries.iter().find(|(p, _)| *p == pid).map(|(_, ft)| *ft)
}

/// A liveness oracle where nothing is alive.
fn all_dead(_pid: u32) -> Option<u64> {
    None
}

// ---------------------------------------------------------------------------
// Namespace membership: which .pid entries belong to which namespace
// ---------------------------------------------------------------------------

#[test]
fn named_namespace_claims_only_its_own_prefixed_entries() {
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha__one", 100, 11);
    write_pid_entry(&dir, "alpha__two", 101, 12);
    write_pid_entry(&dir, "beta__one", 200, 21);
    write_pid_entry(&dir, "solo", 300, 31);

    let peers = namespace_peer_pids(&dir, Some("alpha"), 0);
    let pids: HashSet<u32> = peers.iter().map(|t| t.pid).collect();
    assert_eq!(
        pids,
        HashSet::from([100, 101]),
        "a named namespace must see only its own sessions, got {:?}",
        pids
    );
}

#[test]
fn named_namespace_includes_its_warm_server() {
    // The warm helper is a real server in the namespace; if it is alive the
    // namespace has not gone away, so it must count as a peer.
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha____warm__", 100, 11);

    let peers = namespace_peer_pids(&dir, Some("alpha"), 0);
    assert_eq!(
        peers.iter().map(|t| t.pid).collect::<Vec<_>>(),
        vec![100],
        "the namespace's warm server must be counted as a peer"
    );
}

#[test]
fn default_namespace_does_not_claim_named_namespace_entries() {
    let dir = temp_dir();
    write_pid_entry(&dir, "solo", 300, 31);
    write_pid_entry(&dir, "alpha__one", 100, 11);

    let peers = namespace_peer_pids(&dir, None, 0);
    let pids: HashSet<u32> = peers.iter().map(|t| t.pid).collect();
    assert_eq!(
        pids,
        HashSet::from([300]),
        "the default namespace must not adopt `-L` namespace servers, got {:?}",
        pids
    );
}

#[test]
fn default_namespace_includes_its_own_warm_server() {
    let dir = temp_dir();
    write_pid_entry(&dir, "__warm__", 400, 41);

    let peers = namespace_peer_pids(&dir, None, 0);
    assert_eq!(
        peers.iter().map(|t| t.pid).collect::<Vec<_>>(),
        vec![400],
        "the default namespace's warm server must be counted as a peer"
    );
}

#[test]
fn self_is_never_its_own_peer() {
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha__one", 100, 11);

    let peers = namespace_peer_pids(&dir, Some("alpha"), 100);
    assert!(
        peers.is_empty(),
        "the calling server must not count itself as a peer, got {:?}",
        peers.iter().map(|t| t.pid).collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------
// "Am I the first server in this namespace?"
// ---------------------------------------------------------------------------

#[test]
fn no_peers_at_all_means_first_server() {
    assert!(is_first_server_in_namespace(&[], all_dead));
}

#[test]
fn a_live_peer_means_not_first() {
    let peers = vec![PidTarget { pid: 100, creation_time: 11 }];
    assert!(
        !is_first_server_in_namespace(&peers, alive(&[(100, 11)])),
        "a live peer means the namespace is still up, so the token must be kept"
    );
}

#[test]
fn a_dead_peer_does_not_keep_the_namespace_alive() {
    let peers = vec![PidTarget { pid: 100, creation_time: 11 }];
    assert!(
        is_first_server_in_namespace(&peers, all_dead),
        "a registry entry for a dead process must not preserve a stale token"
    );
}

#[test]
fn a_recycled_pid_does_not_keep_the_namespace_alive() {
    // Same pid, different creation time: the original exited and the OS handed
    // the number to an unrelated process. That is not our peer.
    let peers = vec![PidTarget { pid: 100, creation_time: 11 }];
    assert!(
        is_first_server_in_namespace(&peers, alive(&[(100, 99)])),
        "a pid whose creation time no longer matches must not preserve the token"
    );
}

#[test]
fn one_live_peer_among_dead_ones_is_enough() {
    let peers = vec![
        PidTarget { pid: 100, creation_time: 11 },
        PidTarget { pid: 101, creation_time: 12 },
        PidTarget { pid: 102, creation_time: 13 },
    ];
    assert!(
        !is_first_server_in_namespace(&peers, alive(&[(102, 13)])),
        "a single surviving peer must keep the namespace's token stable"
    );
}

// ---------------------------------------------------------------------------
// The token itself: mint once, then keep — this is the actual #509 fix
// ---------------------------------------------------------------------------

#[test]
fn first_server_mints_a_token() {
    let dir = temp_dir();
    let token = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None);
    assert!(token.is_some(), "the first server in a namespace must mint a token");
    assert!(
        !token.as_deref().unwrap_or_default().is_empty(),
        "the minted token must not be empty"
    );
}

#[test]
fn later_servers_keep_the_first_servers_token() {
    // This is issue #509 in one assertion: creating more sessions must not
    // change the namespace's identity.
    let dir = temp_dir();

    write_pid_entry(&dir, "alpha__one", 100, 11);
    let first = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None)
        .expect("first server mints");

    for (pid, ft, base) in [(101u32, 12u64, "alpha__two"), (102, 13, "alpha__three")] {
        write_pid_entry(&dir, base, pid, ft);
        let seen = ensure_namespace_instance_in(
            &dir,
            Some("alpha"),
            pid,
            alive(&[(100, 11), (101, 12), (102, 13)]),
            None,
        );
        assert_eq!(
            seen.as_deref(),
            Some(first.as_str()),
            "creating session {} changed the namespace token — this is #509",
            base
        );
    }
}

#[test]
fn every_server_in_the_namespace_reports_the_same_token() {
    // Whichever server answers `display-message`, the value must agree, because
    // they all read the same file.
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha__one", 100, 11);
    let minted = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();

    let readings: HashSet<String> = [100u32, 101, 102]
        .iter()
        .filter_map(|_| read_namespace_instance_in(&dir, Some("alpha")))
        .collect();

    assert_eq!(
        readings,
        HashSet::from([minted]),
        "all servers in a namespace must report one identity"
    );
}

#[test]
fn a_genuinely_restarted_namespace_gets_a_new_token() {
    // Every server died, then a new one starts: that IS a restart and a
    // supervisor must be able to see it.
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha__one", 100, 11);
    let before = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();

    // The namespace goes away; the stale registry entry is left behind.
    let after = ensure_namespace_instance_in(&dir, Some("alpha"), 500, all_dead, None).unwrap();

    assert_ne!(
        before, after,
        "a namespace that fully died and restarted must present a new identity"
    );
}

#[test]
fn namespaces_have_independent_identities() {
    let dir = temp_dir();
    let a = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();
    let b = ensure_namespace_instance_in(&dir, Some("beta"), 200, all_dead, None).unwrap();
    assert_ne!(a, b, "separate namespaces must not share an identity");
}

#[test]
fn default_namespace_has_its_own_identity() {
    let dir = temp_dir();
    let named = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();
    let default = ensure_namespace_instance_in(&dir, None, 200, all_dead, None).unwrap();
    assert_ne!(
        named, default,
        "the default namespace must not share the identity of a `-L` namespace"
    );
}

#[test]
fn reading_an_unknown_namespace_yields_nothing() {
    let dir = temp_dir();
    assert_eq!(
        read_namespace_instance_in(&dir, Some("never-existed")),
        None,
        "an unknown namespace must read as absent, not as some other namespace's token"
    );
}

#[test]
fn reading_does_not_mint() {
    // A client-side read must never create identity; only a starting server may.
    let dir = temp_dir();
    assert_eq!(read_namespace_instance_in(&dir, Some("alpha")), None);
    assert_eq!(
        read_namespace_instance_in(&dir, Some("alpha")),
        None,
        "reading must have no side effect"
    );
}

#[test]
fn a_missing_data_dir_is_not_fatal() {
    let mut missing = temp_dir();
    missing.push("does-not-exist");
    // Must not panic, and must not claim an identity it cannot store.
    let _ = ensure_namespace_instance_in(&missing, Some("alpha"), 100, all_dead, None);
    let _ = read_namespace_instance_in(&missing, Some("alpha"));
}

#[test]
fn a_namespace_name_that_is_not_a_safe_filename_is_still_isolated() {
    // `-L` values come from the user; two different names must never collide on
    // one file, whatever characters they contain.
    let dir = temp_dir();
    let a = ensure_namespace_instance_in(&dir, Some("a/b"), 100, all_dead, None);
    let b = ensure_namespace_instance_in(&dir, Some("a_b"), 200, all_dead, None);
    if let (Some(a), Some(b)) = (a, b) {
        assert_ne!(a, b, "distinct namespace names must not share a token file");
    }
}

#[test]
fn an_existing_token_is_returned_verbatim() {
    let dir = temp_dir();
    write_pid_entry(&dir, "alpha__one", 100, 11);
    let minted = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();
    let read_back = read_namespace_instance_in(&dir, Some("alpha")).unwrap();
    assert_eq!(minted, read_back, "the stored token must round-trip unchanged");
    assert!(
        !read_back.contains('\n') && !read_back.contains('\r'),
        "the token must be a single line so `display-message -p` output is usable, got {:?}",
        read_back
    );
}

// ---------------------------------------------------------------------------
// Steady state: the periodic registry re-ensure must not churn the token.
//
// The server main loop re-runs the ensure every few seconds as part of registry
// self-heal. A lone server (single session, no warm helper) has no live peers
// on every one of those ticks; if each tick repeated the startup first-server
// decision it would delete and re-mint its own token every interval, telling a
// supervisor the server restarted every few seconds — the exact defect #509 is
// about. An established token turns the re-ensure into a pure restore.
// ---------------------------------------------------------------------------

#[test]
fn a_lone_servers_periodic_reensure_keeps_its_token() {
    let dir = temp_dir();
    let startup = ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None)
        .expect("startup mints");
    for tick in 0..3 {
        let seen = ensure_namespace_instance_in(
            &dir,
            Some("alpha"),
            100,
            all_dead,
            Some(startup.as_str()),
        );
        assert_eq!(
            seen.as_deref(),
            Some(startup.as_str()),
            "re-ensure tick {} with no live peers must keep the established token",
            tick
        );
    }
}

#[test]
fn reensure_restores_a_lost_token_file_with_the_same_token() {
    // Self-heal must not fake a restart: if the file is lost while the
    // namespace is up, it comes back carrying the SAME identity.
    let dir = temp_dir();
    let startup =
        ensure_namespace_instance_in(&dir, Some("alpha"), 100, all_dead, None).unwrap();
    std::fs::remove_file(crate::paths::namespace_instance_file(&dir, Some("alpha"))).unwrap();
    let healed = ensure_namespace_instance_in(
        &dir,
        Some("alpha"),
        100,
        all_dead,
        Some(startup.as_str()),
    );
    assert_eq!(
        healed.as_deref(),
        Some(startup.as_str()),
        "a restored token file must carry the established identity, not a fresh mint"
    );
    assert_eq!(
        read_namespace_instance_in(&dir, Some("alpha")).as_deref(),
        Some(startup.as_str()),
        "the restored file must be readable by every other server"
    );
}

#[test]
fn an_established_reensure_adopts_a_peers_existing_file() {
    // If another server already holds (or restored) the file, an established
    // re-ensure must agree with what is on disk rather than overwrite it, so
    // all servers converge on one value.
    let dir = temp_dir();
    let path = crate::paths::namespace_instance_file(&dir, Some("alpha"));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "feedfacefeedface").unwrap();
    let seen = ensure_namespace_instance_in(
        &dir,
        Some("alpha"),
        100,
        all_dead,
        Some("0123456789abcdef"),
    );
    assert_eq!(
        seen.as_deref(),
        Some("feedfacefeedface"),
        "an existing on-disk token must win over the caller's cached one"
    );
}
