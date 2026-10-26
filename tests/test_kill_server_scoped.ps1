# Integration: kill-server's force-kill fallback is scoped to its own data dir
# and namespace, and verifies process identity (pid + creation time) before
# terminating. It no longer scans the machine by executable name.
#
# The test exploits the very property under test: because the fallback no longer
# checks the name, an ordinary unrelated process serves as a stand-in for a
# "wedged" server. We start a harmless long-lived pwsh (Start-Sleep), write a
# {pid}:{creation_filetime} pid file for it, run kill-server, and observe whether
# it is terminated. The probe never speaks the control protocol, so the graceful
# pass cannot stop it -- only the force-kill fallback can.
#
# SAFE TO RUN ALONGSIDE REAL psmux SESSIONS: precisely because the name scan is
# gone, kill-server here touches only this temp HOME's registry plus the probe
# pid we authored. (Against a pre-fix binary the bare kill-server below would
# TerminateProcess every psmux.exe on the machine -- do NOT run this on one.)
#
# Removal recipe: delete if force_kill_targets / confirms_identity are removed.

$ErrorActionPreference = "Stop"

# This test issues a REAL kill-server. If it is pointed at a binary that still
# has the old name-based sweep -- a stale build, or the psmux on PATH -- that
# bare kill-server terminates every psmux/pmux/tmux process on the machine.
# Refuse to run unless the caller has confirmed a throwaway environment, exactly
# as run_all_tests.ps1 does. The Docker dev image / CI set this automatically.
# This gate MUST stay before any kill-server call.
if ($env:PSMUX_TEST_SANDBOX -ne '1') {
    Write-Host ''
    Write-Host 'REFUSING TO RUN: this test issues a real kill-server.' -ForegroundColor Red
    Write-Host 'Against a pre-fix or PATH psmux that would terminate every' -ForegroundColor Yellow
    Write-Host 'psmux/pmux/tmux process on the machine. Run only in a sandbox.' -ForegroundColor Yellow
    Write-Host 'To confirm a sandbox and run against a freshly built binary:' -ForegroundColor Yellow
    Write-Host '    $env:PSMUX_TEST_SANDBOX = "1"; $env:PSMUX_EXE = "<freshly built psmux.exe>"' -ForegroundColor Cyan
    Write-Host '    pwsh -File tests\test_kill_server_scoped.ps1' -ForegroundColor Cyan
    Write-Host ''
    exit 2
}

$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) { Write-Host "FATAL: psmux not found ($PSMUX)" -ForegroundColor Red; exit 1 }

$shell = if (Get-Command pwsh -EA SilentlyContinue) { 'pwsh' } else { 'powershell' }

$tmpHome = Join-Path $env:TEMP ("psmux_killscope_" + [guid]::NewGuid().ToString("N").Substring(0,8))
$psmuxDir = Join-Path $tmpHome ".psmux"
New-Item -ItemType Directory $psmuxDir -Force | Out-Null

# Isolate HOME and scrub session vars so a runner inside a psmux session does not
# retarget commands or trip the nesting guard.
$savedUP = $env:USERPROFILE; $savedHOME = $env:HOME
$savedSession = $env:PSMUX_SESSION; $savedTarget = $env:PSMUX_TARGET_SESSION
$savedTmux = $env:TMUX; $savedTmuxPane = $env:TMUX_PANE
$env:USERPROFILE = $tmpHome; $env:HOME = $tmpHome
Remove-Item Env:\PSMUX_SESSION,Env:\PSMUX_TARGET_SESSION,Env:\TMUX,Env:\TMUX_PANE -EA SilentlyContinue

$probes = @()
$pass = 0; $fail = 0
function Write-Result($name, $ok, $msg) {
    if ($ok) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  [FAIL] $name : $msg" -ForegroundColor Red; $script:fail++ }
}

# Start a harmless long-lived process we fully control; return its pid and the
# creation FILETIME exactly as our pid file records it. .NET StartTime ->
# ToFileTimeUtc is the same 100ns-ticks-since-1601-UTC value psmux reads from
# GetProcessTimes, so the recorded pid file matches what the fallback queries.
function Start-Probe {
    $p = Start-Process $shell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60' `
        -PassThru -WindowStyle Hidden
    $script:probes += $p.Id
    $ft = (Get-Process -Id $p.Id).StartTime.ToFileTimeUtc()
    return [pscustomobject]@{ Pid = $p.Id; FileTime = $ft }
}

function Test-Alive($procId) { $null -ne (Get-Process -Id $procId -EA SilentlyContinue) }

function Wait-Dead($procId, $ms) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if (-not (Test-Alive $procId)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return -not (Test-Alive $procId)
}

function Reset-PidFiles { Get-ChildItem $psmuxDir -Filter *.pid -EA SilentlyContinue | Remove-Item -Force }
function Write-PidFile($base, $procId, $fileTime) {
    Set-Content -Path (Join-Path $psmuxDir "$base.pid") -Value ("{0}:{1}" -f $procId, $fileTime) -NoNewline
}

Write-Host ""
Write-Host "=== kill-server force-kill fallback: scoped + identity-checked ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX" -ForegroundColor DarkGray

try {
    # Case 1: in-scope wedged server with a matching identity -> reaped.
    # The base name is bare, so it belongs to the DEFAULT namespace, which is
    # the only thing a bare kill-server is allowed to touch since #649.
    Reset-PidFiles
    $p1 = Start-Probe
    Write-PidFile "scopedvictim" $p1.Pid $p1.FileTime
    & $PSMUX kill-server 2>&1 | Out-Null
    Write-Result "in-scope probe with matching identity is force-killed" (Wait-Dead $p1.Pid 4000) `
        "probe $($p1.Pid) still alive after kill-server"

    # Case 2: same pid but wrong creation time (simulated pid reuse) -> spared.
    Reset-PidFiles
    $p2 = Start-Probe
    Write-PidFile "scopedreuse" $p2.Pid ($p2.FileTime + 99999)
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Write-Result "probe with a mismatched creation time (pid reuse) is spared" (Test-Alive $p2.Pid) `
        "probe $($p2.Pid) was killed despite a creation-time mismatch"

    # Case 3: probe registered under namespace 'a', kill-server -L b -> spared.
    Reset-PidFiles
    $p3 = Start-Probe
    Write-PidFile "a__victim" $p3.Pid $p3.FileTime
    & $PSMUX -L b kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Write-Result "probe in another namespace is spared by -L b kill-server" (Test-Alive $p3.Pid) `
        "probe $($p3.Pid) in namespace 'a' was killed by -L b kill-server"

    # Case 4 (#649): a namespaced probe is spared by a BARE kill-server, which
    # scopes to the default namespace exactly as tmux scopes to its socket.
    Reset-PidFiles
    $p4 = Start-Probe
    Write-PidFile "a__victim" $p4.Pid $p4.FileTime
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Write-Result "probe in namespace 'a' is spared by a bare kill-server" (Test-Alive $p4.Pid) `
        "probe $($p4.Pid) in namespace 'a' was killed by a bare kill-server"

    # Case 5 (#649): -a is the explicit everything sweep and still reaches it.
    & $PSMUX kill-server -a 2>&1 | Out-Null
    Write-Result "kill-server -a reaches every namespace" (Wait-Dead $p4.Pid 4000) `
        "probe $($p4.Pid) in namespace 'a' survived kill-server -a"
}
finally {
    foreach ($id in $probes) { Stop-Process -Id $id -Force -EA SilentlyContinue }
    $env:USERPROFILE = $savedUP; $env:HOME = $savedHOME
    if ($null -ne $savedSession) { $env:PSMUX_SESSION = $savedSession }
    if ($null -ne $savedTarget)  { $env:PSMUX_TARGET_SESSION = $savedTarget }
    if ($null -ne $savedTmux)     { $env:TMUX = $savedTmux }
    if ($null -ne $savedTmuxPane) { $env:TMUX_PANE = $savedTmuxPane }
    Remove-Item -Recurse -Force $tmpHome -EA SilentlyContinue
}

Write-Host ""
Write-Host "=== Results: $pass passed, $fail failed ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
