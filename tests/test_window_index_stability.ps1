# Window index stability: renumber-windows off (the tmux default) must leave a
# gap when a window is killed instead of renumbering the survivors. Previously
# psmux tied window_index to the Vec position, so killing/closing any window
# shifted every later window's number down. This also broke join-pane (see the
# renumber note in issue #437 follow-up).
#
# Fixes: AppState now carries a stable, parallel `window_indices` array.
#   - renumber-windows off (default): kill/close leaves a gap; others keep their number.
#   - renumber-windows on: survivors are renumbered contiguously on close.
#   - new-window appends (highest index + 1); existing gaps persist.
#   - select-window / join-pane resolve a display index through the gap map.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Fresh($S){
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
    & $PSMUX new-session -d -s $S
    Start-Sleep -Seconds 3
}
# Space-joined list of window display indices, in order.
function Indices($S){ ((& $PSMUX list-windows -t $S -F '#{window_index}' 2>&1) | ForEach-Object { "$_".Trim() }) -join ' ' }
function AddWindows($S, $n){ for ($k=0; $k -lt $n; $k++){ & $PSMUX new-window -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 700 } }

Write-Host "`n=== Window index stability (renumber-windows) ===" -ForegroundColor Cyan

# --- Test 1: kill FIRST window leaves a gap (renumber off) ---
Write-Host "`n[Test 1] kill first window leaves gap 1 2 3" -ForegroundColor Yellow
$S = "wis_first"; Fresh $S; AddWindows $S 3   # indices 0 1 2 3
$before = Indices $S
& $PSMUX kill-window -t "$S`:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$after = Indices $S
if ($before -eq "0 1 2 3" -and $after -eq "1 2 3") { Write-Pass "kill :0 -> $after (gap at 0 preserved)" }
else { Write-Fail "before=[$before] after=[$after], expected before 0 1 2 3 / after 1 2 3" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test 2: kill MIDDLE window leaves interior gap ---
Write-Host "`n[Test 2] kill middle window leaves gap" -ForegroundColor Yellow
$S = "wis_mid"; Fresh $S; AddWindows $S 3   # 0 1 2 3
& $PSMUX kill-window -t "$S`:1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$after = Indices $S
if ($after -eq "0 2 3") { Write-Pass "kill :1 -> $after (gap at 1)" }
else { Write-Fail "expected 0 2 3, got [$after]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test 3: new-window appends past the highest index ---
Write-Host "`n[Test 3] new-window appends (highest+1)" -ForegroundColor Yellow
$S = "wis_app"; Fresh $S; AddWindows $S 3   # 0 1 2 3
& $PSMUX kill-window -t "$S`:1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700   # 0 2 3
& $PSMUX new-window -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$after = Indices $S
if ($after -eq "0 2 3 4") { Write-Pass "new-window -> $after (appended index 4)" }
else { Write-Fail "expected 0 2 3 4, got [$after]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test 4: renumber-windows ON renumbers survivors on close ---
Write-Host "`n[Test 4] renumber-windows on renumbers on kill" -ForegroundColor Yellow
$S = "wis_renum"; Fresh $S
& $PSMUX set-option -g renumber-windows on 2>&1 | Out-Null
AddWindows $S 2   # 0 1 2
& $PSMUX kill-window -t "$S`:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$after = Indices $S
if ($after -eq "0 1") { Write-Pass "renumber on: kill :0 -> $after (renumbered, no gap)" }
else { Write-Fail "expected 0 1, got [$after]" }
& $PSMUX set-option -g renumber-windows off 2>&1 | Out-Null
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test 5: select-window resolves a gapped display index ---
Write-Host "`n[Test 5] select-window targets a gapped index" -ForegroundColor Yellow
$S = "wis_sel"; Fresh $S; AddWindows $S 3   # 0 1 2 3
& $PSMUX kill-window -t "$S`:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700   # 1 2 3
& $PSMUX select-window -t "$S`:3" 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
$active = (& $PSMUX display-message -t $S -p '#{window_index}' 2>&1).Trim()
if ($active -eq "3") { Write-Pass "select-window :3 landed on window 3" }
else { Write-Fail "expected active window 3, got [$active]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test 6: join-pane emptying source leaves a gap (not a renumber) ---
Write-Host "`n[Test 6] join-pane empties source -> gap persists" -ForegroundColor Yellow
$S = "wis_join"; Fresh $S; AddWindows $S 2   # 0 1 2
& $PSMUX select-window -t "$S`:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX join-pane -s "$S`:0" -t "$S`:2" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$after = Indices $S
if ($after -eq "1 2") { Write-Pass "join from :0 into :2 -> $after (gap at 0, no renumber)" }
else { Write-Fail "expected 1 2, got [$after]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- TUI Layer 2: real attached window still functional after a kill-induced gap ---
Write-Host "`n[Test 7] TUI: attached session survives a gap" -ForegroundColor Yellow
$S = "wis_tui"
& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
AddWindows $S 2   # 0 1 2
& $PSMUX kill-window -t "$S`:1" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
$idx = Indices $S
$panes = (& $PSMUX display-message -t $S -p '#{window_panes}' 2>&1).Trim()
if ($idx -eq "0 2" -and $panes -match '^\d+$') { Write-Pass "TUI attached: indices $idx, session responsive" }
else { Write-Fail "TUI: indices [$idx], panes [$panes]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
