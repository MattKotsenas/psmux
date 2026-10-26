# Issue #545: commands with an unresolvable -t target silently operate on the
# ACTIVE window (rc=0) instead of erroring.
# Repro per the issue report: send-keys / capture-pane / rename-window /
# kill-pane / list-panes / clear-history with -t S:nosuchwindow must NOT touch
# the active window and must exit non-zero with a diagnostic.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S  = "t545a"
$S2 = "t545b"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Cleanup {
    & $PSMUX kill-session -t $S  2>&1 | Out-Null
    & $PSMUX kill-session -t $S2 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$S.*","$psmuxDir\$S2.*" -Force -EA SilentlyContinue
}
Cleanup

Write-Host "`n=== Issue #545 repro ===" -ForegroundColor Cyan

# --- Session S: two parked windows, active = e1 ---
& $PSMUX new-session -d -s $S -n e0 -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $S -n e1 -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 2
& $PSMUX select-window -t "${S}:e1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$wins = (& $PSMUX list-windows -t $S -F '#{window_index}|#{window_name}|#{window_active}' 2>&1) -join ";"
Write-Host "  windows before: $wins"

# --- Control: select-window already errors (validator exists) ---
$out = & $PSMUX select-window -t "${S}:nosuchwindow" 2>&1
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Pass "control: select-window bad target rc=$rc ($out)" }
else { Write-Fail "control: select-window bad target rc=0" }

# --- A. send-keys to bad window target ---
& $PSMUX new-session -d -s $S2 -x 120 -y 30 -- pwsh -NoProfile -NoLogo
Start-Sleep -Seconds 4
& $PSMUX new-window -d -t $S2 -n park -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 2
& $PSMUX select-window -t "${S2}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$out = & $PSMUX send-keys -t "${S2}:nosuchwindow" 'echo MISROUTE_SENTINEL' Enter 2>&1
$rcA = $LASTEXITCODE
Start-Sleep -Seconds 2
$cap0 = (& $PSMUX capture-pane -p -t "${S2}:0" 2>&1) -join "`n"
if ($rcA -ne 0 -and $cap0 -notmatch "MISROUTE_SENTINEL") {
    Write-Pass "A: send-keys bad window target rc=$rcA, active window clean"
} elseif ($cap0 -match "MISROUTE_SENTINEL") {
    Write-Fail "A: BUG - send-keys bad target rc=$rcA, sentinel typed into ACTIVE window"
} else {
    Write-Fail "A: send-keys bad target rc=$rcA (expected nonzero)"
}

# A2. unresolvable pane on a valid window
$out = & $PSMUX send-keys -t "${S2}:0.%99" 'echo PANE_MISROUTE' Enter 2>&1
$rcA2 = $LASTEXITCODE
Start-Sleep -Seconds 2
$cap0 = (& $PSMUX capture-pane -p -t "${S2}:0" 2>&1) -join "`n"
if ($rcA2 -ne 0 -and $cap0 -notmatch "PANE_MISROUTE") {
    Write-Pass "A2: send-keys bad pane target rc=$rcA2, real pane clean"
} elseif ($cap0 -match "PANE_MISROUTE") {
    Write-Fail "A2: BUG - send-keys -t S2:0.%99 rc=$rcA2, executed in the real pane"
} else {
    Write-Fail "A2: send-keys bad pane rc=$rcA2 (expected nonzero)"
}

# --- B. capture-pane returns ACTIVE window's buffer for bad target ---
$out = & $PSMUX capture-pane -p -t "${S}:nosuchwindow" 2>&1
$rcB = $LASTEXITCODE
if ($rcB -ne 0) { Write-Pass "B: capture-pane bad target rc=$rcB" }
else { Write-Fail "B: BUG - capture-pane bad target rc=0 (returned active window's buffer)" }

# --- C. rename-window mutates ACTIVE window on bad target ---
$out = & $PSMUX rename-window -t "${S}:nosuchwindow" RENAMED 2>&1
$rcC = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$winsAfter = (& $PSMUX list-windows -t $S -F '#{window_index}|#{window_name}' 2>&1) -join ";"
if ($rcC -ne 0 -and $winsAfter -notmatch "RENAMED") {
    Write-Pass "C: rename-window bad target rc=$rcC, no window renamed"
} elseif ($winsAfter -match "RENAMED") {
    Write-Fail "C: BUG - rename-window bad target rc=$rcC, ACTIVE window renamed ($winsAfter)"
} else {
    Write-Fail "C: rename-window bad target rc=$rcC (expected nonzero)"
}

# --- E. list-panes / clear-history on bad target ---
$out = & $PSMUX list-panes -t "${S}:nosuchwindow" -F '#{window_name} #{pane_id}' 2>&1
$rcE1 = $LASTEXITCODE
if ($rcE1 -ne 0) { Write-Pass "E1: list-panes bad target rc=$rcE1" }
else { Write-Fail "E1: BUG - list-panes bad target rc=0, answered for ACTIVE ($out)" }

$out = & $PSMUX clear-history -t "${S}:nosuchwindow" 2>&1
$rcE2 = $LASTEXITCODE
if ($rcE2 -ne 0) { Write-Pass "E2: clear-history bad target rc=$rcE2" }
else { Write-Fail "E2: BUG - clear-history bad target rc=0" }

# --- D. kill-pane DESTROYS the active window on bad target (do last) ---
$winsBefore = (& $PSMUX list-windows -t $S -F '#{window_index}' 2>&1).Count
$out = & $PSMUX kill-pane -t "${S}:nosuchwindow" 2>&1
$rcD = $LASTEXITCODE
Start-Sleep -Seconds 1
$winsAfterD = (& $PSMUX list-windows -t $S -F '#{window_index}' 2>&1).Count
if ($rcD -ne 0 -and $winsAfterD -eq $winsBefore) {
    Write-Pass "D: kill-pane bad target rc=$rcD, window count unchanged ($winsBefore)"
} elseif ($winsAfterD -lt $winsBefore) {
    Write-Fail "D: BUG - kill-pane bad target rc=$rcD DESTROYED active window ($winsBefore -> $winsAfterD)"
} else {
    Write-Fail "D: kill-pane bad target rc=$rcD (expected nonzero)"
}

# D2. bad pane id silently no-ops
$out = & $PSMUX kill-pane -t "${S}:%999" 2>&1
$rcD2 = $LASTEXITCODE
if ($rcD2 -ne 0) { Write-Pass "D2: kill-pane bad pane id rc=$rcD2" }
else { Write-Fail "D2: BUG - kill-pane -t S:%999 rc=0 silent" }

Cleanup
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
