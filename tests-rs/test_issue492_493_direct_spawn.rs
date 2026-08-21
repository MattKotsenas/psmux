// Issues #492 / #493: window/pane commands must spawn plain program
// invocations DIRECTLY (tmux spawn.c execvp parity) instead of wrapping
// everything in `<shell> -Command "<cmd>"`, which left a wrapper powershell
// process around every command pane (#493) and could not parse quoted
// executable paths containing spaces (#492).
#![cfg(windows)]
use super::*;

fn windir() -> String {
    std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".to_string())
}

#[test]
fn tokens_split_on_whitespace_and_quotes() {
    let t = split_spawn_tokens(r#""C:/Program Files/Git/bin/bash.exe" --login -i"#);
    assert_eq!(t, vec!["C:/Program Files/Git/bin/bash.exe", "--login", "-i"]);
    let t = split_spawn_tokens("cmd.exe /k echo hi");
    assert_eq!(t, vec!["cmd.exe", "/k", "echo", "hi"]);
    let t = split_spawn_tokens("'a b' c");
    assert_eq!(t, vec!["a b", "c"]);
    let t = split_spawn_tokens("cmd.exe '' tail");
    assert_eq!(t, vec!["cmd.exe", "", "tail"]);
}

#[test]
fn absolute_exe_path_spawns_directly() {
    let cmd = format!("{}\\System32\\cmd.exe", windir());
    let (prog, args) = try_direct_spawn(&cmd).expect("absolute exe path must direct-spawn");
    assert!(prog.to_lowercase().ends_with("cmd.exe"));
    assert!(args.is_empty());
}

#[test]
fn path_with_spaces_spawns_directly() {
    // Create a dummy exe inside a directory whose name contains a space.
    let dir = std::env::temp_dir().join("psmux 492 spawn test");
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("space tool.exe");
    std::fs::write(&exe, b"MZ").unwrap();
    let raw = exe.to_string_lossy().into_owned();

    // Whole unquoted string (as it arrives from bind-key after quote
    // consumption, the reporter's exact case).
    let (prog, args) = try_direct_spawn(&raw).expect("space path must direct-spawn");
    assert_eq!(prog, raw);
    assert!(args.is_empty());

    // Longest-prefix resolution: unquoted space path followed by arguments.
    let with_args = format!("{} --login -i", raw);
    let (prog, args) = try_direct_spawn(&with_args).expect("space path + args must direct-spawn");
    assert_eq!(prog, raw);
    assert_eq!(args, vec!["--login", "-i"]);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn bare_program_names_keep_shell_wrapper() {
    // Bare names (no path separator) intentionally stay on the shell
    // wrapper: console utilities like timeout.exe exit immediately when
    // spawned without the shell re-establishing console stdin, and bare
    // invocations relied on shell semantics historically.
    assert!(try_direct_spawn("cmd.exe /c exit").is_none());
    assert!(try_direct_spawn("timeout /T 120 /nobreak").is_none());
    assert!(try_direct_spawn("ping -t 127.0.0.1").is_none());
}

#[test]
fn shell_syntax_falls_back_to_shell() {
    // Pipes, chains, redirects and variables need a real shell.
    assert!(try_direct_spawn("echo hi && cmd /k").is_none());
    assert!(try_direct_spawn("dir | more").is_none());
    assert!(try_direct_spawn("cmd.exe > out.txt").is_none());
    assert!(try_direct_spawn("echo $env:PATH").is_none());
    assert!(try_direct_spawn("echo %PATH%").is_none());
    // A first token with no on-disk executable anywhere falls back to the
    // shell.  (`echo` itself is machine-dependent: Git's usr\bin ships an
    // echo.exe, and resolving it via PATH matches tmux's execvp behavior.)
    assert!(try_direct_spawn("definitely-not-a-real-cmd-492 hello").is_none());
    // The #399 env-prefix path emits a pwsh call-operator string.
    assert!(try_direct_spawn("& C:/tools/thing.exe run").is_none());
}

#[test]
fn program_files_x86_style_path_spawns_directly() {
    // Parentheses in the path must not trip the shell-metachar bail when the
    // whole string is an existing file.
    let dir = std::env::temp_dir().join("psmux 492 (x86) test");
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("tool.exe");
    std::fs::write(&exe, b"MZ").unwrap();
    let raw = exe.to_string_lossy().into_owned();
    let (prog, args) = try_direct_spawn(&raw).expect("(x86)-style path must direct-spawn");
    assert_eq!(prog, raw);
    assert!(args.is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn build_command_direct_spawn_has_no_shell_wrapper() {
    // End-to-end through build_command: the resulting CommandBuilder must
    // target the exe itself, not pwsh/powershell/cmd wrapping it.
    let cmd = format!("{}\\System32\\cmd.exe", windir());
    let builder = build_command(Some(&cmd), false, false);
    let line = format!("{:?}", builder);
    assert!(
        !line.to_lowercase().contains("-command"),
        "no `-Command` wrapper expected for a plain exe, got: {}",
        line
    );
}
