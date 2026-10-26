# Running Terminal AI Agents and Multi Pane TUIs on Windows with psmux

This tutorial shows how to run terminal AI coding agents (Claude Code, Codex CLI, Gemini CLI, aider, opencode and similar) and full screen TUI programs (neovim, lazygit, yazi, btop, k9s, gitui, htop inside WSL) inside psmux, the native tmux for Windows. It is written for Windows developers who want several agents or tools running side by side in one terminal, driven and observed from PowerShell scripts, with sessions that keep running after the window is closed.

Every command below was run against psmux 3.3.8 on Windows 11 with PowerShell 7 and Windows Terminal. `psmux`, `pmux` and `tmux` are the same binary, so any example works with `tmux` in front of it too.

## What you will learn

- Why a native terminal multiplexer matters for agents and TUIs on Windows (each pane is a real ConPTY, each agent is a real Windows process)
- A "watch an agent work" layout: agent in a large pane, its log in a side pane, a shell underneath
- A multi agent grid: several agents in parallel windows, driven with `send-keys`, read with `capture-pane`, logged with `pipe-pane`
- Detecting when an agent finishes, restarting a crashed agent with `respawn-pane`, and keeping dead panes visible with `remain-on-exit`
- Naming panes per agent with `select-pane -T` and showing the active agent in the status line
- Running neovim, yazi and lazygit in a pane on PowerShell and inside WSL, and what the mouse wheel does in each

Related pages: [Claude Code agent teams](../claude-code.md) for the Claude Code specific setup, [Scripting and Automation](../scripting.md) for the full command reference, [Windows Use Cases](../use-cases.md) for more scenarios, and [Multi Window and Multi Pane Development Layouts](dev-environment-layouts.md) for layout design.

## Why run terminal agents inside a multiplexer on Windows?

A terminal agent is just a long running console program that reads a prompt, prints a lot, and sometimes waits for you. Windows Terminal tabs can hold several of them, but tabs are not scriptable, do not survive the window closing, and cannot be read back by a script. psmux gives you, on Windows, the same properties tmux gives on Linux and macOS:

| Property | What it means for agents and TUIs |
|---|---|
| **Each pane is a real ConPTY** | The agent sees a genuine console with a size, colours, cursor and key input. TUIs render exactly as they would in a plain Windows Terminal tab. |
| **Each agent is a real Windows process** | `#{pane_pid}` and `#{pane_current_command}` tell you what is running. Task Manager sees it. Nothing is emulated. |
| **Sessions live in a background server** | Close Windows Terminal, sign out of RDP, reconnect tomorrow: `psmux attach` shows the agent exactly where it was. |
| **Everything is a tmux command** | `send-keys`, `capture-pane`, `pipe-pane`, `respawn-pane`, `list-panes -F` all work from PowerShell, cmd, bash or another agent. The same script drives tmux on Linux. |
| **Native multiplexing** | psmux is a single Rust binary talking to ConPTY directly. No WSL, no Cygwin, no MSYS layer between the agent and the console. |

If you have used tmux to babysit agents on a Linux box, everything on this page will look familiar. If you have not, the patterns are simple: put each agent in its own pane or window, give it a name, log it, and poll it.

## Layout 1: watch one agent work

The most common setup. The agent gets most of the screen, a narrow pane on the right tails its log, and a small shell underneath is where you run git or tests without interrupting the agent.

```
+-------------------------------------------+---------------+
|                                           |               |
|  agent: claude            (pane 0, 70%)   |  logs (pane 2)|
|                                           |               |
|                                           |               |
+-------------------------------------------+               |
|  shell                    (pane 1, 25%)   |               |
+-------------------------------------------+---------------+
```

```powershell
$s = 'work'
psmux new-session -d -s $s -n agent -x 160 -y 45

# Right column for logs, then a bottom strip under the agent for a shell
psmux split-window -t "${s}:agent" -h -l 30% -d
psmux split-window -t "${s}:agent.0" -v -l 25% -d

# Name the panes. -T only sets the title, it never changes which pane is active.
psmux select-pane -t "${s}:agent.0" -T 'agent: claude'
psmux select-pane -t "${s}:agent.1" -T 'shell'
psmux select-pane -t "${s}:agent.2" -T 'logs'

# Log the agent pane to a file, then tail it in the logs pane
psmux pipe-pane -t "${s}:agent.0" -o "cat > $env:TEMP\claude.log"
psmux send-keys -t "${s}:agent.2" "Get-Content -Wait $env:TEMP\claude.log" Enter

# Start the agent (replace with codex, gemini, aider, opencode ...)
psmux send-keys -t "${s}:agent.0" 'claude' Enter

psmux attach -t $s
```

What the server reports after the splits and titles:

```
PS> psmux list-panes -t work:agent -F '#{pane_index} #{pane_id} #{pane_width}x#{pane_height} title=#{pane_title} active=#{pane_active}'
0 %1 111x33 title=agent: claude active=1
1 %3 111x11 title=shell active=0
2 %2 48x45 title=logs active=0
```

Pane 0 stayed active while panes 1 and 2 were titled. That is the tmux behaviour restored in [#592](https://github.com/psmux/psmux/issues/592): `select-pane -T` and `-P` are title and style only.

To show the titles on the pane borders, add this to `~/.psmux.conf` (or run it with `psmux set -g ...`):

```tmux
set -g pane-border-status top
set -g pane-border-format " #{pane_index}: #{pane_title} [#{pane_current_command}] "
```

### Why `pipe-pane` with `cat >` works on Windows

`cat` is an alias for `Get-Content` in PowerShell and never reads stdin, so the tmux logging idiom could not work as a shell command on Windows. Since [#576](https://github.com/psmux/psmux/issues/576) the psmux server recognises `cat > <path>` and `cat >> <path>` and writes the pane's raw ConPTY bytes to that file itself, no shell involved. Use an absolute path. The file contains escape sequences (colours, cursor moves) exactly as the agent emitted them, which is what you want for a faithful transcript. Details and the PowerShell sink alternative are in [Piping Pane Output](../scripting.md#piping-pane-output-pipe-pane).

Checked live: after `Write-Host "logged line two"` in the piped pane, the file held 127 bytes including the prompt redraw and the text, and `pipe-pane` with no `-o` stopped the pipe with exit code 0.

## Layout 2: a grid of agents driven from a script

When you want several agents working on different parts of a project at the same time, give each one a window. Windows are cheap, every one has a name, and a script can address them by name.

```
 status line:  [work] 0:hub  1:api*  2:web  3:tests
+------------------------------------------------------------+
|                                                            |
|   window "api": agent working on the API                   |
|   (switch with prefix + 2, or psmux select-window -t api)  |
|                                                            |
+------------------------------------------------------------+
```

The full script. It uses a stand in for the agent so you can run it without any agent installed: `fake-agent.ps1` prints four lines and then `DONE`. Replace `$agent` with `claude`, `codex`, `aider --message "..."` or whatever you run.

```powershell
# fake-agent.ps1 (stand in for a real agent)
1..4 | ForEach-Object { Write-Host "step $_"; Start-Sleep 1 }
Write-Host DONE
```

```powershell
$ErrorActionPreference = 'Stop'
$s = 'work'
$logDir = Join-Path $env:TEMP 'agent-logs'
New-Item -ItemType Directory -Force $logDir | Out-Null

$agent = "pwsh -NoProfile -File $env:TEMP/fake-agent.ps1"   # real life: 'claude' or 'codex'

psmux new-session -d -s $s -n hub -x 160 -y 45
psmux set-option -t $s remain-on-exit on          # keep a finished or crashed pane visible

$names = 'api', 'web', 'tests'
foreach ($n in $names) {
    psmux new-window -t $s -n $n -d
    psmux select-pane -t "${s}:${n}.0" -T "agent: $n"
    psmux pipe-pane   -t "${s}:${n}.0" -o "cat > $logDir\$n.log"
    psmux send-keys   -t "${s}:${n}.0" $agent Enter
}

# Poll every agent window until its pane prints DONE
$pending  = @($names)
$deadline = (Get-Date).AddSeconds(600)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    foreach ($n in @($pending)) {
        $out = psmux capture-pane -t "${s}:${n}.0" -p
        if ($out -match '^DONE') {
            Write-Host "$n finished"
            $pending = @($pending | Where-Object { $_ -ne $n })
        }
    }
    Start-Sleep -Milliseconds 500
}

psmux list-windows -t $s -F '#{window_index}:#{window_name} #{pane_title} cmd=#{pane_current_command}'
foreach ($n in $names) { psmux pipe-pane -t "${s}:${n}.0" }   # stop logging
Get-ChildItem $logDir | Select-Object Name, Length
```

Output of a real run (6.6 seconds end to end, including three new windows and three shells):

```
api finished
web finished
tests finished
0:hub SUPERFLOW cmd=pwsh
1:api agent: api cmd=pwsh
2:web agent: web cmd=pwsh
3:tests agent: tests cmd=pwsh
Name      Length
----      ------
api.log     1322
tests.log   1316
web.log     1322
```

The `hub` window's title is whatever the shell last set with an OSC title sequence (here the machine name). See [Pane Titles](../pane-titles.md) if you want to stop PowerShell from doing that.

### Sending a prompt to a running agent

`send-keys` types into the pane exactly as you would. A prompt for an interactive agent is one string and an `Enter`:

```powershell
psmux send-keys -t work:api 'Add input validation to the /users endpoint and run the tests' Enter
```

Two things to know:

- Quotes and backslashes in the string reach the pane as typed, but a command that nests quotes inside `pwsh -Command "..."` inside a PowerShell string is hard to read and easy to get wrong. Put such a command in a `.ps1` file and send `pwsh -File ...` instead. That is what the script above does.
- `send-keys -l` sends the string literally with no key name parsing, useful when a prompt contains a word like `Enter` or `Space`.

### Reading what an agent printed

`capture-pane -p` returns the visible screen. Add `-S -200` to include the last 200 lines of scrollback, or `-S -` for all of it. `-J` joins lines that wrapped.

```powershell
psmux capture-pane -t work:api -p -S -200 | Select-String -Pattern 'error|failed'
```

If you need the complete transcript with colours, read the `pipe-pane` log file instead. If you only need to know whether the agent is still running, ask the server:

```powershell
psmux list-panes -t work:api -F 'dead=#{pane_dead} cmd=#{pane_current_command} pid=#{pane_pid}'
```

`#{pane_dead}` is `1` once the process has exited and `remain-on-exit` kept the pane. `#{pane_current_command}` is the foreground process, so it reads `claude`, `node`, `nvim` or `pwsh` depending on what is in front.

## Restarting a crashed agent

With `remain-on-exit on` a pane whose process died stays on screen showing its last output. Restart it in place, with a different command if you like:

```powershell
# Kill whatever is left and start the agent again in the same pane
psmux respawn-pane -k -t work:api -- claude

# Or bring back the default shell
psmux respawn-pane -k -t work:api
```

Checked live with a pane whose command had exited:

```
PS> psmux list-panes -t work:worker -F '#{pane_index} dead=#{pane_dead}'
0 dead=1
PS> psmux respawn-pane -k -t work:worker -- pwsh -NoProfile -Command Start-Sleep 60
PS> psmux list-panes -t work:worker -F '#{pane_index} dead=#{pane_dead} cmd=#{pane_current_command}'
0 dead=0 cmd=pwsh
```

A supervisor loop is a few lines of PowerShell: poll `#{pane_dead}` every few seconds and `respawn-pane -k` when it turns to `1`. The layout, the pane id, the log pipe and the pane's scrollback are all preserved across the respawn, so a restarted agent's pane still shows what the previous run printed above the new output. `-e KEY=VALUE` hands the new process its own environment, for example an identity for a successor agent.

## Showing the active agent in the status line

Because every pane can carry a title, the status line can name the agent that has focus:

```tmux
set -g status-right '#{pane_title} [#{pane_current_command}]'
```

```
PS> psmux display-message -t work:agent.0 -p '#{pane_title} [#{pane_current_command}]'
agent: claude [pwsh]
```

Window names do the same job for the tab list. `new-window -n api` names the tab and turns `automatic-rename` off for that window, so the name stays put when the agent starts a child process. If you rename a window later with `rename-window`, the same lock applies.

## A quick shell without leaving the agent

`display-popup` opens a floating pane over the current window and closes it when the command exits:

```powershell
psmux display-popup -w 60% -h 50% -E 'pwsh -NoProfile'
```

Bind it if you use it often:

```tmux
bind-key g display-popup -w 80% -h 80% -E 'lazygit'
```

Zoom is the other way to focus: `prefix + z` (or `resize-pane -Z`) makes the agent pane fill the window and again to go back.

## Claude Code teams in psmux panes

Claude Code has a teammate mode that spawns each teammate agent in its own tmux pane via `split-window` and `send-keys`. psmux sets the environment Claude Code needs (`TMUX`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) and injects `--teammate-mode tmux` when you have not configured it yourself, so a plain `claude` in a psmux pane produces visible teammates. That page also explains the second, in process worktree agent system that never opens panes and why Opus tends to choose it. Read [Claude Code agent teams](../claude-code.md) before relying on it.

Two open issues are worth knowing about: [#578](https://github.com/psmux/psmux/issues/578) (the `TMUX` variable is lost when Claude Code enters Agent View) and [#580](https://github.com/psmux/psmux/issues/580) (pane id targets and silent respawn failures in the teammate backend). Check their current state on GitHub if teammates do not appear.

## Running TUIs: neovim, yazi, lazygit, btop, k9s

A TUI in a psmux pane is a normal console program in a normal ConPTY. Launch it from the shell in the pane, or make it the pane's command:

```powershell
psmux new-window -t work -n edit -- nvim .
psmux new-window -t work -n files -- yazi
psmux new-window -t work -n git -- lazygit
```

`#{pane_current_command}` reports the TUI while it runs, which makes `automatic-rename` and the status line useful:

```
PS> psmux new-window -t work -n edit -d -- nvim -u NONE
PS> psmux list-panes -t work:edit -F 'cmd=#{pane_current_command}'
cmd=nvim
```

### The same TUIs inside WSL

Start a WSL shell in a pane and run Linux builds of the same tools. Everything renders through the same ConPTY, colours and box drawing included:

```powershell
psmux new-window -t work -n linux -- wsl -d Ubuntu
psmux send-keys -t work:linux 'htop' Enter
```

```
PS> psmux send-keys -t work:linux 'echo from-wsl $(uname -r)' Enter
PS> psmux capture-pane -t work:linux -p | Select-Object -Last 2
from-wsl 6.6.114.1-microsoft-standard-WSL2
user@host:/mnt/c/Users/you/project$
PS> psmux list-panes -t work:linux -F 'cmd=#{pane_current_command}'
cmd=wslhost
```

Note the last line: Windows cannot see inside the WSL VM, so `#{pane_current_command}` reads `wslhost` regardless of what Linux program is running, and `#{pane_current_path}` cannot follow a Linux `cd` on its own. Since [#615](https://github.com/psmux/psmux/issues/615) a Linux shell can announce its working directory with an OSC 7 sequence; see [Multi Shell](../multi-shell.md) for the setup. To make WSL the default shell for every new pane, see [Setting Your Default Shell](../multi-shell.md#setting-your-default-shell).

### What the mouse wheel does in a TUI

The rule is tmux's rule: a program that turned mouse reporting on gets the wheel (and clicks and drags); a program that did not gets nothing, and psmux scrolls its own scrollback instead. So `:set mouse=a` in neovim, `--mouse` for `less`, and the mouse setting in htop are what make the wheel work inside those programs. The reasons, the Windows 10 caveat for programs that read the mouse as VT bytes on stdin (Claude Code among them), and the SSH cases are in the [FAQ](../faq.md) and [Mouse Over SSH](../mouse-ssh.md).

If you want psmux's own drag to copy selection even inside a mouse aware TUI, `set -g mouse-selection-force on` keeps it; see [Configuration](../configuration.md).

## Putting it together: an agent supervisor session

A combined example: one window per agent, each logged, a `hub` window whose shell runs the supervisor loop, and a status line that shows what is in front.

```powershell
$s = 'agents'
psmux new-session -d -s $s -n hub -x 200 -y 50
psmux set-option -t $s remain-on-exit on
psmux set-option -t $s status-right '#{pane_title} [#{pane_current_command}] %H:%M'

foreach ($n in 'backend', 'frontend', 'docs') {
    psmux new-window -t $s -n $n -d -c "C:\src\project\$n"
    psmux select-pane -t "${s}:${n}.0" -T "agent: $n"
    psmux pipe-pane   -t "${s}:${n}.0" -o "cat >> C:\logs\$n.log"
    psmux send-keys   -t "${s}:${n}.0" 'claude' Enter
}

psmux attach -t $s
```

From another terminal, or from a scheduled task, the same session is fully inspectable: `psmux list-windows -t agents`, `psmux capture-pane -t agents:backend -p`, `psmux respawn-pane -k -t agents:docs -- claude`. Detach with `prefix + d`; the agents keep running.

## FAQ

### Do I need WSL or Cygwin to run agents this way on Windows?

No. psmux is a native Windows program. The agents run as Windows processes in ConPTY panes. WSL is optional and only needed for Linux only tools, and a WSL shell fits in a pane like any other shell.

### Can one agent drive other agents through psmux?

Yes. Everything on this page is a CLI command, so an agent with shell access can run `psmux new-window`, `send-keys` and `capture-pane` itself. Claude Code's teammate mode is exactly this, built in; see [Claude Code agent teams](../claude-code.md).

### Will my tmux scripts for agents work unchanged?

Mostly. The command names, flags, targets and format variables are tmux's. Use `tmux` as the command name (psmux installs a `tmux.exe` alias) and keep paths and shell syntax portable. The one Windows specific idiom above is the `cat > file` sink for `pipe-pane`, which works on both platforms. See [Cross Platform tmux Scripts](cross-platform-tmux-scripts.md) and [Compatibility](../compatibility.md).

### How do I know an agent has finished?

Poll `capture-pane -p` for a marker the agent prints, or poll `#{pane_dead}` if the agent exits when done. Both are shown above. For a running agent that goes idle rather than exiting, `#{pane_current_command}` returning to the shell name is another signal.

### What happens to running agents when I close Windows Terminal?

Nothing. They live in the psmux server process, not in the window. `psmux attach -t <session>` from any new terminal brings them back. See [Windows Use Cases](../use-cases.md) for boot time services and remote reattach.

### Does the mouse work in Claude Code, Codex and other node based TUIs?

On Windows 11 build 22523 and newer, yes, once the program enables mouse reporting. On Windows 10 the VT mouse bytes are lost inside conhost for programs that read stdin; the [FAQ](../faq.md) has the measured details and the list of frameworks that are unaffected.
