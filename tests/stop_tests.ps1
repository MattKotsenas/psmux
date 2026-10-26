# Stop a running psmux test suite cleanly, from ANY window.
#
# WHY THIS EXISTS: the runner console is not reachable from the keyboard for
# most of a run. Suites launch attached psmux clients in their own consoles and
# those windows take the foreground within seconds (measured 2026-08-26: the
# runner window held focus for 2s of a tui_proof run and never got it back), so
# Ctrl+C lands in a psmux pane instead of the runner. Before this, the only way
# out of a multi-hour sweep was killing pwsh from Task Manager, which skipped
# the summary and stranded every psmux server the in-flight suite had started.
#
# This writes the abort flag the runner polls once a second. The runner then
# kills the current suite's process tree, tears down psmux, writes the summary
# for everything that did complete, and exits 130.
#
# Usage:
#   tests\stop_tests.cmd                 stop the active run and wait for it
#   tests\stop_tests.cmd -Force          also kill the runner if it will not stop
#   tests\stop_tests.cmd -TimeoutSec 60  how long to wait before giving up
param(
    [switch]$Force,
    [int]$TimeoutSec = 45
)

$ErrorActionPreference = 'Continue'
$lockFile = Join-Path $env:TEMP 'psmux-testrun.lock'
$stopFile = Join-Path $env:TEMP 'psmux-teststop.flag'

# Same pid anchor the launcher uses: pid plus process start time, so a recycled
# pid cannot make a dead run look alive.
function Get-ActiveRun {
    if (-not (Test-Path $lockFile)) { return $null }
    $raw = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { return $null }
    $parts = $raw.Trim() -split ':'
    if ($parts.Count -ne 2) { return $null }
    $pidVal = 0; $ticks = 0L
    if (-not [int]::TryParse($parts[0], [ref]$pidVal)) { return $null }
    if (-not [long]::TryParse($parts[1], [ref]$ticks)) { return $null }
    $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    if ($p.StartTime.Ticks -ne $ticks) { return $null }
    return $p
}

$run = Get-ActiveRun
if (-not $run) {
    Write-Host ''
    Write-Host 'No psmux test run is active.' -ForegroundColor Green
    # Never leave a flag behind for a run that is not there to consume it. The
    # runner also clears it at startup, but belt and braces: a stray flag here
    # would be an invisible landmine under the next sweep.
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Host ''
Write-Host ("Stopping psmux test run (pid {0}, started {1})" -f $run.Id, $run.StartTime) -ForegroundColor Cyan
Set-Content -Path $stopFile -Value 'stop requested' -Encoding ASCII

Write-Host '  Flag written. The runner checks it once a second; it will kill the' -ForegroundColor DarkGray
Write-Host '  current suite tree, tear down psmux and print its summary.' -ForegroundColor DarkGray
Write-Host ''

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-ActiveRun)) {
        Write-Host 'Run stopped cleanly.' -ForegroundColor Green
        $logRoot = Join-Path $env:TEMP 'psmux-test-logs'
        $latest = Join-Path $logRoot 'latest_run.txt'
        if (Test-Path $latest) {
            $id = (Get-Content $latest -Raw).Trim()
            Write-Host ("  Summary: {0}" -f (Join-Path $logRoot "$id\summary.log")) -ForegroundColor DarkGray
            Write-Host '  Resume:  tests\run_full_interactive.cmd -Resume' -ForegroundColor DarkGray
        }
        exit 0
    }
    Start-Sleep -Milliseconds 500
}

# Still alive. A suite wedged inside a native call can outlast the poll, so the
# escape hatch is explicit rather than automatic: killing the runner skips its
# cleanup, which is exactly the mess this script exists to avoid.
Write-Host ("Run did not stop within {0}s." -f $TimeoutSec) -ForegroundColor Yellow
if (-not $Force) {
    Write-Host 'Re-run with -Force to kill it outright (skips its cleanup).' -ForegroundColor Yellow
    exit 1
}

Write-Host 'Force: killing the runner process tree.' -ForegroundColor Red
& taskkill /F /T /PID $run.Id 2>&1 | Out-Null
Start-Sleep -Seconds 2

# The runner never got to run Clean-Server, so do its job here: a forced kill
# otherwise leaves live psmux servers holding ports that poison the next run.
$alive = @(Get-Process psmux -ErrorAction SilentlyContinue)
if ($alive.Count -gt 0) {
    Write-Host ("  Killing {0} orphaned psmux process(es)" -f $alive.Count) -ForegroundColor Yellow
    $alive | Stop-Process -Force -ErrorAction SilentlyContinue
}
Remove-Item "$env:USERPROFILE\.psmux\*.port" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.psmux\*.key"  -Force -ErrorAction SilentlyContinue
Remove-Item $lockFile, $stopFile -Force -ErrorAction SilentlyContinue
Write-Host 'Killed. No summary was written for this run.' -ForegroundColor Yellow
exit 130
