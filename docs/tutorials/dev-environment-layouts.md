# Multi Window and Multi Pane Development Layouts on Windows with psmux

This tutorial shows how to design a project session in psmux, the native tmux for Windows: one window per concern (editor, server, tests, git), panes sized and arranged with tmux layout commands, a bootstrap script that rebuilds the whole thing in a second, and a Windows Terminal profile that opens straight into it. It is written for developers on Windows who want the multi pane, multi window workflow tmux users have on Linux and macOS, using PowerShell, cmd, Git Bash or WSL inside the panes.

Every command was run against psmux 3.3.8 on Windows 11 with PowerShell 7 and Windows Terminal. `psmux`, `pmux` and `tmux` are the same binary.

## What you will learn

- How to structure a project session into windows and panes that map to what you actually do
- `split-window` sizing with `-l 30%` and `-p 25`, and the five `select-layout` presets
- Rearranging on the fly: `swap-pane`, `rotate-window`, `resize-pane`, `break-pane`, zoom, `move-window`
- `synchronize-panes` for running one command in several panes at once
- Window naming, `automatic-rename`, `respawn-window`, and logging a pane with `pipe-pane`
- A bootstrap script in PowerShell and the same one in bash, and a Windows Terminal profile that lands in the session
- Four complete layouts to copy

Related pages: [Scripting and Automation](../scripting.md) for every command and format variable, [Command Reference](../tmux_args_reference.md) for per command flags, [Cross Platform tmux Scripts](cross-platform-tmux-scripts.md) for making the bootstrap portable, [Running Terminal AI Agents and TUIs](terminal-agents-and-tuis.md) for agent focused layouts, and [Live Preview in Choosers](../preview.md) for navigating between sessions.

## Designing a project session

A session is a named workspace that lives in the psmux server. Windows are the tabs in its status line; panes are the splits inside a window. A layout that works for most projects:

| Window | Contents | Why its own window |
|---|---|---|
| `edit` | editor pane plus a narrow shell for quick commands | the thing you look at most gets the most space |
| `server` | dev server, watcher, or docker compose logs | long running, noisy, rarely typed into |
| `tests` | a shell for running tests, a small pane tailing test output | you switch here, run, read, switch back |
| `git` | lazygit, gitui, or a plain shell | commits and reviews without disturbing the editor |

Naming the windows is the difference between `prefix + 2` meaning something and meaning nothing. `new-window -n server` names the tab and turns `automatic-rename` off for that window, so the name survives whatever process starts inside.

## Splitting and sizing panes

`split-window -h` puts the new pane to the right, `-v` puts it below. `-l` takes a size in cells or a percentage; `-p` takes a percentage. `-d` keeps focus where it was. `-c` sets the start directory.

```powershell
psmux new-session -d -s proj -n edit -x 160 -y 45
psmux split-window -t proj:edit -h -l 30% -d        # 30% column on the right
psmux split-window -t proj:edit.0 -v -l 25% -d      # 25% strip under the left pane
psmux list-panes -t proj:edit -F '#{pane_index} #{pane_id} #{pane_width}x#{pane_height} at #{pane_left},#{pane_top}'
```

```
0 %1 111x33 at 0,0
1 %3 111x11 at 0,34
2 %2 48x45 at 112,0
```

`-p 25` gives the same 25 percent strip as `-l 25%`. Both forms are accepted, so a script written for either tmux 2.x (`-p`) or 3.x (`-l N%`) works unchanged.

Pane ids (`%1`, `%2`, ...) are allocated per server and never reused within a run, which makes them the safest target for scripts. Pane indexes (`0`, `1`, `2`) are positional and change when panes are swapped or closed.

## The five layout presets

`select-layout` arranges the panes of a window. With four panes in a 160x45 window:

```
PS> foreach ($l in 'even-horizontal','even-vertical','main-horizontal','main-vertical','tiled') {
>>   psmux select-layout -t proj:grid $l
>>   "$l -> " + (psmux display-message -t proj:grid -p '#{window_layout}')
>> }
even-horizontal -> 2b42,160x45,0,0{39x45,0,0,4,39x45,40,0,8,39x45,80,0,7,40x45,120,0,6}
even-vertical   -> 9fb8,160x45,0,0[160x10,0,0,4,160x10,0,11,8,160x10,0,22,7,160x12,0,33,6]
main-horizontal -> 0afc,160x45,0,0[160x26,0,0,4,160x18,0,27{52x18,0,27,8,52x18,53,27,7,54x18,106,27,6}]
main-vertical   -> 5202,160x45,0,0{95x45,0,0,4,64x45,96,0[64x14,96,0,8,64x14,96,15,7,64x15,96,30,6]}
tiled           -> e59f,160x45,0,0[160x22,0,0{79x22,0,0,4,80x22,80,0,8},160x22,0,23{79x22,0,23,7,80x22,80,23,6}]
```

```
even-horizontal        even-vertical          main-horizontal        main-vertical          tiled
+---+---+---+---+      +---------------+      +---------------+      +---------+-----+      +-------+-------+
|   |   |   |   |      +---------------+      |     main      |      |         |     |      |       |       |
|   |   |   |   |      +---------------+      +----+----+-----+      |  main   +-----+      +-------+-------+
|   |   |   |   |      +---------------+      |    |    |     |      |         |     |      |       |       |
+---+---+---+---+      +---------------+      +----+----+-----+      +---------+-----+      +-------+-------+
```

`next-layout` (`prefix + Space`) cycles through them. The strings printed above are tmux layout strings: capture `#{window_layout}` after arranging a window by hand and feed it back to `select-layout` later to restore that arrangement. The aliases `even-h`, `even-v`, `main-h` and `main-v` are accepted too.

## Rearranging on the fly

```powershell
psmux swap-pane -s proj:grid.0 -t proj:grid.1     # exchange two panes
psmux rotate-window -t proj:grid                   # every pane moves one slot
psmux resize-pane -t proj:grid.0 -L 10             # 10 cells narrower on the left edge
psmux resize-pane -t proj:grid.0 -D 5              # 5 cells taller downwards
psmux resize-pane -t proj:grid.0 -Z                # zoom (again to unzoom), same as prefix + z
psmux break-pane -d -t proj:grid.3                 # pane 3 becomes its own window, focus stays
psmux move-window -s proj:git -t proj:9            # renumber a window
```

Checked live, the swap and the rotation do what the names say:

```
PS> psmux swap-pane -s proj:grid.0 -t proj:grid.1; psmux list-panes -t proj:grid -F '#{pane_index} #{pane_id}' | Select-Object -First 2
0 %8
1 %4
PS> psmux rotate-window -t proj:grid; psmux list-panes -t proj:grid -F '#{pane_index} #{pane_id}'
0 %4
1 %7
2 %6
3 %8
```

Zoom survives a split. `split-window -Z` while a pane is zoomed keeps the window zoomed on the new pane ([PR 572](https://github.com/psmux/psmux/pull/572)):

```
PS> psmux resize-pane -t proj:grid.0 -Z; psmux display-message -t proj:grid -p 'zoomed=#{window_zoomed_flag}'
zoomed=1
PS> psmux split-window -t proj:grid -Z -d; psmux display-message -t proj:grid -p 'zoomed=#{window_zoomed_flag} panes=#{window_panes}'
zoomed=1 panes=5
```

Moving a pane from one window into another is `join-pane -s <source>` (`move-pane` is the same command); its cross session form is described in [Scripting and Automation](../scripting.md).

## One command in every pane: `synchronize-panes`

Turn it on for a window and every keystroke goes to all of its panes. Handy for running the same build in several checkouts, or the same command on several SSH hosts.

```powershell
psmux set-option -t proj:grid -w synchronize-panes on
psmux send-keys -t proj:grid.0 'git pull' Enter
psmux set-option -t proj:grid -w synchronize-panes off
```

```
PS> psmux send-keys -t proj:grid.0 'Write-Host "sync $PID"' Enter
PS> 0..3 | ForEach-Object { "pane $_ : " + (psmux capture-pane -t proj:grid.$_ -p | Select-String '^sync').Count }
pane 0 : 1
pane 1 : 1
pane 2 : 1
pane 3 : 1
PS> psmux display-message -t proj:grid -p 'synchronized=#{pane_synchronized}'
synchronized=1
```

`toggle-sync` is a psmux shortcut for flipping it from a key binding: `bind-key S toggle-sync`.

## Logging a pane and restarting a window

`pipe-pane -o "cat > <absolute path>"` streams a pane's raw output to a file; the psmux server writes the file itself so the idiom works even though PowerShell's `cat` is `Get-Content`. Run it again with no `-o` to stop. Details in [Piping Pane Output](../scripting.md#piping-pane-output-pipe-pane).

```powershell
psmux pipe-pane -t proj:server -o "cat >> C:\logs\devserver.log"
```

When a window's process has exited (with `remain-on-exit on` the pane stays visible), `respawn-window` restarts it in place:

```
PS> psmux list-panes -t proj:server -F 'dead=#{pane_dead}'
dead=1
PS> psmux respawn-window -t proj:server
PS> psmux list-panes -t proj:server -F 'dead=#{pane_dead} cmd=#{pane_current_command}'
dead=0 cmd=pwsh
```

`respawn-pane -k -- <command>` does the same for one pane and lets you change the command; see [Dead Panes and Respawn](../configuration.md#dead-panes-and-respawn).

## Window names and `automatic-rename`

`new-window -n name` and `rename-window` both lock the name. `show-options -w automatic-rename` on that window reports `off` afterwards:

```
PS> psmux rename-window -t proj:grid workers
PS> psmux show-options -t proj:workers -w automatic-rename
automatic-rename off
```

Windows without a fixed name track the foreground process (`pwsh`, `nvim`, `node`) through `#{pane_current_command}`. To hand a renamed window back to automatic naming: `psmux set-option -t proj:workers -w automatic-rename on`.

## The bootstrap script

A session that has to be rebuilt by hand is a session you stop using. Put the layout in a script, guard it with `has-session`, and end with `attach`. This one creates the four window layout from the top of the page.

PowerShell (`proj.ps1`):

```powershell
$s    = 'proj'
$root = 'C:\src\proj'

psmux has-session -t $s 2>$null
if ($LASTEXITCODE -ne 0) {
    psmux new-session -d -s $s -n edit -c $root -x 160 -y 45
    psmux split-window -t "${s}:edit" -h -l 35% -c $root
    psmux new-window  -t $s -n server -c $root -d
    psmux new-window  -t $s -n tests  -c $root -d
    psmux split-window -t "${s}:tests" -v -l 30% -c $root -d
    psmux new-window  -t $s -n git    -c $root -d
    psmux select-window -t "${s}:edit"
    psmux select-pane   -t "${s}:edit.0"

    psmux send-keys -t "${s}:edit.0"  'nvim .' Enter
    psmux send-keys -t "${s}:server"  'npm run dev' Enter
    psmux send-keys -t "${s}:git"     'lazygit' Enter
}
psmux attach -t $s
```

The same script in bash, which runs unchanged under tmux on Linux and macOS and under psmux on Windows (Git Bash or WSL) because psmux ships a `tmux.exe` alias:

```bash
#!/usr/bin/env bash
s=proj
root="$HOME/src/proj"

tmux has-session -t "$s" 2>/dev/null || {
  tmux new-session -d -s "$s" -n edit -c "$root" -x 160 -y 45
  tmux split-window -t "$s:edit" -h -l 35% -c "$root"
  tmux new-window  -t "$s" -n server -c "$root" -d
  tmux new-window  -t "$s" -n tests  -c "$root" -d
  tmux split-window -t "$s:tests" -v -l 30% -c "$root" -d
  tmux new-window  -t "$s" -n git    -c "$root" -d
  tmux select-window -t "$s:edit"
}
tmux attach -t "$s"
```

What both produce (the `send-keys` lines omitted for the check):

```
PS> psmux list-windows -t proj -F '#{window_index}:#{window_name} panes=#{window_panes} active=#{window_active}'
0:edit panes=2 active=1
1:server panes=1 active=0
2:tests panes=2 active=0
3:git panes=1 active=0
PS> psmux list-panes -t proj:edit -F '#{pane_index} #{pane_width}x#{pane_height} #{pane_current_path}'
0 103x45 C:\src\proj
1 56x45 C:\src\proj
```

Portability rules (paths, quoting, which shell the panes run) are covered in [Cross Platform tmux Scripts](cross-platform-tmux-scripts.md).

### Saving and restoring layouts automatically

If you would rather not maintain a script, the psmux-resurrect plugin saves every session's windows, panes, layouts and directories, and psmux-continuum saves on a timer and restores on the next start. Both are listed with installation steps in [Plugins and Themes](../plugins.md).

## A Windows Terminal profile that opens the session

`new-session -A` attaches if the session exists and creates it otherwise, so one command is both "start" and "resume":

```powershell
psmux new-session -A -s proj -c C:\src\proj
```

Checked live: the first call created the session with `#{pane_current_path}` reporting `C:\src\proj`; a second call attached to it without creating a duplicate (`list-sessions` still showed one `proj`).

Add it as a profile in Windows Terminal's `settings.json`:

```json
{
  "name": "proj",
  "commandline": "pwsh.exe -NoLogo -Command \"psmux new-session -A -s proj -c C:\\src\\proj\"",
  "startingDirectory": "C:\\src\\proj"
}
```

If you want the profile to run the full bootstrap script instead, point `commandline` at `pwsh.exe -File C:\src\proj\proj.ps1`; the script's `has-session` guard makes it safe to open the profile twice.

## Switching between sessions

`prefix + s` opens `choose-session`, `prefix + w` opens the window chooser, `psmux choose-tree` (from the CLI or the `prefix + :` prompt) shows every session, window and pane, and `p` toggles a live preview of the highlighted target so you can see a window before you jump. `set -g choose-tree-preview on` opens the preview by default. See [Live Preview in Choosers](../preview.md).

## Four layouts to copy

Each block creates a detached session; add `psmux attach -t <name>` at the end or open it from a profile as above.

### 1. Editor with a side terminal

```
+-----------------------------------+------------+
|                                   |            |
|  nvim / code                      |  shell     |
|                                   |            |
|                                   |            |
+-----------------------------------+------------+
```

```powershell
psmux new-session -d -s edit -n main -c C:\src\proj -x 160 -y 45
psmux split-window -t edit:main -h -l 30% -c C:\src\proj -d
psmux send-keys -t edit:main.0 'nvim .' Enter
```

### 2. Full stack: server, client, tests, shell

```
+-------------------------+-------------------------+
|  api server             |  web dev server         |
|                         |                         |
+-------------------------+-------------------------+
|  tests (watch)          |  shell                  |
|                         |                         |
+-------------------------+-------------------------+
```

```powershell
psmux new-session -d -s stack -n dev -c C:\src\proj -x 160 -y 45
psmux split-window -t stack:dev -v -c C:\src\proj -d          # tests, bottom left
psmux split-window -t stack:dev.0 -h -c C:\src\proj\web -d    # web, top right
psmux split-window -t stack:dev.2 -h -c C:\src\proj -d        # shell, bottom right
psmux select-layout -t stack:dev tiled
psmux select-pane -t stack:dev.0 -T 'api'
psmux select-pane -t stack:dev.1 -T 'web'
psmux select-pane -t stack:dev.2 -T 'tests'
psmux select-pane -t stack:dev.3 -T 'shell'
psmux set-option -t stack pane-border-status top
psmux set-option -t stack pane-border-format ' #{pane_title} '
```

### 3. Ops dashboard: main log plus three monitors

```
+---------------------------------------------------+
|  main: application log (pipe-pane to a file)      |
|                                                   |
+----------------+----------------+-----------------+
|  btop          |  docker stats  |  k9s / shell    |
+----------------+----------------+-----------------+
```

```powershell
psmux new-session -d -s ops -n dash -x 160 -y 45
psmux split-window -t ops:dash -v -d
psmux split-window -t ops:dash.1 -h -d
psmux split-window -t ops:dash.1 -h -d
psmux select-layout -t ops:dash main-horizontal
psmux pipe-pane -t ops:dash.0 -o "cat >> C:\logs\app.log"
psmux send-keys -t ops:dash.1 'btop' Enter
psmux send-keys -t ops:dash.2 'docker stats' Enter
```

### 4. Multi checkout with synchronized panes

```
+-------------------------+-------------------------+
|  repo A                 |  repo B                 |
+-------------------------+-------------------------+
|  repo C                 |  repo D                 |
+-------------------------+-------------------------+
   synchronize-panes on: one "git pull && npm test" runs in all four
```

```powershell
psmux new-session -d -s multi -n repos -c C:\src\a -x 160 -y 45
psmux split-window -t multi:repos -v -c C:\src\c -d       # bottom left
psmux split-window -t multi:repos.0 -h -c C:\src\b -d     # top right
psmux split-window -t multi:repos.2 -h -c C:\src\d -d     # bottom right
psmux select-layout -t multi:repos tiled
psmux set-option -t multi:repos -w synchronize-panes on
```

## FAQ

### Can I keep different shells in different panes of one layout?

Yes. `split-window` and `new-window` take a command after `--`, so one pane can be `pwsh`, the next `cmd.exe`, the next `wsl -d Ubuntu`, and `default-shell` sets the fallback. See [Multi Shell](../multi-shell.md).

### Will the layout survive closing Windows Terminal?

Yes. The session, its windows, panes and running processes live in the psmux server. Reopen a terminal and `psmux attach -t proj` (or the `-A` profile above) puts you back. Sign out and the server is gone, which is where psmux-resurrect and psmux-continuum come in.

### Do tmux layout strings from Linux work here?

Yes, the format is the same. Capture `#{window_layout}` on either platform and pass it to `select-layout`. Pane counts must match; the string describes geometry, not contents.

### How do I target a pane in a script without guessing its index?

Use the pane id printed by `split-window -P -F '#{pane_id}'` or by `list-panes -F '#{pane_id}'`. Ids like `%7` are stable for the pane's lifetime; indexes change when you swap or close panes.

### Why does my sized split come out a few cells different from what I asked?

Borders take a cell, and percentages are rounded to whole cells. Asking for `-l 30%` of a 160 column window gives a 48 column pane plus a one cell border, as the `list-panes` output at the top of the page shows.
