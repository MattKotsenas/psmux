// PSMUX_PSREADLINE_HISTORY points a pane's PSReadLine history at a file of
// the caller's choosing, so a test run never writes into (or recalls from)
// the user's ConsoleHost_history.txt.  The redirect must come before the
// profile (PSReadLine loads history at the first prompt) and again after it
// (a profile that sets its own HistorySavePath must not win).

use super::*;

fn positions(s: &str, needle: &str) -> Vec<usize> {
    s.match_indices(needle).map(|(i, _)| i).collect()
}

#[test]
fn profile_init_redirects_history_before_and_after_the_profile() {
    for allow in [false, true] {
        let s = build_psrl_init(false, allow);
        let r = positions(&s, PSRL_HISTORY_REDIRECT);
        let p = s.find(PROFILE_SOURCE).expect("profile sourcing present");
        assert_eq!(r.len(), 2, "allow_predictions={allow}: expected the redirect twice in {s}");
        assert!(r[0] < p && r[1] > p, "allow_predictions={allow}: redirect must bracket the profile");
    }
}

#[test]
fn noprofile_init_redirects_history() {
    let s = build_psrl_init_noprofile(false);
    assert!(s.starts_with(PSRL_HISTORY_REDIRECT), "got {s}");
}

#[test]
fn the_redirect_is_inert_without_the_variable() {
    assert!(PSRL_HISTORY_REDIRECT.starts_with("if ($env:PSMUX_PSREADLINE_HISTORY) {"));
    assert!(PSRL_HISTORY_REDIRECT.contains("Set-PSReadLineOption -HistorySavePath $env:PSMUX_PSREADLINE_HISTORY"));
}
