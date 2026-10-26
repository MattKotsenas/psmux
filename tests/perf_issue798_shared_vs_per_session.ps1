# Issue #798 step 2: what three sessions cost, shared server against one server
# per session. Not a gate: it measures and writes the numbers.
#
# For each mode and round, in a fresh -L namespace and PSMUX_DATA_DIR:
#   * the wall time of `new-session -d` for the first, second and third session
#     (the first one includes starting the server in both modes);
#   * after the third, the server processes of the namespace (found by command
#     line under this binary), their working set and private bytes, with the
#     per session warm standby counted separately, since shared mode has none.
#
# Metrics JSON: $env:USERPROFILE\.psmux-test-data\metrics\ (perf_metrics_common).
# Cleans up only with `-L <ns> kill-server`. PSMUX_TEST_EXE picks the binary.

param([int]$Rounds = 5)
$ErrorActionPreference = "Continue"
$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
$PSMUX = (Resolve-Path $PSMUX).Path
foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_TARGET_SESSION', 'TMUX', 'TMUX_PANE', 'PSMUX_SERVER_MODE') { Remove-Item "Env:$v" -EA SilentlyContinue }
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
. "$PSScriptRoot\isolated_config.ps1" -Lines @("set -g default-shell $POWERSHELL")
. "$PSScriptRoot\perf_metrics_common.ps1"

$ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_798p_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $ROOT | Out-Null
$namespaces = @()

function Server-Procs($ns) {
    @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $PSMUX -and $_.CommandLine -match ' server ' -and $_.CommandLine -match "-L $ns(\s|$)" })
}

$results = [ordered]@{ shared = @(); 'per-session' = @() }
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($mode in 'per-session', 'shared') {
            $ns = "p798" + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $dir = Join-Path $ROOT $ns; New-Item -ItemType Directory -Force $dir | Out-Null
            $namespaces += , @($ns, $dir)
            $env:PSMUX_DATA_DIR = $dir
            $times = @()
            foreach ($s in 'A', 'B', 'C') {
                $env:PSMUX_SERVER_MODE = $mode
                $sw = [Diagnostics.Stopwatch]::StartNew()
                & $PSMUX -L $ns new-session -d -s $s -x 120 -y 30 2>&1 | Out-Null
                $times += [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                Remove-Item Env:PSMUX_SERVER_MODE -EA SilentlyContinue
            }
            # Let the shells and the per session standby settle before reading memory.
            Start-Sleep -Seconds 3
            $procs = Server-Procs $ns
            $warm = @($procs | Where-Object { $_.CommandLine -match ' -s __warm__' })
            $real = @($procs | Where-Object { $_.CommandLine -notmatch ' -s __warm__' })
            $ws = 0; $priv = 0; $wsWarm = 0; $privWarm = 0
            foreach ($p in $real) { $gp = Get-Process -Id $p.ProcessId -EA SilentlyContinue; if ($gp) { $ws += $gp.WorkingSet64; $priv += $gp.PrivateMemorySize64 } }
            foreach ($p in $warm) { $gp = Get-Process -Id $p.ProcessId -EA SilentlyContinue; if ($gp) { $wsWarm += $gp.WorkingSet64; $privWarm += $gp.PrivateMemorySize64 } }
            $row = [ordered]@{
                round = $round
                new_session_ms = $times
                server_processes = $real.Count
                standby_processes = $warm.Count
                working_set_mb = [math]::Round($ws / 1MB, 1)
                private_mb = [math]::Round($priv / 1MB, 1)
                standby_working_set_mb = [math]::Round($wsWarm / 1MB, 1)
                standby_private_mb = [math]::Round($privWarm / 1MB, 1)
            }
            $results[$mode] += $row
            Write-Host ("  {0,-11} round {1}: new-session {2} ms; servers {3} ({4} MB ws, {5} MB private); standby {6} ({7} MB ws)" -f $mode, $round, ($times -join '/'), $real.Count, $row.working_set_mb, $row.private_mb, $warm.Count, $row.standby_working_set_mb)
            & $PSMUX -L $ns kill-server 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
} finally {
    Remove-Item Env:PSMUX_SERVER_MODE -EA SilentlyContinue
    foreach ($pair in $namespaces) { $env:PSMUX_DATA_DIR = $pair[1]; & $PSMUX -L $pair[0] kill-server 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $ROOT -EA SilentlyContinue
    if (Get-Command Remove-PsmuxIsolatedConfig -EA SilentlyContinue) { Remove-PsmuxIsolatedConfig }
}

$summary = [ordered]@{}
foreach ($mode in 'per-session', 'shared') {
    $rows = $results[$mode]
    $summary[$mode] = [ordered]@{
        first_new_session_ms = (Get-PerfStats @($rows | ForEach-Object { $_.new_session_ms[0] }))
        later_new_session_ms = (Get-PerfStats @($rows | ForEach-Object { $_.new_session_ms[1]; $_.new_session_ms[2] }))
        server_processes = (Get-PerfStats @($rows | ForEach-Object { $_.server_processes }))
        working_set_mb = (Get-PerfStats @($rows | ForEach-Object { $_.working_set_mb }))
        private_mb = (Get-PerfStats @($rows | ForEach-Object { $_.private_mb }))
        standby_working_set_mb = (Get-PerfStats @($rows | ForEach-Object { $_.standby_working_set_mb }))
    }
    $s = $summary[$mode]
    Write-Host ("{0,-11}: first new-session p50 {1} ms, later p50 {2} ms; {3} server process(es), {4} MB ws, {5} MB private (+ standby {6} MB ws)" -f $mode, $s.first_new_session_ms.p50, $s.later_new_session_ms.p50, $s.server_processes.p50, $s.working_set_mb.p50, $s.private_mb.p50, $s.standby_working_set_mb.p50) -ForegroundColor Cyan
}
$path = Write-PerfMetrics -Suite "perf_issue798_shared_vs_per_session" -Binary $PSMUX -Data ([ordered]@{ rounds = $Rounds; summary = $summary; raw = $results })
Write-Host "metrics: $path"
