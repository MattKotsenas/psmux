# spawn_trace_watcher.ps1
#
# Background attribution watcher for the full test runner. It answers one
# question: WHICH SUITE spawned the console process that is still sitting on the
# desktop at the end of a run.
#
# Three full sweeps once left about 33 Windows Terminal windows holding 121
# processes whose command line was exactly
#     C:\WINDOWS\system32\cmd.exe /c pause
# all parked at "Press any key to continue". Nothing in tests\*.ps1 spawns that,
# and every suite runs inside a Job Object with kill on close, so the carriers
# were provably NOT descendants of any suite process. With no record of who
# created them the only available evidence was a pile of dead tabs, which is why
# this watcher exists: it records the birth, not the corpse.
#
# WHAT IT RECORDS
#   every start of cmd.exe, conhost.exe, OpenConsole.exe and WindowsTerminal.exe:
#   pid, image, full command line, a three level parent chain (name + command
#   line per level) and the name of the suite that was running at that instant.
#   Starts whose command line matches `/c pause` or `/k ` are additionally
#   tagged PAUSEORK so they can be grepped out in one pass.
#
# WHY THE NAME FILTER IS IN THE WQL, NOT IN POWERSHELL
#   Cost has to be negligible next to a five hour sweep. Win32_ProcessStartTrace
#   fires for EVERY process on the machine, and a full run starts six figures of
#   psmux.exe CLI processes. Filtering in the event query means WMI never
#   delivers those to us and we never pay for a command line lookup on them. The
#   four names above are rare (a few thousand per run) and are the only images
#   that can own a console window or carry a `/c pause` / `/k` tail, so the
#   filter loses nothing that matters.
#
# WHY ManagementEventWatcher AND NOT Register-CimIndicationEvent
#   Same reason as watch_spawn_failures.ps1: the Cim cmdlet depends on the
#   PowerShell runspace event pump, which silently drops these indications in a
#   non-interactive host. The subscription succeeds and zero events arrive.
#
# WHY IT CANNOT OUTLIVE THE RUN
#   It polls -RunnerPid and exits the moment the runner is gone, in addition to
#   being stopped explicitly at the end of the run. A watcher left running would
#   be exactly the kind of stray process it was written to catch.

param(
    # Where the trace goes. The runner passes <run dir>\spawn_trace.log.
    [Parameter(Mandatory = $true)][string]$OutFile,
    # Tiny file the runner rewrites with the name of the suite it is about to
    # start. Read on each event, which is how a start gets attributed.
    [Parameter(Mandatory = $true)][string]$SuiteFile,
    # The runner's pid. When it dies, so do we.
    [Parameter(Mandatory = $true)][int]$RunnerPid,
    # Hard stop so a wedged watcher can never live for ever.
    [int]$MaxHours = 12
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Management

$names = @('cmd.exe', 'conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe')
$where = ($names | ForEach-Object { "ProcessName='$_'" }) -join ' OR '

try {
    $scope = New-Object System.Management.ManagementScope('\\.\root\cimv2')
    $scope.Connect()
    $query = New-Object System.Management.WqlEventQuery("SELECT * FROM Win32_ProcessStartTrace WHERE $where")
    $watcher = New-Object System.Management.ManagementEventWatcher($scope, $query)
    # A short timeout is how this loop idles: WaitForNextEvent throws on timeout,
    # we swallow it, and that tick is also when the runner-liveness check runs.
    $watcher.Options.Timeout = [TimeSpan]::FromMilliseconds(750)
} catch {
    "[watcher] could not subscribe: $($_.Exception.Message)" | Add-Content -Path $OutFile -Encoding UTF8
    exit 1
}

function Get-ProcFacts {
    param([int]$TargetPid)
    if ($TargetPid -le 0) { return $null }
    try {
        $ci = Get-CimInstance -Query "SELECT ProcessId,ParentProcessId,Name,CommandLine FROM Win32_Process WHERE ProcessId=$TargetPid" -ErrorAction Stop
        if (-not $ci) { return $null }
        return [pscustomobject]@{
            Pid     = [int]$ci.ProcessId
            Ppid    = [int]$ci.ParentProcessId
            Name    = [string]$ci.Name
            Cmdline = (([string]$ci.CommandLine) -replace '\s+', ' ').Trim()
        }
    } catch { return $null }
}

# Three levels of parentage, rendered as one line. Captured AT START TIME on
# purpose: by the time anyone reads the log the whole chain is usually dead, and
# a pid alone is worthless once it has been recycled.
function Get-ParentChain {
    param([int]$StartPpid)
    $parts = @()
    $cur = $StartPpid
    for ($i = 0; $i -lt 3 -and $cur -gt 0; $i++) {
        $f = Get-ProcFacts $cur
        if (-not $f) { $parts += "pid=$cur(<exited>)"; break }
        $c = $f.Cmdline
        if ($c.Length -gt 160) { $c = $c.Substring(0, 160) + '...' }
        $parts += ("pid={0}({1}){2}" -f $f.Pid, $f.Name, $(if ($c) { " cmd=[$c]" } else { '' }))
        $cur = $f.Ppid
    }
    if ($parts.Count -eq 0) { return '<none>' }
    return ($parts -join ' <- ')
}

$hdr = @(
    "# psmux spawn trace",
    "# started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  watcher pid=$PID  runner pid=$RunnerPid",
    "# images watched: $($names -join ', ')",
    "# format: <time> suite=<name> <IMAGE> pid=<n> [PAUSEORK] cmd=[...] parents=<chain>",
    ""
) -join "`r`n"
[System.IO.File]::AppendAllText($OutFile, $hdr)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = $MaxHours * 3600
$events = 0
$tagged = 0
$suite = '<none>'
$lastSuiteRead = [DateTime]::MinValue

# Desktop access sampler. This watcher is a child of the runner, inside the
# same lineage the suites run in, so what it can or cannot do with the desktop
# is what the suites can or cannot do. On 2026-09-24 that lineage lost the
# clipboard and the foreground for fifty minutes (see the witness note in
# run_all_tests.ps1) and nothing recorded when. Every 750 ms tick probes once;
# only transitions are written, to <run dir>\ui_access.log, with the suite that
# was running at the time.
$uiLog = Join-Path (Split-Path $OutFile -Parent) 'ui_access.log'
$uiState = ''
try {
    if (-not ('SpawnWatchUi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SpawnWatchUi {
    [DllImport("user32.dll", SetLastError=true)] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    public static string Probe() {
        bool ok = OpenClipboard(IntPtr.Zero);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        if (ok) CloseClipboard();
        string r = "";
        if (!ok) r += "clipboard-denied(err=" + err + ")";
        if (GetForegroundWindow() == IntPtr.Zero) r += (r.Length > 0 ? " " : "") + "no-foreground";
        return r;
    }
}
'@ -ErrorAction Stop
    }
} catch { }
function Sample-UiAccess {
    $r = ''
    try { $r = [SpawnWatchUi]::Probe() } catch { return }
    if ($r -eq $script:uiState) { return }
    $script:uiState = $r
    $msg = if ($r) { "DESKTOP REFUSED $r" } else { "desktop usable again" }
    try { [System.IO.File]::AppendAllText($uiLog, ("[{0}] watcher (suite={1}): {2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $suite, $msg)) } catch { }
}

while ($true) {
    if ($sw.Elapsed.TotalSeconds -ge $deadline) { break }

    $e = $null
    try {
        $e = $watcher.WaitForNextEvent()
    } catch [System.Management.ManagementException] {
        # Timeout tick: the only place the runner liveness check needs to happen.
        if (-not (Get-Process -Id $RunnerPid -ErrorAction SilentlyContinue)) { break }
        if (([DateTime]::Now - $lastSuiteRead).TotalMilliseconds -ge 500) {
            $lastSuiteRead = [DateTime]::Now
            try { $s = [System.IO.File]::ReadAllText($SuiteFile); if ($s) { $suite = $s.Trim() } } catch { }
        }
        Sample-UiAccess
        continue
    } catch {
        [System.IO.File]::AppendAllText($OutFile, "# watcher error: $($_.Exception.Message)`r`n")
        break
    }
    if (-not $e) { continue }

    # Refresh the suite label at most twice a second. The file is a dozen bytes
    # and lives in TEMP, but a sweep can start hundreds of consoles in a burst
    # and there is no reason to re-read it for every one of them.
    if (([DateTime]::Now - $lastSuiteRead).TotalMilliseconds -ge 500) {
        $lastSuiteRead = [DateTime]::Now
        try {
            $s = [System.IO.File]::ReadAllText($SuiteFile)
            if ($s) { $suite = $s.Trim() }
        } catch { }
    }

    $events++
    $procId = [int]$e.ProcessID
    $ppid = [int]$e.ParentProcessID
    $image = [string]$e.ProcessName

    $facts = Get-ProcFacts $procId
    $cmdline = if ($facts) { $facts.Cmdline } else { '<exited before lookup>' }
    # `/c pause` and `/k` are the two shapes that park a console for ever waiting
    # on a keypress nobody will ever press, so they get their own tag.
    $tag = ''
    if ($cmdline -match '/c\s+pause\b' -or $cmdline -match '/k(\s|$)') { $tag = ' PAUSEORK'; $tagged++ }

    $line = "{0} suite={1} {2} pid={3}{4} cmd=[{5}] parents={6}" -f `
        (Get-Date -Format 'HH:mm:ss.fff'), $suite, $image, $procId, $tag, $cmdline, (Get-ParentChain $ppid)
    [System.IO.File]::AppendAllText($OutFile, "$line`r`n")
}

try { $watcher.Stop() } catch { }
try { $watcher.Dispose() } catch { }
[System.IO.File]::AppendAllText($OutFile, ("# stopped $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  events=$events pause-or-k=$tagged`r`n"))
