# Issue #510 follow-up: field-data claim about the startup orphan reaper's reach.
#
# Claim under test (acoliver, 2026-08-03 comment on #510):
#   "I currently have 23 orphaned servers on this machine across 9 distinct -L
#    namespaces, all started between 17:23 and 18:39, every one of them with a
#    dead parent process. They survived more than five hours under the current
#    broad, namespace-blind reaper. So whatever cross-namespace protection
#    #448's reach is meant to provide, it did not fire for these."
#
# The claim contains two separable assertions:
#   A. A psmux server whose parent process is dead survives repeated psmux
#      invocations in other -L namespaces, indefinitely.
#   B. That survival means #448's reaper "did not fire" / the broad reach is
#      already failing to collect cross-namespace orphans.
#
# This suite proves A, and determines whether B follows from it, by measuring
# the ACTUAL discriminator between a reaped server and a surviving one.
#
# Layers: PowerShell E2E via CLI + registry files + live process inspection.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

# Namespaces used by this suite. All live in the same data dir (psmux_dir()
# ignores -L; the namespace is only a filename prefix), which is precisely the
# configuration the reporter describes.
$NS = @("f510a", "f510b", "f510c", "f510d")
$PROBE_NS = "f510probe"

function Get-ServerPid {
    param([string]$Ns, [string]$Sess)
    $pf = "$psmuxDir\${Ns}__${Sess}.pid"
    if (-not (Test-Path $pf)) { return 0 }
    $raw = (Get-Content $pf -Raw).Trim()
    if ($raw -match '^(\d+)') { return [int]$Matches[1] }
    return 0
}

function Test-Alive {
    param([int]$ProcId)
    if ($ProcId -le 0) { return $false }
    $p = Get-Process -Id $ProcId -EA SilentlyContinue
    return ($null -ne $p)
}

function Get-ParentPid {
    param([int]$ProcId)
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -EA SilentlyContinue
    if ($null -eq $ci) { return -1 }
    return [int]$ci.ParentProcessId
}

function New-Victim {
    param([string]$Ns, [string]$Sess)
    & $PSMUX -L $Ns new-session -d -s $Sess 2>&1 | Out-Null
    $pf = "$psmuxDir\${Ns}__${Sess}.port"
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path $pf) {
            $sp = Get-ServerPid $Ns $Sess
            if (Test-Alive $sp) { return $sp }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

function Invoke-Probe {
    param([string]$Ns = $PROBE_NS)
    # A read-only invocation in a DIFFERENT namespace. This is the code path
    # that ran the reaper in the original #510 incident.
    & $PSMUX -L $Ns list-sessions 2>&1 | Out-Null
}

function Remove-RegistryClaim {
    param([string]$Ns, [string]$Sess)
    # Simulate the run_all_tests.ps1 / crashed-harness case: the registry files
    # that make a server "tracked" are gone, but the server process lives on.
    Remove-Item "$psmuxDir\${Ns}__${Sess}.port" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\${Ns}__${Sess}.key"  -Force -EA SilentlyContinue
}

function Cleanup-All {
    foreach ($n in ($NS + @($PROBE_NS))) {
        & $PSMUX -L $n kill-server 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 800
    foreach ($n in ($NS + @($PROBE_NS))) {
        Get-Process psmux -EA SilentlyContinue | ForEach-Object {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA SilentlyContinue
            if ($ci -and $ci.CommandLine -match [regex]::Escape("-L $n ")) {
                Stop-Process -Id $_.Id -Force -EA SilentlyContinue
            }
        }
        Remove-Item "$psmuxDir\${n}__*" -Force -EA SilentlyContinue
    }
}

Write-Host "`n=== Issue #510 follow-up: orphan reaper reach (field-data claim) ===" -ForegroundColor Cyan
Cleanup-All

# ---------------------------------------------------------------------------
# TEST 1: A detached session server is an "orphan" by the reporter's definition
#         (its parent process is dead) the moment it is created.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 1] Detached session server has a dead parent by construction" -ForegroundColor Yellow
$pidA = New-Victim $NS[0] "vic"
if ($pidA -gt 0) {
    Write-Info "victim server pid=$pidA on -L $($NS[0])"
    $ppid = Get-ParentPid $pidA
    $parentAlive = Test-Alive $ppid
    Write-Info "parent pid=$ppid alive=$parentAlive"
    if (-not $parentAlive) {
        Write-Pass "Server pid=$pidA has a dead parent (pid=$ppid) -> matches reporter's 'orphaned server' definition"
    } else {
        Write-Fail "Parent pid=$ppid is still alive; cannot classify as orphan"
    }
} else {
    Write-Fail "Could not create victim session on -L $($NS[0])"
}

# ---------------------------------------------------------------------------
# TEST 2: Such a server still owns a LIVE, USABLE session.
#         (Distinguishes 'orphan garbage' from 'working detached session'.)
# ---------------------------------------------------------------------------
Write-Host "`n[Test 2] The dead-parent server still serves a live session" -ForegroundColor Yellow
& $PSMUX -L $NS[0] has-session -t "vic" 2>$null
if ($LASTEXITCODE -eq 0) {
    $sn = (& $PSMUX -L $NS[0] display-message -t "vic" -p '#{session_name}' 2>&1 | Out-String).Trim()
    if ($sn -eq "vic") { Write-Pass "has-session=0 and display-message returns 'vic' -> live functional session, not garbage" }
    else { Write-Fail "has-session ok but display-message returned '$sn'" }
} else {
    Write-Fail "has-session failed for the dead-parent server"
}

# ---------------------------------------------------------------------------
# TEST 3: THE CLAIM. Aged past the grace window, the dead-parent server
#         survives repeated invocations in OTHER namespaces.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 3] Dead-parent server survives repeated foreign-namespace invocations" -ForegroundColor Yellow
Write-Info "aging past the 10s reap grace window..."
Start-Sleep -Seconds 12
$survivedAll = $true
for ($i = 1; $i -le 4; $i++) {
    Invoke-Probe
    Start-Sleep -Milliseconds 700
    if (-not (Test-Alive $pidA)) { $survivedAll = $false; Write-Info "killed on pass $i"; break }
}
# Also a probe from a second real namespace and from the default namespace.
& $PSMUX -L $NS[1] new-session -d -s "vic2" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX list-sessions 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
if (-not (Test-Alive $pidA)) { $survivedAll = $false }

if ($survivedAll) {
    & $PSMUX -L $NS[0] has-session -t "vic" 2>$null
    $stillUsable = ($LASTEXITCODE -eq 0)
    Write-Pass "CLAIM CONFIRMED: dead-parent server survived 6 cross-namespace invocations past the grace window (still usable=$stillUsable)"
} else {
    Write-Fail "Dead-parent server was killed by a cross-namespace invocation"
}

# ---------------------------------------------------------------------------
# TEST 4: The discriminator. Same server, same namespace, same age, same dead
#         parent -- but with its registry claim removed, it IS reaped.
#         This isolates WHY test 3's server survived.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 4] Discriminator: an UNTRACKED dead-parent server is reaped" -ForegroundColor Yellow
$pidC = New-Victim $NS[2] "vic"
if ($pidC -gt 0) {
    Write-Info "victim pid=$pidC on -L $($NS[2]); aging past grace..."
    Start-Sleep -Seconds 12
    Remove-RegistryClaim $NS[2] "vic"
    Write-Info "registry claim (.port/.key) removed; server process still alive=$(Test-Alive $pidC)"
    $reaped = $false
    for ($i = 1; $i -le 4; $i++) {
        Invoke-Probe
        Start-Sleep -Milliseconds 900
        if (-not (Test-Alive $pidC)) { $reaped = $true; Write-Info "reaped on pass $i"; break }
    }
    if ($reaped) {
        Write-Pass "Untracked dead-parent server WAS reaped -> reaper fires; #448 reach is intact"
    } else {
        Write-Fail "Untracked dead-parent server survived -> reaper genuinely not firing"
    }
} else {
    Write-Fail "Could not create victim on -L $($NS[2])"
}

# ---------------------------------------------------------------------------
# TEST 5: Namespace-blindness of that reach, measured directly.
#         The reap in test 4 was triggered from -L $PROBE_NS against a server
#         on -L f510c. Re-run explicitly from a third namespace to confirm the
#         reach crosses namespaces (this is what policy (3) would change).
# ---------------------------------------------------------------------------
Write-Host "`n[Test 5] The reach that DOES fire is namespace-blind" -ForegroundColor Yellow
$pidD = New-Victim $NS[3] "vic"
if ($pidD -gt 0) {
    Start-Sleep -Seconds 12
    Remove-RegistryClaim $NS[3] "vic"
    $reaped = $false
    for ($i = 1; $i -le 4; $i++) {
        & $PSMUX -L $NS[1] list-sessions 2>&1 | Out-Null   # a DIFFERENT real namespace
        Start-Sleep -Milliseconds 900
        if (-not (Test-Alive $pidD)) { $reaped = $true; break }
    }
    if ($reaped) {
        Write-Pass "Untracked server on -L $($NS[3]) reaped by an invocation on -L $($NS[1]) -> reach is namespace-blind"
    } else {
        Write-Fail "Cross-namespace reap did not occur"
    }
} else {
    Write-Fail "Could not create victim on -L $($NS[3])"
}

# ---------------------------------------------------------------------------
# TEST 6: The one way a live untracked server IS immune post-#514: no marker.
#         (The documented compatibility direction -- servers from builds that
#         predate the ownership marker are never reaped.)
# ---------------------------------------------------------------------------
Write-Host "`n[Test 6] Untracked server with no ownership marker is immune (compat direction)" -ForegroundColor Yellow
$pidE = New-Victim $NS[2] "vicnm"
if ($pidE -gt 0) {
    Start-Sleep -Seconds 12
    Remove-RegistryClaim $NS[2] "vicnm"
    $marker = "$psmuxDir\servers\$pidE"
    $hadMarker = Test-Path $marker
    Remove-Item $marker -Force -EA SilentlyContinue
    Write-Info "marker existed=$hadMarker, now removed (simulates a pre-#514 server)"
    # Distinguish "a probe reaped it" from "it went away on its own". Removing
    # the registry claim above is exactly the state a server self exits from in
    # some paths, so a victim that is already gone BEFORE the first probe proves
    # nothing about the reaper's polarity. Without this the failure said only
    # "was reaped", which is ambiguous: this suite failed once in the sweep of
    # 2026-09-16 and passed 3 of 3 standalone straight afterwards, and the log
    # could not say which of the two had happened.
    $diedBeforeAnyProbe = -not (Test-Alive $pidE)
    if ($diedBeforeAnyProbe) {
        Write-Info "victim exited after the registry claim was removed, before any probe ran"
    }
    $survived = $true
    $diedOnPass = 0
    for ($i = 1; $i -le 4; $i++) {
        Invoke-Probe
        Start-Sleep -Milliseconds 900
        if (-not (Test-Alive $pidE)) { $survived = $false; $diedOnPass = $i; break }
    }
    if (-not $survived) { Write-Info "victim gone after probe pass $diedOnPass (died before any probe: $diedBeforeAnyProbe)" }
    if ($hadMarker -and $survived) {
        Write-Pass "Marker-less untracked server survived all passes -> only marker-claimed servers are reapable"
    } elseif (-not $hadMarker) {
        Write-Fail "Live server never wrote an ownership marker (expected servers\$pidE)"
    } else {
        Write-Fail "Marker-less server was reaped -> polarity fix not holding (died before any probe: $diedBeforeAnyProbe, on pass: $diedOnPass)"
    }
    Stop-Process -Id $pidE -Force -EA SilentlyContinue
} else {
    Write-Fail "Could not create victim on -L $($NS[2]) for marker test"
}

# ---------------------------------------------------------------------------
# TEST 7: Where dead-parent servers actually come from. Each namespace gets a
#         warm helper whose parent is the session server that spawned it. When
#         that session server exits, the helper becomes a dead-parent server.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 7] Warm helper outlives the session server that spawned it" -ForegroundColor Yellow
$warmPid = Get-ServerPid $NS[0] "__warm__"
if ($warmPid -gt 0 -and (Test-Alive $warmPid)) {
    $wppid = Get-ParentPid $warmPid
    Write-Info "warm pid=$warmPid parent=$wppid (session server pid=$pidA), parentAlive=$(Test-Alive $wppid)"
    # Terminate the whole namespace the way a user would.
    & $PSMUX -L $NS[0] kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $sessionServerGone = -not (Test-Alive $pidA)
    $warmStillAlive = Test-Alive $warmPid
    $warmTracked = Test-Path "$psmuxDir\$($NS[0])____warm__.port"
    Write-Info "after kill-server: sessionServerGone=$sessionServerGone warmAlive=$warmStillAlive warmTracked=$warmTracked"
    if ($sessionServerGone -and $warmStillAlive) {
        Write-Pass "LEAK CONFIRMED: kill-server removed the session server but the namespace's warm helper survives as a dead-parent server (tracked=$warmTracked)"
        $script:WarmLeak = $true
    } elseif ($sessionServerGone -and -not $warmStillAlive) {
        Write-Pass "kill-server collected the warm helper as well (no per-namespace residue)"
        $script:WarmLeak = $false
    } else {
        Write-Fail "Session server pid=$pidA survived kill-server"
    }
} else {
    Write-Info "No warm helper for -L $($NS[0]) (PSMUX_NO_WARM or already gone); skipping"
}

# ---------------------------------------------------------------------------
# TEST 8: If the helper leaked, does ANY invocation ever collect it?
#         This is the reporter's steady state: N ephemeral namespaces, each
#         leaving one permanently immune dead-parent server behind.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 8] Nothing collects a leaked warm helper" -ForegroundColor Yellow
if ($script:WarmLeak) {
    Start-Sleep -Seconds 12
    $stillThere = $true
    for ($i = 1; $i -le 5; $i++) {
        Invoke-Probe
        & $PSMUX list-sessions 2>&1 | Out-Null
        & $PSMUX -L $NS[1] list-sessions 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        if (-not (Test-Alive $warmPid)) { $stillThere = $false; Write-Info "collected on pass $i"; break }
    }
    if ($stillThere) {
        Write-Pass "Leaked warm helper pid=$warmPid survived 15 invocations past the grace window -> permanent per-namespace residue"
    } else {
        Write-Fail "Leaked warm helper was collected after all"
    }
    Stop-Process -Id $warmPid -Force -EA SilentlyContinue
} else {
    Write-Info "No leak observed in test 7; skipping"
}

# ---------------------------------------------------------------------------
# TEST 9: kill-session teardown path (not kill-server). Does the namespace's
#         warm helper survive the death of the last real session?
# ---------------------------------------------------------------------------
Write-Host "`n[Test 9] kill-session teardown: does the warm helper survive?" -ForegroundColor Yellow
$pidK = New-Victim $NS[1] "vick"
Start-Sleep -Seconds 3
$warmK = Get-ServerPid $NS[1] "__warm__"
if ($pidK -gt 0 -and $warmK -gt 0 -and (Test-Alive $warmK)) {
    & $PSMUX -L $NS[1] kill-session -t "vick" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $sess = -not (Test-Alive $pidK)
    $warmAlive = Test-Alive $warmK
    Write-Info "after kill-session: sessionServerGone=$sess warmAlive=$warmAlive"
    if ($sess -and $warmAlive) {
        Write-Pass "RESIDUE: kill-session leaves the namespace warm helper pid=$warmK alive with a dead parent"
        $script:Residue9 = $warmK
    } elseif ($sess) {
        Write-Pass "kill-session also collected the warm helper"
        $script:Residue9 = 0
    } else {
        Write-Fail "Session server survived kill-session"
        $script:Residue9 = 0
    }
} else {
    Write-Info "Setup incomplete (pidK=$pidK warmK=$warmK); skipping"
    $script:Residue9 = 0
}

# ---------------------------------------------------------------------------
# TEST 10: Crash teardown path. Force-kill the session server (harness kill,
#          machine churn, taskkill) and see what the namespace leaves behind.
# ---------------------------------------------------------------------------
Write-Host "`n[Test 10] Crash teardown: force-kill the session server" -ForegroundColor Yellow
$pidX = New-Victim $NS[2] "vicx"
Start-Sleep -Seconds 3
$warmX = Get-ServerPid $NS[2] "__warm__"
if ($pidX -gt 0 -and $warmX -gt 0 -and (Test-Alive $warmX)) {
    Stop-Process -Id $pidX -Force -EA SilentlyContinue
    Start-Sleep -Seconds 3
    $warmAlive = Test-Alive $warmX
    $warmTracked = Test-Path "$psmuxDir\$($NS[2])____warm__.port"
    $victimTracked = Test-Path "$psmuxDir\$($NS[2])__vicx.port"
    Write-Info "after force-kill: warmAlive=$warmAlive warmTracked=$warmTracked deadSessionStillTracked=$victimTracked"
    if ($warmAlive) {
        Start-Sleep -Seconds 12
        $survived = $true
        for ($i = 1; $i -le 5; $i++) {
            Invoke-Probe
            & $PSMUX list-sessions 2>&1 | Out-Null
            Start-Sleep -Milliseconds 800
            if (-not (Test-Alive $warmX)) { $survived = $false; Write-Info "collected on pass $i"; break }
        }
        if ($survived) {
            Write-Pass "RESIDUE CONFIRMED: after a crashed session server, the namespace warm helper (pid=$warmX, tracked=$warmTracked) is a dead-parent server that 10 later invocations never collect"
        } else {
            Write-Fail "Warm helper was collected by a later invocation"
        }
        Stop-Process -Id $warmX -Force -EA SilentlyContinue
    } else {
        Write-Pass "Warm helper died with its crashed parent (no residue on the crash path)"
    }
} else {
    Write-Info "Setup incomplete (pidX=$pidX warmX=$warmX); skipping"
}
if ($script:Residue9 -gt 0) { Stop-Process -Id $script:Residue9 -Force -EA SilentlyContinue }

# ---------------------------------------------------------------------------
Cleanup-All

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
