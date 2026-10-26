// Issue #402: what does the run-shell command-string extraction produce for a
// single-quoted vs unquoted `-c <windows path>` argument?
use super::*;

fn extract_run_shell(cmd: &str) -> (String, bool) {
    // Mirror of execute_command_string_single's run-shell arm.
    let args = parse_command_line(cmd);
    let mut cmd_parts: Vec<&str> = Vec::new();
    let mut background = false;
    for arg in &args[1..] {
        if arg == "-b" { background = true; }
        else { cmd_parts.push(arg); }
    }
    (cmd_parts.join(" "), background)
}

#[test]
fn parse_singlequoted_vs_unquoted_c_path() {
    let sq = r"run-shell psmux new-window -n W -c 'C:\Users\testuser\psmux_test402\project'";
    let uq = r"run-shell psmux new-window -n W -c C:\Users\testuser\psmux_test402\project";

    let sq_tokens = parse_command_line(sq);
    let uq_tokens = parse_command_line(uq);
    eprintln!("SQ tokens: {:?}", sq_tokens);
    eprintln!("UQ tokens: {:?}", uq_tokens);

    let (sq_cmd, _) = extract_run_shell(sq);
    let (uq_cmd, _) = extract_run_shell(uq);
    eprintln!("SQ shell_cmd: [{}]", sq_cmd);
    eprintln!("UQ shell_cmd: [{}]", uq_cmd);

    // If these differ, the single-quote handling is the culprit.
    assert_eq!(sq_cmd, uq_cmd, "single-quoted and unquoted -c path produce DIFFERENT shell_cmd");
}

#[test]
fn parse_singlequoted_with_b_flag() {
    let s = r"run-shell -b psmux new-window -n W -c 'C:\work\repo'";
    let toks = parse_command_line(s);
    eprintln!("tokens: {:?}", toks);
    let (cmd, bg) = extract_run_shell(s);
    eprintln!("shell_cmd: [{}] background={}", cmd, bg);
    assert!(bg, "-b should be detected");
    // The path backslashes must survive
    assert!(cmd.contains(r"C:\work\repo"), "path mangled: {}", cmd);
}
