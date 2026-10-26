# Issue #458: kill-session -t <name> on a -L socket returns success but the session survives
#
# Reporter (v3.3.6, Win10 19045, over an SSH exec channel) created per-session servers with
#   psmux -L <name> new-session -s <name> -d -- <cmd>
# and observed that `kill-session -t <name>` exited 0 but the session stayed listed and its
# pane process kept running, while `kill-server` on the same socket worked. Their build hosted
# both the named session AND the internal __warm__ helper in ONE server; that co-residency was
# the trigger. On current master each session (and __warm__) runs as its own server, so
# kill-session tears down the whole server. This test LOCKS IN that correct behavior: a
# kill-session on a -L socket must actually destroy the session (silent success-without-effect
# is the exact failure the reporter hit).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

# has-session exit code: 0 = exists, non-zero = gone
function Test-Alive([string]$Namespace, [string]$Target) {
    & $PSMUX -L $Namespace has-session -t $Target 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Cleanup([string]$Namespace) {
    & $PSMUX -L $Namespace kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Namespace`__*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #458: kill-session on a -L socket must destroy the session ===" -ForegroundColor Cyan

# === TEST 1: reporter's exact invocation - kill-session actually kills ===
Write-Host "`n[Test 1] -L socket, new-session -s NAME -d -- <durable child>, kill-session -t NAME" -ForegroundColor Yellow
$NS1 = "issue458_a"
Cleanup $NS1
# cmd /k is a durable foreground pane child (stands in for the reporter's agent process)
& $PSMUX -L $NS1 new-session -s $NS1 -d -- cmd /k 2>&1 | Out-Null
Start-Sleep -Seconds 3

if (Test-Alive $NS1 $NS1) { Write-Pass "session created and alive before kill" }
else { Write-Fail "session did not come up (setup failed)" }

$lsBefore = (& $PSMUX -L $NS1 ls 2>&1 | Out-String)
# Match the listing line shape ("name: N windows"), not the bare name: since
# 2502955 an empty ls prints "no server running on <dir> (-L <ns>)", and the
# namespace here is the session name, so a bare match would hit the message.
if ($lsBefore -match ('(?m)^(?:[^\s:]+__)?' + [regex]::Escape($NS1) + ':')) { Write-Pass "ls lists the session before kill" }
else { Write-Fail "ls did not list the session before kill: $lsBefore" }

& $PSMUX -L $NS1 kill-session -t $NS1 2>$null | Out-Null
$killRc = $LASTEXITCODE
if ($killRc -eq 0) { Write-Pass "kill-session returned success (rc=0)" }
else { Write-Fail "kill-session returned rc=$killRc" }

Start-Sleep -Seconds 2

# THE REGRESSION GUARD: after a successful kill-session, the session MUST be gone.
if (-not (Test-Alive $NS1 $NS1)) { Write-Pass "has-session reports the session GONE after kill (bug #458 fixed)" }
else { Write-Fail "BUG #458: kill-session returned success but session SURVIVES (has-session still 0)" }

$lsAfter = (& $PSMUX -L $NS1 ls 2>&1 | Out-String)
if ($lsAfter -notmatch ('(?m)^(?:[^\s:]+__)?' + [regex]::Escape($NS1) + ':')) { Write-Pass "ls no longer lists the session after kill" }
else { Write-Fail "BUG #458: ls still lists the session after a 'successful' kill-session: $lsAfter" }
Cleanup $NS1

# === TEST 2: identical socket name and session name (reporter used the same string for both) ===
Write-Host "`n[Test 2] -L NAME and -t NAME are the same string" -ForegroundColor Yellow
$NS2 = "issue458_samename"
Cleanup $NS2
& $PSMUX -L $NS2 new-session -s $NS2 -d -- cmd /k 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (Test-Alive $NS2 $NS2) {
    & $PSMUX -L $NS2 kill-session -t $NS2 2>$null | Out-Null
    Start-Sleep -Seconds 2
    if (-not (Test-Alive $NS2 $NS2)) { Write-Pass "kill-session works when socket==session name" }
    else { Write-Fail "BUG #458: session survived kill when socket==session name" }
} else { Write-Fail "setup failed (session not alive)" }
Cleanup $NS2

# === TEST 3: multi-session namespace - kill one, the other must survive (correct targeting) ===
Write-Host "`n[Test 3] two sessions on one -L socket, kill one, other survives" -ForegroundColor Yellow
$NS3 = "issue458_multi"
Cleanup $NS3
& $PSMUX -L $NS3 new-session -s sessA -d -- cmd /k 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX -L $NS3 new-session -s sessB -d -- cmd /k 2>&1 | Out-Null
Start-Sleep -Seconds 2
if ((Test-Alive $NS3 "sessA") -and (Test-Alive $NS3 "sessB")) {
    & $PSMUX -L $NS3 kill-session -t sessA 2>$null | Out-Null
    Start-Sleep -Seconds 2
    if (-not (Test-Alive $NS3 "sessA")) { Write-Pass "targeted session sessA killed" }
    else { Write-Fail "BUG #458: sessA survived a targeted kill-session" }
    if (Test-Alive $NS3 "sessB") { Write-Pass "non-targeted session sessB survived (no collateral / wrong-target kill)" }
    else { Write-Fail "sessB was wrongly killed" }
} else { Write-Fail "setup failed (both sessions not alive)" }
Cleanup $NS3

# === TEST 4: repeated reaper pattern - session stays gone across repeated kills ===
Write-Host "`n[Test 4] reporter reaper pattern: repeated kill-session leaves session gone" -ForegroundColor Yellow
$NS4 = "issue458_reap"
Cleanup $NS4
& $PSMUX -L $NS4 new-session -s $NS4 -d -- cmd /k 2>&1 | Out-Null
Start-Sleep -Seconds 3
$survived = $false
for ($i = 0; $i -lt 4; $i++) {
    & $PSMUX -L $NS4 kill-session -t $NS4 2>$null | Out-Null
    Start-Sleep -Milliseconds 700
    if (Test-Alive $NS4 $NS4) { $survived = $true }
}
if (-not $survived) { Write-Pass "session never survived across 4 reaper-style kills" }
else { Write-Fail "BUG #458: session was still alive after a kill-session in the reaper loop" }
Cleanup $NS4

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
