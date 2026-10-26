//! Issue #683: the SHELL environment variable seeds `default-shell` the way
//! tmux's `getshell()` / `checkshell()` (tmux.c) do, instead of being ignored.
//!
//! Reproduced on 0bcc421: `$env:SHELL = '...\powershell.exe'; psmux new-session`
//! still spawned pwsh 7 and `show-options -g -v default-shell` still reported
//! pwsh. tmux would have spawned the SHELL. These tests pin the acceptance
//! rule over explicit values so they never touch the process environment;
//! the live behaviour is covered by tests/test_issue683_shell_env_default_shell.ps1.

use super::*;

fn windows_powershell() -> String {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_string());
    format!("{}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", root)
}

#[test]
fn absolute_existing_exe_is_accepted_verbatim() {
    let ps = windows_powershell();
    assert!(std::path::Path::new(&ps).is_file(), "test needs Windows PowerShell at {}", ps);
    assert_eq!(shell_from_env_value(&ps).as_deref(), Some(ps.as_str()));
}

#[test]
fn surrounding_whitespace_is_trimmed() {
    let ps = windows_powershell();
    let padded = format!("  {}  ", ps);
    assert_eq!(shell_from_env_value(&padded).as_deref(), Some(ps.as_str()));
}

#[test]
fn empty_value_is_ignored() {
    assert_eq!(shell_from_env_value(""), None);
    assert_eq!(shell_from_env_value("   "), None);
}

#[test]
fn posix_style_path_is_ignored() {
    // Git Bash exports SHELL=/usr/bin/bash to every Windows child; it is not a
    // path CreateProcess can start, so checkshell() semantics reject it.
    assert_eq!(shell_from_env_value("/usr/bin/bash"), None);
    assert_eq!(shell_from_env_value("/bin/sh"), None);
}

#[test]
fn relative_path_is_ignored() {
    assert_eq!(shell_from_env_value(".\\sh.exe"), None);
    assert_eq!(shell_from_env_value("bin\\sh.exe"), None);
    assert_eq!(shell_from_env_value("./sh"), None);
}

#[test]
fn missing_absolute_path_is_ignored() {
    assert_eq!(shell_from_env_value("C:\\definitely\\missing\\i683\\shell.exe"), None);
}

#[test]
fn directory_is_ignored() {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_string());
    assert_eq!(shell_from_env_value(&root), None);
}

#[test]
fn non_executable_extension_is_ignored() {
    // A real file that CreateProcess cannot run directly (X_OK analogue).
    let tmp = std::env::temp_dir().join("i683_not_a_shell.ps1");
    std::fs::write(&tmp, "Write-Host hi\n").unwrap();
    let value = tmp.to_string_lossy().into_owned();
    let got = shell_from_env_value(&value);
    let _ = std::fs::remove_file(&tmp);
    assert_eq!(got, None);
}

#[test]
fn psmux_itself_is_refused_like_areshell() {
    // tmux refuses SHELL=tmux; psmux refuses its own names, by any path.
    let exe = std::env::current_exe().unwrap();
    let dir = exe.parent().unwrap();
    let fake = dir.join("psmux.exe");
    let created = if fake.is_file() { false } else { std::fs::write(&fake, b"MZ").is_ok() };
    let got = shell_from_env_value(&fake.to_string_lossy());
    if created {
        let _ = std::fs::remove_file(&fake);
    }
    assert_eq!(got, None, "SHELL pointing at psmux.exe must be ignored");
    assert_eq!(shell_from_env_value("psmux"), None);
    assert_eq!(shell_from_env_value("tmux"), None);
}

#[test]
fn bare_name_resolves_on_path() {
    // `default-shell powershell` already works as a bare name; SHELL matches.
    let got = shell_from_env_value("powershell").expect("powershell is on PATH on every Windows");
    assert!(got.to_ascii_lowercase().ends_with("powershell.exe"), "got {}", got);
    assert!(std::path::Path::new(&got).is_file());
}

#[test]
fn bare_name_not_on_path_is_ignored() {
    assert_eq!(shell_from_env_value("i683-no-such-shell"), None);
}

#[test]
fn unset_shell_leaves_the_walk_in_charge() {
    let _lock = crate::util::lock_test_env();
    let saved = std::env::var("SHELL").ok();
    std::env::remove_var("SHELL");
    let got = shell_from_env();
    match saved {
        Some(v) => std::env::set_var("SHELL", v),
        None => std::env::remove_var("SHELL"),
    }
    assert_eq!(got, None);
}

#[test]
fn set_shell_is_read_from_the_environment() {
    let _lock = crate::util::lock_test_env();
    let saved = std::env::var("SHELL").ok();
    let ps = windows_powershell();
    std::env::set_var("SHELL", &ps);
    let got = shell_from_env();
    match saved {
        Some(v) => std::env::set_var("SHELL", v),
        None => std::env::remove_var("SHELL"),
    }
    assert_eq!(got.as_deref(), Some(ps.as_str()));
}
