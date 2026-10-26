# Issue #625: prefix+w (choose-tree) must behave like tmux's mode-tree.
#
# Reported by fekir with `renumber-windows on`, `base-index 1` and
# `pane-base-index 1`. Four gaps, all reproduced on the unfixed build with a
# real attached client, WriteConsoleInput keystrokes and a console screen read:
#
#   1. tmux jumps on the BARE digit. psmux opened a "go to N" prompt and waited
#      for Enter.
#   2. tmux starts with the windows COLLAPSED (`choose-tree -w` sets
#      WINDOW_TREE_WINDOW, and window_tree_build_window then passes
#      expanded = 0), so the visible lines are the sessions and their windows.
#      psmux listed every pane too, so the list was 10 rows deep for 4 windows.
#   3. `0` was dead and it soft locked the dialog: the jump buffer only accepted
#      1..len, "0" fell to the None arm which deliberately KEPT the buffer, and
#      every later Enter re-took that same dead branch.
#   4. Because panes were listed, the digit needed depended on how many panes
#      each window had, so the window number in the status bar was useless.
#
# tmux ground truth (C:\Users\godwin\Documents\workspace\tmux):
#   mode-tree.c mode_tree_build_lines  -> `mti->key = '0' + mti->line`, a ZERO
#                                         based index over the VISIBLE lines
#   mode-tree.c mode_tree_key          -> `mtd->current = choice; *key = '\r';`
#                                         so the digit jumps AND activates
#   window-tree.c window_tree_build_window -> `expanded = 0` under -w
#
# Layout used here: one session, four windows (base-index 1) where window 2
# holds THREE panes. Under tmux rules the visible lines are
#   0 session, 1 window 1, 2 window 2, 3 window 3, 4 window 4
# so digit N picks window N for N in 1..4 no matter how many panes exist.
# Under the old flat listing the same tree was 11 rows and `3` landed on a pane
# of window 1.

param([string]$Bin = "")

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Host "  PASS: $name $detail" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL: $name $detail" -ForegroundColor Red;   $script:fail++ }
}

if (-not $Bin) {
    $Bin = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
}
if (-not $Bin) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $Bin = $c.Source } }
if (-not $Bin) { Write-Error "psmux binary not found"; exit 1 }

$env:PSMUX_SESSION = ""
$env:PSMUX_SESSION_NAME = $null
$SESSION = "i625tree"

# The reporter's exact configuration. The server reads it at startup, so it
# must be in the environment before the first command spawns one.
$conf = Join-Path $env:TEMP "psmux_issue625.conf"
Set-Content -Path $conf -Encoding ASCII -Value @"
set -g renumber-windows on
set -g base-index 1
setw -g pane-base-index 1
"@
$env:PSMUX_CONFIG_FILE = $conf

Write-Host "`n=== Issue #625: choose-tree parity with tmux mode-tree ===" -ForegroundColor Cyan
Write-Host "  Binary: $Bin"
Write-Host "  Config: $conf (renumber-windows on, base-index 1, pane-base-index 1)"

# --- helpers: the injector writes real key records, conread reads the client's
#     visible screen. The chooser is drawn by the CLIENT over the panes, so
#     capture-pane and dump-state cannot see it; conread can.
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injectorExe = "$env:TEMP\psmux_injector.exe"
$conreadExe  = "$env:TEMP\psmux_conread.exe"
foreach ($pair in @(@("injector.cs", $injectorExe), @("conread.cs", $conreadExe))) {
    $src = Join-Path $PSScriptRoot $pair[0]
    $exe = $pair[1]
    if (-not (Test-Path $exe) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $exe).LastWriteTime)) {
        & $csc /nologo /optimize /out:$exe $src 2>&1 | Out-Null
    }
}
$haveTools = (Test-Path $injectorExe) -and (Test-Path $conreadExe)
Add-Result "injector and conread compiled" $haveTools ""
if (-not $haveTools) { exit 1 }

function Active-Idx { (& $Bin display-message -t $SESSION -p '#{window_index}' 2>&1 | Out-String).Trim() }

function Build-Session {
    & $Bin kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $Bin new-session -d -s $SESSION 2>&1 | Out-Null
    for ($i = 0; $i -lt 24; $i++) {
        & $Bin has-session -t $SESSION 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    & $Bin new-window -t $SESSION 2>&1 | Out-Null
    & $Bin new-window -t $SESSION 2>&1 | Out-Null
    & $Bin new-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    # Window 2 gets three panes. Under the old flat listing this alone pushed
    # every later window two rows down.
    & $Bin split-window -t "${SESSION}:2" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    & $Bin split-window -t "${SESSION}:2" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    & $Bin select-window -t "${SESSION}:1" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}

# Attach a real client, press the keys, then report the active window index and
# (optionally) what the client had on screen.
function Drive([string]$Keys, [switch]$Dump) {
    $proc = Start-Process -FilePath $Bin -ArgumentList @("attach","-t",$SESSION) -PassThru
    Start-Sleep -Seconds 4
    & $Bin select-window -t "${SESSION}:1" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $before = Active-Idx
    & $injectorExe $proc.Id $Keys 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $after = Active-Idx
    $screen = ""
    if ($Dump) { $screen = (& $conreadExe $proc.Id 2>&1 | Out-String) }
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 900
    return @{ Before = $before; After = $after; Screen = $screen }
}

Build-Session
$wins = (& $Bin list-windows -t $SESSION 2>&1 | Out-String)
$winCount = @($wins -split "`r?`n" | Where-Object { $_ -match '^\d+:' }).Count
Add-Result "four windows created with base-index 1" `
    (($winCount -eq 4) -and ($wins -match '(?m)^1:') -and ($wins -match '(?m)^4:')) `
    "windows=$winCount"
Add-Result "window 2 holds three panes" ($wins -match '2:.*\(3 panes\)') `
    ($wins -replace "`r?`n", ' | ')

# ── Gap 2 and 4: the tree opens with the windows collapsed ─────────────
Write-Test "prefix+w lists the session and its windows only, panes hidden"
$r = Drive "^b{SLEEP:600}w{SLEEP:1400}" -Dump
$screen = $r.Screen
$open = $screen -match 'choose-tree'
Add-Result "chooser opened" $open ""
# Four window rows, one per window: exactly the `(N panes)` labels and no more.
$windowRows = ([regex]::Matches($screen, '\d+ panes\)')).Count
Add-Result "exactly four window rows are visible (no pane rows)" ($windowRows -eq 4) `
    "rows with a pane count=$windowRows"
# Every visible line carries its tmux jump key and a +/- expansion marker, so
# counting them counts the tree: one session plus four windows, nothing else.
# The old flat listing rendered eleven rows numbered "1." to "11." instead.
# The side border is read back through a code page best fit, so it can come
# back as any single character (a letter such as U+00AA once 0xA6 is decoded
# as OEM): match one optional non blank in front of the key, not a class.
$listRows = ([regex]::Matches($screen, '(?m)^\s*\S?\d+ [-+]')).Count
Add-Result "exactly five visible lines (session plus its four windows)" ($listRows -eq 5) `
    "visible lines=$listRows"
if ($listRows -ne 5) {
    Write-Host "  [screen]`n$screen"
    $row = ($screen -split "`n" | Where-Object { $_ -match "0 -$SESSION" } | Select-Object -First 1)
    if ($row) { Write-Host ("  [row codes] " + (($row.TrimStart().Substring(0, [Math]::Min(8, $row.TrimStart().Length)).ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')) }
}
Add-Result "no row uses the old 1-based 'N.' numbering" (-not ($screen -match '(?m)^\s*\S?\s*\d+\. ')) ""
# tmux stamps '0'+line on the visible lines, so with one session the keys are
# 0 for the session and 1..4 for the four windows.
Add-Result "session row carries jump key 0" ($screen -match "0 -$SESSION") ""
foreach ($n in 1..4) {
    Add-Result "window $n carries jump key $n" ($screen -match "$n \+\s+${n}: ") ""
}
# A collapsed row is marked '+' (tmux MODE_TREE_PREFIX_STYLE), expanded is '-'.
Add-Result "no sixth visible line exists" (-not ($screen -match '(?m)^\S?5 [-+] ')) ""

# ── Gap 1: the bare digit jumps, with no Enter ─────────────────────────
Write-Test "a bare digit jumps and activates, no Enter typed"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}3{SLEEP:1500}" -Dump
Add-Result "bare 3 activates window 3" ($r.After -eq "3") "before=$($r.Before) after=$($r.After)"
Add-Result "bare 3 closes the chooser" (-not ($r.Screen -match 'choose-tree')) ""

# ── Gap 4: a three pane window does not shift the later digits ─────────
Write-Test "the digit is the window number even though window 2 has three panes"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}2{SLEEP:1500}"
Add-Result "bare 2 activates window 2" ($r.After -eq "2") "after=$($r.After)"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}4{SLEEP:1500}"
Add-Result "bare 4 activates window 4" ($r.After -eq "4") "after=$($r.After)"

# ── Gap 3: 0 works and never locks the dialog ──────────────────────────
Write-Test "0 selects the session row, closes the dialog and locks nothing"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}0{SLEEP:1500}" -Dump
Add-Result "0 leaves the active window alone" ($r.After -eq "1") "after=$($r.After)"
Add-Result "0 closes the chooser (no soft lock)" (-not ($r.Screen -match 'choose-tree')) ""
# Reopen after a 0 and jump again: on the unfixed build the stuck buffer made
# every subsequent Enter a no-op.
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}0{SLEEP:800}^b{SLEEP:600}w{SLEEP:1200}4{SLEEP:1500}" -Dump
Add-Result "the chooser still works after a 0" ($r.After -eq "4") "after=$($r.After)"

Write-Test "1 activates window 1 with base-index 1"
& $Bin select-window -t "${SESSION}:3" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $Bin -ArgumentList @("attach","-t",$SESSION) -PassThru
Start-Sleep -Seconds 4
& $Bin select-window -t "${SESSION}:3" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $injectorExe $proc.Id "^b{SLEEP:600}w{SLEEP:1200}1{SLEEP:1500}" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$after1 = Active-Idx
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Milliseconds 900
Add-Result "bare 1 activates window 1 from window 3" ($after1 -eq "1") "after=$after1"

# ── Enter still switches on the cursor row ─────────────────────────────
Write-Test "Enter on a moved cursor still switches (Down x2 from window 1 row)"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}{DOWN}{SLEEP:250}{DOWN}{SLEEP:400}{ENTER}{SLEEP:1500}"
Add-Result "Down Down Enter lands on window 3" ($r.After -eq "3") "after=$($r.After)"

# ── Right expands a window, Left collapses it again ────────────────────
Write-Test "Right expands the window under the cursor and reveals its panes"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}{DOWN}{SLEEP:300}{RIGHT}{SLEEP:1400}" -Dump
$expanded = $r.Screen -match '2 -\s+2: '
Add-Result "window 2 shows the expanded marker after Right" $expanded ""
# With window 2 expanded the tree grows by its three panes, so window 3 moves
# from key 3 to key 6, exactly as mode_tree_build_lines renumbers.
Add-Result "window 3 renumbers to key 6 once window 2 is expanded" `
    ($r.Screen -match '6 \+\s+3: ') ""

Write-Test "Left collapses it back"
$r = Drive "^b{SLEEP:600}w{SLEEP:1200}{DOWN}{SLEEP:300}{RIGHT}{SLEEP:600}{LEFT}{SLEEP:1400}" -Dump
Add-Result "window 2 is collapsed again after Left" ($r.Screen -match '2 \+\s+2: ') ""
Add-Result "window 3 is back on key 3" ($r.Screen -match '3 \+\s+3: ') ""

& $Bin kill-session -t $SESSION 2>&1 | Out-Null
Remove-Item $conf -Force -EA SilentlyContinue
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
exit $fail
