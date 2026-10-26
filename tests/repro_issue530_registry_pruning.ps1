# Issue #530: ~/.psmux accumulates .sid/.pid/.spawnlock files forever.
#
# Two defects, one symptom:
#   1. kill-server removed .port/.key/.pid but not .sid.
#   2. Every registry sweep enumerates .port files and deletes their siblings,
#      so any satellite that outlives its .port is unreachable forever.
#
# This script runs entirely inside a private data directory (USERPROFILE is
# redirected to a temp dir), so it can never read, prune, or otherwise disturb
# the real ~/.psmux or any psmux server running on this machine.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\repro_issue530_registry_pruning.ps1

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$psmux    = Join-Path $repoRoot 'target\debug\psmux.exe'
if (-not (Test-Path $psmux)) {
    Write-Host "FAIL: $psmux not found - run: cargo build --bin psmux" -ForegroundColor Red
    exit 1
}

$stamp   = (Get-Date).ToString('HHmmss')
$ns      = "psmux530e2e$PID$stamp"
$fakeDir = Join-Path $env:TEMP "psmux530home-$PID-$stamp"
$dataDir = Join-Path $fakeDir '.psmux'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$realProfile = $env:USERPROFILE
$failures    = @()

function Check($label, $condition, $detail) {
    if ($condition) {
        Write-Host "  PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $label" -ForegroundColor Red
        if ($detail) { Write-Host "        $detail" -ForegroundColor DarkGray }
        $script:failures += $label
    }
}

# Files in the private data dir, by name.
function DataFiles {
    @(Get-ChildItem $dataDir -File -EA SilentlyContinue | Select-Object -ExpandProperty Name)
}

function Backdate($path, $minutes) {
    $i = Get-Item $path
    $i.LastWriteTime = (Get-Date).AddMinutes(-$minutes)
}

# A PID that is certainly not running (and certainly not a psmux image).
function DeadPid {
    $p = 60000
    while (Get-Process -Id $p -EA SilentlyContinue) { $p += 7 }
    $p
}

try {
    $env:USERPROFILE = $fakeDir
    $env:PSMUX_NO_WARM = '1'

    Write-Host ''
    Write-Host "namespace : $ns"
    Write-Host "data dir  : $dataDir"
    Write-Host ''

    # ---------------------------------------------------------------------
    Write-Host '--- Scenario A: a live session writes a complete registry set ---'
    # ---------------------------------------------------------------------
    & $psmux -L $ns new-session -d -s work 2>&1 | Out-Null

    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $dataDir "${ns}__work.port"))) {
        Start-Sleep -Milliseconds 150
    }

    $created = DataFiles
    Check 'session registry set was created' `
        ($created -contains "${ns}__work.port" -and $created -contains "${ns}__work.sid") `
        ("saw: " + ($created -join ', '))

    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Scenario B: orphans are swept, the LIVE session is not ---'
    # ---------------------------------------------------------------------
    $dead = DeadPid

    # Orphans: no .port sibling, aged past the grace period.
    Set-Content -Path (Join-Path $dataDir 'ghost-a__probe.sid') -Value '11'
    Set-Content -Path (Join-Path $dataDir 'ghost-b__probe.sid') -Value '12'
    Set-Content -Path (Join-Path $dataDir 'ghost-c__probe.pid') -Value "${dead}:134301758043996634"
    Set-Content -Path (Join-Path $dataDir 'ghost-c__probe.sid') -Value '13'
    Set-Content -Path (Join-Path $dataDir 'ghost-d____warm__.spawnlock') -Value "$dead"
    foreach ($f in 'ghost-a__probe.sid','ghost-b__probe.sid','ghost-c__probe.pid','ghost-c__probe.sid','ghost-d____warm__.spawnlock') {
        Backdate (Join-Path $dataDir $f) 10
    }

    # Protected #1: an orphan written just now - indistinguishable from a server
    # still coming up, so the grace period must save it.
    Set-Content -Path (Join-Path $dataDir 'keep-young__starting.sid') -Value '22'

    # Protected #2: bystanders that are not registry satellites at all.
    Set-Content -Path (Join-Path $dataDir 'next_session_id') -Value '41'
    Backdate (Join-Path $dataDir 'next_session_id') 10

    # The sweep is rate-limited by a stamp file so it never runs on every
    # invocation. An earlier command in this scenario already stamped it, so
    # backdate the stamp to stand in for the interval having elapsed.
    $stamp = Join-Path $dataDir '.registry_sweep'
    if (-not (Test-Path $stamp)) { Set-Content -Path $stamp -Value '' }
    Backdate $stamp 10

    # Any psmux invocation runs the sweep at startup once it is due.
    & $psmux -L $ns list-sessions 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300

    $after = DataFiles

    Check 'orphaned .sid files were pruned' `
        (-not ($after -contains 'ghost-a__probe.sid') -and -not ($after -contains 'ghost-b__probe.sid')) `
        ("still present: " + (($after | Where-Object { $_ -like 'ghost-a*' -or $_ -like 'ghost-b*' }) -join ', '))

    Check 'orphan set with a DEAD pid anchor was pruned' `
        (-not ($after -contains 'ghost-c__probe.pid') -and -not ($after -contains 'ghost-c__probe.sid')) `
        ("still present: " + (($after | Where-Object { $_ -like 'ghost-c*' }) -join ', '))

    Check 'stale .spawnlock from a dead holder was reclaimed' `
        (-not ($after -contains 'ghost-d____warm__.spawnlock')) `
        'a lock whose holder was killed is never released by Drop'

    Check 'the LIVE session survived the sweep intact' `
        ($after -contains "${ns}__work.port" -and $after -contains "${ns}__work.sid") `
        ("live session files after sweep: " + (($after | Where-Object { $_ -like "${ns}__*" }) -join ', '))

    Check 'freshly written orphan survived (startup grace)' `
        ($after -contains 'keep-young__starting.sid') `
        'a server writes .sid before .port; deleting inside that window breaks startup'

    Check 'non-registry bystanders untouched' `
        ($after -contains 'next_session_id') `
        'the session-id counter is not a .port satellite'

    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Scenario C: kill-server must not strand the .sid ---'
    # ---------------------------------------------------------------------
    & $psmux -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400

    $afterKill = @(DataFiles | Where-Object { $_ -like "${ns}__*" })
    Check 'kill-server removed the ENTIRE registry set (incl. .sid)' `
        ($afterKill.Count -eq 0) `
        ("leftovers: " + ($afterKill -join ', '))
}
finally {
    & $psmux -L $ns kill-server 2>&1 | Out-Null
    $env:USERPROFILE = $realProfile
    Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue

    # Nothing from this run may outlive it. Scoped to our own build AND our own
    # namespace, so no other psmux server on this machine can be matched.
    $stray = @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $psmux -and $_.CommandLine -like "*$ns*" })
    foreach ($p in $stray) {
        Write-Host "  cleanup: terminating stray server pid $($p.ProcessId)" -ForegroundColor Yellow
        Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue
    }
    Remove-Item -Recurse -Force $fakeDir -EA SilentlyContinue
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'RESULT: PASS - registry satellites are cleaned up and live entries are preserved' -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: FAIL - $($failures.Count) check(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
