# bench_scaling.ps1 — psmux scaling + memory benchmark
#
# Measures how psmux scales across windows, panes (splits), and sessions, plus
# memory growth and a leak indicator. Requires a PRE-CREATED base session named
# 'bench_scaling' (the lead creates it before running this script).
#
# Phases:
#   (A) WINDOW SCALING   — create 30 windows in the base session, per-op timing
#   (B) PANE SCALING     — split one window up to 16 times (alternating -h/-v)
#   (C) SESSION SCALING  — create + destroy 10 detached sessions
#   (D) MEMORY PROFILE   — working-set deltas at 10/20/30 windows
#   (E) LEAK CHECK       — kill windows back toward 1, compare mem vs baseline
#
# All timing uses System.Diagnostics.Stopwatch. JSON written to
#   $env:USERPROFILE\.psmux-test-data\metrics\bench_scaling-$Stamp.json

param(
    [string]$Session = "bench_scaling",
    [string]$Stamp   = "manual"
)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -ErrorAction Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# ─── Require a pre-created base session ──────────────────────────────────────
if (-not (Test-Path "$psmuxDir\$Session.port")) {
    Write-Host "SESSION_NOT_READY"
    exit 2
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
function Get-PsmuxMem {
    $s = (Get-Process psmux -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
    if ($s) { [math]::Round($s / 1MB, 1) } else { 0 }
}

function Percentile($arr, $pct) {
    if (-not $arr -or $arr.Count -eq 0) { return 0 }
    $sorted = @($arr | Sort-Object)
    $idx = [math]::Floor(($pct / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
}

function Wait-SessionAlive {
    param([string]$Name, [int]$TimeoutMs = 10000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = 0
            try { $port = [int]((Get-Content $pf -Raw).Trim()) } catch { $port = 0 }
            if ($port -gt 0) {
                $client = $null
                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    $client.Connect("127.0.0.1", $port)
                    if ($client.Connected) {
                        $client.Close()
                        $sw.Stop()
                        return $sw.ElapsedMilliseconds
                    }
                } catch {
                } finally {
                    if ($client) { $client.Close() }
                }
            }
        }
        Start-Sleep -Milliseconds 25
    }
    $sw.Stop()
    return $null
}

# ─── Header ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host "  PSMUX SCALING + MEMORY BENCHMARK" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  base session: $Session  |  stamp: $Stamp" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host ""

$result = @{}
$winMem = @{}

# ════════════════════════════════════════════════════════════════════════════
# (A) WINDOW SCALING — 30 windows in the base session
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 78) -ForegroundColor DarkGray
Write-Host "  (A) WINDOW SCALING — 30 new-window ops" -ForegroundColor Yellow
Write-Host ("-" * 78) -ForegroundColor DarkGray

$winBaselineMem = Get-PsmuxMem
$winMem["baseline"] = $winBaselineMem
Write-Host ("  baseline memory (base session only): {0} MB" -f $winBaselineMem) -ForegroundColor Gray

$winTimes = @()
$winTotalSw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le 30; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX new-window -t $Session 2>&1 | Out-Null
    $sw.Stop()
    $winTimes += $sw.ElapsedMilliseconds

    if ($i -eq 10) { $winMem["after10"] = Get-PsmuxMem }
    elseif ($i -eq 20) { $winMem["after20"] = Get-PsmuxMem }
    elseif ($i -eq 30) { $winMem["after30"] = Get-PsmuxMem }
}
$winTotalSw.Stop()

$winP50 = Percentile $winTimes 50
$winP90 = Percentile $winTimes 90
$winMax = ($winTimes | Measure-Object -Maximum).Maximum
Write-Host ("  new-window p50: {0} ms | p90: {1} ms | max: {2} ms | total(30): {3} ms" -f `
    $winP50, $winP90, $winMax, $winTotalSw.ElapsedMilliseconds) -ForegroundColor Gray
Write-Host ("  mem @10: {0} MB | @20: {1} MB | @30: {2} MB" -f `
    $winMem["after10"], $winMem["after20"], $winMem["after30"]) -ForegroundColor Gray

$result["window_scaling"] = @{
    ops          = 30
    p50_ms       = $winP50
    p90_ms       = $winP90
    max_ms       = $winMax
    total_ms     = $winTotalSw.ElapsedMilliseconds
}
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# (B) PANE SCALING — split one fresh window up to 16 times
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 78) -ForegroundColor DarkGray
Write-Host "  (B) PANE SCALING — alternating -h / -v splits (max 16)" -ForegroundColor Yellow
Write-Host ("-" * 78) -ForegroundColor DarkGray

& $PSMUX new-window -t $Session 2>&1 | Out-Null

$splitTimes = @()
$splitsSucceeded = 0
for ($i = 1; $i -le 16; $i++) {
    $flag = if ($i % 2 -eq 0) { "-v" } else { "-h" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & $PSMUX split-window $flag -t $Session 2>&1 | Out-String
    $sw.Stop()
    $code = $LASTEXITCODE

    if ($code -ne 0 -or $out -match "too small|no space|not enough|cannot split|pane too") {
        Write-Host ("  split $i ($flag) rejected after {0} successful: {1}" -f $splitsSucceeded, $out.Trim()) -ForegroundColor Gray
        break
    }
    $splitTimes += $sw.ElapsedMilliseconds
    $splitsSucceeded++
}

$splitP50 = Percentile $splitTimes 50
$splitP90 = Percentile $splitTimes 90
$splitMax = if ($splitTimes.Count -gt 0) { ($splitTimes | Measure-Object -Maximum).Maximum } else { 0 }
Write-Host ("  splits succeeded: {0} | p50: {1} ms | p90: {2} ms | max: {3} ms" -f `
    $splitsSucceeded, $splitP50, $splitP90, $splitMax) -ForegroundColor Gray

$result["pane_scaling"] = @{
    splits_succeeded = $splitsSucceeded
    p50_ms           = $splitP50
    p90_ms           = $splitP90
    max_ms           = $splitMax
}
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# (C) SESSION SCALING — create + destroy 10 detached sessions
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 78) -ForegroundColor DarkGray
Write-Host "  (C) SESSION SCALING — 10 detached sessions (create + verify + kill)" -ForegroundColor Yellow
Write-Host ("-" * 78) -ForegroundColor DarkGray

$sessTimes = @()
$sessReady = @()
for ($i = 1; $i -le 10; $i++) {
    $name = "scale$i"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX new-session -d -s $name 2>&1 | Out-Null
    $ready = Wait-SessionAlive $name 10000
    $sw.Stop()
    $sessTimes += $sw.ElapsedMilliseconds
    if ($null -ne $ready) { $sessReady += $ready }
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
}

$sessP50 = Percentile $sessTimes 50
$sessP90 = Percentile $sessTimes 90
$sessMax = ($sessTimes | Measure-Object -Maximum).Maximum
Write-Host ("  new-session p50: {0} ms | p90: {1} ms | max: {2} ms | verified-ready: {3}/10" -f `
    $sessP50, $sessP90, $sessMax, $sessReady.Count) -ForegroundColor Gray

$result["session_scaling"] = @{
    sessions          = 10
    p50_ms            = $sessP50
    p90_ms            = $sessP90
    max_ms            = $sessMax
    verified_ready    = $sessReady.Count
}
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# (D) MEMORY PROFILE — per-window deltas
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 78) -ForegroundColor DarkGray
Write-Host "  (D) MEMORY PROFILE — working-set deltas" -ForegroundColor Yellow
Write-Host ("-" * 78) -ForegroundColor DarkGray

$baseMem  = [double]$winMem["baseline"]
$mem10    = [double]$winMem["after10"]
$mem20    = [double]$winMem["after20"]
$mem30    = [double]$winMem["after30"]

$perWin10 = [math]::Round(($mem10 - $baseMem) / 10, 3)
$perWin20 = [math]::Round(($mem20 - $baseMem) / 20, 3)
$perWin30 = [math]::Round(($mem30 - $baseMem) / 30, 3)

Write-Host ("  baseline: {0} MB | after10: {1} MB | after20: {2} MB | after30: {3} MB" -f `
    $baseMem, $mem10, $mem20, $mem30) -ForegroundColor Gray
Write-Host ("  MB/window  @10: {0} | @20: {1} | @30: {2}" -f $perWin10, $perWin20, $perWin30) -ForegroundColor Gray

$result["memory_profile"] = @{
    baseline_mb      = $baseMem
    after10_mb       = $mem10
    after20_mb       = $mem20
    after30_mb       = $mem30
    mb_per_window_10 = $perWin10
    mb_per_window_20 = $perWin20
    mb_per_window_30 = $perWin30
}
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# (E) LEAK CHECK — kill windows back toward 1, compare mem vs baseline
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 78) -ForegroundColor DarkGray
Write-Host "  (E) LEAK CHECK — kill windows back toward 1" -ForegroundColor Yellow
Write-Host ("-" * 78) -ForegroundColor DarkGray

$killed = 0
$guard = 0
while ($guard -lt 100) {
    $guard++
    $countRaw = & $PSMUX display-message -t $Session -p '#{session_windows}' 2>&1 | Out-String
    $count = 0
    try { $count = [int]($countRaw.Trim()) } catch { $count = 0 }
    if ($count -le 1) { break }
    & $PSMUX kill-window -t $Session 2>&1 | Out-Null
    $killed++
}

Start-Sleep -Seconds 2
$memAfterKill = Get-PsmuxMem
$leakIndicator = [math]::Round($memAfterKill - $baseMem, 1)

Write-Host ("  windows killed: {0} | mem after: {1} MB | baseline: {2} MB | leak_indicator: {3} MB" -f `
    $killed, $memAfterKill, $baseMem, $leakIndicator) -ForegroundColor Gray

$result["leak_check"] = @{
    windows_killed     = $killed
    mem_after_kill_mb  = $memAfterKill
    baseline_mb        = $baseMem
    leak_indicator_mb  = $leakIndicator
}
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# Metadata + JSON output
# ════════════════════════════════════════════════════════════════════════════
$cpuName = ""
try { $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name } catch { $cpuName = "unknown" }

$result["metadata"] = @{
    stamp          = $Stamp
    session        = $Session
    timestamp      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    cpu            = $cpuName
    logical_cores  = [System.Environment]::ProcessorCount
    binary         = $PSMUX
}

$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) {
    New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null
}
$outFile = "$metricsDir\bench_scaling-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8

# ════════════════════════════════════════════════════════════════════════════
# Aligned summary table
# ════════════════════════════════════════════════════════════════════════════
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host "  SCALING SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host ("  {0,-26} {1,10} {2,10} {3,10}" -f "Phase", "p50(ms)", "p90(ms)", "max(ms)") -ForegroundColor White
Write-Host ("  {0,-26} {1,10} {2,10} {3,10}" -f "(A) window-create x30", $winP50, $winP90, $winMax)
Write-Host ("  {0,-26} {1,10} {2,10} {3,10}" -f "(B) split-window", $splitP50, $splitP90, $splitMax)
Write-Host ("  {0,-26} {1,10} {2,10} {3,10}" -f "(C) new-session x10", $sessP50, $sessP90, $sessMax)
Write-Host ""
Write-Host ("  {0,-26} {1,10}" -f "windows total (30) ms", $winTotalSw.ElapsedMilliseconds)
Write-Host ("  {0,-26} {1,10}" -f "splits succeeded", $splitsSucceeded)
Write-Host ("  {0,-26} {1,10}" -f "sessions verified", $sessReady.Count)
Write-Host ""
Write-Host ("  {0,-26} {1,10} {2,10} {3,10} {4,10}" -f "Memory(MB)", "baseline", "after10", "after20", "after30") -ForegroundColor White
Write-Host ("  {0,-26} {1,10} {2,10} {3,10} {4,10}" -f "working-set", $baseMem, $mem10, $mem20, $mem30)
Write-Host ("  {0,-26} {1,10} {2,10} {3,10}" -f "MB/window", $perWin10, $perWin20, $perWin30) -ForegroundColor White
Write-Host ""
Write-Host ("  {0,-26} {1,10}" -f "leak indicator (MB)", $leakIndicator) -ForegroundColor White
Write-Host ""
Write-Host ("  JSON: {0}" -f $outFile) -ForegroundColor Gray
Write-Host ""

# ════════════════════════════════════════════════════════════════════════════
# CLEANUP — destroy scratch sessions only; leave base $Session intact
# ════════════════════════════════════════════════════════════════════════════
for ($i = 1; $i -le 10; $i++) {
    & $PSMUX kill-session -t "scale$i" 2>&1 | Out-Null
}

exit 0
