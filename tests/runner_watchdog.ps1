# runner_watchdog.ps1 - the witness for issue #680.
#
# The two disappearances in #680 wrote nothing because nothing they could write
# with was still running. A job object closing with KILL_ON_JOB_CLOSE, and a
# taskkill /F /T aimed at an ancestor, are both TerminateProcess: no console
# control handler runs, no PowerShell.Exiting fires, no finally block executes.
# Measured on 2026-09-21 against a disposable stand in for the runner: both
# shapes killed the runner AND a child of it that had its own console, and left
# not one line behind in any of the four places that were listening.
#
# So the only way to know what happened is to watch from outside. This process
# does exactly that and nothing else:
#
#   - it is launched DETACHED from the runner's console and, where the job
#     permits breakaway, OUTSIDE the runner's job, so the thing that ends the
#     run does not end the witness;
#   - it polls the runner by pid AND process start time, so a recycled pid can
#     neither fake the runner being alive nor fake it being dead;
#   - it tracks the runner's ancestors the same way, because WHICH of them died
#     is the difference between "the runner was killed" and "the whole tree was
#     killed from above", and that single fact chooses between the remaining
#     explanations;
#   - when the runner goes without writing its end marker it writes one snapshot
#     and leaves;
#   - it NEVER kills anything, and it exits on its own when the run ends, when
#     the run directory goes, or after a hard cap, so it can never become the
#     kind of stray process the runner audits for.
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][int]$RunnerPid,
    # Start time of the runner in ticks. 0 means "could not be read", in which
    # case pid alone is used and the snapshot says so.
    [long]$RunnerTicks = 0,
    # "pid:ticks,pid:ticks,..." for the runner and every ancestor above it.
    [string]$Chain = '',
    [int]$MaxHours = 14,
    [int]$PollMs = 1000
)

$ErrorActionPreference = 'Continue'

$log      = Join-Path $RunDir 'watchdog.log'
$snapshot = Join-Path $RunDir 'runner_vanished.log'
$endMark  = Join-Path $RunDir 'runner_end.marker'
$stopFlag = Join-Path $env:TEMP 'psmux-teststop.flag'

function W {
    param([string]$m, [string]$f = $log)
    try {
        [System.IO.File]::AppendAllText($f, ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $m))
    } catch { }
}

# Pid plus start time. Returns $true only when THAT process is still there, so a
# pid Windows has handed to somebody else reads as gone, which is what it is.
function Test-Anchor {
    param([int]$TargetPid, [long]$Ticks)
    $p = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($Ticks -eq 0) { return $true }
    try { return ($p.StartTime.Ticks -eq $Ticks) } catch { return $true }
}

# Whether this watchdog actually got out of the runner's job. If it did not, it
# will die with the run and record nothing, and the run needs to know that in
# advance rather than discover it in the silence afterwards.
$inJob = '<unknown>'
try {
    if (-not ('WdJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WdJob {
    [DllImport("kernel32.dll")] static extern bool IsProcessInJob(IntPtr p, IntPtr j, out bool r);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static bool In() { bool r; IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out r); return r; }
}
'@ -ErrorAction Stop
    }
    $inJob = [WdJob]::In()
} catch { }

$parent = '<unknown>'
try {
    $ci = Get-CimInstance -Query "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=$PID" -ErrorAction SilentlyContinue
    if ($ci) {
        $pp = [int]$ci.ParentProcessId
        $pn = try { (Get-Process -Id $pp -ErrorAction Stop).ProcessName } catch { '<exited>' }
        $parent = "$pp($pn)"
    }
} catch { }

W "===== watchdog start ====="
W "watchdog pid=$PID parent=$parent inJob=$inJob watching runner pid=$RunnerPid ticks=$RunnerTicks"
if ($inJob -eq $true) {
    W "watchdog WARNING this watchdog is itself inside a job object; if that job is what ends the run, this witness dies with it"
}

# Ancestors, newest first. The runner is element 0.
$anchors = @()
foreach ($tok in ($Chain -split ',')) {
    if (-not $tok) { continue }
    $bits = $tok -split ':'
    if ($bits.Count -ne 2) { continue }
    $p = 0; $t = 0L
    if (-not [int]::TryParse($bits[0], [ref]$p)) { continue }
    [void][long]::TryParse($bits[1], [ref]$t)
    if ($p -le 0) { continue }
    $nm = try { (Get-Process -Id $p -ErrorAction Stop).ProcessName } catch { '<gone>' }
    $anchors += [pscustomobject]@{ Pid = $p; Ticks = $t; Name = $nm; Alive = $true; Died = $null }
}
if ($anchors.Count -eq 0) {
    $anchors += [pscustomobject]@{ Pid = $RunnerPid; Ticks = $RunnerTicks; Name = 'runner'; Alive = $true; Died = $null }
}
W ("tracking {0} process(es) in the runner's chain: {1}" -f $anchors.Count, (($anchors | ForEach-Object { "$($_.Pid)($($_.Name))" }) -join ' '))

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = $MaxHours * 3600
$lastRunnerSeen = Get-Date
$reason = $null

while ($true) {
    Start-Sleep -Milliseconds $PollMs

    if ($sw.Elapsed.TotalSeconds -ge $deadline) { $reason = 'hard cap reached'; break }
    if (-not (Test-Path $RunDir))  { $reason = 'run directory is gone'; break }
    if (Test-Path $endMark) {
        $m = ''
        try { $m = (Get-Content $endMark -Raw -ErrorAction SilentlyContinue).Trim() } catch { }
        $reason = "runner wrote its end marker: $m"
        break
    }

    # Note every ancestor death as it happens, whether or not the runner is
    # affected. The launcher going first, for example, is how a tree kill from
    # above looks a fraction of a second before it reaches us.
    foreach ($a in $anchors) {
        if (-not $a.Alive) { continue }
        if ($a.Pid -eq $RunnerPid) { continue }
        if (-not (Test-Anchor $a.Pid $a.Ticks)) {
            $a.Alive = $false
            $a.Died = Get-Date
            W ("chain pid={0} ({1}) is gone" -f $a.Pid, $a.Name)
        }
    }

    if (Test-Anchor $RunnerPid $RunnerTicks) { $lastRunnerSeen = Get-Date; continue }

    # ── The runner is gone and it did not say goodbye ────────────────────────
    Start-Sleep -Milliseconds 400      # let anything still dying finish dying
    if (Test-Path $endMark) { $reason = 'runner wrote its end marker as it went'; break }

    W "RUNNER VANISHED without an end marker; writing snapshot to $snapshot"
    $now = Get-Date
    W "===== runner vanished =====" $snapshot
    W ("runner pid={0} last seen alive {1}, missing by {2}; death falls in a window of about {3:F1}s" -f `
        $RunnerPid, $lastRunnerSeen.ToString('yyyy-MM-dd HH:mm:ss.fff'),
        $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), ($now - $lastRunnerSeen).TotalSeconds) $snapshot
    W ("watchdog pid={0} parent={1} inJob={2}" -f $PID, $parent, $inJob) $snapshot

    # WHICH of the chain went. This is the line that picks the explanation.
    foreach ($a in $anchors) {
        if ($a.Pid -eq $RunnerPid) { continue }
        $state = if (Test-Anchor $a.Pid $a.Ticks) { 'STILL ALIVE' }
                 elseif ($a.Died) { "gone at $($a.Died.ToString('HH:mm:ss.fff'))" }
                 else { 'gone' }
        W ("chain pid={0} ({1}) {2}" -f $a.Pid, $a.Name, $state) $snapshot
    }
    $deadAbove = @($anchors | Where-Object { $_.Pid -ne $RunnerPid -and -not (Test-Anchor $_.Pid $_.Ticks) }).Count
    $liveAbove = @($anchors | Where-Object { $_.Pid -ne $RunnerPid -and (Test-Anchor $_.Pid $_.Ticks) }).Count
    if ($deadAbove -gt 0 -and $liveAbove -eq 0) {
        W "verdict the ENTIRE chain above the runner went too: consistent with a job object closing on the run, or a tree kill aimed at an ancestor" $snapshot
    } elseif ($deadAbove -gt 0) {
        W ("verdict {0} of the runner's ancestors went and {1} survived: the kill was bounded, look at the lowest survivor" -f $deadAbove, $liveAbove) $snapshot
    } else {
        W "verdict every ancestor survived: the runner alone was killed, so look for something that targeted this pid" $snapshot
    }

    W ("stop flag present: {0}" -f (Test-Path $stopFlag)) $snapshot
    try {
        $cs = Get-Content (Join-Path $RunDir 'current_suite.txt') -Raw -ErrorAction SilentlyContinue
        W ("current suite at death: [{0}]" -f ($cs -replace '\s+', ' ').Trim()) $snapshot
    } catch { }

    W "----- last 30 lines of progress.log -----" $snapshot
    try {
        foreach ($l in (Get-Content (Join-Path $RunDir 'progress.log') -Tail 30 -ErrorAction SilentlyContinue)) {
            try { [System.IO.File]::AppendAllText($snapshot, "$l`r`n") } catch { }
        }
    } catch { }

    W "----- last 10 lines of kills.log -----" $snapshot
    try {
        foreach ($l in (Get-Content (Join-Path $RunDir 'kills.log') -Tail 10 -ErrorAction SilentlyContinue)) {
            try { [System.IO.File]::AppendAllText($snapshot, "$l`r`n") } catch { }
        }
    } catch { }

    W "----- processes from this run still standing -----" $snapshot
    try {
        $q = "SELECT ProcessId,ParentProcessId,Name,CommandLine FROM Win32_Process WHERE Name='psmux.exe' OR Name='tmux.exe' OR Name='pmux.exe' OR Name='pwsh.exe' OR Name='cmd.exe'"
        foreach ($p in (Get-CimInstance -Query $q -ErrorAction SilentlyContinue)) {
            $cl = (([string]$p.CommandLine) -replace '\s+', ' ').Trim()
            # Narrow on purpose. Matching the word psmux anywhere in a command
            # line also matches every shell whose working directory happens to be
            # the repo, and a snapshot padded with a dozen unrelated prompts is a
            # snapshot nobody reads.
            if ($p.Name -eq 'pwsh.exe' -or $p.Name -eq 'cmd.exe') {
                if ($cl -notmatch 'run_all_tests|run_full_interactive|runner_watchdog|spawn_trace_watcher|tests\\test_') { continue }
            }
            if ($cl.Length -gt 220) { $cl = $cl.Substring(0, 220) + '...' }
            W ("alive pid={0} ppid={1} {2} cmd=[{3}]" -f $p.ProcessId, $p.ParentProcessId, $p.Name, $cl) $snapshot
        }
    } catch { W ("process enumeration failed: {0}" -f $_.Exception.Message) $snapshot }

    W "----- event log, last 2 minutes -----" $snapshot
    $since = $now.AddMinutes(-2)
    foreach ($ln in 'System', 'Application') {
        try {
            $evs = Get-WinEvent -FilterHashtable @{ LogName = $ln; StartTime = $since } -MaxEvents 60 -ErrorAction SilentlyContinue
            if (-not $evs) { W ("{0}: nothing in the window" -f $ln) $snapshot; continue }
            foreach ($e in $evs) {
                $msg = ($e.Message -replace '\s+', ' ')
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                W ("{0} {1} id={2} {3}: {4}" -f $ln, $e.TimeCreated.ToString('HH:mm:ss.fff'), $e.Id, $e.ProviderName, $msg) $snapshot
            }
        } catch { W ("{0}: unreadable ({1})" -f $ln, $_.Exception.Message) $snapshot }
    }
    # Process exit auditing is usually off; when it is on, 4689 names the killer's
    # subject. Asking costs nothing and it is the one event that would settle it.
    try {
        $sec = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688, 4689; StartTime = $since } -MaxEvents 40 -ErrorAction Stop
        foreach ($e in $sec) {
            $msg = ($e.Message -replace '\s+', ' ')
            if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
            W ("Security {0} id={1}: {2}" -f $e.TimeCreated.ToString('HH:mm:ss.fff'), $e.Id, $msg) $snapshot
        }
    } catch {
        W "Security: process creation/exit auditing is off or the log is not readable from here" $snapshot
    }

    W "===== end of snapshot =====" $snapshot
    $reason = 'runner vanished, snapshot written'
    break
}

W "watchdog exiting: $reason"
