# A recycled parent pid must not make a stranger the pane's foreground.
#
# Repro script for the sweep failure of 2026-10-02 (test_issue657 Layer 4
# reported `vctip` as the foreground of a pane running a different program).
#
# Mechanism: Windows reuses pids, and a process's ParentProcessId is never
# updated.  A survivor whose parent has exited keeps naming the dead pid, and
# when Windows hands that pid to a pane process, an unguarded walk of the
# Toolhelp parent links adopts the survivor as the pane's child.
#
# PID reuse cannot be forced, but the stale parent link can be manufactured:
#   1. start a helper A (cmd.exe) that starts a long lived grandchild G
#      (ping.exe) and exits at once, so G keeps ParentProcessId = A's dead pid;
#   2. churn pane processes in a private namespace until one of them is given
#      one of those dead pids;
#   3. ask that pane for #{pane_current_command}.
# An unguarded build names G ("PING"); a guarded build names the pane's own
# program.  If no pane received a dead pid within the time budget the script
# reports SKIP, not FAIL: the gate for this bug is the Rust unit test suite
# tests-rs/test_proc_tree_pid_reuse.rs, this script is the end to end witness.
#
# Isolation: unique -L namespace, private PSMUX_DATA_DIR, cleanup by that
# namespace's kill-server and by the pids this script started, nothing by name.

param(
    [int]$BudgetSeconds = 120,
    [int]$OrphansPerRound = 40,
    [int]$MaxOrphans = 160,
    [int]$WindowsPerRound = 12
)

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
foreach ($v in @("PSMUX_SESSION_NAME", "PSMUX_SESSION", "PSMUX_PANE", "TMUX", "TMUX_PANE")) {
    Remove-Item "env:$v" -EA SilentlyContinue
}

$tag = "afg_reuse_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$NS = $tag
$SESSION = "reuse"
$dataDir = Join-Path ([IO.Path]::GetTempPath()) $tag
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:PSMUX_DATA_DIR = $dataDir

function Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "=== recycled parent pid vs #{pane_current_command} ===" -ForegroundColor Cyan
Info "binary: $PSMUX ($((& $PSMUX -V 2>&1 | Out-String).Trim()))"
Info "namespace: $NS  data dir: $dataDir"

$orphans = @{}        # dead parent pid -> orphan pid
$startedPids = New-Object System.Collections.Generic.List[int]
$result = "SKIP"
$detail = ""
$panesTried = 0
$deadline = (Get-Date).AddSeconds($BudgetSeconds)

try {
    & $PSMUX -L $NS new-session -d -s $SESSION -x 100 -y 30 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX -L $NS has-session -t $SESSION 2>$null
    if ($LASTEXITCODE -ne 0) { throw "could not start a session in $NS" }

    while ((Get-Date) -lt $deadline) {
        # 1. Fresh orphans whose parents die right now.
        if ($orphans.Count -lt $MaxOrphans) {
            $parents = @()
            for ($i = 0; $i -lt $OrphansPerRound; $i++) {
                $a = Start-Process -FilePath "cmd.exe" -NoNewWindow -PassThru `
                    -ArgumentList '/c', 'start "" /b ping.exe -n 100000 127.0.0.1 >nul'
                $parents += $a
                $startedPids.Add($a.Id)
            }
            foreach ($a in $parents) { try { $a.WaitForExit(5000) | Out-Null } catch {} }
            $ids = @($parents | ForEach-Object { $_.Id })
            $kids = Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -EA SilentlyContinue |
                Where-Object { $ids -contains [int]$_.ParentProcessId }
            foreach ($k in $kids) {
                $orphans[[int]$k.ParentProcessId] = [int]$k.ProcessId
                $startedPids.Add([int]$k.ProcessId)
            }
            Info "orphans alive with a dead parent pid: $($orphans.Count)"
        }

        # 2. Churn pane processes.
        for ($w = 0; $w -lt $WindowsPerRound; $w++) {
            & $PSMUX -L $NS new-window -d -t $SESSION 2>&1 | Out-Null
        }
        Start-Sleep -Milliseconds 800
        $panes = @(& $PSMUX -L $NS list-panes -a -F '#{pane_id} #{pane_pid} #{window_index}' 2>$null)
        $hit = $null
        foreach ($line in $panes) {
            $f = "$line".Trim() -split ' '
            if ($f.Count -lt 3) { continue }
            $panesTried++
            $pp = [int]$f[1]
            if ($orphans.ContainsKey($pp)) {
                $o = Get-CimInstance Win32_Process -Filter "ProcessId=$($orphans[$pp])" -EA SilentlyContinue
                if ($o -and [int]$o.ParentProcessId -eq $pp) { $hit = @{ Pane = $f[0]; Pid = $pp; Orphan = $o }; break }
            }
        }
        if ($hit) {
            Start-Sleep -Milliseconds 400
            $fg = (& $PSMUX -L $NS display-message -t $hit.Pane -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
            $paneProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($hit.Pid)" -EA SilentlyContinue
            Info ("pane $($hit.Pane) pid=$($hit.Pid) is $($paneProc.Name) created $($paneProc.CreationDate.ToString('HH:mm:ss.fff'))")
            Info ("orphan pid=$($hit.Orphan.ProcessId) $($hit.Orphan.Name) ppid=$($hit.Orphan.ParentProcessId) created $($hit.Orphan.CreationDate.ToString('HH:mm:ss.fff'))")
            Info "#{pane_current_command} = '$fg'"
            if ($fg -match '^(?i)ping') {
                $result = "FAIL"
                $detail = "the pane reports the orphan '$fg' (older than the pane process) as its foreground"
            } else {
                $result = "PASS"
                $detail = "the pane reports its own program '$fg', not the orphan"
            }
            break
        }
        # Keep the namespace small: drop every window but the first.
        $wins = @(& $PSMUX -L $NS list-windows -t $SESSION -F '#{window_index}' 2>$null | Select-Object -Skip 1)
        foreach ($wi in $wins) { & $PSMUX -L $NS kill-window -t "${SESSION}:$("$wi".Trim())" 2>&1 | Out-Null }
    }
} catch {
    $result = "SKIP"
    $detail = "harness error: $($_.Exception.Message)"
} finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    foreach ($p in $startedPids) { Stop-Process -Id $p -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $dataDir -EA SilentlyContinue
}

Info "pane processes inspected: $panesTried, orphans manufactured: $($orphans.Count)"
switch ($result) {
    "PASS" { Write-Host "  [PASS] $detail" -ForegroundColor Green; exit 0 }
    "FAIL" { Write-Host "  [FAIL] $detail" -ForegroundColor Red; exit 1 }
    default {
        if (-not $detail) { $detail = "no pane process received a dead parent pid within $BudgetSeconds s" }
        Write-Host "  [SKIP] $detail" -ForegroundColor DarkYellow
        exit 0
    }
}
