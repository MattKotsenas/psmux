# bench_startup.ps1 — Startup benchmark for psmux (cold + warm server-ready and prompt-ready)
#
# Authoring-only benchmark. Executed serially by the lead in a clean room.
# Measures:
#   - cold_server_ready  : fresh server start (kill-server first) until TCP accept
#   - cold_prompt_ready  : fresh server start until pwsh prompt visible in pane
#   - warm_server_ready  : new-session against an already-warm server until TCP accept
#
# All timing via System.Diagnostics.Stopwatch. Results written as JSON.

param(
    [int]$Iterations = 0,
    [string]$Stamp = "manual"
)

$ErrorActionPreference = "Continue"

$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# Default iteration counts (overridden by -Iterations when > 0)
$coldIters = if ($Iterations -gt 0) { $Iterations } else { 15 }
$warmIters = if ($Iterations -gt 0) { $Iterations } else { 25 }

# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------
function Percentile {
    param($arr, $pct)
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    $sorted = @($arr | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $rank = ($pct / 100.0) * ($sorted.Count - 1)
    $lo = [math]::Floor($rank)
    $hi = [math]::Ceiling($rank)
    if ($lo -eq $hi) { return [double]$sorted[[int]$lo] }
    $frac = $rank - $lo
    return [double]($sorted[[int]$lo] + ($sorted[[int]$hi] - $sorted[[int]$lo]) * $frac)
}

function Get-Mean {
    param($arr)
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    return [double](($arr | Measure-Object -Average).Average)
}

function Get-StdDev {
    param($arr)
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    if ($arr.Count -eq 1) { return 0.0 }
    $mean = Get-Mean $arr
    $sumSq = 0.0
    foreach ($v in $arr) { $sumSq += [math]::Pow(($v - $mean), 2) }
    # Sample standard deviation (n-1)
    return [double][math]::Sqrt($sumSq / ($arr.Count - 1))
}

# ---------------------------------------------------------------------------
# Wait-SessionAlive — poll port file, then confirm TCP accept; return elapsed ms
# ---------------------------------------------------------------------------
function Wait-SessionAlive {
    param([string]$Name, [int]$TimeoutMs)
    $portFile = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $portFile) {
            $port = $null
            try { $port = (Get-Content $portFile -Raw -EA SilentlyContinue).Trim() } catch {}
            if ($port -and ([int]$port) -gt 0) {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                    $tcp.Close()
                    $sw.Stop()
                    return [double]$sw.ElapsedMilliseconds
                } catch {
                    # server not accepting yet, keep polling
                }
            }
        }
        Start-Sleep -Milliseconds 5
    }
    $sw.Stop()
    return $null
}

# ---------------------------------------------------------------------------
# Wait-PanePrompt — poll capture-pane for a pwsh prompt; return elapsed ms
# ---------------------------------------------------------------------------
function Wait-PanePrompt {
    param([string]$Name, [int]$TimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $cap = (& $PSMUX capture-pane -t $Name -p 2>&1) -join "`n"
            if ($cap -match "PS [A-Z]:\\") {
                $sw.Stop()
                return [double]$sw.ElapsedMilliseconds
            }
        } catch {
            # server/pane not ready yet
        }
        Start-Sleep -Milliseconds 50
    }
    $sw.Stop()
    return $null
}

Write-Host ""
Write-Host ("=" * 72)
Write-Host "  psmux STARTUP BENCHMARK"
Write-Host "  binary: $PSMUX"
Write-Host "  cold iters: $coldIters   warm iters: $warmIters   stamp: $Stamp"
Write-Host ("=" * 72)
Write-Host ""

# ---------------------------------------------------------------------------
# COLD loop
# ---------------------------------------------------------------------------
$coldServerReady = @()
$coldPromptReady = @()

Write-Host "--- COLD loop ($coldIters iterations) ---"
for ($i = 0; $i -lt $coldIters; $i++) {
    $sess = "cold$i"

    # Tear down any existing server and stale state
    & $PSMUX kill-server 2>&1 | Out-Null
    try { Get-Process psmux -EA SilentlyContinue | Stop-Process -Force } catch {}
    Remove-Item "$psmuxDir\cold$i.*" -Force -EA SilentlyContinue
    Start-Sleep -Seconds 1

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", $sess, "-d" -WindowStyle Hidden

    $serverMs = Wait-SessionAlive -Name $sess -TimeoutMs 30000
    $promptMs = Wait-PanePrompt -Name $sess -TimeoutMs 30000
    $sw.Stop()

    if ($null -ne $serverMs) {
        $coldServerReady += $serverMs
        Write-Host ("  iter {0,2}: server={1,7:N1} ms" -f $i, $serverMs) -NoNewline
    } else {
        Write-Host ("  iter {0,2}: server=TIMEOUT" -f $i) -NoNewline
    }
    if ($null -ne $promptMs) {
        $coldPromptReady += $promptMs
        Write-Host ("  prompt={0,7:N1} ms" -f $promptMs)
    } else {
        Write-Host "  prompt=TIMEOUT"
    }

    & $PSMUX kill-session -t $sess 2>&1 | Out-Null
}
Write-Host ""

# ---------------------------------------------------------------------------
# WARM loop — keep a single warm server up across iterations
# ---------------------------------------------------------------------------
$warmServerReady = @()

Write-Host "--- WARM loop ($warmIters iterations) ---"
& $PSMUX warmup 2>&1 | Out-Null
Start-Sleep -Seconds 2

for ($i = 0; $i -lt $warmIters; $i++) {
    $sess = "warm$i"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX new-session -d -s $sess 2>&1 | Out-Null
    $serverMs = Wait-SessionAlive -Name $sess -TimeoutMs 30000
    $sw.Stop()

    if ($null -ne $serverMs) {
        $warmServerReady += $serverMs
        Write-Host ("  iter {0,2}: server={1,7:N1} ms" -f $i, $serverMs)
    } else {
        Write-Host ("  iter {0,2}: server=TIMEOUT" -f $i)
    }

    & $PSMUX kill-session -t $sess 2>&1 | Out-Null
}
Write-Host ""

# ---------------------------------------------------------------------------
# Compute stats
# ---------------------------------------------------------------------------
function Get-Stats {
    param($arr)
    $clean = @($arr | Where-Object { $null -ne $_ })
    if ($clean.Count -eq 0) {
        return [ordered]@{
            p50 = $null; p90 = $null; p99 = $null
            min = $null; max = $null; mean = $null; stddev = $null; n = 0
        }
    }
    return [ordered]@{
        p50    = [math]::Round((Percentile $clean 50), 2)
        p90    = [math]::Round((Percentile $clean 90), 2)
        p99    = [math]::Round((Percentile $clean 99), 2)
        min    = [math]::Round([double](($clean | Measure-Object -Minimum).Minimum), 2)
        max    = [math]::Round([double](($clean | Measure-Object -Maximum).Maximum), 2)
        mean   = [math]::Round((Get-Mean $clean), 2)
        stddev = [math]::Round((Get-StdDev $clean), 2)
        n      = $clean.Count
    }
}

$coldServerStats = Get-Stats $coldServerReady
$coldPromptStats = Get-Stats $coldPromptReady
$warmServerStats = Get-Stats $warmServerReady

# ---------------------------------------------------------------------------
# Build result + write JSON
# ---------------------------------------------------------------------------
$cpuName = ""
try { $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name } catch {}

$result = [ordered]@{
    metadata = [ordered]@{
        stamp           = $Stamp
        captured_at     = $Stamp
        cold_iterations = $coldIters
        warm_iterations = $warmIters
        cpu             = $cpuName
        binary          = $PSMUX
    }
    cold_server_ready = $coldServerStats
    cold_prompt_ready = $coldPromptStats
    warm_server_ready = $warmServerStats
}

$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) {
    New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null
}
$jsonPath = "$metricsDir\bench_startup-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

# ---------------------------------------------------------------------------
# Aligned summary table
# ---------------------------------------------------------------------------
Write-Host ("=" * 88)
Write-Host "  SUMMARY (all values in ms)"
Write-Host ("=" * 88)
$hdr = "{0,-20} {1,9} {2,9} {3,9} {4,9} {5,9} {6,9} {7,9} {8,5}"
Write-Host ($hdr -f "metric", "p50", "p90", "p99", "min", "max", "mean", "stddev", "n")
Write-Host ("-" * 88)

function Write-StatRow {
    param([string]$label, $s)
    $fmt = "{0,-20} {1,9} {2,9} {3,9} {4,9} {5,9} {6,9} {7,9} {8,5}"
    $f = { param($v) if ($null -eq $v) { "n/a" } else { ("{0:N1}" -f $v) } }
    Write-Host ($fmt -f $label,
        (& $f $s.p50), (& $f $s.p90), (& $f $s.p99),
        (& $f $s.min), (& $f $s.max), (& $f $s.mean), (& $f $s.stddev), $s.n)
}

Write-StatRow "cold_server_ready" $coldServerStats
Write-StatRow "cold_prompt_ready" $coldPromptStats
Write-StatRow "warm_server_ready" $warmServerStats
Write-Host ("=" * 88)
Write-Host ""
Write-Host "  JSON written to: $jsonPath"
Write-Host ""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
for ($i = 0; $i -lt $coldIters; $i++) {
    & $PSMUX kill-session -t "cold$i" 2>&1 | Out-Null
}
for ($i = 0; $i -lt $warmIters; $i++) {
    & $PSMUX kill-session -t "warm$i" 2>&1 | Out-Null
}
Remove-Item "$psmuxDir\cold*.*", "$psmuxDir\warm*.*" -Force -EA SilentlyContinue
