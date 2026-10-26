# Issue #551: display-message -p -t <window> '#{window_active}' returns 1 for
# ANY targeted window, including non-active ones. list-windows reports the
# same windows correctly, so the two read paths disagree.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t551"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #551 repro ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $S -n w0 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $S -n w1 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 2
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Ground truth via list-windows
$lw = (& $PSMUX list-windows -t $S -F 'idx=#{window_index} active=#{window_active}' 2>&1) -join ";"
Write-Host "  list-windows: $lw"
if ($lw -match "idx=0 active=1" -and $lw -match "idx=1 active=0") { Write-Pass "control: list-windows reports w0 active, w1 not" }
else { Write-Fail "control: unexpected list-windows state: $lw" }

# Targeting the ACTIVE window: active=1 is correct
$d0 = (& $PSMUX display-message -p -t "${S}:0" 'idx=#{window_index} active=#{window_active}' 2>&1 | Out-String).Trim()
if ($d0 -eq "idx=0 active=1") { Write-Pass "display-message -t S:0 (active window): $d0" }
else { Write-Fail "display-message -t S:0 expected 'idx=0 active=1', got '$d0'" }

# Targeting the NON-active window: idx must be 1, active must be 0
$d1 = (& $PSMUX display-message -p -t "${S}:1" 'idx=#{window_index} active=#{window_active}' 2>&1 | Out-String).Trim()
if ($d1 -eq "idx=1 active=0") { Write-Pass "display-message -t S:1 (non-active window): $d1" }
elseif ($d1 -match "idx=1 active=1") { Write-Fail "BUG: display-message -t S:1 reports active=1 for non-active window ($d1)" }
else { Write-Fail "display-message -t S:1 unexpected output '$d1'" }

# By name too
$dn = (& $PSMUX display-message -p -t "${S}:w1" 'idx=#{window_index} active=#{window_active}' 2>&1 | Out-String).Trim()
if ($dn -eq "idx=1 active=0") { Write-Pass "display-message -t S:w1 (by name): $dn" }
else { Write-Fail "display-message -t S:w1 expected 'idx=1 active=0', got '$dn'" }

# The active window must NOT have visibly changed for other observers
$lw2 = (& $PSMUX list-windows -t $S -F 'idx=#{window_index} active=#{window_active}' 2>&1) -join ";"
if ($lw2 -match "idx=0 active=1") { Write-Pass "active window unchanged after targeted display-message" }
else { Write-Fail "active window CHANGED after targeted display-message: $lw2" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
