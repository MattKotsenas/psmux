# watch_spawn_failures.ps1
#
# Records every process exit on this machine that carries an NTSTATUS failure
# code, and attributes it to the process that spawned it.
#
# Motivation: 0xC0000142 (STATUS_DLL_INIT_FAILED) kills a process before it can
# file a Windows Error Reporting record, so those failures leave NOTHING in the
# Application event log.  The only way to catch them is to watch process exits
# as they happen.
#
# Two implementation notes, both learned the hard way:
#
#  1. Uses System.Management.ManagementEventWatcher rather than
#     Register-CimIndicationEvent.  The latter depends on the PowerShell
#     runspace event pump, which silently drops these indications in a
#     non-interactive host (subscription succeeds, zero events arrive).
#
#  2. Subscribes to Win32_ProcessTrace, the BASE class, so both start and stop
#     events arrive on one watcher.  Win32_ProcessStopTrace reports
#     ParentProcessID as 0, so parentage has to be captured at START time and
#     joined on ProcessID at stop time.  Command lines are captured at start
#     too, while the process is still alive to be queried.
#
# Usage:
#   pwsh -NoProfile -File tests\watch_spawn_failures.ps1 -DurationSec 120
#   pwsh -NoProfile -File tests\watch_spawn_failures.ps1 -DurationSec 20 -SelfTest
#
# Output: JSONL, one record per failing exit, at -OutFile.

param(
    [int]$DurationSec = 120,
    [string]$OutFile  = "$env:TEMP\psmux_spawn_failures.jsonl",
    [string]$AllFile  = "",
    # Only these names get the (relatively costly) command-line lookup at start.
    [string[]]$TrackNames = @('pwsh','powershell','psmux','conhost','OpenConsole','cmd','handlecheck'),
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Management

$KNOWN = @{
    [uint32]3221225794 = '0xC0000142 STATUS_DLL_INIT_FAILED'
    [uint32]3221225477 = '0xC0000005 STATUS_ACCESS_VIOLATION'
    [uint32]3221225781 = '0xC0000135 STATUS_DLL_NOT_FOUND'
    [uint32]3221226505 = '0xC0000409 STATUS_STACK_BUFFER_OVERRUN'
    [uint32]3221225786 = '0xC000013A STATUS_CONTROL_C_EXIT'
    [uint32]3221225725 = '0xC00000FD STATUS_STACK_OVERFLOW'
}

Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
if ($AllFile) { Remove-Item $AllFile -Force -ErrorAction SilentlyContinue }

$scope = New-Object System.Management.ManagementScope('\\.\root\cimv2')
$scope.Connect()

# Base class => both Win32_ProcessStartTrace and Win32_ProcessStopTrace.
$query   = New-Object System.Management.WqlEventQuery("SELECT * FROM Win32_ProcessTrace")
$watcher = New-Object System.Management.ManagementEventWatcher($scope, $query)
$watcher.Options.Timeout = [TimeSpan]::FromMilliseconds(500)

# pid -> spawn facts, captured at start while the process is still queryable.
$born = @{}

function Get-Cmdline {
    param([uint32]$TargetPid)
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction Stop
        return [string]$ci.CommandLine
    } catch { return '' }
}

Write-Host "[watcher] armed for ${DurationSec}s  pid=$PID" -ForegroundColor Cyan
Write-Host "[watcher] failures -> $OutFile" -ForegroundColor DarkGray

if ($SelfTest) {
    Start-Job -ScriptBlock {
        Start-Sleep -Milliseconds 1200
        # STATUS_CONTROL_C_EXIT (0xC000013A) is an NTSTATUS failure we can
        # produce on demand, proving the failure path writes a record.
        $p = Start-Process cmd.exe -ArgumentList '/c','pause' -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 600
        Stop-Process -Id $p.Id -Force
    } | Out-Null
}

$sw       = [System.Diagnostics.Stopwatch]::StartNew()
$failures = 0
$stops    = 0
$starts   = 0

while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    try {
        $e = $watcher.WaitForNextEvent()
    } catch [System.Management.ManagementException] {
        continue    # timeout: how this loop idles
    } catch {
        Write-Host "[watcher] error: $($_.Exception.Message)" -ForegroundColor Red
        break
    }

    $cls    = $e.ClassPath.ClassName
    $name   = [string]$e.ProcessName
    $procId = [uint32]$e.ProcessID

    if ($cls -eq 'Win32_ProcessStartTrace') {
        $starts++
        $ppid  = [uint32]$e.ParentProcessID
        $short = $name -replace '\.exe$',''
        $track = $TrackNames -contains $short

        $parentName = '<unknown>'
        try { $parentName = (Get-Process -Id $ppid -ErrorAction Stop).ProcessName } catch { $parentName = '<exited>' }

        $born[$procId] = @{
            name       = $name
            ppid       = $ppid
            parent     = $parentName
            cmdline    = $(if ($track) { Get-Cmdline $procId } else { '' })
            parent_cmd = $(if ($track) { Get-Cmdline $ppid } else { '' })
            born_at    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        continue
    }

    if ($cls -ne 'Win32_ProcessStopTrace') { continue }

    $stops++
    $status = [uint32]$e.ExitStatus
    $info   = $born[$procId]

    $rec = [ordered]@{
        time      = (Get-Date).ToString('o')
        elapsed_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        process   = $name
        pid       = $procId
        exit_dec  = $status
        exit_hex  = ('0x{0:X8}' -f $status)
        known     = $(if ($KNOWN.ContainsKey($status)) { $KNOWN[$status] } else { '' })
        lifetime_s = $(if ($info) { [math]::Round($sw.Elapsed.TotalSeconds - $info.born_at, 2) } else { $null })
        ppid       = $(if ($info) { $info.ppid }       else { $null })
        parent     = $(if ($info) { $info.parent }     else { '<not-seen-at-start>' })
        cmdline    = $(if ($info) { $info.cmdline }    else { '' })
        parent_cmd = $(if ($info) { $info.parent_cmd } else { '' })
    }

    if ($AllFile) { ($rec | ConvertTo-Json -Compress) | Add-Content -Path $AllFile -Encoding UTF8 }

    # Severity bits set => NTSTATUS error.  A plain `exit 7` is not of interest.
    #
    # The L suffix is load-bearing.  PowerShell parses a hex literal at or above
    # 0x80000000 as a SIGNED Int32, so a bare 0xC0000000 is -1073741824 and the
    # comparison never matches -- every failure would be silently classified as
    # healthy.  0xC0000000L forces Int64 and keeps the value positive.
    if (($status -band 0xC0000000L) -eq 0xC0000000L) {
        ($rec | ConvertTo-Json -Compress) | Add-Content -Path $OutFile -Encoding UTF8
        $failures++
        $label = if ($rec.known) { $rec.known } else { $rec.exit_hex }
        Write-Host ("[watcher] FAIL {0} pid={1} parent={2}({3}) life={4}s {5}" -f `
            $name, $procId, $rec.parent, $rec.ppid, $rec.lifetime_s, $label) -ForegroundColor Red
    }

    $born.Remove($procId)
}

$watcher.Stop()
$watcher.Dispose()

# Leaked-process report.
#
# Everything still in $born started during the window and never stopped.  This
# is a separate failure mode from an NTSTATUS exit and the stop-driven path
# above STRUCTURALLY cannot see it: a process that hangs forever never emits a
# stop event, so it produces no record at all.  That blind spot is why an
# earlier hunt for leaked `pwsh -NoProfile -Command echo` shells (bare `echo`
# reads the pipeline forever and never exits) came up empty.
#
# Only processes still alive at the end count -- an entry can also linger in
# $born because its stop event was missed.
$leaks = @()
foreach ($entry in $born.GetEnumerator()) {
    $stillAlive = $false
    try { $null = Get-Process -Id $entry.Key -ErrorAction Stop; $stillAlive = $true } catch { }
    if (-not $stillAlive) { continue }
    $info = $entry.Value
    $leaks += [ordered]@{
        pid        = $entry.Key
        process    = $info.name
        born_at_s  = $info.born_at
        alive_s    = [math]::Round($sw.Elapsed.TotalSeconds - $info.born_at, 1)
        ppid       = $info.ppid
        parent     = $info.parent
        cmdline    = $info.cmdline
        parent_cmd = $info.parent_cmd
    }
}

if ($leaks.Count -gt 0) {
    $leakFile = [System.IO.Path]::ChangeExtension($OutFile, $null) + 'leaks.jsonl'
    foreach ($l in $leaks) { ($l | ConvertTo-Json -Compress) | Add-Content -Path $leakFile -Encoding UTF8 }
    Write-Host "[watcher] LEAKED (started, never exited, still alive):" -ForegroundColor Yellow
    $leaks | Sort-Object alive_s -Descending | Select-Object -First 20 | ForEach-Object {
        Write-Host ("  pid={0} {1} alive={2}s parent={3}({4})" -f $_.pid, $_.process, $_.alive_s, $_.parent, $_.ppid) -ForegroundColor Yellow
        if ($_.cmdline) { Write-Host ("      " + ($_.cmdline -replace '\s+', ' ')) -ForegroundColor DarkYellow }
    }
    Write-Host ("[watcher] leak records: $leakFile") -ForegroundColor Yellow
}

Write-Host "[watcher] done. starts=$starts stops=$stops ntstatus-failures=$failures leaked=$($leaks.Count)" -ForegroundColor Cyan
if ($failures -gt 0) {
    Write-Host "[watcher] records: $OutFile" -ForegroundColor Yellow
} else {
    Write-Host "[watcher] no NTSTATUS failures observed" -ForegroundColor Green
}
