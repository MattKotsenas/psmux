// Issue #734: `start-server ; set-option -g exit-empty off` must leave a server
// that untargeted commands reach before any session exists, as tmux does
// (server.c server_loop keeps an empty server alive while exit-empty is off).
//
// psmux's empty server is the namespace's `__warm__` standby while it is HELD
// (unclaimed, exit-empty off), which it advertises with `<base>.held`. These
// tests pin the routing decisions over a throwaway registry directory: no
// server is started and no environment variable is touched.

use super::*;

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

static TMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

struct TempRegistry {
    dir: PathBuf,
}

impl TempRegistry {
    fn new(tag: &str) -> Self {
        let mut dir = std::env::temp_dir();
        let n = TMP_COUNTER.fetch_add(1, Ordering::SeqCst);
        dir.push(format!("psmux_734_{}_{}_{}", tag, std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp registry dir");
        TempRegistry { dir }
    }
    fn port(&self, base: &str) -> &Self {
        std::fs::write(self.dir.join(format!("{}.port", base)), "50000").unwrap();
        self
    }
    fn held(&self, base: &str) -> &Self {
        std::fs::write(self.dir.join(format!("{}.held", base)), "1234").unwrap();
        self
    }
}

impl Drop for TempRegistry {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn warm_base_names_match_the_registry_convention() {
    assert_eq!(warm_base_for(None), "__warm__");
    assert_eq!(warm_base_for(Some("ns")), "ns____warm__");
    assert!(is_warm_session(&warm_base_for(None)));
    assert!(is_warm_session(&warm_base_for(Some("sock-0123456789abcdef"))));
}

#[test]
fn an_unheld_standby_is_not_a_server() {
    // Plain start-server (exit-empty on): tmux's server exits at once, so
    // nothing is reachable. The standby stays internal.
    let r = TempRegistry::new("unheld");
    r.port("ns____warm__");
    assert_eq!(held_warm_base_in(&r.dir, Some("ns")), None);
    assert_eq!(
        resolve_routing_target(Some("ns"), None, &r.dir),
        Some("ns__default".to_string())
    );
}

#[test]
fn a_held_standby_is_the_namespace_server() {
    let r = TempRegistry::new("held");
    r.port("ns____warm__").held("ns____warm__");
    assert_eq!(held_warm_base_in(&r.dir, Some("ns")), Some("ns____warm__".to_string()));
    assert_eq!(
        resolve_routing_target(Some("ns"), None, &r.dir),
        Some("ns____warm__".to_string())
    );
}

#[test]
fn the_default_namespace_held_standby_is_reachable_without_l() {
    let r = TempRegistry::new("default");
    r.port("__warm__").held("__warm__");
    assert_eq!(held_warm_base_in(&r.dir, None), Some("__warm__".to_string()));
    assert_eq!(resolve_routing_target(None, None, &r.dir), Some("__warm__".to_string()));
}

#[test]
fn a_marker_without_a_registration_is_inert() {
    // A crash can leave `.held` behind; without the `.port` there is no
    // server, so routing must not point at one.
    let r = TempRegistry::new("stale");
    r.held("ns____warm__");
    assert_eq!(held_warm_base_in(&r.dir, Some("ns")), None);
    assert_eq!(
        resolve_routing_target(Some("ns"), None, &r.dir),
        Some("ns__default".to_string())
    );
}

#[test]
fn a_real_session_outranks_the_held_standby() {
    let r = TempRegistry::new("real");
    r.port("ns____warm__").held("ns____warm__").port("ns__work");
    assert_eq!(
        resolve_routing_target(Some("ns"), None, &r.dir),
        Some("ns__work".to_string())
    );
}

#[test]
fn another_namespace_held_standby_is_never_used() {
    let r = TempRegistry::new("isolation");
    r.port("other____warm__").held("other____warm__");
    assert_eq!(held_warm_base_in(&r.dir, Some("ns")), None);
    assert_eq!(held_warm_base_in(&r.dir, None), None);
    assert_eq!(
        resolve_routing_target(Some("ns"), None, &r.dir),
        Some("ns__default".to_string())
    );
    assert_eq!(resolve_routing_target(None, None, &r.dir), None);
}

#[test]
fn start_server_queue_reaches_its_standby_before_it_is_held() {
    // The commands queued after start-server (`set -g exit-empty off` is the
    // one that makes it held) must reach the standby start-server named.
    let r = TempRegistry::new("route");
    r.port("ns____warm__");
    assert_eq!(
        resolve_routing_target_with(Some("ns"), None, &r.dir, Some("ns____warm__")),
        Some("ns____warm__".to_string())
    );
    // Only this namespace's standby may be named.
    assert_eq!(
        resolve_routing_target_with(Some("ns"), None, &r.dir, Some("other____warm__")),
        Some("ns__default".to_string())
    );
}

#[test]
fn new_session_claims_the_held_standby_only_while_the_namespace_is_empty() {
    let r = TempRegistry::new("claim");
    r.port("ns____warm__");
    assert!(!cli_must_claim_standby(&r.dir, Some("ns"), None));
    assert!(cli_must_claim_standby(&r.dir, Some("ns"), Some("ns____warm__")));
    r.held("ns____warm__");
    assert!(cli_must_claim_standby(&r.dir, Some("ns"), None));
    r.port("ns__work");
    assert!(!cli_must_claim_standby(&r.dir, Some("ns"), None));
}

#[test]
fn a_named_standby_that_is_gone_is_not_claimed() {
    let r = TempRegistry::new("gone");
    assert!(!cli_must_claim_standby(&r.dir, Some("ns"), Some("ns____warm__")));
}

#[test]
fn held_claim_followups_cover_what_a_claim_cannot_carry() {
    assert!(held_claim_followups(None, None, None, None, None).is_empty());
    // `-c` alone is carried by the claim itself (the standby re-homes).
    assert!(held_claim_followups(None, None, Some("C:\\work"), None, None).is_empty());
    let shell = held_claim_followups(Some("pwsh -NoLogo"), None, Some("C:\\my dir"), None, None);
    assert_eq!(shell, vec!["respawn-pane -k -c \"C:\\\\my dir\" -- \"pwsh -NoLogo\"\n".to_string()]);
    let argv = vec!["node".to_string(), "a b.js".to_string()];
    let raw = held_claim_followups(None, Some(&argv), None, None, None);
    assert_eq!(raw, vec!["respawn-pane -k -- \"node\" \"a b.js\"\n".to_string()]);
    let size = held_claim_followups(None, None, None, Some(120), Some(40));
    assert_eq!(size, vec!["resize-window -x 120 -y 40\n".to_string()]);
}
