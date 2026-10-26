// Issue #649: a bare `kill-server` ended every `-L` namespace, not just its own.
//
// psmux keeps every namespace in ONE registry directory: a `-L foo` session is
// `foo__name.port`, a default-namespace session is `name.port`. kill-server's
// target scan applied the namespace prefix only when `-L` was given:
//
//     // Apply -L namespace filtering:
//     // With -L: only kill sessions under that namespace
//     // Without -L: kill ALL sessions (tmux behavior)
//     if let Some(ref pfx) = ns_prefix {
//         if !session_name.starts_with(pfx.as_str()) { continue; }
//     }
//
// so `psmux kill-server` (and `tmux kill-server` through the alias) walked
// every `.port` file in the data dir. Measured on the pre-fix build with three
// namespaces in one isolated data dir: one bare kill-server and all of
// `nsA649__sA`, `nsB649__sB` and `sDef649` were gone.
//
// tmux's kill-server kills the server on its selected socket and nothing else
// (`cmd-kill-server.c`: `kill(getpid(), SIGTERM)` — the running server, no
// enumeration at all). The parity rule is therefore: bare kill-server covers
// the default namespace, `-L X` covers X, and the psmux-only `-a`/`--all`
// keeps the machine-wide sweep for people who want the stop-everything switch.
//
// These tests pin the SELECTION (which registry entries are in scope), which is
// where the bug lived; the end-to-end behaviour is in
// tests/test_issue649_kill_server_namespace_scope.ps1.

use super::*;
use std::fs;
use std::path::PathBuf;

/// An empty registry directory of our own.
fn temp_registry(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "psmux_i649_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Write a `.port` file naming `port`, as a running server does.
fn port_file(dir: &PathBuf, base: &str, port: u16) {
    fs::write(dir.join(format!("{base}.port")), port.to_string()).unwrap();
}

fn bases(targets: &[KillTarget]) -> Vec<String> {
    let mut v: Vec<String> = targets.iter().map(|t| t.base.clone()).collect();
    v.sort();
    v
}

// --- the membership rule ----------------------------------------------------

#[test]
fn default_namespace_owns_only_unprefixed_names() {
    assert!(registry_base_in_namespace("work", None), "a bare name is the default namespace's");
    assert!(
        registry_base_in_namespace("__warm__", None),
        "the default namespace's own warm helper is its own, despite the `__`"
    );
    assert!(
        !registry_base_in_namespace("nsA__work", None),
        "a `-L nsA` session is another socket and is NOT the default namespace's"
    );
    assert!(
        !registry_base_in_namespace("nsA____warm__", None),
        "nor is another namespace's warm helper"
    );
}

#[test]
fn named_namespace_owns_only_its_own_prefix() {
    assert!(registry_base_in_namespace("nsA__work", Some("nsA")));
    assert!(
        registry_base_in_namespace("nsA____warm__", Some("nsA")),
        "a namespace's warm helper is a real server in it"
    );
    assert!(!registry_base_in_namespace("nsB__work", Some("nsA")));
    assert!(!registry_base_in_namespace("work", Some("nsA")));
    assert!(
        !registry_base_in_namespace("nsAB__work", Some("nsA")),
        "prefix matching must respect the `__` separator, not just the letters"
    );
}

#[test]
fn kill_scope_all_covers_every_namespace() {
    let all = KillScope::All;
    for base in ["work", "__warm__", "nsA__work", "nsB____warm__"] {
        assert!(all.covers(base), "-a must cover {base}");
    }
}

// --- the target selection ---------------------------------------------------

#[test]
fn bare_kill_server_leaves_other_namespaces_alone() {
    // The regression itself: three namespaces sharing one data dir.
    let dir = temp_registry("bare");
    port_file(&dir, "sDef", 5001);
    port_file(&dir, "__warm__", 5002);
    port_file(&dir, "nsA__sA", 5003);
    port_file(&dir, "nsA____warm__", 5004);
    port_file(&dir, "nsB__sB", 5005);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::Namespace(None), None);

    assert_eq!(
        bases(&targets),
        vec!["__warm__".to_string(), "sDef".to_string()],
        "a bare kill-server may only end the default namespace's servers"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn dash_l_kill_server_ends_only_that_namespace() {
    let dir = temp_registry("dashl");
    port_file(&dir, "sDef", 5001);
    port_file(&dir, "nsA__sA", 5002);
    port_file(&dir, "nsA____warm__", 5003);
    port_file(&dir, "nsB__sB", 5004);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::Namespace(Some("nsA")), None);

    assert_eq!(
        bases(&targets),
        vec!["nsA____warm__".to_string(), "nsA__sA".to_string()],
        "-L nsA covers nsA and nothing else"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn all_flag_keeps_the_machine_wide_sweep() {
    let dir = temp_registry("all");
    port_file(&dir, "sDef", 5001);
    port_file(&dir, "nsA__sA", 5002);
    port_file(&dir, "nsB__sB", 5003);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::All, None);

    assert_eq!(
        bases(&targets),
        vec!["nsA__sA".to_string(), "nsB__sB".to_string(), "sDef".to_string()],
        "-a is the opt-in stop-everything switch and must still reach every namespace"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn the_caller_can_exclude_its_own_server() {
    // An attached client's kill-server fans out to its peers first: it cannot
    // answer its own graceful kill from inside the command handler.
    let dir = temp_registry("exclude");
    port_file(&dir, "mine", 5001);
    port_file(&dir, "peer", 5002);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::Namespace(None), Some("mine"));

    assert_eq!(bases(&targets), vec!["peer".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn an_unreadable_port_file_is_swept_not_contacted() {
    let dir = temp_registry("stale");
    port_file(&dir, "live", 5001);
    fs::write(dir.join("junk.port"), "not-a-port").unwrap();
    fs::write(dir.join("nsA__junk.port"), "not-a-port").unwrap();

    let (targets, stale) = kill_server_targets(&dir, KillScope::Namespace(None), None);

    assert_eq!(bases(&targets), vec!["live".to_string()]);
    let stale_names: Vec<String> = stale
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
        .collect();
    assert_eq!(
        stale_names,
        vec!["junk.port".to_string()],
        "a stale entry is swept only inside the scope; another namespace's is left for its own kill-server"
    );
    let _ = fs::remove_dir_all(&dir);
}

// --- the exit-code input ----------------------------------------------------

#[test]
fn warm_standbys_do_not_count_as_running_sessions() {
    // tmux exits 1 with `no server running` when there is nothing to kill. A
    // warm standby is an implementation detail, not a session, exactly as `ls`
    // treats it, so a namespace holding only one must still say that.
    let dir = temp_registry("warmonly");
    port_file(&dir, "__warm__", 5001);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::Namespace(None), None);

    assert_eq!(targets.len(), 1, "the warm standby is still killed");
    assert_eq!(
        user_session_count(&targets),
        0,
        "but it must not make an empty namespace look occupied"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn user_sessions_are_counted_for_the_exit_code() {
    let dir = temp_registry("count");
    port_file(&dir, "one", 5001);
    port_file(&dir, "two", 5002);
    port_file(&dir, "__warm__", 5003);

    let (targets, _stale) = kill_server_targets(&dir, KillScope::Namespace(None), None);

    assert_eq!(user_session_count(&targets), 2);
    let _ = fs::remove_dir_all(&dir);
}

// --- the force-kill fallback follows the same scope -------------------------

#[test]
fn force_kill_fallback_is_scoped_like_the_graceful_pass() {
    // The fallback used to be handed a prefix that was None for a bare
    // kill-server, i.e. "every wedged server in the dir". It must now see the
    // same namespace the graceful pass did, or a wedged server in another
    // namespace would still be terminated.
    let dir = temp_registry("fallback");
    fs::write(dir.join("sDef.pid"), "101:11").unwrap();
    fs::write(dir.join("__warm__.pid"), "102:12").unwrap();
    fs::write(dir.join("nsA__sA.pid"), "201:21").unwrap();

    let default_ns = force_kill_targets(&dir, KillScope::Namespace(None));
    let mut pids: Vec<u32> = default_ns.iter().map(|t| t.pid).collect();
    pids.sort();
    assert_eq!(
        pids,
        vec![101, 102],
        "a bare kill-server's fallback must not reach namespace nsA's pid"
    );

    let everything = force_kill_targets(&dir, KillScope::All);
    let mut all_pids: Vec<u32> = everything.iter().map(|t| t.pid).collect();
    all_pids.sort();
    assert_eq!(all_pids, vec![101, 102, 201], "-a still reaches every namespace");
    let _ = fs::remove_dir_all(&dir);
}
