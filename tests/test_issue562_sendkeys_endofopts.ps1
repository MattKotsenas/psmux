# Issue #562: send-keys had no end-of-options state, so `--` and any dash-leading
# operand were silently discarded at rc 0. The fix teaches the send-keys server
# handler that a bare `--` terminates flag parsing and everything after it is an
# operand. This test proves `--` rescues a dash-leading literal.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = 'test562dash'
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Last($w){ (& $PSMUX capture-pane -p -t "${S}:$w" 2>&1 | Where-Object { $_ -match '\S' } | Select-Object -Last 1) }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S -c C:\Temp
foreach ($w in 'ctrl','dashdash') { & $PSMUX new-window -t $S -n $w -c C:\Temp | Out-Null }
Start-Sleep -Seconds 4

Write-Host "=== Issue #562: send-keys -- end-of-options ===" -ForegroundColor Cyan

# Control: a leading 'a' means the payload is not a dash token -> always delivered.
& $PSMUX send-keys -t "${S}:ctrl" -l 'a-please continue now'
# Test: -- must let the dash-leading literal through.
& $PSMUX send-keys -t "${S}:dashdash" -l -- '-please continue now'
Start-Sleep -Seconds 3

$ctrl = Last 'ctrl'
$dd = Last 'dashdash'
if ($ctrl -match 'a-please continue now') { Pass "control delivered (probe valid)" }
else { Fail "control not delivered: [$ctrl]" }

if ($dd -match '-please continue now') { Pass "-- delivered the dash-leading literal" }
else { Fail "-- did not rescue dash-leading payload: [$dd]" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
