# Getting Started with psmux: tmux on Windows in 10 Minutes

psmux is a native terminal multiplexer for Windows that speaks the tmux command language. This tutorial walks a Windows user from installation to a working, persistent multi-pane session in PowerShell or Windows Terminal, with no WSL, Cygwin or MSYS2 involved. If you have used tmux on Linux or macOS, everything you already know applies; if you have never used a multiplexer, this page is the place to start.

**What you will learn**

- How to install psmux with winget, Scoop, Chocolatey, Cargo or a release zip
- How to start a session, split panes and open windows with the `Ctrl+b` prefix
- How to detach, close the terminal window, and reattach later with everything still running
- How copy mode, the Windows clipboard and the mouse work
- How to write a first `~/.psmux.conf` (your existing `.tmux.conf` also works)
- How to pick pwsh, cmd, Git Bash, WSL or nushell as the shell inside panes

**Key facts**

| | |
|---|---|
| Binary names | `psmux`, plus `pmux` and `tmux` aliases (type `tmux` and it just works) |
| Default prefix | `Ctrl+b`, same as tmux |
| Default shell in panes | PowerShell 7 (`pwsh`), configurable per session, window or pane |
| Config file | first of `~/.psmux.conf`, `~/.psmuxrc`, `~/.tmux.conf`, `~/.config/psmux/psmux.conf` |
| Requirements | Windows 10 or 11; PowerShell 7 recommended |
| Terminal | Windows Terminal, plain conhost, VS Code terminal, or any ConPTY host |

## How do I install psmux on Windows?

Pick one channel. All of them put `psmux.exe`, `pmux.exe` and `tmux.exe` on your PATH.

```powershell
# WinGet (Windows 10/11 built in package manager)
winget install psmux

# Scoop
scoop bucket add psmux https://github.com/psmux/scoop-psmux
scoop install psmux

# Chocolatey
choco install psmux

# Cargo (builds from crates.io, needs a Rust toolchain)
cargo install psmux
```

You can also download the `.zip` from [GitHub Releases](https://github.com/psmux/psmux/releases) and add the folder to your PATH. Verify the install from any shell:

```powershell
psmux -V
# psmux 3.3.8 (cbb9c10 2026-08-28)

tmux -V
# tmux 3.3.8
```

The `tmux -V` output is deliberately tmux shaped so scripts and tools that check the version string keep working. See the [cross platform scripting tutorial](cross-platform-tmux-scripts.md) for why that matters.

psmux launches PowerShell 7 by default. If `pwsh` is not installed it falls back to Windows PowerShell 5, then `cmd.exe`, but the experience is much better with pwsh:

```powershell
winget install --id Microsoft.PowerShell
```

## How do I start my first session?

Open Windows Terminal (or any console) and type:

```powershell
psmux
```

You get a full screen view with a status bar at the bottom and a PowerShell prompt inside a pane. That prompt is running inside a psmux **server**, a background process that owns your shells. The window you are looking at is a **client** attached to that server. Keeping the two apart is what makes sessions survive later on.

Give sessions names from the start; it makes everything else easier:

```powershell
psmux new-session -s main
```

`new`, `new-session` and `new -s main` are all the same command. To attach to an existing session, or create it if it does not exist yet:

```powershell
psmux new -A -s main
```

## How do I split a pane in PowerShell?

Inside the session, press the prefix (`Ctrl+b`), release it, then press the next key:

| Keys | What happens |
|------|--------------|
| `Ctrl+b` then `%` | Split the current pane left and right |
| `Ctrl+b` then `"` | Split the current pane top and bottom |
| `Ctrl+b` then arrow key | Move focus to the pane in that direction |
| `Ctrl+b` then `o` | Cycle focus to the next pane |
| `Ctrl+b` then `z` | Zoom the current pane to full size (press again to restore) |
| `Ctrl+b` then `x` | Kill the current pane |
| `Ctrl+b` then `Space` | Cycle through the built in layouts |
| `Ctrl+b` then `q` | Flash pane numbers, press one to jump there |

The same actions are commands, so you can run them from a prompt in another terminal or from a script:

```powershell
psmux split-window -h -t main          # left/right split in session "main"
psmux split-window -v -p 30 -t main    # bottom pane takes 30 percent
psmux split-window -h -c "#{pane_current_path}"   # new pane starts in the same folder
psmux select-layout -t main main-vertical
```

Every pane is its own ConPTY with its own shell process. Resizing the terminal window resizes the layout; dragging a pane border with the mouse resizes a split.

## How do I open more windows?

A window is a full screen tab with its own set of panes. The status bar lists them.

| Keys | What happens |
|------|--------------|
| `Ctrl+b` then `c` | Create a new window |
| `Ctrl+b` then `n` / `p` | Next / previous window |
| `Ctrl+b` then `0` to `9` | Jump to window by number |
| `Ctrl+b` then `,` | Rename the current window |
| `Ctrl+b` then `w` | Interactive window and pane chooser (`choose-tree`) |
| `Ctrl+b` then `&` | Kill the current window |

From the command line:

```powershell
psmux new-window -t main -n logs                     # named window
psmux new-window -t main -n build -- cargo watch     # window that runs a command
psmux new-window -t main -c C:\Projects\api          # window that starts in a folder
```

Clicking a window name in the status bar switches to it.

## How do I detach and reattach a session?

This is the feature that makes a multiplexer worth using. Press `Ctrl+b` then `d` to **detach**. Your terminal returns to the plain prompt, but the session, its panes and every process inside them keep running in the psmux server.

Close the terminal window entirely. Open a new one. Then:

```powershell
psmux ls
# main: 3 windows (created Sat Aug 29 15:40:16 2026)

psmux attach -t main
```

Everything is exactly where you left it, including a `cargo watch`, an SSH connection or an AI coding agent that was mid task. `psmux ls` (or `list-sessions`) shows what the server is holding, and `psmux kill-session -t main` ends a session for good.

Because the server is a separate process, this also works for things started without any window at all:

```powershell
# Start a session in the background, no window opens
psmux new-session -d -s worker -- python .\long_job.py

# Come back later from any terminal
psmux attach -t worker
```

The [Windows use cases](../use-cases.md) page builds on this idea for boot time services, remote administration and long running agents.

## How does copy mode and the Windows clipboard work?

Press `Ctrl+b` then `[` to enter **copy mode**. The pane border turns yellow, `[copy mode]` appears in the title, and you can move around the scrollback with the arrow keys or `h j k l`, page with `PageUp`/`PageDown`, and search with `/` (forward) and `?` (backward). Press `Space` to start a selection, move the cursor, then `Enter` or `y` to copy it to the Windows clipboard and leave copy mode. `q` or `Escape` leaves without copying.

Prefer vi keys? One line of config switches the keymap:

```tmux
set -g mode-keys vi
```

One thing to know if you come from vim: as in tmux, `v` toggles rectangle selection and does not start one. `Space` starts a selection and `V` starts a line selection. If you want `v` to begin a selection the way vim does, bind it:

```tmux
bind-key -T copy-mode-vi v send-keys -X begin-selection
```

Paste inside a pane with `Ctrl+b` then `]`, or use the terminal's normal paste (`Ctrl+Shift+V` or right click in Windows Terminal); both reach the shell in the active pane. The full copy mode keymap, for emacs and vi, is in [Key Bindings](../keybindings.md).

## Does the mouse work?

Yes, and it is on by default. With the mouse you can:

- Click a pane to focus it
- Click a window name in the status bar to switch to it
- Drag a pane border to resize the split
- Scroll the wheel to move through scrollback (this enters copy mode at a shell prompt, and passes the wheel through to full screen apps such as `nvim`, `htop` or `less` that ask for it)
- Left drag to select text; the selection is copied to the Windows clipboard on release
- Right click to paste

Applications that draw their own columns (lazygit, opencode, a split nvim) may prefer to handle selection themselves; `set -g mouse-selection off` hands drag selection to the app while keeping clicks, scrolling and border resizing. Details, including how mouse events reach programs over SSH, are in [Mouse and SSH](../mouse-ssh.md) and [Configuration](../configuration.md).

## How do I write my first config file?

psmux reads the first file it finds from this list: `~/.psmux.conf`, `~/.psmuxrc`, `~/.tmux.conf`, `~/.config/psmux/psmux.conf`. `~` is your Windows user profile (`C:\Users\<you>`). If you already have a `.tmux.conf` from Linux, copy it over as is; the syntax is tmux syntax.

A useful first `~/.psmux.conf`:

```tmux
# Use Ctrl+a as the prefix (Ctrl+b is the default)
set -g prefix C-a

# Windows and panes count from 1
set -g base-index 1
set -g pane-base-index 1

# vi keys in copy mode
set -g mode-keys vi

# Bigger scrollback
set -g history-limit 10000

# Easier splits that keep the current folder
bind-key | split-window -h -c "#{pane_current_path}"
bind-key - split-window -v -c "#{pane_current_path}"

# Reload the config with Prefix + r
bind-key r source-file ~/.psmux.conf \; display-message "config reloaded"

# Status bar
set -g status-style "bg=#1e1e2e,fg=#cdd6f4"
set -g status-left "[#S] "
set -g status-right "%H:%M %d-%b-%y"
```

Save the file, then either restart psmux or run `psmux source-file ~/.psmux.conf`. To try a config without touching your default one, use `psmux -f C:\path\to\other.conf`, and `psmux -f NUL` starts with no config at all.

Themes and plugins (Catppuccin, Dracula, Nord, session save and restore, and more) install through the plugin manager described in [Plugins and Themes](../plugins.md).

## Which shell runs inside the panes: pwsh, cmd, Git Bash, WSL or nushell?

The default is PowerShell 7. Change it globally in the config:

```tmux
set -g default-shell cmd          # cmd.exe
set -g default-shell powershell   # Windows PowerShell 5
set -g default-shell nu           # nushell
set -g default-shell wsl          # your default WSL distro
set -g default-shell "C:/Program Files/Git/bin/bash.exe"   # Git Bash
```

Or mix shells in one session, per window or per pane:

```powershell
psmux new-window -n linux wsl
psmux split-window -h -- "C:/Program Files/Git/bin/bash.exe"
psmux new-session -s admin -- cmd
```

A session with pwsh on the left, WSL Ubuntu on the right and a cmd window for legacy tools is a normal psmux setup. [Multi-Shell](../multi-shell.md) covers the bindings, the per shell quirks and how `#{pane_current_path}` behaves in each.

## How do I make Windows Terminal open straight into psmux?

Add a profile whose command line attaches to (or creates) a named session. In Windows Terminal open Settings, add a new profile, and set:

```text
Command line: psmux new -A -s main
Starting directory: %USERPROFILE%
```

Or in `settings.json`:

```json
{
  "name": "psmux",
  "commandline": "psmux new -A -s main",
  "startingDirectory": "%USERPROFILE%"
}
```

`new -A -s main` attaches if `main` exists and creates it otherwise, so every new tab of that profile lands in the same session, and closing the tab only detaches. Set it as the default profile if you want psmux in every tab.

Session creation is fast because psmux keeps a **warm** server pre spawned in the background and claims it on `new-session`; see [Warm Sessions](../warm-sessions.md).

## Where do I go next?

- [Windows Use Cases](../use-cases.md): boot time services, remote admin, AI agents, dashboards
- [Terminal agents and TUIs](terminal-agents-and-tuis.md): running Claude Code, Codex, lazygit, nvim and friends in panes
- [Dev environment layouts](dev-environment-layouts.md): repeatable project layouts and sessionizer scripts
- [Cross platform tmux scripts](cross-platform-tmux-scripts.md): automation that runs on Windows, Linux and macOS unchanged
- [Key Bindings](../keybindings.md), [Configuration](../configuration.md), [Scripting](../scripting.md), [Command Reference](../tmux_args_reference.md)
- [FAQ](../faq.md) and [Compatibility](../compatibility.md)

## FAQ

**Q: Do I need WSL, Cygwin or MSYS2 to run psmux?**
A: No. psmux is a native Windows executable built on ConPTY. It runs PowerShell, cmd and Windows programs directly. WSL and Git Bash are optional shells you can put inside panes.

**Q: Can I type `tmux` instead of `psmux`?**
A: Yes. `tmux.exe` and `pmux.exe` ship alongside `psmux.exe` and behave identically, so muscle memory and existing scripts keep working.

**Q: My `.tmux.conf` from Linux has lines psmux does not understand. Will it break?**
A: No. An unknown option produces a one line warning at startup and is otherwise skipped, so the rest of the file still loads. The [Compatibility](../compatibility.md) matrix lists every supported command and option, and `psmux list-commands` prints the live list for your build.

**Q: Where did my session go after I closed Windows Terminal?**
A: Nowhere. Closing the window detaches the client. Run `psmux ls` from a new terminal and `psmux attach -t <name>` to get back in. Only `kill-session`, `kill-server` or a reboot ends a session.

**Q: Does psmux work over SSH into a Windows machine?**
A: Yes. Install psmux on the Windows host, SSH in with OpenSSH, and run `psmux` there. Mouse support over SSH depends on the Windows build; [Mouse and SSH](../mouse-ssh.md) has the table.

**Q: How do I see every key binding currently active?**
A: Press `Ctrl+b` then `?`, or run `psmux list-keys`.
