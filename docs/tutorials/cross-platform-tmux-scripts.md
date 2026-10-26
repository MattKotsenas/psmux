# Write One tmux Script That Runs on Windows, Linux and macOS with psmux

psmux is a tmux compatible terminal multiplexer for Windows, and it ships a `tmux.exe` alias. That means automation written against tmux, whether a session bootstrap script, a project sessionizer, a CI harness that drives a TUI, or an agent orchestrator built on `send-keys` and `capture-pane`, runs on Windows unchanged. This tutorial shows the same script running under Git Bash on Windows through psmux, the PowerShell equivalent for pure Windows shops, the quoting and `--` rules psmux applies, the exit codes and error strings you can script against, and the short list of platform differences a cross platform script needs to know about.

Every command and every output block on this page was run against psmux 3.3.8 on Windows 11.

**What you will learn**

- Why `tmux` on a Windows PATH can be psmux, and what `tmux -V` reports
- A session bootstrap script in bash that runs on all three operating systems, and its PowerShell twin
- The idempotent `has-session` pattern and what exit codes to expect
- How psmux parses `--`, dash leading operands, quotes, backslashes and newlines
- `display-message -p`, `-F` formats, `wait-for`, `pipe-pane` and `run-shell` from scripts
- A portability checklist and a headless CI style test that asserts on `capture-pane` output

## Why does a tmux script run on Windows at all?

psmux installs three binaries: `psmux.exe`, `pmux.exe` and `tmux.exe`. They are the same program. The command names, flags, target syntax (`session:window.pane`, `%pane_id`, `@window_id`), format variables and config syntax are tmux's, and the version string is tmux shaped so version checks keep passing:

```console
$ tmux -V
tmux 3.3.8
$ psmux -V
psmux 3.3.8 (cbb9c10 2026-08-28)
```

So a script that calls `tmux` finds psmux on Windows and real tmux on Linux and macOS. You write it once. The [Compatibility](../compatibility.md) page lists every command and option; `psmux list-commands` prints the live list for the build you have.

## A session bootstrap script in bash (Git Bash on Windows, sh on Linux and macOS)

`dev.sh` creates a project session with an editor window in the `main-vertical` layout and a background logs window, sends a command into two panes, and prints what it built. Run it twice and it is a no op the second time.

```bash
#!/usr/bin/env bash
# dev.sh: bootstrap a project session. Runs unchanged on Linux/macOS (tmux) and Windows (psmux).
set -e
SESSION="${1:-dev}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "session $SESSION already exists"
else
  tmux new-session -d -s "$SESSION" -n editor
  tmux split-window -h -t "$SESSION:editor"
  tmux split-window -v -t "$SESSION:editor.1"
  tmux select-layout -t "$SESSION:editor" main-vertical
  tmux new-window -d -t "$SESSION" -n logs
  tmux send-keys -t "$SESSION:editor.0" 'echo hello from pane 0' Enter
  tmux send-keys -t "$SESSION:logs" 'echo log window ready' Enter
fi

tmux list-windows -t "$SESSION" -F '#{window_index}:#{window_name} panes=#{window_panes}'
tmux display-message -p -t "$SESSION:editor.0" 'active pane #{pane_id} in #{session_name}:#{window_name} (#{pane_width}x#{pane_height})'
```

Run from Git Bash on Windows (`C:\Program Files\Git\bin\bash.exe`), with psmux answering as `tmux`:

```console
$ bash ./dev.sh tutaDev
0:editor panes=3
1:logs panes=1
active pane %1 in tutaDev:editor (71x30)

$ bash ./dev.sh tutaDev
session tutaDev already exists
0:editor panes=3
1:logs panes=1
active pane %1 in tutaDev:editor (71x30)
```

The panes are running PowerShell 7 (the psmux default shell), and `capture-pane` shows the command landed:

```console
$ tmux capture-pane -p -t tutaDev:editor.0
PS C:\Users\godwin\projects\api> echo hello from pane 0
hello
from
pane
0
```

(`echo` in PowerShell is `Write-Output` and prints each argument on its own line. That is the shell, not psmux; quote the string or use `Write-Host` if you want one line.)

Attach with `tmux attach -t tutaDev` from any terminal, and `tmux kill-session -t tutaDev` when done.

## The same bootstrap in PowerShell

If your team is Windows only, write the script in PowerShell. The psmux commands are identical; only the surrounding shell changes. Note `$LASTEXITCODE` for the `has-session` check, and `${Session}:editor` so PowerShell does not read `$Session:` as a scoped variable.

```powershell
# dev.ps1: the same session bootstrap, written for PowerShell.
param([string]$Session = "dev")

psmux has-session -t $Session 2>$null
if ($LASTEXITCODE -ne 0) {
    psmux new-session -d -s $Session -n editor
    psmux split-window -h -t "${Session}:editor"
    psmux split-window -v -t "${Session}:editor.1"
    psmux select-layout -t "${Session}:editor" main-vertical
    psmux new-window -d -t $Session -n logs
    psmux send-keys -t "${Session}:editor.0" 'Write-Host "hello from pane 0"' Enter
    psmux send-keys -t "${Session}:logs" 'Write-Host "log window ready"' Enter
} else {
    Write-Host "session $Session already exists"
}

psmux list-windows -t $Session -F '#{window_index}:#{window_name} panes=#{window_panes}'
psmux display-message -p -t "${Session}:editor.0" 'active pane #{pane_id} in #{session_name}:#{window_name} (#{pane_width}x#{pane_height})'
```

```console
PS> pwsh -NoProfile -File .\dev.ps1 tutaDevPs
0:editor panes=3
1:logs panes=1
active pane %1 in tutaDevPs:editor (71x30)
PS> pwsh -NoProfile -File .\dev.ps1 tutaDevPs
session tutaDevPs already exists
0:editor panes=3
1:logs panes=1
active pane %1 in tutaDevPs:editor (71x30)
```

## How do I make a script idempotent with has-session?

`has-session -t NAME` exits 0 when the session exists and 1 when it does not, in tmux and in psmux. Always redirect stderr, because tmux prints `can't find session` on the failure path.

```bash
if ! tmux has-session -t "$S" 2>/dev/null; then
  tmux new-session -d -s "$S"
fi
```

`new-session -A -s NAME` is the one line version for the interactive case (attach if it exists, create otherwise), and `new-session -A -d -s NAME` does the same without attaching. Both work in psmux.

## What exit codes and error strings can I script against?

An unresolvable target is an error with a non zero exit, never a silent fallback to the active window (this was tightened in psmux 3.3.8, issue #545):

```console
$ tmux send-keys -t tutaProbe:nope 'x' Enter; echo rc=$?
psmux: can't find window: nope
rc=1
$ tmux capture-pane -p -t %999; echo rc=$?
psmux: can't find pane: %999
rc=1
$ tmux has-session -t tutaMissing; echo rc=$?
rc=1
```

The message prefix is `psmux:` rather than `tmux:`. If you match on the text, match on the part after the colon (`can't find window`, `can't find pane`, `can't find session`), which is tmux's wording.

`kill-session -t NAME` on a name that is not a session exits 1 with `can't find session: NAME`, as in tmux, so a typo in a teardown script is not a silent success.

`list-sessions` with nothing running prints `no server running on <data dir>` and exits 1, as tmux does, which keeps the `tmux ls 2>/dev/null || tmux new -d -s work` idiom portable. A `-f` filter that matches nothing on a live server is still an empty listing at exit 0.

## How does psmux parse `--`, dashes, quotes and backslashes?

This is where scripts most often differ between shells, so here are the exact rules psmux applies. All of them match tmux unless noted.

**`--` ends option parsing.** A dash leading operand after `--` is data. `send-keys -- -la Enter` types `-la` into the pane, and `set-option -- @k -u` stores the string `-u` in `@k` instead of unsetting it:

```console
$ tmux send-keys -t tutaProbe -- -la Enter
$ tmux set-option -t tutaProbe -- @marker -dash-value
$ tmux show-options -t tutaProbe | grep marker
@marker "-dash-value"
```

Put the `--` before the option name for `set-option` and `set-hook`, exactly as you would with tmux.

**`send-keys -l` is literal.** Nothing after `-l` is parsed as a key name, so `Enter`, `C-c` and friends are typed as text. Send the key on a separate call:

```bash
tmux send-keys -t "$S" -l 'literal $env:TEMP "quoted" a\b'
tmux send-keys -t "$S" Enter
```

Both the `$`, the double quotes and the backslash arrive intact (psmux escapes `"` and `\` on the wire and unescapes them in the server, issue #547).

**Newlines in a payload are safe.** A `send-keys` argument that contains a newline is delivered as one argument and cannot split into a second psmux command (issue #560). It is typed as text rather than as a key press, so send multi line input as separate `send-keys` calls with `Enter` between them.

**Multiple tokens after `--` are executed directly; a single string goes through the shell.** `new-window -- ping -n 30 127.0.0.1` starts `ping` as the pane's process, with no shell in between, the way tmux calls `execvp`. A single quoted string is handed to the pane's shell so pipes and redirects work:

```console
$ tmux new-window -d -t tutaR -n direct -- ping -n 30 127.0.0.1
$ tmux display-message -p -t tutaR:direct '#{window_name} runs #{pane_current_command}'
direct runs PING
$ tmux new-window -d -t tutaR -n shstr "ping -n 30 127.0.0.1 | findstr Reply"
$ tmux display-message -p -t tutaR:shstr '#{window_name} runs #{pane_current_command}'
shstr runs findstr
```

**Shell quoting is the caller's job, and it differs by shell.** In bash and in PowerShell, single quotes pass the text to psmux untouched, so `'echo "pid=$PID"'` reaches the pane with the `$` intact and the pane's shell expands it. In PowerShell double quotes, `$env:TEMP` and `$PID` are expanded by the calling shell before psmux ever sees them. In bash, the same is true of `"$HOME"`. Use single quotes around anything the pane should expand.

```console
$ tmux send-keys -t tutaQ 'echo "pid=$PID home=$HOME"' Enter
$ tmux capture-pane -p -t tutaQ | grep pid=
pid=27140 home=C:\Users\godwin
```

Chaining several commands in one invocation uses `\;` in bash and `` `; `` in PowerShell, because each shell treats a bare `;` as its own separator. See [Scripting](../scripting.md) for more.

## How do I read state back: display-message -p and -F formats

`display-message -p` prints a format string and exits, which is the standard way to pull one value into a script. `-F` on the `list-*` commands does the same for lists. psmux supports 140+ tmux format variables and the `#{==:a,b}`, `#{?cond,yes,no}` and modifier forms.

```bash
pane=$(tmux display-message -p -t "$S:editor.0" '#{pane_id}')
tmux list-panes -s -t "$S" -F '#{window_index}.#{pane_index} #{pane_current_command} #{pane_width}x#{pane_height}'
tmux if-shell -F '#{==:#{session_name},tutaR}' 'display-message -p format-yes' 'display-message -p format-no'
```

`#{pane_current_path}` returns a Windows path on Windows (`C:\Users\godwin\projects\api`). In Git Bash, convert it when you need a POSIX path:

```console
$ cygpath -u "$(tmux display-message -p -t tutaR '#{pane_current_path}')"
/c/Users/godwin/Documents/workspace/psmux
```

## wait-for, pipe-pane and run-shell from a script

**`wait-for`** blocks until another process signals the same channel. It is the tmux way to sequence steps across panes, and it works the same in psmux:

```console
$ ( sleep 2; tmux wait-for -S tutaGo ) &
$ tmux wait-for tutaGo; echo "released rc=$?"
released rc=0
```

**`pipe-pane`** streams a pane's raw output to a sink. The sink runs on the Windows side, so give it a Windows path. In Git Bash `$TEMP` and `$TMP` are mapped to `/tmp`, which the psmux server cannot open; use `cygpath -w` or a literal `C:/...` path:

```bash
LOG="$(cygpath -w "$TEMP")\\pane.log"
tmux pipe-pane -t "$S" "cat >> '$LOG'"
tmux send-keys -t "$S" 'echo piped-line-1' Enter
tmux pipe-pane -t "$S"       # no argument turns the pipe off
```

```console
$ grep -c piped-line-1 "C:/Users/godwin/AppData/Local/Temp/pane.log"
2
```

(Two hits: the echoed command line and its output.) `cat >> file` sinks are serviced by the psmux server itself so they need no `cat.exe` on PATH; other sinks run through the shell. psmux does not expand `#{...}` in the sink command, where tmux does; expand it in the caller if you need `#{pane_id}` in the file name.

**`run-shell` and `if-shell` use the platform's shell.** On Linux and macOS tmux runs them with `sh -c`. On Windows psmux runs them with `pwsh -NoProfile -Command` (falling back to Windows PowerShell, then `cmd /c`). This is the one place where a tmux script is not automatically portable: `run-shell 'test -f ~/.x && ...'` is sh syntax and will not run under pwsh. Keep those commands to things both shells accept, or branch. A cheap branch that works in both places, because `Get-Command` does not exist in sh and so fails there:

```console
$ tmux if-shell 'Get-Command pwsh' 'display-message -p yes-pwsh' 'display-message -p no-pwsh'
yes-pwsh
```

In a config file:

```tmux
if-shell 'Get-Command pwsh' 'source-file ~/.tmux.windows.conf' 'source-file ~/.tmux.unix.conf'
```

Format variables are expanded in `run-shell` arguments before the command runs, on both sides:

```console
$ tmux run-shell -t tutaProbe 'echo run-shell says #{session_name}:#{pane_id}'
run-shell
says
tutaProbe:%1
```

(One word per line is PowerShell's `echo` again. Both the format variables were expanded before the command ran, which is the point.)

## What is set inside a pane: TMUX and TMUX_PANE

Processes inside a psmux pane see `TMUX` and `TMUX_PANE`, so the common guard `[ -n "$TMUX" ]` and tools that read `$TMUX_PANE` work:

```console
$ tmux send-keys -t tutaProbe 'echo "TMUX=$env:TMUX PANE=$env:TMUX_PANE"' Enter
$ tmux capture-pane -p -t tutaProbe | grep TMUX=
TMUX=/tmp/psmux-53400/default,61721,0 PANE=%1
```

The `TMUX` value has tmux's `socket,pid,index` shape, but the first field is not a Unix socket path on Windows; psmux clients and servers talk over a loopback TCP port. Do not parse it for a socket to connect to. Use the CLI, or [control mode](../control-mode.md) (`psmux -C`) for a machine readable stream.

Inside the pane, `$TMUX_PANE` is the current pane id (`%1`), which is what `tmux send-keys -t "$TMUX_PANE"` style self targeting scripts expect.

## Portability checklist

| Concern | tmux on Linux/macOS | psmux on Windows | What to do in the script |
|---------|--------------------|------------------|--------------------------|
| Binary name | `tmux` | `tmux`, `psmux` or `pmux` | Call `tmux` |
| Version check | `tmux 3.x` | `tmux 3.3.8` | Parse `tmux -V` as usual |
| Default shell in panes | `$SHELL` | `SHELL` when it names a usable Windows executable, else `pwsh` (then `powershell`, then `cmd`) | Set `default-shell` or send shell neutral commands |
| `run-shell` / `if-shell` interpreter | `sh -c` | `pwsh -NoProfile -Command` | Keep commands shell neutral, or branch with `if-shell 'Get-Command pwsh'` |
| Paths from `#{pane_current_path}` | POSIX | Windows (`C:\...`) | `cygpath -u` in Git Bash when needed |
| `pipe-pane` sink path | POSIX | Windows path | `cygpath -w "$TEMP"` in Git Bash |
| `#{pane_current_path}` inside WSL | n/a | Frozen unless the Linux shell emits OSC 7 | Add the one line from the [FAQ](../faq.md) to `~/.bashrc` in the distro |
| Unresolvable `-t` target | error, rc 1 | error, rc 1 (`psmux: can't find ...`) | Match the text after `psmux:`/`tmux:` |
| `kill-session` on a missing name | `can't find session`, rc 1 | `can't find session`, rc 1 | Same code |
| `list-sessions` with no server | `no server running on <socket>`, rc 1 | `no server running on <data dir>`, rc 1 | `tmux ls 2>/dev/null \|\| tmux new -d` works on both |
| `$TMUX` inside a pane | socket path | not a socket | Use only as a "running inside tmux" flag |
| `--` end of options | supported | supported | Use it before any dash leading operand |
| `send-keys -l`, newline payloads | supported | supported | Same code |
| `wait-for`, `capture-pane -p`, `display-message -p`, `-F` | supported | supported | Same code |
| Control mode `-C` / `-CC` | supported | supported | Same protocol, see [Control Mode](../control-mode.md) |
| Quoting | bash rules | bash rules under Git Bash, PowerShell rules under pwsh | Single quote anything the pane should expand |

## Worked example: a project sessionizer

A sessionizer takes a folder, derives a session name from it, builds the layout if needed and attaches. This one runs under bash on all three platforms; it uses `cygpath` only when it exists, so the same file works on Linux.

```bash
#!/usr/bin/env bash
# sessionize.sh <project-dir>
set -e
dir="${1:-.}"
if command -v cygpath >/dev/null 2>&1; then dir="$(cygpath -w "$dir")"; fi
name="$(basename "$dir" | tr '. ' '__')"

if ! tmux has-session -t "$name" 2>/dev/null; then
  tmux new-session -d -s "$name" -c "$dir" -n code
  tmux split-window -h -t "$name:code" -c "$dir"
  tmux split-window -v -t "$name:code.1" -c "$dir"
  tmux select-layout -t "$name:code" main-vertical
  tmux new-window -d -t "$name" -n git -c "$dir"
  tmux send-keys -t "$name:git" 'git status' Enter
  tmux select-window -t "$name:code"
fi

if [ -n "$TMUX" ]; then
  tmux switch-client -t "$name"
else
  tmux attach -t "$name"
fi
```

Bind it to a key so `Prefix + f` builds and switches to a project, the same binding on every machine:

```tmux
bind-key f run-shell -b "bash ~/bin/sessionize.sh ~/projects/api"
```

The PowerShell version differs only in syntax; the psmux calls are the same. Layout recipes for other kinds of projects are in [Dev environment layouts](dev-environment-layouts.md).

## Worked example: a CI style headless TUI test

Multiplexers make full screen programs testable without a display. Start the program in a detached session of a known size, type into it, and assert on `capture-pane`. This script launches Neovim, inserts a line, turns on line numbers, and checks the rendered screen. It passed on Windows through psmux and needs no change for Linux:

```bash
#!/usr/bin/env bash
# ci-check.sh: drive a full screen TUI headlessly and assert on what it drew.
set -e
S=ci-nvim
tmux kill-session -t $S 2>/dev/null || true

tmux new-session -d -s $S -x 100 -y 30 -n tui
tmux send-keys -t $S:tui 'nvim --clean' Enter

# wait until the editor has painted its welcome screen
for i in $(seq 1 30); do
  if tmux capture-pane -p -t $S:tui | grep -q 'NVIM'; then break; fi
  sleep 0.5
done

tmux send-keys -t $S:tui 'i' 'hello from a headless tui' Escape
tmux send-keys -t $S:tui ':set nu' Enter
sleep 1

if tmux capture-pane -p -t $S:tui | grep -Eq '1 +hello from a headless tui'; then
  echo "PASS: the editor shows the typed line with a line number"
  rc=0
else
  echo "FAIL: unexpected screen"
  tmux capture-pane -p -t $S:tui
  rc=1
fi

tmux send-keys -t $S:tui ':q!' Enter
tmux kill-session -t $S
exit $rc
```

```console
$ bash ./ci-check.sh
PASS: the editor shows the typed line with a line number
```

Two habits make these tests reliable on any platform: poll `capture-pane` for a marker instead of sleeping a fixed time, and fix the pane size with `-x`/`-y` so line wrapping is the same everywhere.

In GitHub Actions the same script runs on both runners with `shell: bash`; install tmux with `apt` on Ubuntu and psmux with `choco install psmux` (or `winget`, `scoop`, `cargo install psmux`) on Windows, and the job body does not change.

## Where to go next

- [Scripting and Automation](../scripting.md): every command with examples, hooks, targets, popups, pipe-pane
- [Command Reference](../tmux_args_reference.md): per command flag tables
- [Compatibility](../compatibility.md): the tmux command and option matrix
- [Configuration](../configuration.md): config files, options, environment variables
- [Control Mode](../control-mode.md): the `-C` protocol for IDEs and tools
- [Multi-Shell](../multi-shell.md): pwsh, cmd, Git Bash, WSL and nushell in panes
- [Terminal agents and TUIs](terminal-agents-and-tuis.md) and [Windows use cases](../use-cases.md)

## FAQ

**Q: Does psmux understand tmux's target syntax (`session:window.pane`, `%id`, `@id`)?**
A: Yes. `dev:editor.0`, `dev:1`, `%3` and `@1` style targets resolve the way tmux resolves them, and an invalid one errors with a non zero exit code.

**Q: Can I use my tmux sessionizer script from Linux on Windows?**
A: If it is bash, run it under Git Bash and it will call psmux's `tmux.exe`. Convert paths with `cygpath -w` before passing them to `-c`, and check any `run-shell` or `if-shell` bodies, which run under PowerShell on Windows.

**Q: Why does `echo hello world` in a pane print one word per line?**
A: The pane is running PowerShell, whose `echo` is `Write-Output` and prints each argument separately. Quote the string, use `Write-Host`, or set `default-shell` to the shell you expect.

**Q: Do format variables like `#{pane_current_command}` and `#{pane_current_path}` work on Windows?**
A: Yes. `pane_current_command` reports the foreground process (`findstr`, `PING`, `nvim`), and `pane_current_path` follows `cd` in PowerShell, cmd, Git Bash and Cygwin. Inside WSL it needs the shell to announce its directory with OSC 7; the [FAQ](../faq.md) has the line.

**Q: Is there a machine readable interface instead of parsing text?**
A: Yes, control mode. `psmux -C` gives the same `%begin`/`%end`/`%output` stream as `tmux -C`, so tools built on it work unchanged. See [Control Mode](../control-mode.md).

**Q: Will `send-keys` deliver Ctrl keys and special keys the same way?**
A: Yes: `Enter`, `Tab`, `Escape`, `C-c`, `M-x`, `F1` to `F12`, arrows, `PageUp`, `Home`, `End` and the rest of tmux's key names are accepted, and `-l` types the text literally.
