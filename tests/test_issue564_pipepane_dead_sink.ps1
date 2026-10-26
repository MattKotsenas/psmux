# Issue #564: pipe-pane -o toggled OFF against a dead sink because app.pipe_panes
# had no liveness check, so a sink that exits on its own left the pane marked as
# piped forever and every second re-arm was swallowed. The fix reaps exited
# entries (try_wait) before the toggle decision reads them.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = 'test564pp'; $D = 'C:/Temp/test564pp'
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

New-Item -ItemType Directory -Force ($D -replace '/','\') | Out-Null
Remove-Item "$D/*.txt" -Force -EA SilentlyContinue
& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S
Start-Sleep 3

Write-Host "=== Issue #564: pipe-pane -o against a dead sink ===" -ForegroundColor Cyan

# arm #1 (control): -o on a virgin pane starts the sink. The sink exits at once.
& $PSMUX pipe-pane -t "${S}:0" -o "echo armed-a1 > $D/a1.txt"
Start-Sleep 8
$a1 = Test-Path "$D/a1.txt"
if ($a1) { Pass "control: first -o armed the sink" } else { Fail "control invalid: first -o did not arm" }

# make the pane emit output so the dead sink's pipe takes a failing write
& $PSMUX send-keys -t "${S}:0" "echo hello1" Enter
Start-Sleep 3

# arm #2 (test): identical -o must RE-ARM, because the previous sink has exited.
& $PSMUX pipe-pane -t "${S}:0" -o "echo armed-a2 > $D/a2.txt"
Start-Sleep 12
$a2 = Test-Path "$D/a2.txt"
if ($a2) { Pass "-o re-armed against a dead sink" }
else { Fail "-o toggled off against a dead sink (capture silently lost)" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
