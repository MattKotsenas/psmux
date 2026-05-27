# test_detached_session_server_race.ps1 — regression test for cleanup_stale_port_files race
#
# Bug: cleanup_stale_port_files (called at every CLI startup) uses a 5ms TCP
# connect timeout to decide whether a port file refers to a live server. Under
# load (or just bad luck), a healthy server may take longer than 5ms to accept
# a localhost TCP connection. When that happens, the port file is deleted
# while the server is still running, and subsequent CLI commands fail with
# "no server running on session 'X'".
#
# Repro pattern: `new-session -d` + small sleep + `list-sessions` + `new-window`.
# Without the fix this fails ~40-50% of the time on a busy machine.
#
# Each CLI invocation runs cleanup_stale_port_files. The `list-sessions` step
# is what makes the failure rate spike: it keeps the alpha server briefly
# busy handling the request, increasing the chance the next CLI's cleanup
# scans the alpha port file while the alpha accept thread is slow to respond.

$ErrorActionPreference = "Continue"
# Prefer the freshly-built local binary over anything on PATH so this test
# actually exercises the in-tree code. Fall back to PATH when running outside
# the build tree.
$LocalPsmux = "$PSScriptRoot\..\target\release\psmux.exe"
if (Test-Path $LocalPsmux) {
    $PSMUX = (Resolve-Path $LocalPsmux).Path
} else {
    $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source
}
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$script:Passed = 0
$script:Failed = 0

function Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:Passed++ }
function Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red;   $script:Failed++ }
function Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Cyan }

# Unique socket name so this test is isolated from any user sessions and from
# parallel test runs.
$Sock = "race-test-$([System.Diagnostics.Process]::GetCurrentProcess().Id)-$(Get-Random)"

function CleanSocket() {
    & $PSMUX -L $Sock kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    Get-ChildItem "$env:USERPROFILE\.psmux\$Sock*" -ErrorAction SilentlyContinue |
        Remove-Item -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "================================================"
Write-Host "detached-session server race regression test"
Write-Host "  socket: $Sock"
Write-Host "================================================"
Write-Host ""

CleanSocket

# ═════════════════════════════════════════════
# Test: new-session + list-sessions + new-window
# ═════════════════════════════════════════════
# 20 iterations is enough that, with the pre-fix ~40% per-iteration failure
# rate, the chance of all 20 passing without the fix is < 1e-4. After the
# fix the chance of all 20 passing should be effectively 1.

Test "new-session/list-sessions/new-window must not race port-file cleanup (20 iterations)"
$iters = 20
$failures = New-Object System.Collections.ArrayList
for ($i = 1; $i -le $iters; $i++) {
    CleanSocket

    $newSessOut = & $PSMUX -L $Sock new-session -d -s alpha -n editor 2>&1
    $newSessExit = $LASTEXITCODE
    if ($newSessExit -ne 0) {
        [void]$failures.Add("iter $i`: new-session -d failed (exit=$newSessExit): $newSessOut")
        continue
    }
    # 50ms sleep is the sweet spot — long enough that the warm-server claim
    # has returned OK to the client but short enough that the alpha server
    # may still be busy spawning its replacement warm server.
    Start-Sleep -Milliseconds 50

    $listOut = & $PSMUX -L $Sock list-sessions 2>&1
    if ($LASTEXITCODE -ne 0) {
        [void]$failures.Add("iter $i`: list-sessions failed (exit=$LASTEXITCODE): $listOut")
        continue
    }

    $newWinOut = & $PSMUX -L $Sock new-window -t alpha -n logs 2>&1
    if ($LASTEXITCODE -ne 0) {
        [void]$failures.Add("iter $i`: new-window failed (exit=$LASTEXITCODE): $newWinOut")
    }
}

if ($failures.Count -eq 0) {
    Pass "all $iters iterations passed without 'no server running' errors"
} else {
    Fail "$($failures.Count)/$iters iterations failed:"
    foreach ($f in $failures) { Write-Host "    $f" -ForegroundColor Yellow }
}

# Final cleanup
CleanSocket

Write-Host ""
Write-Host "================================================"
Write-Host "Results: $script:Passed passed, $script:Failed failed"
Write-Host "================================================"

if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
