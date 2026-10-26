// Issue #474: Git Bash / MSYS2 / zsh as default-shell backends on Windows.
//
// Three confirmed defects, each with a unit-testable core:
//  1. POSIX shells spawned as non-login shells -> MSYS2 /usr/bin missing from
//     PATH (uname/pacman/oh-my-zsh unreachable). Fix: spawn with -l and
//     CHERE_INVOKING=1 (build_default_shell).
//  2. git-bash.exe (a GUI launcher) configured as default-shell -> stray
//     mintty windows and a dead pane. Fix: remap to the sibling bin\bash.exe.
//  3. psmux run from an MSYS2 login shell (USERPROFILE unset, HOME=/home/x)
//     resolved the data dir to a nonexistent path and the startup orphan
//     reaper killed every live server. Fix: home_dir() no longer trusts HOME
//     ahead of the Windows profile API (paths.rs), and the reaper refuses to
//     run without an existing data dir (session.rs).

use super::*;

// ---- login-shell spawning ---------------------------------------------------

#[test]
fn posix_shell_stems_are_detected() {
    for p in [
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\msys64\\usr\\bin\\zsh.exe",
        "C:\\msys64\\usr\\bin\\BASH.EXE",
        "sh.exe",
        "fish",
    ] {
        assert!(is_posix_shell_path(p), "{p} should be a POSIX shell");
    }
}

#[test]
fn non_posix_shells_are_not_detected() {
    for p in [
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "powershell.exe",
        "cmd.exe",
        "C:\\Windows\\System32\\notepad.exe",
        "",
    ] {
        assert!(!is_posix_shell_path(p), "{p} should NOT be a POSIX shell");
    }
}

#[test]
fn bash_default_shell_gets_login_flag_and_chere() {
    // Use an existing bash if present so resolve_shell_program's fast path
    // fires; fall back to a bare name (still resolves via stem check).
    let shell = "C:\\Program Files\\Git\\bin\\bash.exe";
    let builder = build_default_shell(shell, false, false);
    let args: Vec<String> = builder
        .get_argv()
        .iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    assert!(
        args.iter().any(|a| a == "-l"),
        "bash default-shell must be spawned as a login shell, argv: {args:?}"
    );
    assert_eq!(
        builder.get_env("CHERE_INVOKING").map(|v| v.to_string_lossy().to_string()),
        Some("1".to_string()),
        "CHERE_INVOKING=1 must be set so login shells keep the pane cwd"
    );
}

#[test]
fn zsh_default_shell_gets_login_flag() {
    let builder = build_default_shell("zsh.exe", false, false);
    let args: Vec<String> = builder
        .get_argv()
        .iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    assert!(args.iter().any(|a| a == "-l"), "zsh argv: {args:?}");
}

#[test]
fn user_supplied_args_suppress_login_flag() {
    // The user controls the invocation when they pass their own args; we must
    // not inject -l behind their back.
    let builder = build_default_shell("bash.exe --posix", false, false);
    let args: Vec<String> = builder
        .get_argv()
        .iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    assert!(
        !args.iter().any(|a| a == "-l"),
        "explicit user args must suppress the injected -l, argv: {args:?}"
    );
    assert!(args.iter().any(|a| a == "--posix"), "user arg preserved: {args:?}");
}

#[test]
fn pwsh_default_shell_unaffected_by_login_logic() {
    let builder = build_default_shell("pwsh", false, false);
    let args: Vec<String> = builder
        .get_argv()
        .iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    assert!(!args.iter().any(|a| a == "-l"), "pwsh must not get -l: {args:?}");
    assert!(
        args.iter().any(|a| a.eq_ignore_ascii_case("-NoExit")),
        "pwsh branch must still apply its own args: {args:?}"
    );
    assert!(builder.get_env("CHERE_INVOKING").is_none());
}

// ---- git-bash.exe launcher remap ---------------------------------------------

#[test]
fn git_bash_launcher_remaps_to_real_bash_when_present() {
    // Build a fake Git install layout so the test does not depend on a real
    // Git for Windows installation.
    let root = std::env::temp_dir().join("psmux_i474_gitroot");
    let bin = root.join("bin");
    let _ = std::fs::create_dir_all(&bin);
    std::fs::write(root.join("git-bash.exe"), b"launcher").unwrap();
    std::fs::write(bin.join("bash.exe"), b"shell").unwrap();

    let launcher = root.join("git-bash.exe").to_string_lossy().into_owned();
    let remapped = remap_git_bash_launcher(launcher);
    assert!(
        remapped.to_ascii_lowercase().ends_with("bin\\bash.exe"),
        "expected remap to bin\\bash.exe, got {remapped}"
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn git_bash_launcher_unchanged_when_no_real_bash_beside_it() {
    let root = std::env::temp_dir().join("psmux_i474_gitroot_nobash");
    let _ = std::fs::create_dir_all(&root);
    std::fs::write(root.join("git-bash.exe"), b"launcher").unwrap();

    let launcher = root.join("git-bash.exe").to_string_lossy().into_owned();
    let remapped = remap_git_bash_launcher(launcher.clone());
    assert_eq!(remapped, launcher, "no sibling bash.exe -> leave unchanged");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn non_launcher_paths_never_remapped() {
    for p in ["C:\\Program Files\\Git\\bin\\bash.exe", "pwsh.exe", "zsh"] {
        assert_eq!(remap_git_bash_launcher(p.to_string()), p);
    }
}

#[test]
fn build_default_shell_with_git_bash_launcher_spawns_real_bash() {
    let root = std::env::temp_dir().join("psmux_i474_gitroot_full");
    let bin = root.join("bin");
    let _ = std::fs::create_dir_all(&bin);
    std::fs::write(root.join("git-bash.exe"), b"launcher").unwrap();
    std::fs::write(bin.join("bash.exe"), b"shell").unwrap();

    let launcher = root.join("git-bash.exe").to_string_lossy().into_owned();
    let builder = build_default_shell(&launcher, false, false);
    let args: Vec<String> = builder
        .get_argv()
        .iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect();
    assert!(
        args[0].to_ascii_lowercase().ends_with("bin\\bash.exe"),
        "argv[0] must be the remapped real bash, argv: {args:?}"
    );
    // Remapped bash is a POSIX shell -> login-shell logic applies too.
    assert!(args.iter().any(|a| a == "-l"), "remapped bash gets -l: {args:?}");

    let _ = std::fs::remove_dir_all(&root);
}
