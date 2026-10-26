# How psmux Multiplexes Natively on Windows

psmux is a terminal multiplexer for Windows, a tmux for Windows written in Rust that drives real ConPTY pseudo consoles directly through the Win32 API. This page explains the architecture: the detached server process, the thin client that Windows Terminal or any console host attaches to, the per pane ConPTY and VT parser, and how bytes move between your shell and your screen. It is written so that a developer, a script author, or an AI agent can verify every claim against the source files named below.

## Key facts

- **One server per session, one client per attached window.** `psmux new-session` spawns `psmux.exe server -s <name>` as a detached background process. `psmux attach` starts a client that connects to it over loopback TCP. Closing the window kills only the client.
- **Every pane is a native ConPTY.** Each pane is created with `CreatePseudoConsole` through the vendored `portable-pty-psmux` crate. There is no WSL, Cygwin, or MSYS layer between psmux and the shell.
- **No POSIX emulation.** psmux does not need `fork()`, Unix sockets, or a pty device. The tmux socket is replaced by `127.0.0.1:<port>` plus a per session key file, both under `~\.psmux\`.
- **The client is a renderer, not a shell host.** The client never owns the shell processes. It receives screen frames as JSON and pushes keystrokes back as `send-key` commands.
- **Three names, one binary.** `psmux.exe`, `pmux.exe`, and `tmux.exe` are the same program (three `[[bin]]` entries in `Cargo.toml` pointing at `src/main.rs`), so scripts written for `tmux` run unchanged.
- **Windows first process model.** psmux's own processes run at `above-normal` priority by default (issue #608), shells stay at normal priority, the Windows clipboard is used directly, and detached servers survive Task Scheduler and RDP disconnects.

Related reading: [Performance](performance.md), [Warm Sessions](warm-sessions.md), [Multi-Shell](multi-shell.md), [Scripting and Automation](scripting.md), [Control Mode](control-mode.md), [Windows Use Cases](use-cases.md).

## What does "native" mean for a Windows terminal multiplexer?

There are three ways to get tmux style multiplexing on Windows:

| Approach | Where the shells run | What you lose |
|----------|----------------------|---------------|
| tmux inside WSL | Linux processes inside the WSL VM | Native pwsh, cmd, and Windows tools become remote calls through `wsl.exe`; Windows paths, the Windows clipboard, and Windows job control are one hop away |
| tmux under Cygwin or MSYS2 | Windows processes wrapped by a POSIX emulation layer and its pty shim | Console apps that need a real console (PSReadLine, Windows Terminal features, ConPTY aware TUIs) misbehave; performance is bounded by the emulation layer |
| **psmux** | **Real Windows processes in real ConPTY consoles** | Nothing on the Windows side; tmux features that depend on Unix signals are emulated (see [Compatibility](compatibility.md)) |

With psmux a pane running `pwsh`, a pane running `cmd`, a pane running `nu`, and a pane running `wsl` are four ordinary child processes of one server. Each has its own console, its own working directory (a Windows path, or a WSL path translated by `src/wsl_path.rs`), and its own environment. `#{pane_current_path}` is read from the child's process environment block, and for WSL panes from the OSC 7 sequence the shell emits (issue #615).

## The client and server model

```
  Windows Terminal tab            ~\.psmux\                    background process
 +----------------------+      +----------------+      +-----------------------------+
 |  psmux.exe (client)  |      | work.port      |      | psmux.exe server -s work    |
 |  attach -t work      |----->| work.key       |----->|  TcpListener 127.0.0.1:0    |
 |                      |      | work.pid       |      |  AppState (windows, panes)  |
 |  ratatui renderer    |<=====| work.sid       |=====>|  per pane ConPTY + parser   |
 |  crossterm input     | TCP  +----------------+ TCP  |  hooks, options, buffers    |
 +----------------------+                              +-----------------------------+
                                                          |         |         |
                                                       pwsh.exe  cmd.exe   wsl.exe
```

### How does a client find its server?

There is no Unix socket on Windows, so `src/server/mod.rs` binds a `TcpListener` to `127.0.0.1` on an ephemeral port (`TcpListener::bind(("127.0.0.1", 0))`) and publishes it through four small files in the data directory (`src/paths.rs`):

| File | Content | Purpose |
|------|---------|---------|
| `<session>.key` | random auth key | Every connection must send `AUTH <key>` first; the server rejects anything else in `src/server/connection.rs` |
| `<session>.sid` | session id | Stable identity for `#{session_id}` |
| `<session>.pid` | `pid:creation_time` | Liveness anchor: a recycled pid with a different creation time is never mistaken for a live server |
| `<session>.port` | TCP port | Written **last**, so its existence is the readiness beacon a client waits on |

The write order matters and is enforced in `ensure_session_registry_files`: key, sid, and pid go first, port goes last. A client such as `psmux attach` polls for the `.port` file every 10 ms (`src/main.rs`) and connects as soon as it appears, so a cold start attaches within one polling tick of the server being ready.

The data directory is `~\.psmux\` by default and can be moved with `PSMUX_DATA_DIR`. The `-L <name>` socket namespace of tmux maps to a file prefix (`<ns>__<session>.port`), so `psmux -L work ls` and `psmux -L home ls` see different registries. A named Win32 mutex keyed on the data root and session name (`acquire_session_mutex` in `src/platform.rs`) guarantees that at most one server owns a given name, which is what makes `new-session -A` and the warm pool safe against races (issues #509 and #599).

### What happens when you run a psmux command?

Every CLI invocation, whether it is `psmux split-window -h` from a script or a keystroke from an attached client, is one line of text sent over the TCP connection:

1. `src/main.rs` parses the command line, normalises tmux style attached flags (`-Lwork`, `-tname`), resolves the target session from `-t`, `PSMUX_SESSION_NAME`, or the most recently active session (issue #603), and reads that session's `.port` and `.key`.
2. The client connects, sends `AUTH <key>`, then the command line (`src/client.rs`).
3. The accept thread in `src/server/mod.rs` spawns a per connection thread. `handle_connection` in `src/server/connection.rs` parses the line, splits `;` separated command chains, and either answers directly (queries such as `list-panes` and `display-message -p`) or posts a `CtrlReq` enum value to the server's main loop through a channel.
4. The main loop in `run_server` applies the request to `AppState` (the tree of windows and panes defined in `src/types.rs` and `src/tree.rs`), fires any hooks, marks the state dirty, and pushes a new frame to attached clients.

Accepted sockets are explicitly made non inheritable with `SetHandleInformation` before any child is spawned, because the server starts children with inherited handles (ConPTY shells, `pipe-pane` sinks, `run-shell` commands) and an inherited socket would keep a one shot command's connection open after the reply.

The same wire protocol is what [control mode](control-mode.md) (`psmux -C`) exposes to IDEs and plugin authors.

## How a pane works: ConPTY, reader, parser, screen

```
   child process (pwsh.exe)
        |  writes VT bytes to its console
        v
   ConPTY (conhost.exe / OpenConsole)         crates/portable-pty-psmux/src/win/
        |  output pipe                        psuedocon.rs, conpty.rs
        v
   reader thread ---------> staging buffer ----> parser thread -----> vt100::Parser
   (64 KB reads,             (Mutex + Condvar)    (adaptive 1 ms       (screen grid +
    src/pane.rs)                                   coalescing)          scrollback)
                                                                             |
   write queue thread <---- server main loop <---- CtrlReq channel           |
   (per pane, PR #543)          |                                            |
        |                       +---- dump_layout_json_fast() snapshot <-----+
        v                       |
   ConPTY input pipe            +---- push frame over TCP to every attached client
```

### Spawning

`src/pane.rs` asks the pty crate for a pseudo console of the pane's size (`native_pty_system().openpty(size)`), builds a `CommandBuilder` for the shell (resolved once and cached in an `OnceLock`, so PATH lookups are not repeated per pane), and calls `spawn_command`. On the Windows side that is `CreatePseudoConsole` plus `CreateProcessW` with a `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` attribute list (`crates/portable-pty-psmux/src/win/psuedocon.rs`). The child is a normal Windows process whose console happens to be owned by psmux.

### Reading output

Each pane owns three threads (`src/pane.rs`):

- **Reader thread.** Pure I/O. It reads up to 64 KB at a time from the ConPTY output pipe into a staging buffer and never touches the parser lock, so a busy pane cannot stall its own reads. It also answers terminal colour queries (OSC 4, 10, 11) straight off the read, which is what stopped `yazi` from misreading a late reply as a keystroke (issue #556).
- **Parser thread.** Waits on the staging buffer's condition variable, then keeps draining in 1 ms ticks while bytes are still arriving (adaptive coalescing), and feeds the bytes into a `vt100::Parser` from the vendored `vt100-psmux` crate. The parser owns the screen grid, the alternate screen, the scrollback (`history-limit` rows), cell attributes including the SGR 58 underline colours added for issue #589, and the OSC 8 hyperlink and OSC 7 working directory state, and the per pane OSC 4 colour palette added for issue #685 (indexed colours are resolved through it where a cell is serialised for the client, which is psmux's equivalent of tmux's `tty_check_fg`).
- **Write queue thread.** Keystrokes and pasted text are queued per pane and written to the ConPTY input pipe by a dedicated thread, so a slow or wedged child never blocks the server loop and a transient write error is retried rather than dropped (PR #543).

### Building a frame

The server does not re render on a timer. Whenever a pane's parser reports new output or the window tree changes, the main loop marks the state dirty and, if any client is attached, serialises the visible cells of every pane in the active window with `dump_layout_json_fast` (`src/layout.rs`). The snapshot holds each parser's mutex for about a millisecond, then the JSON frame is pushed to every attached client. Frames therefore arrive a few milliseconds after ConPTY output rather than on the next poll.

### Rendering in the client

`src/client.rs` (`run_remote`) drives a `ratatui` terminal on a `PsmuxBackend` (`src/platform.rs`). It reads frames from the socket, draws pane contents, borders, the status line, and any popup or floating pane, and forwards input. The poll cadence adapts: 10 ms while you are typing, 16 ms when idle and frames are being pushed, 1 ms while a bracketed paste is being assembled. Mouse and keyboard events arrive through the Win32 console input API (`src/ssh_input.rs`, `src/input.rs`), are translated to tmux key names (`C-a`, `M-Left`, `S-Enter`), and go back to the server as `send-key` lines. Copy mode (`src/copy_mode.rs`) runs inside the server against the pane's own scrollback, so `send-keys -X` works from scripts exactly as in tmux.

### Resizing

`resize_all_panes` in `src/tree.rs` resizes only the panes of the active window. Background windows are resized when you switch to them. That keeps a session with fifty windows from issuing fifty `ResizePseudoConsole` calls every time the Windows Terminal tab changes size.

## ConPTY passthrough mode

On Windows 11 22H2 and later (build 22621+), psmux creates each pseudo console with `PSEUDOCONSOLE_PASSTHROUGH_MODE` (`0x8`, defined in `crates/portable-pty-psmux/src/win/psuedocon.rs`, added in PR #538). In passthrough mode conhost stops re rendering the child's output into its own screen buffer and forwards the VT stream as the application wrote it, which preserves sequences that conhost would otherwise rewrite (cursor shape, some colour queries) and removes a copy from the output path.

If `CreatePseudoConsole` rejects the flag, or a later `ResizePseudoConsole` fails on a build that advertises the flag but does not fully support it, the crate recreates the console without passthrough and logs the fallback (`conpty.rs`). You can disable it yourself with:

```powershell
$env:PSMUX_NO_PASSTHROUGH = "1"
```

Whether a pane got passthrough is recorded in the debug log (see [Diagnostics](diagnostics.md)).

## Warm servers and warm panes

Shell startup, not psmux, is the slow part of opening a pane (see [Performance](performance.md)). psmux hides it twice:

- A hidden `__warm__` server is pre spawned with your config already loaded. `psmux new-session` claims it by renaming its registry files, which turns a cold start into a rename (measured at about 50 ms on the reference machine versus about 215 ms cold).
- Inside every server a spare shell is kept booted. `split-window` and `new-window` hand you that shell and boot the next spare in the background, so the prompt is visible in roughly 100 ms instead of a full shell start.

[Warm Sessions](warm-sessions.md) documents the lifecycle, the `warm` option, and `PSMUX_NO_WARM`.

## Process priority: why typing stays responsive under load

Issue #608 reported that a compile or a test sweep pegging every core made the interactive path (server loop, client renderer) starve at normal priority. psmux now sets its **own** processes, the server and the client, to `ABOVE_NORMAL_PRIORITY_CLASS` by default (`set_process_priority` in `src/platform.rs`). Pane shells and everything they run are created without an explicit class and stay at normal priority, so psmux never steals time from the work you are running, only from other background processes competing with the multiplexer itself.

Three values are accepted, deliberately not `realtime` or the below normal classes:

```tmux
set -g priority above-normal   # default
set -g priority high
set -g priority normal
```

`PSMUX_PRIORITY` in the environment outranks the option, so you can recover from a bad configured value from the shell you launch psmux from. A claimed warm server inherits the claiming client's priority (the claim message carries it, see `src/types.rs` and `src/main.rs`), so the setting is effective from the first keystroke.

## Windows integration points

| Concern | How psmux does it | Source |
|---------|-------------------|--------|
| Clipboard (`copy-pipe`, `set-clipboard`, OSC 52) | `OpenClipboard` / `SetClipboardData(CF_UNICODETEXT)` on the client side, no `clip.exe` round trip | `src/clipboard.rs` |
| Killing a pane's process tree | Walks the child tree by parent pid and creation time so a recycled pid is never killed | `src/platform.rs` (`process_kill`) |
| Working directory of a pane | Read from the child's process environment block, or from OSC 7 for shells Win32 cannot see (WSL) | `src/platform.rs`, `src/wsl_path.rs` |
| Foreground command (`#{pane_current_command}`) | The live foreground process of the pane's shell tree, not the shell itself (PR #577) | `src/platform.rs` |
| Mouse | Win32 `MOUSE_EVENT` records translated to SGR mouse reports for panes that enabled them | `src/ssh_input.rs`, `src/input.rs` |
| Detached operation | The server is spawned with no console window and null stdio, so it survives the parent window, an RDP disconnect, or a Task Scheduler launch at boot | `src/main.rs` |
| Multiple shells | Any Windows executable can be a pane: `pwsh`, `powershell`, `cmd`, `nu`, `bash` (Git for Windows, MSYS2), `wsl` | [Multi-Shell](multi-shell.md) |

## Source map

| Path | What lives there |
|------|------------------|
| `src/main.rs` | CLI entry point, argument normalisation, session routing, server spawn, attach |
| `src/cli.rs` | Attached flag normalisation and argv helpers |
| `src/server/mod.rs` | `run_server`: listener, registry files, accept thread, main loop, frame push |
| `src/server/connection.rs` | Wire protocol: auth, command parsing, per command handlers |
| `src/server/options.rs`, `src/server/option_catalog.rs` | `set-option` / `show-options` |
| `src/pane.rs` | ConPTY spawn, reader, parser, write queue threads |
| `src/tree.rs`, `src/layout.rs` | Window and pane tree, layouts, frame serialisation |
| `src/client.rs` | Attached client: render loop, input forwarding, mouse, copy drag |
| `src/copy_mode.rs` | Copy mode, search, selection |
| `src/format.rs` | The `#{...}` format engine |
| `src/config.rs`, `src/commands.rs` | Config parsing, key bindings, hooks |
| `src/control.rs` | Control mode (`-C`, `-CC`) |
| `src/platform.rs` | Win32: console modes, process tree, priority, clipboard, mutexes |
| `crates/portable-pty-psmux` | ConPTY wrapper (fork of `portable-pty` with passthrough mode and psmux fixes) |
| `crates/vt100-psmux` | VT parser and screen model (fork of `vt100` with scrollback, OSC 7/8, SGR 58, mouse mode tracking) |

## FAQ

### Does psmux need WSL, Cygwin, or MSYS2?

No. psmux is a single Rust binary that talks to ConPTY through the Win32 API. WSL is optional and only involved if you open a pane running `wsl.exe`.

### Is the server a Windows service?

No. It is an ordinary background process running as your user, started by the first `new-session`. That is what lets you attach to it later from any terminal, including after a Task Scheduler launch at boot (see [Windows Use Cases](use-cases.md)).

### Why TCP instead of a named pipe?

Loopback TCP gives the same stream semantics on every Windows version, works from inside WSL and over SSH port forwards, and lets control mode clients written in any language connect with a plain socket. The auth key file, readable only by your user profile, is the access control.

### Can another user on the machine see my sessions?

They would need read access to your `~\.psmux\<session>.key` file. Keep your profile directory private, or point `PSMUX_DATA_DIR` at a directory with the ACL you want.

### Does each pane really get its own conhost?

Yes. `CreatePseudoConsole` starts a conhost (or OpenConsole, depending on Windows Terminal's configuration) per pseudo console. That is a Windows design constraint and it is what gives each pane a fully independent console, including its own input mode and its own cursor state.

### How is this different from Windows Terminal panes?

Windows Terminal panes live inside the Windows Terminal process; close the window and the shells die. psmux panes live in a detached server, can be driven from scripts (`send-keys`, `capture-pane`, `pipe-pane`, `wait-for`), can be attached from SSH, and answer to your existing `.tmux.conf`. Many people use both: Windows Terminal as the window, psmux as the multiplexer inside it.
