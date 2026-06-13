# bench_throughput.ps1 - Output rendering throughput benchmark for psmux
#
# Measures how fast psmux renders bulk shell output to its pane. Three scenarios,
# each repeated >=5 times, polling capture-pane until a per-rep sentinel appears.
#
#   Scenario A BULK       - 5000 lines with payload text
#   Scenario B ANSI-HEAVY - 2000 lines each with an ANSI SGR color escape
#   Scenario C RAPID BURST- 10000 short numeric lines
#
# Reports time-to-complete p50/p90/max and throughput lines/sec p50 per scenario.
# Writes a JSON metrics file. Does NOT create or kill the session - the lead
# pre-creates session 'bench_throughput'. This script is authoring/run-only and
# never launches psmux itself beyond send-keys/capture-pane against the live session.

param(
    [string]$Session = "bench_throughput",
    [string]$Stamp   = "manual",
    [int]$Reps       = 5
)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# The lead pre-creates the session. Bail clearly if it is not ready.
if (-not (Test-Path "$psmuxDir\$Session.port")) {
    Write-Host "SESSION_NOT_READY"
    exit 2
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Percentile {
    param([double[]]$Arr, [int]$Pct)
    if (-not $Arr -or $Arr.Count -eq 0) { return $null }
    $sorted = $Arr | Sort-Object
    $idx = [Math]::Floor(($Pct / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
}

# Send a command and poll capture-pane until the sentinel appears. Returns
# elapsed milliseconds, or $null on timeout.
function Measure-Bulk {
    param(
        [string]$Cmd,
        [string]$Sentinel,
        [int]$TimeoutMs = 30000
    )
    $escaped = [regex]::Escape($Sentinel)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX send-keys -t $Session $Cmd Enter
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Session -p | Out-String
        if ($cap -match $escaped) {
            $sw.Stop()
            return $sw.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 75
    }
    $sw.Stop()
    return $null
}

function Clear-Pane {
    & $PSMUX send-keys -t $Session 'clear' Enter
    Start-Sleep -Milliseconds 400
}

# Run a scenario over $Reps reps. $CmdBuilder is a scriptblock taking the
# sentinel string and returning the shell command to send.
function Invoke-Scenario {
    param(
        [string]$Name,
        [string]$Tag,
        [int]$Lines,
        [scriptblock]$CmdBuilder,
        [int]$TimeoutMs = 30000
    )

    Write-Host ""
    Write-Host ("--- Scenario {0}: {1} ({2} lines x {3} reps) ---" -f $Tag, $Name, $Lines, $Reps) -ForegroundColor Yellow

    $times = @()
    $rates = @()
    for ($rep = 1; $rep -le $Reps; $rep++) {
        $sentinel = "BENCH_${Tag}_$rep"
        $cmd = & $CmdBuilder $sentinel
        $ms = Measure-Bulk -Cmd $cmd -Sentinel $sentinel -TimeoutMs $TimeoutMs
        if ($null -ne $ms) {
            $times += [double]$ms
            $secs = $ms / 1000.0
            $lps = if ($secs -gt 0) { [Math]::Round($Lines / $secs, 1) } else { 0 }
            $rates += [double]$lps
            Write-Host ("  rep {0}/{1}: {2,7:N0} ms  {3,10:N1} lines/sec" -f $rep, $Reps, $ms, $lps) -ForegroundColor Green
        } else {
            Write-Host ("  rep {0}/{1}: TIMEOUT (>{2} ms)" -f $rep, $Reps, $TimeoutMs) -ForegroundColor Red
        }
        Clear-Pane
    }

    $p50 = Percentile $times 50
    $p90 = Percentile $times 90
    $maxMs = if ($times.Count -gt 0) { ($times | Measure-Object -Maximum).Maximum } else { $null }
    $lpsP50 = Percentile $rates 50

    return [ordered]@{
        name          = $Name
        tag           = $Tag
        lines         = $Lines
        reps          = $Reps
        valid         = $times.Count
        time_p50_ms   = $p50
        time_p90_ms   = $p90
        time_max_ms   = $maxMs
        lines_per_sec_p50 = $lpsP50
        samples_ms    = $times
        samples_lps   = $rates
    }
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "  PSMUX OUTPUT RENDERING THROUGHPUT BENCHMARK" -ForegroundColor Cyan
Write-Host ("  Session: {0} | Stamp: {1} | Reps: {2}" -f $Session, $Stamp, $Reps) -ForegroundColor Cyan
Write-Host ("  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan

# Settle the pane before starting.
Clear-Pane

# ---------------------------------------------------------------------------
# Scenario A: BULK - 5000 lines with payload
#   Inner shell command (single-quoted so $ stays literal for the child shell):
#     1..5000 | % { "line $_ payload ABCDEFGHIJKLMNOP" }; echo SENTINEL
# ---------------------------------------------------------------------------
$scenA = Invoke-Scenario -Name "BULK" -Tag "A" -Lines 5000 -CmdBuilder {
    param($s)
    '1..5000 | % { "line $_ payload ABCDEFGHIJKLMNOP" }; echo ' + $s
}

# ---------------------------------------------------------------------------
# Scenario B: ANSI-HEAVY - 2000 lines each with an ANSI SGR sequence
#   Inner: $e=[char]27; 1..2000 | % { "$e[3$($_ % 8)mcolor $_$e[0m" }; echo SENTINEL
# ---------------------------------------------------------------------------
$scenB = Invoke-Scenario -Name "ANSI-HEAVY" -Tag "B" -Lines 2000 -CmdBuilder {
    param($s)
    '$e=[char]27; 1..2000 | % { "$e[3$($_ % 8)mcolor $_$e[0m" }; echo ' + $s
}

# ---------------------------------------------------------------------------
# Scenario C: RAPID BURST - 10000 short numeric lines
#   Inner: 1..10000 | % { "$_" }; echo SENTINEL
# ---------------------------------------------------------------------------
$scenC = Invoke-Scenario -Name "RAPID BURST" -Tag "C" -Lines 10000 -CmdBuilder {
    param($s)
    '1..10000 | % { "$_" }; echo ' + $s
}

# ---------------------------------------------------------------------------
# Assemble result + metadata, write JSON
# ---------------------------------------------------------------------------
$cpu = $null
try { $cpu = (Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1).Name } catch {}

$result = [ordered]@{
    metadata = [ordered]@{
        stamp     = $Stamp
        session   = $Session
        reps      = $Reps
        cpu       = $cpu
        timestamp = (Get-Date -Format 'o')
        psmux     = $PSMUX
    }
    scenarios = [ordered]@{
        A = $scenA
        B = $scenB
        C = $scenC
    }
}

$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) {
    New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null
}
$outFile = Join-Path $metricsDir "bench_throughput-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8

# ---------------------------------------------------------------------------
# Aligned summary table
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host ("  {0,-14} {1,6} {2,5} {3,11} {4,11} {5,11} {6,14}" -f `
    "Scenario", "Lines", "Valid", "p50 ms", "p90 ms", "max ms", "lines/s p50") -ForegroundColor White
Write-Host ("  " + ("-" * 70)) -ForegroundColor DarkGray

foreach ($s in @($scenA, $scenB, $scenC)) {
    $p50 = if ($null -ne $s.time_p50_ms) { "{0:N0}" -f $s.time_p50_ms } else { "n/a" }
    $p90 = if ($null -ne $s.time_p90_ms) { "{0:N0}" -f $s.time_p90_ms } else { "n/a" }
    $mx  = if ($null -ne $s.time_max_ms) { "{0:N0}" -f $s.time_max_ms } else { "n/a" }
    $lps = if ($null -ne $s.lines_per_sec_p50) { "{0:N1}" -f $s.lines_per_sec_p50 } else { "n/a" }
    Write-Host ("  {0,-14} {1,6} {2,5} {3,11} {4,11} {5,11} {6,14}" -f `
        $s.name, $s.lines, $s.valid, $p50, $p90, $mx, $lps)
}

Write-Host ""
Write-Host ("  Metrics written to: {0}" -f $outFile) -ForegroundColor Gray
Write-Host ("  Session '{0}' left running (not killed)." -f $Session) -ForegroundColor Gray
Write-Host ""

exit 0
