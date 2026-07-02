// Warm-pane `-c <dir>` re-home: the fast paths (create_window / split) now
// transplant the warm pane even when a start_dir is requested, then silently
// re-home the pre-spawned shell to that directory via `silent_rehome`.
//
// These unit tests cover the pure command-construction half (`rehome_command`),
// which is the security-sensitive part (single-quote escaping). The full
// behavioural path — warm pane actually consumed for `new-window -c` and the
// shell landing in the requested dir — needs real ConPTY/shell scaffolding and
// is covered by tests/test_warm_pane_start_dir.ps1.

use super::*;

/// The injected command must: start with a space (kept out of shell history),
/// `cd` into the requested directory, chain a clear to hide the echo, and end
/// with a single CR so it submits as exactly one command line.
#[test]
fn rehome_command_wraps_dir_and_clears() {
    let cmd = rehome_command(r"C:\code\project");
    assert!(cmd.starts_with(' '), "must start with a space, got {cmd:?}");
    assert!(cmd.ends_with('\r'), "must end with CR, got {cmd:?}");
    assert!(
        cmd.contains(r"cd 'C:\code\project'"),
        "must cd into the dir, got {cmd:?}"
    );
    let clear = if cfg!(windows) { "cls" } else { "clear" };
    assert!(cmd.contains(clear), "must chain {clear}, got {cmd:?}");
    assert_eq!(cmd.matches('\r').count(), 1, "exactly one line, got {cmd:?}");
}

/// A single quote in the path must be doubled so the single-quoted string stays
/// well-formed — otherwise the `cd` breaks (or a crafted path could inject a
/// second command). Precondition: the input actually contains a lone quote.
#[test]
fn rehome_command_escapes_single_quotes() {
    let input = r"C:\weird'dir";
    assert_eq!(input.matches('\'').count(), 1, "precondition: one lone quote");

    let cmd = rehome_command(input);
    assert!(
        cmd.contains(r"cd 'C:\weird''dir'"),
        "lone quote must be doubled, got {cmd:?}"
    );
    // Still exactly one command line — the quote didn't terminate it early.
    assert_eq!(cmd.matches('\r').count(), 1, "got {cmd:?}");
}

/// Full contract lock on Windows: documents the precise bytes injected so a
/// future refactor can't silently change the wire format.
#[test]
fn rehome_command_exact_windows_form() {
    if cfg!(windows) {
        assert_eq!(rehome_command(r"C:\x"), " cd 'C:\\x'; cls\r");
    }
}
