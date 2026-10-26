# psmux run-shell child PATH test
#
# A run-shell child inherits the SERVER's environment, and the server is not
# necessarily started by a process whose PATH contains the psmux install
# directory: a parked warm server keeps the environment of whatever spawned it,
# even after a later session claims it. Plugin scripts and key bindings that
# shell out to `psmux` then fail with "not recognized as the name of a cmdlet"
# although psmux is demonstrably running.
#
# This test starts a server whose PATH deliberately does NOT contain the psmux
# directory (the poisoned case) and proves that a run-shell child can still
# resolve `psmux`:
#   1. the server really was started without the psmux directory on PATH
#      (otherwise the test would not reproduce the reported failure)
#   2. the probe child resolves `psmux` to the directory psmux runs from
#   3. that directory appears exactly once on the child PATH - so the fix
#      supplied it and not the inherited environment
#
# Note: the psmux directory is prepended on the SERVER side. A `pwsh` child
# prepends $PSHOME to its own PATH at startup, so the child itself may not show
# the psmux directory first even though the server put it there.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_run_shell_child_path.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { Write-Error "psmux binary not found. Build first: cargo build --release"; exit 1 }

$PSMUX_DIR = Split-Path $PSMUX -Parent
$NS        = "rspath"     # isolated namespace - the default one is never touched
$SESSION   = "rspath"
$PROBE     = Join-Path $env:TEMP "psmux_run_shell_child_path_probe.ps1"
$RESULT    = Join-Path $env:TEMP "psmux_run_shell_child_path_result.txt"

Write-Info "psmux:     $PSMUX"
Write-Info "psmux dir: $PSMUX_DIR"

function Normalize([string]$Path) { return $Path.TrimEnd([char[]]("\", "/")) }

function Cleanup {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$env:USERPROFILE\.psmux\$NS.*" -Force -ErrorAction SilentlyContinue
}

# The probe runs as the child of run-shell and reports what it can resolve.
@'
$dir = $args[0]
$out = New-Object System.Collections.Generic.List[string]
$found = Get-Command psmux -ErrorAction SilentlyContinue
$out.Add("resolved=" + $(if ($found) { $found.Source } else { "NOT_FOUND" }))
$entries = @($env:PATH -split ';')
$out.Add("count=" + @($entries | Where-Object { $_.TrimEnd([char[]]("\", "/")) -ieq $dir.TrimEnd([char[]]("\", "/")) }).Count)
$out.Add("first=" + $entries[0])
Set-Content -LiteralPath $args[1] -Value $out -Encoding UTF8
'@ | Set-Content -LiteralPath $PROBE -Encoding UTF8

Cleanup
Remove-Item $RESULT -Force -ErrorAction SilentlyContinue

# ── Start the server with a PATH that lacks the psmux directory ─────────────
Write-Info "starting a server whose PATH excludes $PSMUX_DIR ..."
$savedPath = $env:PATH
$env:PATH  = (@($savedPath -split ';' | Where-Object { (Normalize $_) -ine (Normalize $PSMUX_DIR) }) -join ';')
$leftover  = @($env:PATH -split ';' | Where-Object { (Normalize $_) -ieq (Normalize $PSMUX_DIR) })
$poisoned  = ($leftover.Count -eq 0)
& $PSMUX -L $NS new-session -d -s $SESSION 2>&1 | Out-Null
$env:PATH = $savedPath
Start-Sleep -Seconds 3

# ── Route the probe through the server (`#{pane_id}` keeps it server-side) ───
$probeCmd = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$PROBE`" `"$PSMUX_DIR`" `"$RESULT`" #{pane_id}"
Write-Info "run-shell -b $probeCmd"
& $PSMUX -L $NS run-shell -b $probeCmd 2>&1 | Out-Null

$deadline = [DateTime]::Now.AddSeconds(30)
while (-not (Test-Path $RESULT) -and [DateTime]::Now -lt $deadline) { Start-Sleep -Milliseconds 500 }

if (-not (Test-Path $RESULT)) {
    Write-Fail "the run-shell child never reported back (no $RESULT after 30s)"
} else {
    $report = @{}
    foreach ($line in Get-Content -LiteralPath $RESULT) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $report[$pair[0].Trim()] = $pair[1].Trim() }
    }
    Write-Info ("child report: resolved={0} count={1} first={2}" -f $report['resolved'], $report['count'], $report['first'])

    if ($poisoned) {
        Write-Pass "the server was started with a PATH that has no psmux directory (reproduces the reported failure)"
    } else {
        Write-Fail "setup: could not remove $PSMUX_DIR from PATH before starting the server"
    }

    $resolved = $report['resolved']
    if ($resolved -and $resolved -ne "NOT_FOUND" -and (Normalize (Split-Path $resolved -Parent)) -ieq (Normalize $PSMUX_DIR)) {
        Write-Pass "run-shell child resolved psmux to $resolved"
    } else {
        Write-Fail "run-shell child could not resolve psmux (resolved='$resolved', expected a binary in $PSMUX_DIR)"
    }

    if ("$($report['count'])" -eq "1" -and $poisoned) {
        Write-Pass "the psmux directory appears exactly once on the child PATH, and the server's own PATH did not have it - the fix supplied it"
    } else {
        Write-Fail "expected the psmux directory exactly once on the child PATH, got count='$($report['count'])' (poisoned=$poisoned)"
    }
}

# ── Teardown ────────────────────────────────────────────────────────────────
Cleanup
Remove-Item $PROBE, $RESULT -Force -ErrorAction SilentlyContinue

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
