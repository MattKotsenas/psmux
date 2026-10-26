# BSOD guard regression test (bugcheck 0xEF).
#
# Kernel dumps proved psmux.exe TerminateProcess'd a critical session-0
# svchost.exe: the pane-tree-kill BFS walked a STALE Toolhelp32 ParentPid link
# (a pane descendant exited, Windows recycled its PID for an unrelated
# process, and the BFS followed that stale numeric edge straight into the OS
# process hierarchy). The fix adds a protected-image denylist + a
# creation-time "edge is genuine" check before any PID is terminated.
#
# This E2E proves BOTH sides of that fix at once:
#   1. Legitimate pane-tree teardown (kill-session) still reaps every real
#      descendant -- if the new guard is too aggressive and starts leaking
#      panes, this MUST fail loudly (a regression is worse than the bug).
#   2. Rapid session churn (the exact "stale PID recycled fast" conditions
#      that produced the original crash) never touches svchost.exe or any
#      other critical system process on the box.
#
# NOTE: this script is NOT executed as part of this change (the installed
# psmux predates the fix). It is validated with the PowerShell parser only
# (see the accompanying test-worker report). It is written to the same
# Write-Pass/Write-Fail/$script:TestsPassed conventions as
# tests\test_issue447_kill_tree.ps1 and tests\test_issue448_orphan_reaper.ps1
# so it can be dropped into the suite once the fix lands.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup-BsodGuardSessions {
    & $PSMUX kill-session -t bsodguard_tree 2>&1 | Out-Null
    Remove-Item "$psmuxDir\bsodguard_tree.*" -Force -EA SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        & $PSMUX kill-session -t "bsodguard_c$i" 2>&1 | Out-Null
        Remove-Item "$psmuxDir\bsodguard_c$i.*" -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

function Get-DescendantPids($rootProcId) {
    # Recursive BFS over the live process table, mirroring the shape of the
    # tree-kill sweep under test (parent -> children -> grandchildren...).
    $all = Get-CimInstance Win32_Process -EA SilentlyContinue |
        Select-Object ProcessId, ParentProcessId
    $queue = New-Object System.Collections.Generic.Queue[uint32]
    $queue.Enqueue([uint32]$rootProcId)
    $seen = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $null = $seen.Add([uint32]$rootProcId)
    $descendants = @()
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($p in $all) {
            if ($p.ParentProcessId -eq $parent -and -not $seen.Contains([uint32]$p.ProcessId)) {
                $null = $seen.Add([uint32]$p.ProcessId)
                $queue.Enqueue([uint32]$p.ProcessId)
                $descendants += [uint32]$p.ProcessId
            }
        }
    }
    return $descendants
}

function Get-CriticalSnapshot {
    # PIDs of the specific critical system processes named in the fix's
    # denylist that are realistically enumerable/queryable from a normal
    # (non-admin) session. lsaiso/fontdrvhost/dwm are session/VBS-dependent
    # and intentionally left out of this liveness snapshot.
    $names = @("csrss", "wininit", "services", "lsass")
    $snap = @{}
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -EA SilentlyContinue
        if ($procs) { $snap[$n] = @($procs | Select-Object -ExpandProperty Id | Sort-Object) }
        else { $snap[$n] = @() }
    }
    return $snap
}

function Assert-CriticalSnapshotUnchanged($before, $after, $label) {
    $ok = $true
    foreach ($n in $before.Keys) {
        $b = @($before[$n])
        $a = @($after[$n])
        if (($b -join ',') -ne ($a -join ',')) {
            Write-Fail "$label -- $n PID set changed: before=[$($b -join ',')] after=[$($a -join ',')] (CRITICAL SYSTEM PROCESS DISTURBED)"
            $ok = $false
        }
    }
    if ($ok) { Write-Pass "$label -- csrss/wininit/services/lsass PIDs all unchanged" }
}

Cleanup-BsodGuardSessions
Write-Host "`n=== BSOD guard: protected-process kill safety ===" -ForegroundColor Cyan

# === Baseline snapshot (BEFORE any psmux session churn) ===
$svchostBefore = @(Get-Process -Name svchost -EA SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$criticalBefore = Get-CriticalSnapshot
$scmWindowStart = Get-Date   # SCM event-log window for the kill-detection check
Write-Host "  baseline svchost count: $($svchostBefore.Count)" -ForegroundColor DarkGray
foreach ($n in $criticalBefore.Keys) {
    Write-Host "  baseline $n pids: $($criticalBefore[$n] -join ',')" -ForegroundColor DarkGray
}

# ===========================================================================
# TEST 1 (CRITICAL): legitimate tree-kill must still reap every real
# descendant. If the new protected-process guard over-blocks, this test
# fails LOUDLY -- a leaked pane tree is a suite regression, not a pass.
# ===========================================================================
Write-Host "`n[Test 1] Tree-kill regression: kill-session still reaps a real nested descendant" -ForegroundColor Yellow

& $PSMUX new-session -d -s bsodguard_tree
Start-Sleep -Seconds 3
& $PSMUX has-session -t bsodguard_tree 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
} else {
    Write-Pass "Session bsodguard_tree created"

    & $PSMUX send-keys -t bsodguard_tree "pwsh -NoProfile -Command Start-Sleep 300" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $panePid = (& $PSMUX display-message -t bsodguard_tree -p '#{pane_pid}' 2>&1).Trim()
    Write-Host "  pane root pid = $panePid" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($panePid) -or -not ($panePid -match '^\d+$')) {
        Write-Fail "Could not read a numeric pane_pid ('$panePid')"
    } else {
        # Poll rather than trust the 3 s sleep: a Store pwsh can take longer
        # than that to appear when the machine is busy (sweep 2026-10-12_23-41,
        # "Could not find the nested pwsh descendant", passed 3/3 on rerun).
        $descendants = @()
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $descendants = @(Get-DescendantPids ([uint32]$panePid))
            if ($descendants.Count -gt 0) { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        Write-Host "  descendants at kill time: $($descendants -join ',')" -ForegroundColor DarkGray

        if ($descendants.Count -eq 0) {
            Write-Fail "Could not find the nested pwsh descendant before kill (test setup issue, not a guard result)"
        } else {
            Write-Pass "Captured $($descendants.Count) descendant pid(s) of the pane before kill-session"
        }

        & $PSMUX kill-session -t bsodguard_tree 2>&1 | Out-Null

        $rootDead = $false
        $descendantsDead = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            $rootProc = Get-Process -Id ([int]$panePid) -EA SilentlyContinue
            $rootDead = ($null -eq $rootProc)

            $stillAlive = @()
            foreach ($d in $descendants) {
                if (Get-Process -Id ([int]$d) -EA SilentlyContinue) { $stillAlive += $d }
            }
            $descendantsDead = ($stillAlive.Count -eq 0)

            if ($rootDead -and $descendantsDead) { break }
        }

        if ($rootDead) { Write-Pass "pane root pid $panePid was torn down by kill-session" }
        else { Write-Fail "pane root pid $panePid SURVIVED kill-session (guard over-blocked the root)" }

        if ($descendants.Count -gt 0) {
            if ($descendantsDead) {
                Write-Pass "all $($descendants.Count) descendant(s) were torn down (no orphan leak)"
            } else {
                Write-Fail "REGRESSION: descendant(s) [$($stillAlive -join ',')] survived kill-session -- guard is over-blocking legitimate tree-kill"
                foreach ($d in $stillAlive) { Stop-Process -Id $d -Force -EA SilentlyContinue }
            }
        }
    }
}

Cleanup-BsodGuardSessions

# ===========================================================================
# TEST 2: rapid session churn (create/split/kill x10) must never touch
# svchost.exe or any of the other critical system processes.
# ===========================================================================
Write-Host "`n[Test 2] Churn safety: 10x new-session/split-window/kill-session cycles" -ForegroundColor Yellow

for ($i = 0; $i -lt 10; $i++) {
    $name = "bsodguard_c$i"
    & $PSMUX new-session -d -s $name 2>&1 | Out-Null
    & $PSMUX split-window -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
}
Start-Sleep -Seconds 1

# Windows services legitimately idle-stop (their svchost host exits with a
# graceful SCM 7036 "entered the stopped state"), so strict PID-set equality
# is flaky by design. What a psmux mis-kill WOULD produce is SCM event 7034
# "terminated unexpectedly" for every service the murdered host was running.
# Assert on that signal instead: zero 7034 events across the churn window.
$svchostAfter = @(Get-Process -Name svchost -EA SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$disappeared = @($svchostBefore | Where-Object { $svchostAfter -notcontains $_ })
if ($disappeared.Count -gt 0) {
    Write-Host "  note: svchost pid(s) exited during churn: $($disappeared -join ',') (checking SCM log for kill evidence)" -ForegroundColor DarkGray
}
$unexpected = @(Get-WinEvent -FilterHashtable @{
    LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7034
    StartTime = $scmWindowStart
} -ErrorAction SilentlyContinue)
if ($unexpected.Count -eq 0) {
    Write-Pass "no service host was terminated during churn (zero SCM 7034 events; $($disappeared.Count) graceful idle-stop exit(s) tolerated)"
} else {
    $detail = ($unexpected | ForEach-Object { $_.Message -replace "`r`n", ' ' }) -join ' | '
    Write-Fail "CRITICAL: SCM reported service(s) terminated unexpectedly during churn: $detail"
}

$criticalAfter = Get-CriticalSnapshot
Assert-CriticalSnapshotUnchanged $criticalBefore $criticalAfter "Churn safety"

# === Cleanup trailer ===
Cleanup-BsodGuardSessions
# Best-effort: sweep any stray bsodguard_* sessions left by a partial run.
& $PSMUX list-sessions 2>&1 | Select-String '^bsodguard_' | ForEach-Object {
    $sname = ($_.ToString() -split ':')[0]
    & $PSMUX kill-session -t $sname 2>&1 | Out-Null
}
Remove-Item "$psmuxDir\bsodguard_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
