// Issue #638: Ctrl+C at an idle shell inside Neovim `:terminal` killed Neovim.
//
// Reproduced with a physical Ctrl+C (WriteConsoleInput) into a real attached
// psmux client, 3 of 3 runs fatal, with both `cmd.exe` and `pwsh` as Neovim's
// `&shell`.  The pane console at the moment of the signal:
//
//   ctrl_c: console process list n=4 members=[3628=pmux.exe ppid=26384 ... |
//     8636=nvim.exe ppid=21068 ... | 21068=nvim.exe ppid=11276 ... |
//     11276=pwsh.exe ppid=3628 ...]
//   ctrl_c: console mode=0x0208 PROCESSED_INPUT=false fg_is_shell=true
//   ctrl_c: GenerateConsoleCtrlEvent => ok=1 err=183
//   -> pane shows: Nvim: Caught deadly signal 'SIGINT'
//
// The Ctrl+C router resolves the pane's foreground by walking the PPID tree to
// its deepest leaf.  With `:terminal` open that leaf is the inner shell, which
// Neovim runs on its OWN pseudoconsole: a PPID descendant of the pane, so the
// walk finds it and `fg_is_shell` is true, but NOT a member of the pane
// console, so the console-wide broadcast cannot be delivered to it.  What the
// broadcast does reach is every process that is on the pane console, Neovim
// included, and Neovim's default handler terminates it.
//
// `broadcast_can_reach_foreground` is the structural rule that closes it: fire
// the console control event only when the process the classification was based
// on is a member of the console that receives the event.  It names no
// application, so it covers any program that hosts a child pseudoconsole.
//
// The control arm, `ping localhost -t` inside the same `:terminal`, took the
// raw 0x03 branch before the fix and still does after it: the leaf is ping.exe,
// a plain console app, and console membership is irrelevant to that branch.

use crate::platform::process_info::broadcast_can_reach_foreground;

/// The measured #638 shape.  Pane console = {psmux, nvim, nvim, pwsh}; the
/// classified foreground leaf is the inner `cmd.exe` on Neovim's private
/// pseudoconsole, absent from the list.  The broadcast must be refused.
#[test]
fn issue638_leaf_on_a_private_pseudoconsole_refuses_the_broadcast() {
    let pane_root = 11276; // pwsh.exe, the pane's shell
    let console = [3628u32 /* psmux */, 8636 /* nvim */, 21068 /* nvim */, 11276 /* pwsh */];
    let inner_shell = 30001u32; // cmd.exe run by :terminal, on nvim's own pty

    assert!(
        !broadcast_can_reach_foreground(pane_root, Some(inner_shell), &console),
        "the leaf that justified the signal is not on the console that would receive it, \
         so the broadcast must be refused and the raw 0x03 written instead"
    );
}

/// Issue #338: bare shell prompt line-cancel.  The pane root has no children,
/// so the router classifies the root itself and `foreground_leaf_pid` yields
/// `None`.  The root is on the pane console by construction, so the broadcast
/// stays allowed.  Measured console for this arm: n=2, {psmux, pwsh}.
#[test]
fn issue338_childless_shell_prompt_still_broadcasts() {
    let pane_root = 14156;
    let console = [17600u32 /* psmux */, 14156 /* pwsh */];

    assert!(
        broadcast_can_reach_foreground(pane_root, None, &console),
        "a childless pane root is the classified process and is on the console"
    );
}

/// The same guarantee stated explicitly: even if the walk hands back the root
/// itself rather than `None`, that is a console member and must not be refused.
#[test]
fn issue338_root_as_its_own_leaf_still_broadcasts() {
    let pane_root = 14156;
    let console = [17600u32, 14156];

    assert!(
        broadcast_can_reach_foreground(pane_root, Some(pane_root), &console),
        "the pane root is always on the console psmux attached to"
    );
}

/// Issue #346: `ping` launched from the pane shell.  ping.exe is a plain
/// console app and joins the PANE console, so the classified leaf is reachable
/// and the broadcast is allowed.  This is the arm that would break if the rule
/// were "any non-shell foreground refuses the broadcast".
#[test]
fn issue346_ping_under_the_pane_shell_still_broadcasts() {
    let pane_root = 14156;
    let ping = 22334u32;
    let console = [17600u32 /* psmux */, 14156 /* pwsh */, 22334 /* ping */];

    assert!(
        broadcast_can_reach_foreground(pane_root, Some(ping), &console),
        "ping shares the pane console, so the signal reaches exactly the process \
         that justified it"
    );
}

/// Issue #579's WSL boot window reaches this point only when no bridge started
/// recently, and it gets there through the childless fallback, so the rule must
/// not add a second refusal on top of it.
#[test]
fn issue579_boot_window_fallback_is_not_refused_by_this_rule() {
    let pane_root = 9001;
    let console = [9000u32 /* psmux */, 9001 /* pwsh */];

    assert!(
        broadcast_can_reach_foreground(pane_root, None, &console),
        "the childless fallback must keep its own #579 decision, not be overridden here"
    );
}

/// A snapshot failure yields `None` as well, and must preserve the established
/// interrupt behaviour rather than silently disabling Ctrl+C.
#[test]
fn snapshot_failure_preserves_the_broadcast() {
    assert!(
        broadcast_can_reach_foreground(4242, None, &[]),
        "unknown foreground defaults to allow, matching foreground_is_shell's unwrap_or(true)"
    );
}

/// A leaf that is a console member is allowed even when the console holds many
/// processes, and one that is not is refused even when the console is large:
/// membership is the whole rule, nothing about ordering or list length.
#[test]
fn membership_is_the_only_criterion() {
    let console: Vec<u32> = (100..164).collect();

    assert!(broadcast_can_reach_foreground(100, Some(163), &console));
    assert!(broadcast_can_reach_foreground(100, Some(100), &console));
    assert!(!broadcast_can_reach_foreground(100, Some(164), &console));
    assert!(!broadcast_can_reach_foreground(100, Some(99), &console));
}

/// An empty console list cannot reach anything but the root.  The call site
/// guards this with `n > 0`, so the rule never has to invent a decision from an
/// empty enumeration, but the function itself stays honest about it.
#[test]
fn empty_console_reaches_only_the_root() {
    assert!(broadcast_can_reach_foreground(7, Some(7), &[]));
    assert!(!broadcast_can_reach_foreground(7, Some(8), &[]));
}
