// Issue #399 (comment 5041988743): the PSMUX_CLAUDE_TEAMMATE_MODE claude
// wrapper injected `--teammate-mode tmux` unconditionally.  Claude Code gives
// CLI flags the highest priority, and current builds DO read `teammateMode`
// from settings.json (`[TeammateModeSnapshot] Captured from config: ...`), so
// the blind injection silently overrode a user's explicit
// `"teammateMode": "..."` in .claude/settings.json.
//
// Fix: the wrapper only injects when teammateMode is NOT already configured
// in any settings file Claude Code consults at call time:
//   - an explicit --teammate-mode CLI arg (pre-existing behavior)
//   - <ProgramData>/ClaudeCode/managed-settings.json
//   - user scope: $CLAUDE_CONFIG_DIR/settings.json or ~/.claude/settings.json
//   - project scope: .claude/settings.json / .claude/settings.local.json in
//     the CWD or any ancestor directory
//
// These are functional tests: they run the real shipped shim through
// pwsh/powershell against a fake claude.ps1 that echoes its args.

use super::ENV_SHIM_PS;

/// Scratch dir outside the real user profile so the ancestor walk cannot see
/// the developer's own ~/.claude/settings.json.
fn neutral_dir(tag: &str) -> std::path::PathBuf {
    let base = std::env::var_os("PUBLIC")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let d = base.join(format!("psmux_test399_{tag}"));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Fake npm-style claude that just echoes the args it received.
fn fake_claude_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("psmux_test399_fake_claude_{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("claude.ps1"),
        "Write-Output \"FAKE_CLAUDE_ARGS=$args\"\r\n",
    )
    .unwrap();
    dir
}

/// PATH = fake claude dir + every original PATH dir without a claude.exe.
fn path_with_fake_claude(fake: &std::path::Path) -> std::ffi::OsString {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut dirs: Vec<std::path::PathBuf> = vec![fake.to_path_buf()];
    dirs.extend(std::env::split_paths(&path).filter(|d| !d.join("claude.exe").exists()));
    std::env::join_paths(dirs).unwrap()
}

fn run_wrapper(
    claude_args: &str,
    path: &std::ffi::OsStr,
    cwd: &std::path::Path,
    cfg_dir: &std::path::Path,
) -> String {
    let script = format!("{}; claude {}", ENV_SHIM_PS, claude_args);
    let attempt = |exe: &str| {
        std::process::Command::new(exe)
            .args(["-NoProfile", "-Command", &script])
            .env("PATH", path)
            .env("PSMUX_CLAUDE_TEAMMATE_MODE", "tmux")
            .env("CLAUDE_CONFIG_DIR", cfg_dir)
            .current_dir(cwd)
            .output()
    };
    let out = attempt("pwsh")
        .or_else(|_| attempt("powershell"))
        .expect("no PowerShell available");
    format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Regression guard for the original #399 workaround: with teammateMode
/// configured nowhere, the wrapper must still inject --teammate-mode tmux.
#[test]
fn injects_when_teammate_mode_unconfigured_anywhere() {
    let cwd = neutral_dir("baseline");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    let fake = fake_claude_dir("baseline");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &cwd, &cfg);
    assert!(
        out.contains("--teammate-mode tmux"),
        "workaround regressed: no injection with teammateMode unconfigured.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}

/// THE BUG: project .claude/settings.json with teammateMode must suppress
/// injection so Claude Code resolves the mode from config, not a forced flag.
#[test]
fn respects_project_settings_json() {
    let cwd = neutral_dir("proj");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::write(
        cwd.join(".claude").join("settings.json"),
        "{ \"teammateMode\": \"in-process\" }",
    )
    .unwrap();
    let fake = fake_claude_dir("proj");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &cwd, &cfg);
    assert!(
        out.contains("FAKE_CLAUDE_ARGS="),
        "fake claude did not run.\nout: {out}"
    );
    assert!(
        !out.contains("--teammate-mode"),
        "BUG #399 PRESENT: wrapper injected --teammate-mode despite project settings.json teammateMode.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}

/// Project .claude/settings.local.json must also suppress injection.
#[test]
fn respects_project_settings_local_json() {
    let cwd = neutral_dir("projlocal");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::write(
        cwd.join(".claude").join("settings.local.json"),
        "{ \"teammateMode\": \"in-process\" }",
    )
    .unwrap();
    let fake = fake_claude_dir("projlocal");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &cwd, &cfg);
    assert!(
        !out.contains("--teammate-mode"),
        "wrapper must honour .claude/settings.local.json teammateMode.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}

/// User-scope settings ($CLAUDE_CONFIG_DIR/settings.json, standing in for
/// ~/.claude/settings.json) must suppress injection.
#[test]
fn respects_user_scope_settings() {
    let cwd = neutral_dir("userscope");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::write(
        cfg.join("settings.json"),
        "{ \"teammateMode\": \"in-process\" }",
    )
    .unwrap();
    let fake = fake_claude_dir("userscope");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &cwd, &cfg);
    assert!(
        !out.contains("--teammate-mode"),
        "wrapper must honour user-scope settings.json teammateMode.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}

/// Running claude from a subdirectory of the project must still find the
/// project settings via the ancestor walk.
#[test]
fn respects_parent_directory_project_settings() {
    let root = neutral_dir("walkup");
    let cfg = root.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::create_dir_all(root.join(".claude")).unwrap();
    std::fs::write(
        root.join(".claude").join("settings.json"),
        "{ \"teammateMode\": \"in-process\" }",
    )
    .unwrap();
    let sub = root.join("src").join("deep");
    std::fs::create_dir_all(&sub).unwrap();
    let fake = fake_claude_dir("walkup");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &sub, &cfg);
    assert!(
        !out.contains("--teammate-mode"),
        "wrapper must find project settings in an ancestor directory.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&fake);
}

/// A settings.json WITHOUT a teammateMode key must not suppress injection.
#[test]
fn settings_without_teammate_mode_still_injects() {
    let cwd = neutral_dir("nokey");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::write(
        cwd.join(".claude").join("settings.json"),
        "{ \"model\": \"opus\" }",
    )
    .unwrap();
    let fake = fake_claude_dir("nokey");
    let out = run_wrapper("--print hi", &path_with_fake_claude(&fake), &cwd, &cfg);
    assert!(
        out.contains("--teammate-mode tmux"),
        "settings.json without teammateMode must not disable injection.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}

/// An explicit CLI flag still wins and passes through exactly once, even with
/// settings present.
#[test]
fn explicit_cli_flag_passes_through_once() {
    let cwd = neutral_dir("explicit");
    let cfg = cwd.join("cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::write(
        cwd.join(".claude").join("settings.json"),
        "{ \"teammateMode\": \"in-process\" }",
    )
    .unwrap();
    let fake = fake_claude_dir("explicit");
    let out = run_wrapper(
        "--teammate-mode tmux --print hi",
        &path_with_fake_claude(&fake),
        &cwd,
        &cfg,
    );
    assert!(
        out.contains("FAKE_CLAUDE_ARGS=--teammate-mode tmux --print hi"),
        "explicit flag must pass through untouched.\nout: {out}"
    );
    assert_eq!(
        out.matches("--teammate-mode").count(),
        1,
        "flag must not be duplicated.\nout: {out}"
    );
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&fake);
}
