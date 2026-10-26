# Issue #530 performance: the pruning sweep adds a second directory scan to
# every CLI invocation, so it has to pay for itself.
#
# What this measures, fixed build vs unfixed:
#   1. CLI latency with a realistic 6,000 file backlog (the reported state).
#   2. CLI latency once the directory is clean.
#   3. Steady state: does the sweep cost anything when there is nothing to do?
#
# Run against the unfixed binary with -Binary <path> to get the comparison.

param([string]$Binary = "", [int]$Backlog = 6000)

$ErrorActionPreference = "Continue"
$PSMUX = if ($Binary) { (Resolve-Path $Binary).Path } else { (Get-Command psmux -EA Stop).Source }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Metric($n, $v) { Write-Host ("  [METRIC] {0,-42} {1,8:N1} ms" -f $n, $v) -ForegroundColor DarkCyan }

$SANDBOX = Join-Path $env:TEMP ("i530perf_" + (Get-Random))
$PSMUXDIR = Join-Path $SANDBOX ".psmux"
New-Item -ItemType Directory -Path $PSMUXDIR -Force | Out-Null
$RU = $env:USERPROFILE; $RH = $env:HOME
$SESSION = "perf530"

function Use-SandboxEnv { $env:USERPROFILE = $SANDBOX; $env:HOME = $SANDBOX; $env:PSMUX_TEST_SANDBOX = "1" }
function Restore-Env {
    $env:USERPROFILE = $RU
    if ($null -eq $RH) { Remove-Item Env:\HOME -EA SilentlyContinue } else { $env:HOME = $RH }
}
function Invoke-Psmux {
    param([string[]]$PsmuxArgs)
    Use-SandboxEnv
    try { return (& $PSMUX @PsmuxArgs 2>&1 | Out-String) } finally { Restore-Env }
}
function Percentile($arr, $pct) {
    if ($arr.Count -eq 0) { return 0 }
    $sorted = [double[]]($arr | Sort-Object)
    return $sorted[[Math]::Floor(($pct / 100.0) * ($sorted.Count - 1))]
}
function Measure-Cli {
    param([int]$Iterations = 15)
    $t = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Psmux @("display-message", "-t", $SESSION, "-p", "#{session_name}") | Out-Null
        $sw.Stop()
        [void]$t.Add($sw.Elapsed.TotalMilliseconds)
    }
    return $t
}
function Plant-Backlog {
    param([int]$Count)
    for ($i = 0; $i -lt $Count; $i++) {
        $f = Join-Path $PSMUXDIR "hist$i.sid"
        Set-Content -Path $f -Value "$($i + 90000)" -Encoding ASCII -NoNewline
        (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-14)
    }
}

Write-Host "`n=== Issue #530 sweep cost ===" -ForegroundColor Cyan
Write-Host "  binary:  $PSMUX" -ForegroundColor DarkGray
Write-Host "  backlog: $Backlog files" -ForegroundColor DarkGray

try {
    Invoke-Psmux @("new-session", "-d", "-s", $SESSION) | Out-Null
    $ok = $false
    for ($i = 0; $i -lt 200; $i++) {
        if (Test-Path (Join-Path $PSMUXDIR "$SESSION.port")) { $ok = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ok) { Write-Fail "session never came up"; exit 1 }
    Start-Sleep -Seconds 1

    # --- Baseline: clean directory ------------------------------------------
    $clean = Measure-Cli
    $cleanP50 = Percentile $clean 50
    $cleanP90 = Percentile $clean 90
    Metric "clean dir p50" $cleanP50
    Metric "clean dir p90" $cleanP90

    # --- With the reported backlog ------------------------------------------
    Write-Host "  planting $Backlog aged orphan .sid files..." -ForegroundColor DarkGray
    Plant-Backlog $Backlog
    $filesBefore = (Get-ChildItem $PSMUXDIR -File -Force).Count

    # A single sweep is capped by a per-invocation budget, and sweeps are rate
    # limited by a stamp file. Clear the stamp to stand in for the interval
    # having elapsed, then time ONE sweep over the backlog.
    Remove-Item (Join-Path $PSMUXDIR ".registry_sweep") -Force -EA SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Psmux @("display-message", "-t", $SESSION, "-p", "#{session_name}") | Out-Null
    $sw.Stop()
    $firstMs = $sw.Elapsed.TotalMilliseconds
    Metric "one sweep over a $Backlog file backlog" $firstMs

    $afterOne = (Get-ChildItem $PSMUXDIR -File -Force).Count
    $perSweep = $filesBefore - $afterOne
    Write-Host ("  files after one sweep: {0} -> {1} (removed {2})" -f $filesBefore, $afterOne, $perSweep) -ForegroundColor DarkGray

    if ($perSweep -eq 0) {
        Write-Host "  (unfixed binary: nothing is ever reclaimed, so every call pays the backlog forever)" -ForegroundColor Yellow
        Write-Fail "$Backlog / $Backlog orphans still on disk after a sweep opportunity"
    } else {
        Write-Pass "a single sweep removed $perSweep files and then stopped (bounded work per invocation)"
    }

    if ($firstMs -lt 1000) { Write-Pass ("one bounded sweep cost {0:N0}ms" -f $firstMs) }
    else { Write-Fail ("one sweep took {0:N0}ms, over the 1000ms budget" -f $firstMs) }

    # Drain the rest and confirm the backlog really does go away.
    $sweeps = 1
    while ((Get-ChildItem $PSMUXDIR -Filter "hist*.sid" -File -EA SilentlyContinue).Count -gt 0 -and $sweeps -lt 200) {
        Remove-Item (Join-Path $PSMUXDIR ".registry_sweep") -Force -EA SilentlyContinue
        Invoke-Psmux @("display-message", "-t", $SESSION, "-p", "#{session_name}") | Out-Null
        $sweeps++
    }
    $remaining = (Get-ChildItem $PSMUXDIR -Filter "hist*.sid" -File -EA SilentlyContinue).Count
    Write-Host ("  sweeps needed to drain {0} files: {1}" -f $Backlog, $sweeps) -ForegroundColor DarkGray
    if ($remaining -eq 0) { Write-Pass "the backlog drained completely over $sweeps bounded sweeps" }
    else { Write-Fail "$remaining files still on disk after $sweeps sweeps" }

    $after = Measure-Cli
    $afterP50 = Percentile $after 50
    $afterP90 = Percentile $after 90
    Metric "post-drain p50" $afterP50
    Metric "post-drain p90" $afterP90
    $filesAfter = (Get-ChildItem $PSMUXDIR -File -Force).Count
    Write-Host ("  files: {0} -> {1}" -f $filesBefore, $filesAfter) -ForegroundColor DarkGray

    if ($afterP90 -le ($cleanP90 * 1.5 + 15)) {
        Write-Pass ("post-drain latency back to baseline (p90 {0:N1}ms vs clean {1:N1}ms)" -f $afterP90, $cleanP90)
    } else {
        Write-Fail ("post-drain latency did not return to baseline: p90 {0:N1}ms vs clean {1:N1}ms" -f $afterP90, $cleanP90)
    }

    $metrics = @{
        binary = $PSMUX; backlog = $Backlog
        clean_p50 = $cleanP50; clean_p90 = $cleanP90
        first_call_over_backlog = $firstMs
        after_p50 = $afterP50; after_p90 = $afterP90
        files_before = $filesBefore; files_after = $filesAfter
    }
    $dir = "$env:USERPROFILE\.psmux-test-data\metrics"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $metrics | ConvertTo-Json | Set-Content (Join-Path $dir ("issue530-" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + ".json")) -Encoding UTF8
} finally {
    Invoke-Psmux @("kill-session", "-t", $SESSION) | Out-Null
    Start-Sleep -Milliseconds 500
    Get-ChildItem $PSMUXDIR -Filter "*.pid" -File -EA SilentlyContinue | ForEach-Object {
        $raw = (Get-Content $_.FullName -Raw -EA SilentlyContinue)
        if ($raw -and $raw.Trim() -match '^(\d+)') {
            $q = [int]$Matches[1]
            $g = Get-Process -Id $q -EA SilentlyContinue
            if ($g -and $g.ProcessName -eq "psmux") { try { Stop-Process -Id $q -Force -EA SilentlyContinue } catch {} }
        }
    }
    Start-Sleep -Milliseconds 500
    Remove-Item $SANDBOX -Recurse -Force -EA SilentlyContinue
    Restore-Env
    Remove-Item Env:\PSMUX_TEST_SANDBOX -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
