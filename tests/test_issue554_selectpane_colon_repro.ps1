# Issue #554: select-pane exits 0 for any ':'-bearing target, valid or not.
# The #545 validator handles ':' forms but select-pane was left off its
# command list; the select-pane arm's own older validator skips anything
# containing ':'. tmux 3.4 errors (rc=1) on every unresolvable form.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t554"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #554 repro ===" -ForegroundColor Cyan

# Topology: window 0 (1 pane), window 1 (2 panes)
& $PSMUX new-session -d -s $S -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $S -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 2
& $PSMUX split-window -d -t "${S}:1" -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 2
$panes = (& $PSMUX list-panes -a -t $S -F '#{window_index}.#{pane_index}' 2>&1) -join ";"
Write-Host "  panes: $panes"
if ($panes -match "0\.0" -and $panes -match "1\.0" -and $panes -match "1\.1") { Write-Pass "setup: topology 0.0 / 1.0 / 1.1" }
else { Write-Fail "setup: unexpected topology $panes"; }

function Check-Bad([string]$Target, [string]$Label) {
    $out = & $PSMUX select-pane -t $Target 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Write-Pass "$Label rc=$rc ($out)" }
    else { Write-Fail "BUG: $Label rc=0 (no output, no error)" }
}

# All five forms from the issue must be rc=1
Check-Bad "${S}:0.99"   "select-pane -t S:0.99 (bad pane index)"
Check-Bad "${S}:0.%999" "select-pane -t S:0.%999 (bad pane id)"
Check-Bad "${S}:99"     "select-pane -t S:99 (bad window)"
Check-Bad "${S}:99.0"   "select-pane -t S:99.0 (bad window with pane)"
Check-Bad "${S}:0.1"    "select-pane -t S:0.1 (window 0 has no pane 1)"

# Controls: already-validated sibling forms
$out = & $PSMUX select-pane -t "${S}.99" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Pass "control: -t S.99 rc=1 ($out)" }
else { Write-Fail "control: -t S.99 rc=0" }
$out = & $PSMUX select-pane -t "%999" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Pass "control: -t %999 rc=1 ($out)" }
else { Write-Fail "control: -t %999 rc=0" }

# Positive controls: valid ':' targets still work and actually move focus
& $PSMUX select-window -t "${S}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX select-pane -t "${S}:1.1" 2>&1 | Out-Null
$rcP = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$active = (& $PSMUX display-message -p -t $S '#{window_index}.#{pane_index}' 2>&1 | Out-String).Trim()
if ($rcP -eq 0 -and $active -eq "1.1") { Write-Pass "positive: select-pane -t S:1.1 rc=0, active=$active" }
else { Write-Fail "positive: select-pane -t S:1.1 rc=$rcP active=$active" }

& $PSMUX select-pane -t "${S}:1.0" 2>&1 | Out-Null
$rcP2 = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$active = (& $PSMUX display-message -p -t $S '#{window_index}.#{pane_index}' 2>&1 | Out-String).Trim()
if ($rcP2 -eq 0 -and $active -eq "1.0") { Write-Pass "positive: select-pane -t S:1.0 rc=0, active=$active" }
else { Write-Fail "positive: select-pane -t S:1.0 rc=$rcP2 active=$active" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
