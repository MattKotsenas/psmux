// Issue #495: #{pane_current_path} stayed stale after `cd` in Windows
// PowerShell 5.1 (powershell.exe) panes because the interactive spawn branch
// gated the CWD-sync hook (psrl_init) on the path containing "pwsh", which
// excludes powershell.exe. Users without pwsh7, and every SSH session (which
// resolves to classic powershell.exe), lost cwd tracking.
//
// The gate is now the shared `shell_needs_psrl_init`, which both build_command
// and build_default_shell use. These tests pin its behavior so the two spawn
// paths cannot drift apart again.
#![cfg(windows)]
use super::*;

#[test]
fn pwsh7_needs_psrl_init() {
    assert!(shell_needs_psrl_init(r"C:\Program Files\PowerShell\7\pwsh.exe"));
    assert!(shell_needs_psrl_init("pwsh.exe"));
    assert!(shell_needs_psrl_init("PWSH.EXE"));
}

#[test]
fn windows_powershell_51_needs_psrl_init() {
    // The regression: this path was previously excluded, leaving the CWD hook
    // uninstalled and #{pane_current_path} frozen.
    assert!(
        shell_needs_psrl_init(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"),
        "powershell.exe (Windows PowerShell 5.1) must get psrl_init so the CWD hook is installed (#495)"
    );
    assert!(shell_needs_psrl_init("powershell.exe"));
    assert!(shell_needs_psrl_init("POWERSHELL.EXE"));
}

#[test]
fn non_powershell_shells_do_not_get_psrl_init() {
    assert!(!shell_needs_psrl_init(r"C:\Windows\System32\cmd.exe"));
    assert!(!shell_needs_psrl_init(r"C:\Program Files\Git\bin\bash.exe"));
    assert!(!shell_needs_psrl_init("zsh.exe"));
    assert!(!shell_needs_psrl_init("cmd.exe"));
}

#[test]
fn cwd_sync_hook_present_in_psrl_init() {
    // The psrl_init block must actually contain the Set-Location hook that
    // syncs the Win32 process CWD — that is what makes pane_current_path track.
    let init = build_psrl_init(false, false);
    assert!(init.contains("Set-Location"), "psrl_init must wrap Set-Location");
    assert!(
        init.contains("SetCurrentDirectory"),
        "psrl_init must call [Directory]::SetCurrentDirectory to sync the Win32 CWD (#495)"
    );
    assert!(init.contains("__psmux_cwd_hook"), "psrl_init must guard the hook install");
}

#[test]
fn build_command_powershell_interactive_has_cwd_hook() {
    // Directly exercise the interactive spawn path for an explicit
    // powershell.exe default-shell: build_default_shell must produce a
    // CommandBuilder whose args include the psrl_init hook.
    let builder = build_default_shell(
        r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        false,
        false,
    );
    let dbg = format!("{:?}", builder);
    assert!(
        dbg.contains("SetCurrentDirectory") || dbg.contains("__psmux_cwd_hook"),
        "powershell.exe pane must launch with the CWD-sync hook (#495); got: {}",
        dbg
    );
}
