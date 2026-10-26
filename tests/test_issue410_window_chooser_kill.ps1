# Issue #410: choose-tree window picker (Ctrl+b w) must allow killing the
# highlighted window via `x`, mirroring the session picker (Ctrl+b s).
#
# Reproduction strategy (WriteConsoleInput keystroke injection into the attached
# client, Layer 3): the choose-tree overlay is NOT captured by capture-pane and
# is NOT reflected in dump-state, so we prove the picker is genuinely OPEN by the
# fact that it ABSORBS typed characters (they never reach the shell). Then we
# press `x`, which since #778 only asks (as tmux does), answer `y`, and assert
# the window count drops.
param([string]$Bin = "")

$ErrorActionPreference = "Continue"
$PSMUX = if ($Bin) { $Bin } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Info($m){ Write-Host $m -ForegroundColor Cyan }

# Compile injector if missing
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe (Join-Path (Split-Path $PSScriptRoot -Parent) "tests\injector.cs") 2>&1 | Out-Null
}

function New-Sess($name, $extraWindows) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$name -PassThru
    Start-Sleep -Seconds 4
    & $PSMUX rename-window -t "${name}:0" alpha 2>&1 | Out-Null
    foreach ($w in $extraWindows) { & $PSMUX new-window -t $name -n $w 2>&1 | Out-Null }
    Start-Sleep -Seconds 1
    return $p
}
function WinCount($name){ (& $PSMUX display-message -t $name -p '#{session_windows}' 2>&1).Trim() }
function ActiveWin($name){ (& $PSMUX display-message -t $name -p '#{window_name}' 2>&1).Trim() }
function Cap($name){ (& $PSMUX capture-pane -t $name -p 2>&1 | Out-String) }
function KillSess($p, $name){ & $PSMUX kill-session -t $name 2>&1 | Out-Null; try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {} }

Write-Host "`n=== Issue #410: window chooser `x` kill ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# TEST 1: `x` on the highlighted window kills it (core fix)
# ---------------------------------------------------------------------------
Info "`n[Test 1] Ctrl+b w, then x -> kills highlighted window"
$S = "issue410_t1"
$p = New-Sess $S @("bravo","charlie")
$before = WinCount $S
# open chooser, prove it's open by absorption, then x
& $injectorExe $p.Id "^b{SLEEP:500}w{SLEEP:1200}"
Start-Sleep -Seconds 1
& $injectorExe $p.Id "MARKERabsorb{SLEEP:500}"
Start-Sleep -Milliseconds 800
$absorbed = -not ((Cap $S) -match "MARKERabsorb")
# Since #778 `x` only asks, as tmux's window_tree_key does ("Kill window %u? "
# through a PROMPT_SINGLE prompt), and the kill waits for `y`.
& $injectorExe $p.Id "x{SLEEP:1200}"
Start-Sleep -Milliseconds 600
$asked = WinCount $S
& $injectorExe $p.Id "y{SLEEP:1200}"
Start-Sleep -Seconds 1
$after = WinCount $S
& $injectorExe $p.Id "{ESC}{SLEEP:300}" 2>&1 | Out-Null
if ($absorbed) { Write-Pass "chooser is open (typed chars absorbed, not leaked to shell)" }
else { Write-Fail "chooser did not absorb input; picker may not be open" }
if ([int]$asked -eq [int]$before) { Write-Pass "x alone asked and killed nothing ($before -> $asked)" }
else { Write-Fail "x alone killed without asking ($before -> $asked)" }
if ([int]$after -eq [int]$before - 1) { Write-Pass "x then y killed one window ($before -> $after)" }
else { Write-Fail "x then y did not kill a window ($before -> $after)" }
KillSess $p $S

# ---------------------------------------------------------------------------
# TEST 2: navigate (jj) then x kills the SELECTED window (cursor path)
#
# Tree geometry, since #625. choose-tree now opens the way tmux's
# `choose-tree -w` does: window rows start COLLAPSED, so no pane rows are
# interleaved (window-tree.c window_tree_build_window sets `expanded = 0` when
# data->type is WINDOW_TREE_WINDOW), and the session row stays expanded. The
# visible lines for this session are therefore
#     line 0  session header
#     line 1  alpha
#     line 2  bravo
#     line 3  charlie
# and the cursor opens on the ACTIVE window, because window_tree_build hands
# mode_tree_set_current the current winlink (`*tag = (uint64_t)data->fs.wl`).
# alpha is selected below, so the cursor starts on line 1 and the two `j`
# presses (mode-tree.c mode_tree_down) walk it to line 3 = charlie.
#
# Before #625 the tree was FLAT (every pane listed under its window), so the
# same two presses stopped on bravo, which is what this check used to assert.
# The expectation moved with the geometry; the behaviour under test, "x kills
# whatever row the cursor is on", is unchanged.
# ---------------------------------------------------------------------------
Info "`n[Test 2] Ctrl+b w, jj (select charlie), then x -> kills charlie"
$S = "issue410_t2"
$p = New-Sess $S @("bravo","charlie")
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null  # active = alpha so jj walks down into window rows
Start-Sleep -Milliseconds 600
$before = WinCount $S
& $injectorExe $p.Id "^b{SLEEP:500}w{SLEEP:1200}"
Start-Sleep -Seconds 1
& $injectorExe $p.Id "j{SLEEP:350}j{SLEEP:500}x{SLEEP:800}y{SLEEP:1500}"
Start-Sleep -Seconds 1
$after = WinCount $S
$names = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1) -join ","
& $injectorExe $p.Id "{ESC}{SLEEP:300}" 2>&1 | Out-Null
if ([int]$after -eq [int]$before - 1 -and $names -notmatch "charlie" -and $names -match "alpha" -and $names -match "bravo") { Write-Pass "jj+x killed the selected window charlie ($before -> $after; remaining: $names)" }
else { Write-Fail "jj+x did not kill charlie as expected ($before -> $after; remaining: $names)" }
KillSess $p $S

# ---------------------------------------------------------------------------
# TEST 2b: an out-of-range jump digit is a no-op, and x still kills the row the
# cursor is on.
#
# Since #625 a digit is not a buffer that x consumes: it is tmux's mode-tree
# jump key, looked up among the VISIBLE lines and rewritten to Enter on the
# spot (mode-tree.c mode_tree_key):
#     choice = -1;
#     for (i = 0; i < mtd->line_size; i++)
#             if (*key == mtd->line_list[i].item->key) { choice = i; break; }
#     if (choice != -1) { mtd->current = choice; *key = '\r'; return (0); }
# mode_tree_build_lines stamps '0'+line on the visible lines, so this four-line
# tree (0 session, 1 alpha, 2 bravo, 3 charlie) answers to '0'..'3' only. '4'
# matches nothing, falls through mode_tree_key's switch with no case of its own
# and does nothing at all: the cursor does not move and the chooser stays open.
# alpha is selected below, so the cursor is still on alpha and x kills alpha.
#
# That expectation pins both ways this could regress: a digit clamped to the
# last visible line would kill charlie, and the pre-#625 "go to N" buffer would
# have swallowed the 4 and killed bravo.
# ---------------------------------------------------------------------------
Info "`n[Test 2b] Ctrl+b w, type out-of-range 4 (no-op), then x -> kills alpha"
$S = "issue410_t2b"
$p = New-Sess $S @("bravo","charlie")
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null  # active = alpha, so the cursor opens on alpha
Start-Sleep -Milliseconds 600
$before = WinCount $S
& $injectorExe $p.Id "^b{SLEEP:500}w{SLEEP:1200}"
Start-Sleep -Seconds 1
& $injectorExe $p.Id "4{SLEEP:400}x{SLEEP:800}y{SLEEP:1200}"
Start-Sleep -Seconds 1
$after = WinCount $S
$names = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1) -join ","
& $injectorExe $p.Id "{ESC}{SLEEP:300}" 2>&1 | Out-Null
if ([int]$after -eq [int]$before - 1 -and $names -notmatch "alpha" -and $names -match "bravo" -and $names -match "charlie") { Write-Pass "out-of-range 4 left the cursor alone; x killed alpha ($before -> $after; remaining: $names)" }
else { Write-Fail "out-of-range 4 + x did not kill alpha ($before -> $after; remaining: $names)" }
KillSess $p $S

# ---------------------------------------------------------------------------
# TEST 3 (regression): Enter still switches window (chooser not broken)
# ---------------------------------------------------------------------------
Info "`n[Test 3] Regression: Enter still selects/switches a window"
$S = "issue410_t3"
$p = New-Sess $S @("bravo","charlie")
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null  # active = alpha
Start-Sleep -Milliseconds 600
$activeBefore = ActiveWin $S
# open chooser, jj down two visible lines (alpha -> bravo -> charlie under the
# #625 collapsed geometry), Enter -> should switch the active window
& $injectorExe $p.Id "^b{SLEEP:500}w{SLEEP:1200}"
Start-Sleep -Seconds 1
& $injectorExe $p.Id "jj{SLEEP:400}{ENTER}{SLEEP:800}"
Start-Sleep -Seconds 1
$activeAfter = ActiveWin $S
& $injectorExe $p.Id "{ESC}{SLEEP:300}" 2>&1 | Out-Null
if ($activeAfter -ne $activeBefore -and $activeAfter -ne "") { Write-Pass "Enter switched active window ($activeBefore -> $activeAfter)" }
else { Write-Fail "Enter did not switch window ($activeBefore -> $activeAfter)" }
KillSess $p $S

# ---------------------------------------------------------------------------
# TEST 4 (regression): Esc still closes chooser, no window killed
# ---------------------------------------------------------------------------
Info "`n[Test 4] Regression: Esc closes chooser without killing"
$S = "issue410_t4"
$p = New-Sess $S @("bravo","charlie")
$before = WinCount $S
& $injectorExe $p.Id "^b{SLEEP:500}w{SLEEP:1200}"
Start-Sleep -Seconds 1
& $injectorExe $p.Id "{ESC}{SLEEP:600}"
Start-Sleep -Seconds 1
# after Esc, typing should reach the shell again
& $PSMUX send-keys -t "${S}:0" "cls" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $injectorExe $p.Id "REACHshell{SLEEP:600}"
Start-Sleep -Seconds 1
$after = WinCount $S
$reached = ((Cap $S) -match "REACHshell")
& $injectorExe $p.Id "{ESC}{SLEEP:200}" 2>&1 | Out-Null
if ([int]$after -eq [int]$before) { Write-Pass "Esc killed no windows ($before -> $after)" }
else { Write-Fail "window count changed after Esc ($before -> $after)" }
if ($reached) { Write-Pass "Esc closed chooser (input reaches shell again)" }
else { Write-Fail "input did not reach shell after Esc" }
KillSess $p $S

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
