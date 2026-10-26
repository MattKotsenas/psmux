# Issue #510: a psmux invocation resolving one data dir must never terminate
# servers belonging to another.
#
# The startup reaper enumerates candidates machine-wide but drew its authority
# from a single ~/.psmux resolved from USERPROFILE/HOME, so anything that
# registry did not account for was killed as an "orphan". Any invocation under a
# different home therefore destroyed every other instance's live sessions.
#
# SHAPE OF THE TEST
#   victim   - a real server in the NORMAL data dir under a unique -L namespace,
#              per AGENTS.md. It must outlive the reaper's 10s grace window to
#              be eligible for reaping at all, which is why it cannot live in a
#              throwaway home: psmux servers under a redirected USERPROFILE/HOME
#              shut themselves down after ~10s on Windows (reproducible with the
#              reaper compiled out, so it is unrelated to this fix), and would
#              vanish before the scenario begins.
#   intruder - a read-only command run under a throwaway home. That empty data
#              dir can account for nothing on this machine, which is exactly the
#              redirected-HOME harness / MSYS2 / second-account case.
#
# The assertion is that the victim survives the intruder.
#
# SAFETY: Get-PsmuxExe resolves the locally BUILT binary (PSMUX_EXE, then
# target\release, then target\debug) and never PATH. That matters more here than
# in most tests: the intruder step against a PRE-FIX binary is precisely the
# operation that kills every psmux session on the machine, including the user's
# own. Do not point PSMUX_EXE at an installed build.

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot 'psmux_test_helpers.ps1')

$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_issue510_foreign_server_survives.ps1 starts a real psmux server." -ForegroundColor DarkYellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 to run (CI sets CI/GITHUB_ACTIONS)." -ForegroundColor DarkYellow
    exit 0
}

$script:Passed = 0
$script:Failed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }
function Is-PidAlive($procId) {
    if (-not ("$procId" -match '^\d+$')) { return $false }
    $p = Get-Process -Id ([int]$procId) -EA SilentlyContinue
    return ($null -ne $p -and -not $p.HasExited)
}

Write-Host "`n=== Issue #510: a foreign data dir must not reap our servers ===" -ForegroundColor Cyan

$exe = Get-PsmuxExe
Write-Host "    binary under test: $exe" -ForegroundColor DarkGray

$ns = "i510victim"
$psmuxDir = Join-Path $env:USERPROFILE '.psmux'
$intruderHome = $null
$savedProfile = $env:USERPROFILE
$savedHome = $env:HOME

# Snapshot every live psmux server up front. The whole point of the fix is that
# this set is untouched by an unrelated invocation, so it doubles as the blast
# radius check: if the fix regressed, this is what names the casualties.
$liveBefore = @(Get-Process -Name psmux, pmux, tmux -EA SilentlyContinue | ForEach-Object { $_.Id })
Write-Host "    live psmux servers before: $($liveBefore -join ', ')" -ForegroundColor DarkGray

try {
    # ---- The victim: a healthy server in the normal data dir ---------------
    & $exe -L $ns new-session -d -s survivor 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $pidFile = Join-Path $psmuxDir "${ns}__survivor.pid"
    if (-not (Test-Path $pidFile)) {
        Write-Fail "victim did not register a .pid ($pidFile); cannot run the scenario"
        throw "setup failed"
    }
    $victimPid = ((Get-Content $pidFile -Raw).Trim() -split ':')[0]
    if (Is-PidAlive $victimPid) { Write-Pass "victim server $victimPid is live" }
    else { Write-Fail "victim server $victimPid is not alive"; throw "setup failed" }

    # The reaper spares anything inside its 10s grace window, so a young victim
    # would survive even a pre-fix build and prove nothing.
    Write-Host "    aging victim past the 10s reap grace window..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 12
    if (-not (Is-PidAlive $victimPid)) {
        Write-Fail "victim died while aging; environment cannot sustain the scenario"
        throw "setup failed"
    }
    Write-Pass "victim survived to eligible age (reaping is now possible)"

    # A real server must have self-declared ownership: the marker is the only
    # thing that will ever again authorise a reap, so its absence would mean
    # #448 cleanup silently stopped working for every new server.
    $markerFile = Join-Path $psmuxDir "servers\$victimPid"
    if (Test-Path $markerFile) {
        $markerBody = (Get-Content $markerFile -Raw).Trim()
        if ($markerBody -match "^$victimPid`:\d+$") { Write-Pass "victim wrote an identity-gated ownership marker ($markerBody)" }
        else { Write-Fail "marker body is not pid:creation_filetime, got '$markerBody'" }
    } else {
        Write-Fail "victim never wrote its ownership marker ($markerFile)"
    }

    # ---- The intruder: an unrelated home that must keep its hands off ------
    $intruderHome = Join-Path $env:TEMP ("psmux_i510intruder_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $intruderHome '.psmux') -Force | Out-Null
    $env:USERPROFILE = $intruderHome
    $env:HOME = $intruderHome

    & $exe -L i510intruder list-sessions 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    if (Is-PidAlive $victimPid) { Write-Pass "victim $victimPid SURVIVED a foreign-home invocation" }
    else { Write-Fail "victim $victimPid was reaped by a foreign-home invocation (#510)" }

    # The reaper runs on EVERY invocation, so one survival could be luck.
    for ($i = 0; $i -lt 3; $i++) {
        & $exe -L i510intruder list-sessions 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
    }
    if (Is-PidAlive $victimPid) { Write-Pass "victim survived repeated foreign-home reaper passes" }
    else { Write-Fail "victim was reaped by a later foreign-home reaper pass" }

    # Not SEEING another home's sessions is correct; killing them is not.
    $seen = (& $exe -L i510intruder list-sessions 2>&1 | Out-String).Trim()
    if ($seen -notmatch 'survivor') { Write-Pass "intruder correctly does not see the victim's session" }
    else { Write-Fail "intruder unexpectedly listed the victim's session: $seen" }

    $env:USERPROFILE = $savedProfile
    $env:HOME = $savedHome
}
finally {
    $env:USERPROFILE = $savedProfile
    $env:HOME = $savedHome
    if ($intruderHome) { Remove-Item -Recurse -Force $intruderHome -EA SilentlyContinue }
    # Scoped teardown only: never a bare kill-server, which would hit every
    # namespace including the user's own sessions (AGENTS.md).
    & $exe -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item (Join-Path $psmuxDir "${ns}__*") -Force -EA SilentlyContinue
}

# Nothing outside the victim's namespace may have died.
$liveAfter = @(Get-Process -Name psmux, pmux, tmux -EA SilentlyContinue | ForEach-Object { $_.Id })
$lost = @($liveBefore | Where-Object { $_ -notin $liveAfter })
if ($lost.Count -eq 0) { Write-Pass "no pre-existing psmux server was terminated by this test" }
else { Write-Fail "pre-existing psmux servers were terminated: $($lost -join ', ')" }

# The dead victim's marker must be reconciled away on a reap pass from OUR
# home, so the marker dir tracks live servers rather than growing forever.
# The victim may still be mid-exit right after kill-server, and a claim on a
# still-live process is correctly retained, so wait for the process to be
# fully gone before judging the prune.
if ($victimPid) {
    for ($i = 0; $i -lt 40 -and (Is-PidAlive $victimPid); $i++) { Start-Sleep -Milliseconds 250 }
    $markerFile = Join-Path $psmuxDir "servers\$victimPid"
    $pruned = $false
    for ($i = 0; $i -lt 3; $i++) {
        & $exe -L i510prunepass list-sessions 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $markerFile)) { $pruned = $true; break }
    }
    if ($pruned) { Write-Pass "dead victim's marker was pruned on a reap pass" }
    else { Write-Fail "dead victim's marker lingered across reap passes ($markerFile)" }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Passed)" -ForegroundColor Green
Write-Host "  Failed: $($script:Failed)" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
exit $script:Failed
