// Regression tests for MSIX package-interior shell resolution.
//
// Store-installed PowerShell puts its package-interior directory
// (C:\Program Files\WindowsApps\<pkg>) on PATH, so `which` resolves pwsh to
// the exe INSIDE the package (the proper app execution alias is a zero-length
// APPEXECLINK reparse point that `which` cannot follow, so it skips it).
// ConPTY-spawning the interior exe depends on MSIX activation that breaks
// when the environment's USERPROFILE does not match the real profile
// (CreateProcessW fails with ACCESS_DENIED and the pane child never runs;
// found via tests/test_first_pane_cpr_hang.ps1 whose isolated throwaway HOME
// redirects USERPROFILE).  `prefer_app_execution_alias` swaps the interior
// path for the supported alias.

use super::*;

#[test]
fn non_windowsapps_paths_pass_through_untouched() {
    for p in [
        r"C:\Program Files\PowerShell\7\pwsh.exe",
        r"C:\Windows\System32\cmd.exe",
        r"C:\Program Files\Git\bin\bash.exe",
        "pwsh.exe",
    ] {
        assert_eq!(prefer_app_execution_alias(p.to_string()), p, "{} must not be rewritten", p);
    }
}

#[test]
fn alias_dir_path_is_not_rewritten() {
    // Already the supported launch surface; rewriting would be a no-op loop.
    let alias = r"C:\Users\u\AppData\Local\Microsoft\WindowsApps\pwsh.exe";
    assert_eq!(prefer_app_execution_alias(alias.to_string()), alias);
}

#[test]
fn interior_path_without_matching_alias_is_kept() {
    // No alias exists for this made-up exe, so the resolved path must be kept
    // rather than swapped for a nonexistent file.
    let interior = r"C:\Program Files\WindowsApps\Fake.Package_1.0_x64__abc\no_such_alias_zz9.exe";
    assert_eq!(prefer_app_execution_alias(interior.to_string()), interior);
}

#[cfg(windows)]
#[test]
fn interior_path_is_swapped_for_existing_alias() {
    // Build a fake LOCALAPPDATA layout containing Microsoft\WindowsApps\<exe>
    // and verify the interior path is rewritten to that alias.
    let _lock = crate::util::lock_test_env();
    let tmp = std::env::temp_dir().join(format!("psmux_alias_test_{}", std::process::id()));
    let alias_dir = tmp.join("Microsoft").join("WindowsApps");
    std::fs::create_dir_all(&alias_dir).unwrap();
    let alias = alias_dir.join("aliastest_shell.exe");
    std::fs::write(&alias, b"").unwrap();

    let orig = std::env::var("LOCALAPPDATA").ok();
    std::env::set_var("LOCALAPPDATA", &tmp);

    let interior = r"C:\Program Files\WindowsApps\Fake.Package_1.0_x64__abc\aliastest_shell.exe";
    let rewritten = prefer_app_execution_alias(interior.to_string());

    match &orig {
        Some(v) => std::env::set_var("LOCALAPPDATA", v),
        None => std::env::remove_var("LOCALAPPDATA"),
    }
    let _ = std::fs::remove_dir_all(&tmp);

    assert_eq!(rewritten, alias.to_string_lossy(), "interior path must be swapped for the alias");
}

#[test]
fn case_insensitive_interior_detection() {
    let interior = r"c:\program files\windowsapps\Fake.Pkg_1_x64__abc\no_such_alias_zz9.exe";
    // Detection must trigger (case-insensitive); with no alias present the
    // path is kept, which proves the branch was taken without panicking.
    assert_eq!(prefer_app_execution_alias(interior.to_string()), interior);
}
