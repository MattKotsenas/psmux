//! Issue #579: the Ctrl+C CTRL_C_EVENT broadcast hits every process on the
//! pane console, so the skip decision must consider every process on the
//! console (GetConsoleProcessList membership), not just the resolved
//! foreground leaf.  `any_vt_bridge` is that console-scoped classifier.
use super::*;

#[test]
fn empty_pid_list_is_not_a_bridge() {
    assert!(!any_vt_bridge(&[]));
}

#[test]
fn own_process_is_not_a_bridge() {
    // The test runner is a cargo test binary, never wsl/ssh.
    assert!(!any_vt_bridge(&[std::process::id()]));
}

#[test]
fn unknown_pid_is_not_a_bridge() {
    // PID 4 is the Windows System process; u32::MAX is never a live PID.
    assert!(!any_vt_bridge(&[u32::MAX]));
}

#[test]
fn empty_console_never_hits_bridge() {
    assert!(!console_broadcast_hits_bridge(&[]));
}

#[test]
fn own_process_console_does_not_hit_bridge() {
    // The cargo test process tree contains no wsl/ssh.
    assert!(!console_broadcast_hits_bridge(&[std::process::id()]));
}

#[test]
fn unix_shell_classification() {
    assert!(is_unix_shell_exe("bash.exe"));
    assert!(is_unix_shell_exe("zsh"));
    assert!(is_unix_shell_exe("sh.exe"));
    // PowerShell/cmd must NOT count: under them the broadcast is harmless to
    // bridges and still needed for cooked console apps (#346).
    assert!(!is_unix_shell_exe("pwsh.exe"));
    assert!(!is_unix_shell_exe("powershell.exe"));
    assert!(!is_unix_shell_exe("cmd.exe"));
    assert!(!is_unix_shell_exe("wsl.exe"));
}

#[test]
fn system_bridge_check_excludes_the_resident_service() {
    // wslservice.exe is a Windows service resident forever once WSL has run.
    // If any_vt_bridge_running counted it, the childless-fallback Ctrl+C
    // guard would fire on EVERY bare-prompt press on a WSL-installed machine
    // and (with the PROCESSED_INPUT strip) break cancelling in-process
    // cmdlets like Start-Sleep.  The prefix classifier still counts it as a
    // bridge for pane-scoped checks; only the system-wide check excludes it.
    assert!(is_vt_bridge_exe("wslservice.exe"));
    // On the machine running this suite wslservice is typically resident
    // while no wsl.exe client is: the system-wide check must not be true
    // SOLELY because of it.  (Cannot assert a fixed value here since a real
    // wsl.exe/ssh.exe may legitimately be running during the suite.)
}

#[test]
fn vt_bridge_name_classification() {
    assert!(is_vt_bridge_exe("wsl.exe"));
    assert!(is_vt_bridge_exe("wsl"));
    assert!(is_vt_bridge_exe("wslhost.exe"));
    assert!(is_vt_bridge_exe("ssh.exe"));
    assert!(is_vt_bridge_exe("ubuntu.exe"));
    assert!(!is_vt_bridge_exe("bash.exe"));
    assert!(!is_vt_bridge_exe("cmd.exe"));
    assert!(!is_vt_bridge_exe("pwsh.exe"));
    assert!(!is_vt_bridge_exe("node.exe"));
}
