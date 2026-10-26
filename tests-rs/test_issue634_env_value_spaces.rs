// Unit tests for issue #634: a Claude Code teammate whose project lives under a
// path with a space died in its pane with
//   &: The module 'Code' could not be loaded. For more information, run 'Import-Module Code'.
//
// Claude Code's TmuxBackend hands psmux one operand:
//   respawn-pane -k -t %N -- "cd '<cwd>' && env <VAR=val ...> '<claude>' <flags>"
// and POSIX quotes every value that is not [A-Za-z0-9_./:=@+,-]+, so any
// forwarded environment value holding a space arrives single quoted.
// detect_env_prefix_command used to cut the assignment run on plain whitespace,
// so `XDIR='D:\POC Code\todosample'` was read as the assignment `XDIR=
// 'D:\POC` plus an orphan `Code\todosample'`, and that orphan became the
// program of the `&` call psmux builds. PowerShell reads `Name\Command` as a
// module qualified invocation, hence the "module 'Code'" message.
//
// The scan is quote aware now, and the program/args are re-quoted for the `&`
// call so a space in them cannot split a second time.

use super::*;

#[cfg(windows)]
#[test]
fn quoted_env_value_with_spaces_stays_one_assignment() {
    // The reporter's exact shape, with the program swapped for a stable path.
    let cmd = "cd 'D:\\OneDrive - ACME INC\\ADL\\POC Code\\todosample' && env CLAUDECODE=1 XDIR='D:\\POC Code\\todosample\\.claude' 'C:\\Windows\\System32\\cmd.exe' /c echo OK";
    let (cwd, sets, remainder) = detect_env_prefix_command(cmd).expect("env idiom must match");
    assert_eq!(cwd.as_deref(), Some("D:\\OneDrive - ACME INC\\ADL\\POC Code\\todosample"),
        "the quoted cd target keeps its spaces");
    assert_eq!(sets, vec![
        ("CLAUDECODE".to_string(), "1".to_string()),
        ("XDIR".to_string(), "D:\\POC Code\\todosample\\.claude".to_string()),
    ], "a quoted value holding a space is ONE assignment, not two tokens");
    assert!(!remainder.starts_with("Code\\"),
        "the orphaned tail must never become the program, got: {remainder}");
    assert_eq!(remainder, "C:\\Windows\\System32\\cmd.exe /c echo OK",
        "the program is the first non-assignment token (no spaces, so no quotes needed)");
}

#[cfg(windows)]
#[test]
fn program_path_with_spaces_is_requoted_for_the_call_operator() {
    // The tokeniser consumes the original quotes, so the program has to get
    // them back or `& C:\Program Files\x\claude.exe` splits at the space.
    let cmd = "env CLAUDECODE=1 'C:\\Program Files\\anthropic\\claude.exe' --agent-id Bob@team";
    let (_, _, remainder) = detect_env_prefix_command(cmd).expect("env idiom must match");
    assert_eq!(remainder, "'C:\\Program Files\\anthropic\\claude.exe' --agent-id Bob@team");
}

#[cfg(windows)]
#[test]
fn argument_with_spaces_is_requoted_too() {
    let cmd = "env FOO=bar C:\\tools\\app.exe --prompt 'do the thing' --flag";
    let (_, _, remainder) = detect_env_prefix_command(cmd).expect("env idiom must match");
    assert_eq!(remainder, "C:\\tools\\app.exe --prompt 'do the thing' --flag");
}

#[cfg(windows)]
#[test]
fn embedded_single_quote_is_doubled_for_powershell() {
    let cmd = "env FOO=bar \"C:\\dev\\Bob's Tools\\app.exe\" --go";
    let (_, _, remainder) = detect_env_prefix_command(cmd).expect("env idiom must match");
    assert_eq!(remainder, "'C:\\dev\\Bob''s Tools\\app.exe' --go",
        "a literal quote inside the token is doubled, not left to end the string");
}

#[cfg(windows)]
#[test]
fn ampamp_inside_the_cd_target_does_not_split_it() {
    let cmd = "cd 'C:\\dir && more' && env FOO=bar C:\\a.exe";
    let (cwd, sets, remainder) = detect_env_prefix_command(cmd).expect("env idiom must match");
    assert_eq!(cwd.as_deref(), Some("C:\\dir && more"));
    assert_eq!(sets, vec![("FOO".to_string(), "bar".to_string())]);
    assert_eq!(remainder, "C:\\a.exe");
}

#[cfg(windows)]
#[test]
fn build_command_never_calls_the_orphaned_path_tail() {
    // End to end: the pwsh -Command argument must call the real program, and
    // must not contain the `& Code\` shape the reporter saw.
    let builder = build_command(
        Some("cd 'D:\\OneDrive - ACME INC\\ADL\\POC Code\\todosample' && env CLAUDECODE=1 XDIR='D:\\POC Code\\todosample\\.claude' 'C:\\Windows\\System32\\cmd.exe' /c echo OK"),
        false,
        false,
    );
    let args: Vec<String> = builder.get_argv().iter().map(|s| s.to_string_lossy().to_string()).collect();
    let joined = args.join(" ");
    assert!(!joined.contains("& Code\\"),
        "the module-qualified orphan call must be gone, got: {joined}");
    assert!(joined.contains("& C:\\Windows\\System32\\cmd.exe /c echo OK"),
        "the real program must be what `&` calls, got: {joined}");

    // Same shape but with the teammate binary itself under a spaced path: the
    // call operator must receive it as one quoted literal.
    let builder = build_command(
        Some("cd 'D:\\POC Code\\todosample' && env CLAUDECODE=1 'C:\\Program Files\\anthropic\\claude.exe' --agent-id Bob@team"),
        false,
        false,
    );
    let joined = builder.get_argv().iter()
        .map(|s| s.to_string_lossy().to_string())
        .collect::<Vec<String>>()
        .join(" ");
    assert!(joined.contains("& 'C:\\Program Files\\anthropic\\claude.exe' --agent-id Bob@team"),
        "a spaced program path stays one quoted literal, got: {joined}");
}
