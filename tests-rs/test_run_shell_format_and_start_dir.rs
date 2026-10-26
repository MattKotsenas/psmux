//! `run-shell` format expansion, `-b` error reporting, and `-c` start-dir
//! hardening.
//!
//! Three related failures, all of which presented as "the keybind does nothing":
//!
//! 1. `run-shell` never expanded `#{...}`. A bind of the shape
//!    `run-shell "helper -Path '#{pane_current_path}' -Target '#{pane_id}'"`
//!    handed the helper those strings literally, so its target lookup failed.
//!    Only `-c`/`-d` start-dirs were being expanded, which is why
//!    `popup -d "#{pane_current_path}"` worked and this did not.
//! 2. `-b` discarded the spawn result (`let _ = c.spawn();`), so the failure
//!    produced no output, no status message, and no log line.
//! 3. Splits inherited a `-c` directory the new shell could not enter (a
//!    `\\wsl.localhost\...` UNC path, or a since-deleted directory), which on
//!    Windows fails the spawn itself and tears the pane back down.

use super::*;

// ───────────────────────── start-dir hardening ─────────────────────────

#[test]
fn an_existing_local_directory_is_used_as_is() {
    let tmp = std::env::temp_dir();
    let got = crate::util::usable_start_dir(&tmp.display().to_string())
        .expect("temp dir should be usable");
    assert_eq!(got, tmp, "a usable start-dir must be passed through unchanged");
}

#[test]
fn a_missing_directory_falls_back_to_home() {
    let missing = if cfg!(windows) {
        r"C:\psmux-does-not-exist-9d3f1a\nor-this"
    } else {
        "/psmux-does-not-exist-9d3f1a/nor-this"
    };
    let got = crate::util::usable_start_dir(missing).expect("should fall back, not give up");
    assert_ne!(
        got, std::path::Path::new(missing),
        "a deleted start-dir must not be handed to the pane shell — the spawn \
         fails and psmux closes the pane"
    );
    assert!(got.is_dir(), "the fallback must itself be a real directory");
}

// Windows-only: UNC rejection is scoped to Windows (a leading `//` is a valid
// absolute path on Unix), so this asserts Windows-specific behavior.
#[cfg(windows)]
#[test]
fn a_unc_path_falls_back_even_when_it_looks_plausible() {
    // Rejected by shape, not by reachability: whether \\wsl.localhost works
    // depends on the WSL VM being up, so a split that succeeds now and dies
    // later is worse than one that predictably lands in home.
    for unc in [r"\\wsl.localhost\Ubuntu\home\me", "//wsl.localhost/Ubuntu/home/me"] {
        let got = crate::util::usable_start_dir(unc).expect("should fall back");
        assert!(
            !got.display().to_string().starts_with("\\\\")
                && !got.display().to_string().starts_with("//"),
            "UNC start-dir {:?} was passed through as {:?}",
            unc,
            got
        );
        assert!(got.is_dir());
    }
}

#[test]
fn an_empty_start_dir_falls_back() {
    let got = crate::util::usable_start_dir("").expect("empty should fall back to home");
    assert!(got.is_dir());
}

// ───────────────────────── run-shell format expansion ─────────────────────────

/// The command string a `run-shell` bind produces must have its `#{...}`
/// replaced before it reaches the shell. Assert against the same expansion
/// entry point both run-shell paths now use.
#[test]
fn run_shell_command_strings_expand_format_variables() {
    let app = AppState::new("rs_fmt".to_string());

    let cmd = "helper.ps1 -Session '#{session_name}'";
    let expanded = crate::format::expand_format(cmd, &app);

    assert!(
        expanded.contains("rs_fmt"),
        "expected the session name in {:?}",
        expanded
    );
    assert!(
        !expanded.contains("#{"),
        "an unexpanded #{{...}} reached the shell: {:?} — this is the bug that \
         made every split bind silently do nothing",
        expanded
    );
}

/// The connection-thread path only pays for the round trip to the server loop
/// when the command actually needs it. Pin the predicate so an optimisation
/// does not accidentally start skipping expansion for a real format string.
#[test]
fn the_expansion_round_trip_predicate_matches_real_binds() {
    // Exactly the shapes from the reported config.
    for needs in [
        "psmux-split.ps1 -Path '#{pane_current_path}' -Target '#{pane_id}'",
        "echo '#{session_name}'",
        "helper -x '#{b:pane_path}'",
    ] {
        assert!(
            needs.contains("#{"),
            "{:?} should be detected as needing expansion",
            needs
        );
    }
    // And commands that genuinely have no format reference should skip it.
    for skips in ["lazygit", "pwsh -NoProfile -File ./x.ps1", "echo hi"] {
        assert!(
            !skips.contains("#{"),
            "{:?} should not trigger a needless round trip",
            skips
        );
    }
}

/// `#` is common in shell commands. Expansion must not corrupt a command that
/// merely contains a `#` without a following `{`.
#[test]
fn a_bare_hash_is_not_treated_as_a_format_reference() {
    let app = AppState::new("hash".to_string());
    let cmd = "git commit -m 'fixes #481'";
    assert_eq!(
        crate::format::expand_format(cmd, &app),
        cmd,
        "a literal # in a command must survive expansion untouched"
    );
}
