# Issue #546: cleanup_stale_port_files' pre-boot mtime guard reaps a LIVE
# session's registry before the PID anchor can veto it, and the orphan reaper
# then kills its server. Trigger: any psmux invocation (even -V) after the
# .port mtime falls behind the derived boot time (wall-clock step, VM restore,
# backup restore). Backdating the .port mtime is algebraically identical to a
# forward wall-clock step with uptime unchanged (see issue).
#
# Expected (tmux parity): liveness is decided by the process table, a live
# server is never reaped by a metadata heuristic. The .pid anchor (which keeps
# today's mtime and returns Some(true)) must veto the boot guard.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t546hunt"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #546 repro ===" -ForegroundColor Cyan

# 1. Park a session and age it past ORPHAN_REAP_MIN_AGE (10s) so the orphan
#    reaper is allowed to consider it and the 5s registry self-heal cannot
#    mask the deletion.
& $PSMUX new-session -d -s $S -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "setup: session not created"; exit 1 }

# Find the server PID from the .pid anchor (format pid:creation)
$pidRaw = (Get-Content "$psmuxDir\$S.pid" -Raw -EA SilentlyContinue).Trim()
$srvPid = [int]($pidRaw -split ':')[0]
Write-Host "  server pid: $srvPid"
Write-Host "  aging session 15s past ORPHAN_REAP_MIN_AGE..."
Start-Sleep -Seconds 15

& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "setup: session alive after aging" }
else { Write-Fail "setup: session died during aging"; exit 1 }

# 2. Simulate the forward wall-clock step: backdate ONLY the .port mtime.
#    .pid keeps today's mtime so pid_anchor_verdict would return Some(true).
(Get-Item "$psmuxDir\$S.port").LastWriteTime = [datetime]'2020-01-01T10:00:00'
Write-Pass "backdated $S.port mtime to 2020-01-01"

# 3. Any psmux invocation at all: a version banner suffices.
$env:PSMUX_SESSION_DEBUG = "1"
& $PSMUX -V 2>&1 | Out-Null
$rcV = $LASTEXITCODE
$env:PSMUX_SESSION_DEBUG = $null
Start-Sleep -Seconds 2

# 4. Verdict: session must still be alive, registry intact, server running.
$portThere = Test-Path "$psmuxDir\$S.port"
$pidThere = Test-Path "$psmuxDir\$S.pid"
$procAlive = $null -ne (Get-Process -Id $srvPid -EA SilentlyContinue)
& $PSMUX has-session -t $S 2>$null
$hasRc = $LASTEXITCODE

if ($portThere -and $pidThere) { Write-Pass "registry files survive psmux -V (rc=$rcV)" }
else { Write-Fail "BUG: registry reaped by psmux -V (port=$portThere pid=$pidThere)" }

if ($procAlive) { Write-Pass "server pid $srvPid still running" }
else { Write-Fail "BUG: server pid $srvPid was terminated" }

if ($hasRc -eq 0) { Write-Pass "has-session still rc=0" }
else { Write-Fail "BUG: has-session rc=$hasRc, session gone" }

# Show debug log lines if the reap fired
$dbg = "$psmuxDir\session_debug.log"
if (Test-Path $dbg) {
    $lines = Get-Content $dbg -Tail 10 | Where-Object { $_ -match "reap" }
    if ($lines) { Write-Host "  debug log:"; $lines | ForEach-Object { Write-Host "    $_" } }
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
