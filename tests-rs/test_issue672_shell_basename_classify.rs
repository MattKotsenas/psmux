// Issue #672: "Warm-pane cd injection uses PowerShell syntax for full-path Git
// Bash default-shell" (TreyThomasCodes, on 3.3.8 / 66cf613).
//
// Reported line, in a Git Bash pane served from the warm pool:
//
//     $  cd 'C:\Users\trey\trading\newsletter-follower'; try { [System.IO.Directory]::SetCurrentDirectory($PWD.ProviderPath) } catch {}; cls
//     bash: syntax error near unexpected token `('
//
// with `set -g default-shell "C:/Program Files/Git/bin/bash.exe"`.
//
// That is the same defect as #600 and 3.3.8's `rehome_command` is where it
// lives: it had no shell classification at all, it picked the snippet from
// `cfg!(windows)`, so on Windows every pane got the PowerShell form whatever
// shell was running in it. `rehome_syntax_for_shell` (added for #600) replaced
// that with a classification keyed on the shell.
//
// The reporter's hypothesis was that the classification "compares the raw
// default-shell value against bare names instead of matching on the basename".
// That is the property this file pins: the answer must depend only on WHICH
// shell the value names, never on HOW it is spelled. A bare name, an absolute
// path, forward or backslashes, with or without `.exe`, any letter case, a
// quoted value and a value carrying arguments must all classify identically.
//
// tests-rs/test_issue600_bash_rehome.rs pins the wire form of each dialect;
// tests/test_issue672_gitbash_fullpath_warm_cd.ps1 drives the real panes.

use super::*;

/// Every way a user can spell one and the same shell in `default-shell`.
///
/// `dir` is a directory that is NOT on this machine, on purpose: the spelling
/// rule must not depend on the file being present (a config is often shared
/// between machines, and psmux classifies before it ever spawns anything).
fn spellings(dir: &str, stem: &str) -> Vec<String> {
    let fwd = dir.replace('\\', "/");
    vec![
        // bare name, with and without the extension
        stem.to_string(),
        format!("{stem}.exe"),
        // absolute path, forward slashes
        format!("{fwd}/{stem}.exe"),
        format!("{fwd}/{stem}"),
        // absolute path, backslashes
        format!("{dir}\\{stem}.exe"),
        format!("{dir}\\{stem}"),
        // mixed case: Windows paths are case insensitive and users type them
        // however they like
        format!("{}/{}.EXE", fwd.to_uppercase(), stem.to_uppercase()),
        format!("{}/{}", fwd, mixed_case(stem)),
        // quoted, the spelling docs/multi-shell.md tells users to use for a
        // path containing spaces
        format!("\"{fwd}/{stem}.exe\""),
        format!("\"{dir}\\{stem}.exe\""),
        // with arguments, quoted and bare
        format!("\"{fwd}/{stem}.exe\" --some-flag"),
        format!("{stem} --some-flag"),
        // surrounding whitespace survives a hand edited config
        format!("  {stem}.exe  "),
    ]
}

/// "bash" -> "BaSh": neither the lower nor the upper spelling.
fn mixed_case(stem: &str) -> String {
    stem.chars()
        .enumerate()
        .map(|(i, c)| if i % 2 == 0 { c.to_ascii_uppercase() } else { c })
        .collect()
}

/// A directory with a space in it, like the reporter's `C:\Program Files\...`,
/// and one without. Both must behave the same.
const DIRS: &[&str] = &[
    r"C:\Program Files\Some Vendor\bin",
    r"C:\tools\bin",
];

fn assert_family(stem: &str, expected: RehomeSyntax) {
    for dir in DIRS {
        for spelling in spellings(dir, stem) {
            assert_eq!(
                rehome_syntax_for_shell(&spelling),
                expected,
                "default-shell {spelling:?} names {stem}, so it must classify as {expected:?} (#672)"
            );
        }
    }
}

// ───────────────────────── one family per test ─────────────────────────

/// The reporter's own shell. Every spelling of bash is a POSIX shell, so the
/// injected line is `cd '<dir>'; clear` and never contains `(`.
#[test]
fn bash_classifies_posix_however_it_is_spelled() {
    assert_family("bash", RehomeSyntax::Posix);
}

#[test]
fn zsh_classifies_posix_however_it_is_spelled() {
    assert_family("zsh", RehomeSyntax::Posix);
}

#[test]
fn fish_classifies_posix_however_it_is_spelled() {
    assert_family("fish", RehomeSyntax::Posix);
}

/// The rest of the POSIX family psmux knows about.
#[test]
fn other_posix_shells_classify_posix_however_they_are_spelled() {
    for stem in ["sh", "dash", "ksh", "tcsh", "csh", "ash", "busybox"] {
        assert_family(stem, RehomeSyntax::Posix);
    }
}

#[test]
fn cmd_classifies_cmd_however_it_is_spelled() {
    assert_family("cmd", RehomeSyntax::Cmd);
}

#[test]
fn pwsh_classifies_powershell_however_it_is_spelled() {
    assert_family("pwsh", RehomeSyntax::PowerShell);
}

#[test]
fn powershell_classifies_powershell_however_it_is_spelled() {
    assert_family("powershell", RehomeSyntax::PowerShell);
}

/// Nushell used to keep the platform default — the PowerShell form, which
/// is a parse error in nu (`nu::parser::env_var_not_var` on `$PWD`, so the
/// `cd` never ran either); tests-rs/test_nu_rehome.rs pins its own dialect
/// now. #672 is about SPELLING, not about which family a shell is in, so
/// what is pinned here is that every spelling of nushell lands in the same
/// place as every other: the fallback must not be reached for some spellings
/// and skipped for others.
#[test]
fn nushell_classifies_the_same_however_it_is_spelled() {
    assert_family("nu", RehomeSyntax::Nu);
}

// ───────────────────────── the reporter's config ─────────────────────────

/// The exact `default-shell` line from the issue, in the two path styles a
/// Windows user writes, with and without the extension, and quoted the way
/// docs/multi-shell.md tells users to quote a path with spaces.
#[test]
fn reporters_git_bash_default_shell_selects_posix() {
    for shell in [
        "C:/Program Files/Git/bin/bash.exe",
        r"C:\Program Files\Git\bin\bash.exe",
        "C:/Program Files/Git/usr/bin/bash.exe",
        "C:/Program Files/Git/bin/bash",
        "\"C:/Program Files/Git/bin/bash.exe\"",
        "\"C:\\Program Files\\Git\\bin\\bash.exe\"",
        "\"C:/Program Files/Git/bin/bash.exe\" --login",
        "C:/PROGRAM FILES/GIT/BIN/BASH.EXE",
    ] {
        assert_eq!(
            rehome_syntax_for_shell(shell),
            RehomeSyntax::Posix,
            "the documented Git Bash setup {shell:?} must select the POSIX form (#672)"
        );
    }
}

/// The end-to-end composition that produced the reported scrollback: classify
/// the reporter's `default-shell`, build the line, and check it is something
/// bash can run. The pre-#600 code produced the PowerShell form here and bash
/// answered `syntax error near unexpected token '('`.
#[test]
fn reporters_config_produces_a_line_bash_can_run() {
    let syntax = rehome_syntax_for_shell("C:/Program Files/Git/bin/bash.exe");
    let line = rehome_command(r"C:\Users\trey\trading\newsletter-follower", syntax);
    assert!(
        !line.contains("SetCurrentDirectory"),
        "the .NET call is the token bash choked on, got {line:?}"
    );
    for tok in ['(', ')', '{', '}'] {
        assert!(!line.contains(tok), "bash cannot parse {tok:?} here, got {line:?}");
    }
    if cfg!(windows) {
        assert_eq!(line, " cd 'C:/Users/trey/trading/newsletter-follower'; clear\r");
    }
}

// ──────────────────────── the spelling rule itself ────────────────────────

/// WSL's `bash.exe` sits in System32 and is what a bare `bash` resolves to on
/// a machine without Git Bash on PATH (the reporter says so explicitly). Its
/// stem is `bash`, so it classifies POSIX like any other bash, which is right:
/// the shell on the other side of `wsl` is a Linux bash and `cd '<dir>'; clear`
/// is exactly what it speaks. Behaviour unchanged by #672; pinned so it stays
/// deliberate.
#[test]
fn wsl_system32_bash_is_posix() {
    assert_eq!(
        rehome_syntax_for_shell(r"C:\Windows\System32\bash.exe"),
        RehomeSyntax::Posix,
        "System32 bash.exe is WSL's bash and speaks POSIX"
    );
}

/// `wsl.exe` itself is not a shell psmux can write a `cd` for (the Win32 side
/// is a launcher), so it keeps the platform default rather than guessing.
#[test]
fn wsl_launcher_keeps_the_platform_default() {
    let expected = if cfg!(windows) { RehomeSyntax::PowerShell } else { RehomeSyntax::Posix };
    for shell in ["wsl", "wsl.exe", r"C:\Windows\System32\wsl.exe"] {
        assert_eq!(rehome_syntax_for_shell(shell), expected, "{shell:?}");
    }
}

/// An unrecognised program keeps the platform default however it is spelled:
/// the fallback must not flip between spellings either.
#[test]
fn unknown_shell_keeps_the_platform_default_however_spelled() {
    let expected = if cfg!(windows) { RehomeSyntax::PowerShell } else { RehomeSyntax::Posix };
    for dir in DIRS {
        for spelling in spellings(dir, "some-unheard-of-shell-9f3a") {
            assert_eq!(rehome_syntax_for_shell(&spelling), expected, "{spelling:?}");
        }
    }
}

/// A directory component that merely CONTAINS a shell's name must not decide
/// the dialect: only the file the path names does. This is the misclassification
/// the reporter hypothesised, in its other direction.
#[test]
fn a_directory_named_after_another_shell_does_not_decide() {
    assert_eq!(
        rehome_syntax_for_shell(r"C:\Users\trey\powershell-tools\bin\bash.exe"),
        RehomeSyntax::Posix,
        "a `powershell` directory must not turn bash into PowerShell (#672)"
    );
    assert_eq!(
        rehome_syntax_for_shell(r"C:\bash-scripts\bin\pwsh.exe"),
        RehomeSyntax::PowerShell,
        "a `bash` directory must not turn pwsh into a POSIX shell (#672)"
    );
    assert_eq!(
        rehome_syntax_for_shell(r"C:\cmd-tools\bin\bash.exe"),
        RehomeSyntax::Posix,
        "a `cmd` directory must not turn bash into cmd (#672)"
    );
}

/// The whole point, stated once: for a given shell, the classification is a
/// function of the shell and nothing else. Any two spellings of one shell must
/// agree with each other.
#[test]
fn every_spelling_of_one_shell_agrees_with_every_other() {
    for stem in ["bash", "zsh", "fish", "sh", "cmd", "pwsh", "powershell", "nu"] {
        let mut answers = std::collections::BTreeSet::new();
        for dir in DIRS {
            for spelling in spellings(dir, stem) {
                answers.insert(format!("{:?}", rehome_syntax_for_shell(&spelling)));
            }
        }
        assert_eq!(
            answers.len(),
            1,
            "{stem} classified {} different ways across its spellings: {answers:?} (#672)",
            answers.len()
        );
    }
}
