# Issue #549: set-hook -g is accepted and listed by show-hooks -g but the
# hook never fires. The identical hook set session-scoped (set-hook -t S)
# fires correctly.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t549"
$psmuxDir = "$env:USERPROFILE\.psmux"
$logDir = "$env:TEMP\psmux_t549"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
Remove-Item $logDir -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host "`n=== Issue #549 repro ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $S -n w0 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $S -n w1 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 2
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$glog = "$logDir\g1.log" -replace '\\','/'

# --- Global hook ---
$ghookCmd = 'run-shell "' + "'GLOBAL' | Out-File -Append -Encoding ascii '$glog'" + '"'
& $PSMUX set-hook -t $S -g after-select-window $ghookCmd 2>&1 | Out-Null
$rcSet = $LASTEXITCODE
Start-Sleep -Milliseconds 300
$hooks = (& $PSMUX show-hooks -g -t $S 2>&1) -join ";"
Write-Host "  show-hooks -g: $hooks"
if ($rcSet -eq 0 -and $hooks -match "after-select-window") { Write-Pass "global hook accepted and listed (rc=0)" }
else { Write-Fail "global hook not listed (rc=$rcSet): $hooks" }

& $PSMUX select-window -t "${S}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 3

if (Test-Path "$logDir\g1.log") { Write-Pass "GLOBAL hook fired ($((Get-Content "$logDir\g1.log").Count) entries)" }
else { Write-Fail "BUG: global after-select-window hook never fired (no log file)" }

# --- Control: identical hook, session-scoped ---
& $PSMUX set-hook -t $S -g -u after-select-window 2>&1 | Out-Null
$slog = "$logDir\s1.log" -replace '\\','/'
$shookCmd = 'run-shell "' + "'SESSION' | Out-File -Append -Encoding ascii '$slog'" + '"'
& $PSMUX set-hook -t $S after-select-window $shookCmd 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

& $PSMUX select-window -t "${S}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 3

if (Test-Path "$logDir\s1.log") { Write-Pass "control: session-scoped hook fires ($((Get-Content "$logDir\s1.log").Count) entries)" }
else { Write-Fail "control: session-scoped hook did not fire either (different bug?)" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
