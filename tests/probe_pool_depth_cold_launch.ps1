# Probe (not run by the sweep): cold launch then five new-window (each timed to
# its prompt), a burst of eight, and idle memory, for several pool depths,
# interleaved. Depth is set with PSMUX_WARM_POOL_SIZE on the same binary (or
# -UseDefault for the compiled default). Every run uses its own fresh
# `-L pool34_<pid>_<run>_<depth>` namespace and cleans up only that namespace's
# process tree. This is what chose warm-pool-size 3 (docs/warm-sessions.md,
# "Why the default is three"). Cadences used there:
#
#   immediate  -GapMs 0 -BetweenMs 0          (agent tooling)
#   human      -GapMs 2000 -BetweenMs 300 -SkipBurst
#   slow       -GapMs 2000 -BetweenMs 1000
#   cold burst -Windows 0 -BurstSettleMs 0    (eight at once right after launch)
#
#   pwsh -NoProfile -File tests\probe_pool_depth_cold_launch.ps1 -Binary <psmux.exe> -Depths "2,3,4" -Runs 6 -Out r.json
param(
    [Parameter(Mandatory)][string]$Binary,
    # A comma list STRING: `pwsh -File` hands "2,3,4" over as one string, and an
    # [int[]] param then reads it as the single number 234 (clamped to 8).
    [string]$Depths = "2,3,4",
    [int]$Runs = 6,
    [switch]$UseDefault,     # do not set PSMUX_WARM_POOL_SIZE (measures compiled default)
    [string]$Out = "",
    [switch]$SkipBurst,
    [switch]$SkipMem,
    # Human cadence: wait GapMs after pane one's prompt before the first
    # new-window, and BetweenMs between one creation's prompt and the next.
    [int]$GapMs = 0,
    [int]$BetweenMs = 0,
    # The burst of eight: how long after the five windows (or after the cold
    # prompt with -Windows 0) it starts.
    [int]$BurstSettleMs = 9000,
    [int]$Windows = 5
)
$ErrorActionPreference = "Continue"
$DataDir = "$env:USERPROFILE\.psmux"
$env:PSMUX_SESSION_NAME = $null; $env:PSMUX_SESSION = $null; $env:TMUX = $null; $env:PSMUX_TARGET_SESSION = $null
$PromptRe = 'PS [A-Z]:\\'
$Sess = "p"

function Invoke-Psmux([int]$Port, [string]$Key, [string]$Cmd) {
    $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.NoDelay = $true
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 20000
        $wr = New-Object System.IO.StreamWriter($st); $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $Key"); $wr.Flush()
        if ($rd.ReadLine() -ne "OK") { return "" }
        $wr.WriteLine("TARGET $Sess"); $wr.WriteLine($Cmd); $wr.Flush()
        $acc = New-Object System.Collections.Generic.List[string]
        while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $acc.Add($l) }
        return ($acc -join "`n")
    } catch { return "" } finally { $tcp.Close() }
}
function Wait-Reg([string]$ns, [int]$TimeoutMs = 20000) {
    $pf = "$DataDir\$($ns)__$Sess.port"; $kf = "$DataDir\$($ns)__$Sess.key"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            try { $p = [int](Get-Content $pf -Raw).Trim(); $k = (Get-Content $kf -Raw).Trim(); if ($p -gt 0 -and $k) { return @{Port = $p; Key = $k } } } catch {}
        }
        Start-Sleep -Milliseconds 3
    }
    return $null
}
function Wait-Prompt($inf, [string]$target, $sw, [int]$TimeoutMs = 20000) {
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Invoke-Psmux $inf.Port $inf.Key "capture-pane -p -t $target") -match $PromptRe) { return $sw.Elapsed.TotalMilliseconds }
        Start-Sleep -Milliseconds 5
    }
    return -1
}
function Get-NsProcs([string]$ns) {
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CommandLine, Name, WorkingSetSize
    $roots = @($all | Where-Object { $_.CommandLine -and $_.CommandLine -match "-L\s+$ns(\s|$)" -and $_.Name -match '^psmux' })
    $set = @{}; foreach ($r in $roots) { $set[[int]$r.ProcessId] = $r }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $all) { if (-not $set.ContainsKey([int]$p.ProcessId) -and $set.ContainsKey([int]$p.ParentProcessId)) { $set[[int]$p.ProcessId] = $p; $changed = $true } }
    }
    return @($set.Values)
}
function Cleanup([string]$ns) {
    $left = Get-NsProcs $ns
    try { & $Binary -L $ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 600
    foreach ($p in $left) { if (Get-Process -Id $p.ProcessId -EA SilentlyContinue) {
        # only pids that belong to this namespace's tree, verified by the tree walk above
        $still = Get-NsProcs $ns | Where-Object { $_.ProcessId -eq $p.ProcessId }
        if ($still) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue } } }
    Get-ChildItem "$DataDir\$($ns)__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

$results = New-Object System.Collections.Generic.List[object]
for ($run = 1; $run -le $Runs; $run++) {
    foreach ($d in @($Depths -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })) {
        if ($UseDefault) { Remove-Item Env:PSMUX_WARM_POOL_SIZE -EA SilentlyContinue } else { $env:PSMUX_WARM_POOL_SIZE = "$d" }
        $ns = "pool34_${PID}_${run}_$d"
        Cleanup $ns
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Process -FilePath $Binary -ArgumentList "-L", $ns, "new-session", "-d", "-s", $Sess, "-x", "160", "-y", "45" -WindowStyle Hidden | Out-Null
        $inf = Wait-Reg $ns
        if (-not $inf) { Write-Host "run $run d=$d never registered"; Cleanup $ns; continue }
        $cold = Wait-Prompt $inf "$($Sess):0.0" $sw
        $times = @(); $wids = @()
        if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
        for ($i = 1; $i -le $Windows; $i++) {
            if ($i -gt 1 -and $BetweenMs -gt 0) { Start-Sleep -Milliseconds $BetweenMs }
            $t = [Diagnostics.Stopwatch]::StartNew()
            $id = (Invoke-Psmux $inf.Port $inf.Key "new-window -P -F '#{pane_id}'").Trim().Trim("'")
            if ($id -notmatch '^%\d+$') { Write-Host "  bad id [$id]"; $id = (Invoke-Psmux $inf.Port $inf.Key "display-message -p '#{pane_id}'").Trim().Trim("'") }
            $ms = Wait-Prompt $inf $id $t
            $times += [math]::Round($ms, 0); $wids += $id
        }
        $burst = @(); $burstAll = -1
        if (-not $SkipBurst) {
            if ($BurstSettleMs -gt 0) { Start-Sleep -Milliseconds $BurstSettleMs }   # surge over, pool back at target
            $t = [Diagnostics.Stopwatch]::StartNew()
            $ids = @()
            for ($i = 1; $i -le 8; $i++) { $ids += (Invoke-Psmux $inf.Port $inf.Key "new-window -P -F '#{pane_id}'").Trim().Trim("'") }
            $pending = [System.Collections.Generic.List[string]]::new(); $ids | ForEach-Object { $pending.Add($_) }
            $ready = @{}
            while ($pending.Count -gt 0 -and $t.ElapsedMilliseconds -lt 30000) {
                foreach ($id in @($pending)) {
                    if ((Invoke-Psmux $inf.Port $inf.Key "capture-pane -p -t $id") -match $PromptRe) { $ready[$id] = [math]::Round($t.Elapsed.TotalMilliseconds, 0); $pending.Remove($id) | Out-Null }
                }
                Start-Sleep -Milliseconds 5
            }
            $burst = @($ids | ForEach-Object { if ($ready.ContainsKey($_)) { $ready[$_] } else { -1 } })
            $burstAll = ($burst | Measure-Object -Maximum).Maximum
        }
        Cleanup $ns
        $mem = $null; $nproc = $null
        if (-not $SkipMem) {
            $ns2 = "pool34m_${PID}_${run}_$d"
            Cleanup $ns2
            Start-Process -FilePath $Binary -ArgumentList "-L", $ns2, "new-session", "-d", "-s", $Sess, "-x", "160", "-y", "45" -WindowStyle Hidden | Out-Null
            Start-Sleep -Seconds 14
            $ps = Get-NsProcs $ns2
            $nproc = $ps.Count
            $mem = [math]::Round((($ps | Measure-Object WorkingSetSize -Sum).Sum) / 1MB, 0)
            Cleanup $ns2
        }
        $row = [pscustomobject]@{ run = $run; depth = $d; gap_ms = $GapMs; between_ms = $BetweenMs; cold_ms = [math]::Round($cold, 0); w = ($times -join ","); w4 = $times[3]; wmax = ($times | Measure-Object -Maximum).Maximum; burst = ($burst -join ","); burst_all = $burstAll; idle_mb = $mem; nproc = $nproc }
        $results.Add($row)
        Write-Host (("run {0} d={1} cold={2} windows=[{3}] burst=[{4}] mem={5}MB procs={6}" -f $run, $d, $row.cold_ms, $row.w, $row.burst, $mem, $nproc) + " ids=" + ($wids -join ","))
    }
}
Remove-Item Env:PSMUX_WARM_POOL_SIZE -EA SilentlyContinue
if ($Out) { $results | ConvertTo-Json -Depth 4 | Set-Content $Out }
