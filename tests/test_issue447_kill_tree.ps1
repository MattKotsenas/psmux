# Issue #447: PID-reuse guard must NOT regress normal process-tree teardown.
#
# This E2E proves that after adding the creation-time reuse guard, killing a
# session still tears down a REAL descendant process launched inside a pane
# (pane shell -> ping). If the guard were too aggressive it would leave the
# ping orphaned; if teardown works the ping PID is gone.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue447_tree"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Get-PingPids {
    (Get-Process -Name PING -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
}

Cleanup
Write-Host "`n=== Issue #447: process-tree teardown regression ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; Cleanup; exit 1 }
Write-Pass "Session created"

$rootPid = (& $PSMUX display-message -t $SESSION -p '#{pane_pid}' 2>&1).Trim()
Write-Host "  pane root pid = $rootPid" -ForegroundColor DarkGray

# Snapshot pre-existing ping PIDs so we can isolate the one WE launch.
$before = @(Get-PingPids)

# Launch a long-lived descendant inside the pane (shell -> ping).
& $PSMUX send-keys -t $SESSION "ping -n 600 127.0.0.1" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

$after = @(Get-PingPids)
$ourPings = @($after | Where-Object { $before -notcontains $_ })

if ($ourPings.Count -ge 1) {
    Write-Pass "Descendant ping spawned inside pane (pid(s): $($ourPings -join ','))"
} else {
    Write-Fail "Could not spawn/identify a descendant ping process"
    Cleanup
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)"
    exit 1
}

# Kill the session -> should tear down the whole tree including the ping.
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

# Poll for the descendant to actually die.
$dead = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $live = @(Get-PingPids)
    $stillOurs = @($ourPings | Where-Object { $live -contains $_ })
    if ($stillOurs.Count -eq 0) { $dead = $true; break }
}

if ($dead) {
    Write-Pass "kill-session tore down the descendant ping (tree teardown intact, no orphan)"
} else {
    Write-Fail "Descendant ping survived kill-session (ORPHAN LEAK / guard too aggressive)"
    # Best-effort cleanup of the leaked pings.
    foreach ($p in $ourPings) { Stop-Process -Id $p -Force -EA SilentlyContinue }
}

Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
