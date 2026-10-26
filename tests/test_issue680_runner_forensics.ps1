# Issue #680: the runner's forensics must survive the thing that ends the runner.
#
# Twice in two days a sweep vanished mid stride with nothing written anywhere.
# The shape of it was settled by one detail: the spawn attribution watcher, a
# separate process with its OWN console, writes a "# stopped" footer on every
# voluntary exit including the one it takes when it sees the runner is gone, and
# neither dead run's trace has that footer. So the watcher was terminated in the
# same second as the runner, although it shares no console with it.
#
# Only two mechanisms reproduce that, and both are TerminateProcess, so nothing
# inside the dying process can record them: a job object with KILL_ON_JOB_CLOSE
# at or above the runner, and a tree kill aimed at an ancestor. This suite holds
# the forensics that were added for it to the standard the incident set.
#
# EVERYTHING HERE IS SELF CONTAINED. It starts its own stand in processes, it
# ends only pids it started itself, by pid, and it never kills by image name and
# never touches psmux. It does not run the real runner.
$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
function Write-Pass { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function Write-Info { param($m) Write-Host "  $m" -ForegroundColor DarkGray }

$testsDir = $PSScriptRoot
$sandbox  = Join-Path $env:TEMP ("psmux_i680_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

# Every process this suite creates, so teardown is by pid and nothing else.
$script:MyPids = @()
function Start-Mine {
    param([string[]]$PsArgs)
    $p = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass') + $PsArgs)
    $script:MyPids += $p.Id
    return $p
}
function Stop-Mine {
    foreach ($p in ($script:MyPids | Sort-Object -Unique)) {
        if ($p -gt 0) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
}

# The stand in for run_all_tests.ps1: it loads the REAL forensics module.
$standIn = Join-Path $sandbox 'standin.ps1'
@'
param([string]$RunDir, [string]$Tests, [int]$LiveSeconds, [switch]$CleanEnd)
$script:AuditOwnPids = @{}
. (Join-Path $Tests 'run_forensics.ps1')
Initialize-RunForensics -RunDir $RunDir -RunId 'issue680'
$parent = [int](Get-CimInstance -Query "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=$PID").ParentProcessId
$third  = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep 90')
@(
  "self=$(Test-KillTargetSafe -TargetPid $PID -Reason 'i680 self' -Tree)",
  "parent=$(Test-KillTargetSafe -TargetPid $parent -Reason 'i680 parent' -Tree)",
  "third=$(Test-KillTargetSafe -TargetPid $third.Id -Reason 'i680 third party' -Tree)",
  "system=$(Test-KillTargetSafe -TargetPid 4 -Reason 'i680 system pid' -Tree)",
  "thirdpid=$($third.Id)"
) | Set-Content (Join-Path $RunDir 'verdicts.txt')
Stop-Process -Id $third.Id -Force -ErrorAction SilentlyContinue
Set-Content (Join-Path $RunDir 'standin.pid') "$PID"
Start-Sleep -Seconds $LiveSeconds
if ($CleanEnd) { Complete-RunForensics -Status 'issue680 clean end' }
'@ | Set-Content -Path $standIn -Encoding UTF8

function New-RunDir {
    param([string]$Tag)
    $d = Join-Path $sandbox $Tag
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content (Join-Path $d 'progress.log') "[i680] --- [588/731] Queuing test_newsession_flags ---"
    Set-Content (Join-Path $d 'current_suite.txt') 'test_newsession_flags'
    return $d
}

function Wait-File {
    param([string]$Path, [int]$Seconds = 30)
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if (Test-Path $Path) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

Write-Host "`n=== Issue #680: runner forensics ===" -ForegroundColor Cyan
Write-Host "sandbox: $sandbox" -ForegroundColor DarkGray

try {

# ── 1. Identity, ledger, and a witness that is outside our jobs ─────────────
Write-Host "`n[1] a runner that vanishes leaves a snapshot behind" -ForegroundColor Yellow
$rd = New-RunDir 'vanish'
$null = Start-Mine @('-File', $standIn, '-RunDir', $rd, '-Tests', $testsDir, '-LiveSeconds', '90')

if (-not (Wait-File (Join-Path $rd 'standin.pid') 45)) {
    Write-Fail "1.0: the stand in runner never started"
} else {
    $spid = [int](Get-Content (Join-Path $rd 'standin.pid') -Raw).Trim()
    $script:MyPids += $spid
    Write-Info "stand in runner pid $spid"

    $idFile = Join-Path $rd 'runner_identity.log'
    if (Wait-File $idFile 20) {
        $id = Get-Content $idFile -Raw
        if ($id -match "runner pid=$spid\b")            { Write-Pass "1.1: identity records the runner pid and start time" }
        else                                            { Write-Fail "1.1: identity has no runner pid line" }
        if ($id -match '(?m)^\[.*\] ancestry\[1\] pid=') { Write-Pass "1.2: identity records the ancestry above the runner with creation times" }
        else                                            { Write-Fail "1.2: identity records no ancestor" }
        if ($id -match 'job inJob=')                    { Write-Pass "1.3: identity records job membership and limit flags" }
        else                                            { Write-Fail "1.3: identity records no job membership" }
        if ($id -match 'console attached pid=')         { Write-Pass "1.4: identity records every process attached to the runner's console" }
        else                                            { Write-Fail "1.4: identity records no console process list" }
    } else { Write-Fail "1.1: no runner_identity.log was written" }

    # The kill ledger. A tree kill of the runner or an ancestor must be refused,
    # because that is precisely the shape that ends a run with nothing written.
    if (Wait-File (Join-Path $rd 'verdicts.txt') 25) {
        $v = @{}
        foreach ($line in (Get-Content (Join-Path $rd 'verdicts.txt'))) {
            $bits = $line -split '=', 2
            if ($bits.Count -eq 2) { $v[$bits[0]] = $bits[1] }
        }
        if ($v['self']   -eq 'False') { Write-Pass "1.5: a tree kill aimed at the runner itself is refused" }
        else                          { Write-Fail "1.5: a tree kill aimed at the runner was ALLOWED" }
        if ($v['parent'] -eq 'False') { Write-Pass "1.6: a tree kill aimed at an ancestor of the runner is refused" }
        else                          { Write-Fail "1.6: a tree kill aimed at an ancestor was ALLOWED" }
        if ($v['system'] -eq 'False') { Write-Pass "1.7: a kill aimed at a system pid is refused" }
        else                          { Write-Fail "1.7: a kill aimed at pid 4 was ALLOWED" }
        # The guard must not turn into a blanket refusal: the suite teardown it
        # sits in front of has to keep working.
        if ($v['third']  -eq 'True')  { Write-Pass "1.8: a tree kill of an unrelated process is still allowed" }
        else                          { Write-Fail "1.8: the ledger refused a legitimate kill" }
        if ($v['thirdpid']) { $script:MyPids += [int]$v['thirdpid'] }
    } else { Write-Fail "1.5: the ledger verdicts were never written" }

    $wdLog = Join-Path $rd 'watchdog.log'
    if (Wait-File $wdLog 25) {
        $wl = Get-Content $wdLog -Raw
        if ($wl -match 'inJob=False') { Write-Pass "1.9: the watchdog is outside every job the runner is in" }
        else { Write-Fail "1.9: the watchdog is inside a job, so it dies with the run it is meant to describe" }
    } else { Write-Fail "1.9: the watchdog never started" }

    # Now take the runner away without an end marker, which is the incident.
    Write-Info "ending the stand in runner by pid, with no end marker"
    Stop-Process -Id $spid -Force -ErrorAction SilentlyContinue
    $snap = Join-Path $rd 'runner_vanished.log'
    if (Wait-File $snap 40) {
        # The watchdog writes this snapshot line by line over a second or more
        # (chain, verdict, progress tail, kill ledger, process list, event log),
        # and the file exists from its first line. Reading it the moment it
        # appears races the writer: in sweep 2026-10-01_01-53-14 the read landed
        # after the chain lines and before the verdict, so 1.10 and 1.11 passed
        # and 1.12 to 1.14 failed on a half written file. Judge it only once
        # the writer has put down its own closing line.
        $s = ''
        $snapEnd = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $snapEnd) {
            $s = Get-Content $snap -Raw -ErrorAction SilentlyContinue
            if ("$s" -match '===== end of snapshot =====') { break }
            Start-Sleep -Milliseconds 300
        }
        if ("$s" -notmatch '===== end of snapshot =====') {
            Write-Fail "1.10: the watchdog did not finish its snapshot within 60 s ($("$s".Length) bytes so far); the checks below see a partial file"
        }
        if ($s -match 'runner pid=')                   { Write-Pass "1.10: the vanish was recorded with the window the death falls in" }
        else                                           { Write-Fail "1.10: the snapshot names no runner" }
        if ($s -match '(?m)^\[.*\] chain pid=')        { Write-Pass "1.11: the snapshot says which ancestors went and which survived" }
        else                                           { Write-Fail "1.11: the snapshot says nothing about the ancestry" }
        if ($s -match '(?m)^\[.*\] verdict ')          { Write-Pass "1.12: the snapshot commits to a verdict" }
        else                                           { Write-Fail "1.12: the snapshot has no verdict line" }
        if ($s -match 'Queuing test_newsession_flags') { Write-Pass "1.13: the snapshot carries the tail of progress.log" }
        else                                           { Write-Fail "1.13: the snapshot has no progress.log tail" }
        if ($s -match 'KILL-REFUSED')                  { Write-Pass "1.14: the snapshot carries the kill ledger" }
        else                                           { Write-Fail "1.14: the snapshot has no kill ledger" }
    } else { Write-Fail "1.10: no runner_vanished.log was written for a runner that disappeared" }
}

# ── 2. A run that ends properly must produce no alarm ───────────────────────
Write-Host "`n[2] a clean end leaves no snapshot and no stray watchdog" -ForegroundColor Yellow
$rd2 = New-RunDir 'clean'
# A stale end marker is what -Resume finds in a reused run directory. It must be
# cleared, or the new run's watchdog leaves before it has watched anything.
Set-Content (Join-Path $rd2 'runner_end.marker') '2026-01-01 00:00:00.000 finished pid=1'
$p2 = Start-Mine @('-File', $standIn, '-RunDir', $rd2, '-Tests', $testsDir, '-LiveSeconds', '8', '-CleanEnd')
$p2.WaitForExit(90000) | Out-Null
if ($p2.HasExited -and $p2.ExitCode -eq 0) { Write-Pass "2.1: a clean run still exits 0 with the forensics loaded" }
else { Write-Fail "2.1: the stand in exited $($p2.ExitCode) with the forensics loaded" }

Start-Sleep -Seconds 5
if (-not (Test-Path (Join-Path $rd2 'runner_vanished.log'))) { Write-Pass "2.2: a clean end raises no vanish snapshot" }
else { Write-Fail "2.2: a clean end was reported as a disappearance" }

$wd2 = Join-Path $rd2 'watchdog.log'
if (Test-Path $wd2) {
    $w2 = Get-Content $wd2 -Raw
    if ($w2 -match 'watchdog exiting: runner wrote its end marker') { Write-Pass "2.3: the watchdog leaves on the end marker" }
    else { Write-Fail "2.3: the watchdog did not leave on the end marker" }
    # It cleared the stale marker on start, or it would have left immediately.
    if ($w2 -match 'tracking \d+ process') { Write-Pass "2.4: a stale end marker from a resumed run does not retire the watchdog early" }
    else { Write-Fail "2.4: the watchdog never got as far as tracking anything" }
} else { Write-Fail "2.3: no watchdog log for the clean run" }

$gasp = Join-Path $rd2 'last_gasp.log'
if ((Test-Path $gasp) -and ((Get-Content $gasp -Raw) -match 'PowerShell.Exiting')) {
    Write-Pass "2.5: the engine exit hook records a last gasp on an ordinary exit"
} else { Write-Fail "2.5: PowerShell.Exiting recorded nothing" }

# Nothing of ours may still be running: a watchdog that outlives its run is
# exactly the stray process the runner audits for.
$stray = @(Get-CimInstance -Query "SELECT ProcessId,CommandLine FROM Win32_Process WHERE Name='pwsh.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -match [regex]::Escape($sandbox) })
if ($stray.Count -eq 0) { Write-Pass "2.6: no watchdog or stand in outlives its run" }
else { Write-Fail "2.6: $($stray.Count) process(es) from this suite are still running" }

} finally {
    Stop-Mine
    Start-Sleep -Milliseconds 500
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "PASS: $pass" -ForegroundColor Green
Write-Host "FAIL: $fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 }
exit 0
