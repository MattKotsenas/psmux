// Issue #495 follow-up: #{pane_current_path} stayed frozen for PowerShell
// panes spawned as EXPLICIT commands (`new-window C:\...\pwsh.exe`). The
// direct-spawn path added for #492/#493 launched the exe verbatim, so the
// pane never got the psrl_init block and therefore never installed the
// Set-Location hook that syncs the Win32 process CWD. Default-shell panes
// were fine after aef2d1d, which is why the gap only showed for users who
// open pwsh/powershell panes explicitly while their default shell is the
// other PowerShell.
//
// Also covered: `-NoProfile` panes previously dropped the CWD hook because
// it was bundled with profile sourcing; build_psrl_init_noprofile keeps it.
#![cfg(windows)]
use super::*;

const PS51: &str = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
const CMD: &str = r"C:\Windows\System32\cmd.exe";

#[test]
fn direct_spawn_powershell_gets_cwd_hook() {
    // The regression: an explicit powershell.exe path spawned as a pane
    // command must launch with the CWD-sync hook, exactly like a
    // default-shell pane.
    let builder = build_command(Some(PS51), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        dbg.contains("__psmux_cwd_hook"),
        "explicit powershell.exe pane must get the CWD-sync hook (#495); got: {}",
        dbg
    );
    assert!(dbg.contains("-NoExit"), "init must keep the shell interactive; got: {}", dbg);
}

#[test]
fn direct_spawn_pwsh_gets_cwd_hook() {
    // pwsh.exe may live in different places; resolve it and skip if absent.
    let Ok(pwsh) = which::which("pwsh") else { return };
    let path = pwsh.to_string_lossy().into_owned();
    let builder = build_command(Some(&path), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        dbg.contains("__psmux_cwd_hook"),
        "explicit pwsh.exe pane must get the CWD-sync hook (#495); got: {}",
        dbg
    );
}

#[test]
fn direct_spawn_powershell_with_command_arg_untouched() {
    // `-Command <x>` runs a command, not an interactive shell — appending our
    // init would collide with the user's -Command. Must stay verbatim.
    let cmd = format!("{} -Command Get-Date", PS51);
    let builder = build_command(Some(&cmd), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        !dbg.contains("__psmux_cwd_hook"),
        "non-interactive PowerShell command must not get the init appended; got: {}",
        dbg
    );
    assert!(!dbg.contains("-NoExit"), "must not force -NoExit on a user command; got: {}", dbg);
}

#[test]
fn direct_spawn_powershell_with_file_arg_untouched() {
    let cmd = format!("{} -File script.ps1", PS51);
    let builder = build_command(Some(&cmd), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        !dbg.contains("__psmux_cwd_hook"),
        "-File invocation must not get the init appended; got: {}",
        dbg
    );
}

#[test]
fn direct_spawn_powershell_positional_arg_untouched() {
    // A positional arg is -File (pwsh) / -Command (powershell) semantics.
    let cmd = format!("{} script.ps1", PS51);
    let builder = build_command(Some(&cmd), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        !dbg.contains("__psmux_cwd_hook"),
        "positional-arg invocation must not get the init appended; got: {}",
        dbg
    );
}

#[test]
fn direct_spawn_powershell_noprofile_keeps_cwd_hook() {
    // User opts out of profiles, NOT out of cwd tracking.
    let cmd = format!("{} -NoProfile", PS51);
    let builder = build_command(Some(&cmd), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        dbg.contains("__psmux_cwd_hook"),
        "-NoProfile interactive pane must still get the CWD-sync hook (#495); got: {}",
        dbg
    );
    assert!(
        !dbg.contains("PROFILE.CurrentUserCurrentHost"),
        "-NoProfile pane must not source profiles; got: {}",
        dbg
    );
}

#[test]
fn direct_spawn_cmd_exe_untouched() {
    // Non-PowerShell direct spawns must stay verbatim — PowerShell flags
    // would break them (and cmd.exe tracks cd natively anyway).
    let builder = build_command(Some(CMD), false, false);
    let dbg = format!("{:?}", builder);
    assert!(!dbg.contains("__psmux_cwd_hook"), "cmd.exe must not get PowerShell init; got: {}", dbg);
    assert!(!dbg.contains("-NoExit"), "cmd.exe must not get PowerShell flags; got: {}", dbg);
}

#[test]
fn default_shell_noprofile_keeps_cwd_hook() {
    // Second gap in the same class: default-shell with user-passed
    // -NoProfile used a PSRL-fix-only init that dropped the CWD hook.
    let builder = build_default_shell(&format!("\"{}\" -NoProfile", PS51), false, false);
    let dbg = format!("{:?}", builder);
    assert!(
        dbg.contains("__psmux_cwd_hook"),
        "default-shell -NoProfile pane must still get the CWD-sync hook (#495); got: {}",
        dbg
    );
}

#[test]
fn noprofile_init_contains_cwd_sync() {
    let init = build_psrl_init_noprofile(false);
    assert!(init.contains("SetCurrentDirectory"), "noprofile init must sync Win32 CWD");
    assert!(init.contains("__psmux_cwd_hook"), "noprofile init must guard the hook install");
    assert!(!init.contains("PROFILE.CurrentUserCurrentHost"), "noprofile init must not source profiles");
}

#[test]
fn is_powershell_program_matches_only_stems() {
    assert!(is_powershell_program(PS51));
    assert!(is_powershell_program(r"C:\Program Files\PowerShell\7\pwsh.exe"));
    assert!(is_powershell_program("pwsh.exe"));
    assert!(is_powershell_program("POWERSHELL.EXE"));
    // Substring in the directory must NOT match — appending PowerShell flags
    // to an arbitrary exe would break it.
    assert!(!is_powershell_program(r"C:\tools\powershell-scripts\foo.exe"));
    assert!(!is_powershell_program(CMD));
    assert!(!is_powershell_program(r"C:\Program Files\Git\bin\bash.exe"));
}

#[test]
fn powershell_args_interactive_classification() {
    let s = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert!(powershell_args_interactive(&[]));
    assert!(powershell_args_interactive(&s(&["-NoProfile"])));
    assert!(powershell_args_interactive(&s(&["-NoLogo", "-NoProfile"])));
    assert!(!powershell_args_interactive(&s(&["-Command", "Get-Date"])));
    assert!(!powershell_args_interactive(&s(&["-command", "Get-Date"])));
    assert!(!powershell_args_interactive(&s(&["-c", "ls"])));
    assert!(!powershell_args_interactive(&s(&["-File", "x.ps1"])));
    assert!(!powershell_args_interactive(&s(&["-f", "x.ps1"])));
    assert!(!powershell_args_interactive(&s(&["-EncodedCommand", "aQBmAA=="])));
    assert!(!powershell_args_interactive(&s(&["script.ps1"])));
    assert!(!powershell_args_interactive(&s(&["-NoProfile", "script.ps1"])));
}
