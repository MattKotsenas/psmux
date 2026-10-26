# Issue #677: the standby must come back on its own, and a spawn lock left by a
# holder that is gone must not keep it missing.
#
# The standby is a separate server process named __warm__ whose whole purpose is
# that `new-session` does not have to pay for a cold spawn. It used to be
# spawned from exactly two places, a server starting up and a claim being
# answered, with nothing retrying, and the lock that serialises the spawn was
# judged stale by the file's AGE alone rather than by whether the process named
# in it still existed.
#
# Measured before the fix, in an isolated data root:
#   - standby killed with a live session beside it: no standby returned in 90 s
#   - a lock naming a dead pid: no standby after a creation (12 s), none after a
#     further 25 s, and one appeared instantly on the NEXT creation once the age
#     rule finally allowed the steal
#
# Everything here runs in a private -L namespace and a private data root, and
# nothing is ever killed by image name.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$Ns = "i677_$PID"
$DataDir = Join-Path ([IO.Path]::GetTempPath()) "psmux_i677_$PID"
$env:PSMUX_DATA_DIR = $DataDir
New-Item -ItemType Directory -Force $DataDir | Out-Null
$base = "$($Ns)____warm__"
$lock = Join-Path $DataDir "$base.spawnlock"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Cyan }

function WarmPort { $p = Join-Path $DataDir "$base.port"; if (Test-Path $p) { (Get-Content $p -Raw).Trim() } else { "" } }
# The .pid body is a pid anchor, "<pid>:<creation-time>", not a bare pid.
function WarmPid { $p = Join-Path $DataDir "$base.pid"; if (Test-Path $p) { ((Get-Content $p -Raw).Trim() -split ':')[0] } else { "" } }

function WarmAlive {
    $p = WarmPort
    if (-not $p) { return $false }
    try { $t = [Net.Sockets.TcpClient]::new("127.0.0.1", [int]$p); $t.Close(); return $true } catch { return $false }
}
function WaitWarm([int]$sec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        if (WarmAlive) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 300
    }
    return -1
}
# Kill the standby by PID, only ever after confirming that pid is a psmux.
function KillWarm {
    $wp = WarmPid
    if (-not $wp) { return $false }
    $pr = Get-CimInstance Win32_Process -Filter "ProcessId=$wp" -EA SilentlyContinue
    if (-not $pr -or $pr.Name -ne 'psmux.exe') { return $false }
    Stop-Process -Id ([int]$wp) -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
    return -not [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$wp" -EA SilentlyContinue)
}
function Nuke {
    & $PSMUX -L $Ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Get-ChildItem (Join-Path $DataDir "$($Ns)__*") -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #677: standby recovery ===" -ForegroundColor Cyan
Write-Info "binary: $PSMUX"
Write-Info "namespace: $Ns  data root: $DataDir"

# ---------------------------------------------------------------- Test 1
# A standby that dies must come back while a server is up, with no help.
Write-Host "`n[Test 1] a standby that dies comes back on its own" -ForegroundColor Yellow
Nuke
& $PSMUX -L $Ns new-session -d -s live 2>&1 | Out-Null
if ((WaitWarm 30) -lt 0) {
    Write-Fail "no standby appeared after the first session, cannot test recovery"
} else {
    Write-Pass "a standby exists after the first session"
    if (-not (KillWarm)) {
        Write-Fail "could not kill the standby by pid, skipping the recovery check"
    } else {
        Write-Info "standby killed; watching for a replacement with the session still up"
        $back = WaitWarm 45
        if ($back -ge 0) { Write-Pass "a standby returned on its own after ${back}s" }
        else { Write-Fail "no standby returned in 45s (before the fix: none in 90s)" }
        & $PSMUX -L $Ns has-session -t live 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Pass "the session that was up stayed up" }
        else { Write-Fail "the session died while the standby was replaced" }
    }
}

# ---------------------------------------------------------------- Test 2
# A lock left by a holder that no longer exists must not block the spawn.
Write-Host "`n[Test 2] a spawn lock naming a dead process does not block the standby" -ForegroundColor Yellow
Nuke
& $PSMUX -L $Ns new-session -d -s live2 2>&1 | Out-Null
$null = WaitWarm 30
$null = KillWarm
Get-ChildItem (Join-Path $DataDir "$base.*") -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
# 4294967280 is above any live pid and owned by nothing: a holder that died
# before it could drop its guard.
Set-Content -Path $lock -Value "4294967280" -Encoding ASCII
Write-Info "planted a spawn lock naming a dead pid"
& $PSMUX -L $Ns new-session -d -s live3 2>&1 | Out-Null
$got = WaitWarm 30
if ($got -ge 0) { Write-Pass "the standby appeared ${got}s after the creation despite the stale lock" }
else { Write-Fail "no standby in 30s with a stale lock present (before the fix: none, and the lock stayed)" }
# The abandoned lock is cleared by the spawner taking the lock for itself, and
# the standby's port file can appear about 200 ms before that spawner releases
# its own guard (measured 3 of 3 on 2026-10-05 after the boot hold moved the
# standby spawn past the first shell: content "<live pid>:<start>" at the
# instant the port file lands, gone 200 ms later). So the dead pid must be gone
# now, and the file itself within a bound that a live holder honours.
$content = try { (Get-Content $lock -Raw -EA Stop).Trim() } catch { "" }
if ($content -ne "4294967280") { Write-Pass "the abandoned lock was cleared (lock now '$content')" }
else { Write-Fail "the abandoned lock is still on disk with the dead pid" }
$released = $false
for ($i = 0; $i -lt 30; $i++) {
    if (-not (Test-Path $lock)) { $released = $true; break }
    Start-Sleep -Milliseconds 100
}
if ($released) { Write-Pass "the spawner released its own lock within $($i * 100) ms of the standby appearing" }
else { Write-Fail "a lock is still on disk 3 s after the standby appeared: '$(try { (Get-Content $lock -Raw).Trim() } catch { '' })'" }

# ---------------------------------------------------------------- Test 3
# The lock still does its job: a spawn that is genuinely in progress keeps it,
# or two callers would each spawn a standby.
Write-Host "`n[Test 3] a lock held by a live process is still respected" -ForegroundColor Yellow
Nuke
& $PSMUX -L $Ns new-session -d -s live4 2>&1 | Out-Null
$null = WaitWarm 30
$null = KillWarm
Get-ChildItem (Join-Path $DataDir "$base.*") -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
# This very shell is alive, so a lock naming it reads as a spawn in progress.
Set-Content -Path $lock -Value "$PID" -Encoding ASCII
Write-Info "planted a spawn lock naming this live shell (pid $PID)"
$held = WaitWarm 12
if ($held -lt 0) { Write-Pass "no standby was spawned while a live holder held the lock" }
else { Write-Fail "a standby appeared after ${held}s even though the lock was held by a live process" }
Remove-Item $lock -Force -EA SilentlyContinue
Write-Info "lock released; the standby should now come back without another command"
$after = WaitWarm 45
if ($after -ge 0) { Write-Pass "the standby returned ${after}s after the lock was released" }
else { Write-Fail "no standby returned in 45s after the lock was released" }

Nuke
Remove-Item $DataDir -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
