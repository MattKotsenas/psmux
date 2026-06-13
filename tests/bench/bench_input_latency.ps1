# bench_input_latency.ps1 - Keystroke-to-echo latency benchmark for psmux
#
# Headline "typing speed" metric: time from sending a single character over a
# PERSISTENT authed TCP socket until that character is echoed into the pane,
# observed via dump-state. Measures three scenarios so the lead can compare
# idle latency against latency under output load and with large scrollback.
#
# AUTHORING NOTE: This benchmark does NOT create or kill the session. The lead
# pre-creates a detached session named (by default) 'bench_input' and runs this
# script serially. We only connect, measure, and disconnect.

param(
    [string]$Session = "bench_input",
    [string]$Stamp   = "manual",
    [int]$Samples    = 30
)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# ── Session must already exist (lead pre-creates it) ──
if (-not (Test-Path "$psmuxDir\$Session.port")) {
    Write-Host "SESSION_NOT_READY"
    exit 2
}

# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────

function Percentile {
    param([double[]]$Arr, [double]$Pct)
    if (-not $Arr -or $Arr.Count -eq 0) { return 0.0 }
    $sorted = [double[]]($Arr | Sort-Object)
    $idx = [Math]::Floor(($Pct / 100.0) * ($sorted.Count - 1))
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -gt ($sorted.Count - 1)) { $idx = $sorted.Count - 1 }
    return $sorted[$idx]
}

function Get-StdDev {
    param([double[]]$Arr)
    if (-not $Arr -or $Arr.Count -lt 2) { return 0.0 }
    $mean = ($Arr | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Arr) { $sumSq += [Math]::Pow($v - $mean, 2) }
    return [Math]::Sqrt($sumSq / ($Arr.Count - 1))
}

function Connect-Persistent {
    param([string]$Name)
    $port = (Get-Content "$psmuxDir\$Name.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Name.key"  -Raw).Trim()

    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 10000
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $false
    $reader = [System.IO.StreamReader]::new($stream)

    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()

    $writer.Write("PERSISTENT`n"); $writer.Flush()
    Start-Sleep -Milliseconds 100

    return @{ tcp = $tcp; stream = $stream; writer = $writer; reader = $reader }
}

# Pull a fresh dump-state payload. The server may answer "NC" (no change) or
# short control lines; we loop until we see a substantial state line.
function Get-Dump {
    param($Conn)
    $Conn.writer.Write("dump-state`n"); $Conn.writer.Flush()
    $line = $null
    for ($i = 0; $i -lt 100; $i++) {
        try { $r = $Conn.reader.ReadLine() } catch { break }
        if ($null -eq $r) { break }
        if ($r.Length -gt 100 -and $r -ne "NC") { $line = $r; break }
        # Once we have started receiving, shrink the read timeout so trailing
        # NC / control lines do not stall the loop.
        $Conn.stream.ReadTimeout = 200
    }
    $Conn.stream.ReadTimeout = 10000
    return $line
}

# Measure a single keystroke-to-echo latency in ms. Sends "x", then polls
# dump-state until the state hash changes, capped at 500ms. Returns elapsed ms
# (or the 500ms cap if no echo was observed). Updates [ref]$PrevHash in place.
function Measure-Echo {
    param($Conn, [ref]$PrevHash)
    $freq = [System.Diagnostics.Stopwatch]::Frequency
    $maxTicks = $freq / 2   # 500ms cap

    $start = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $Conn.writer.Write("send-text ""x""`n"); $Conn.writer.Flush()

    $found = $false
    while (([System.Diagnostics.Stopwatch]::GetTimestamp() - $start) -lt $maxTicks) {
        $dump = Get-Dump $Conn
        if ($dump) {
            $h = $dump.GetHashCode()
            if ($h -ne $PrevHash.Value) {
                $PrevHash.Value = $h
                $found = $true
                break
            }
        }
    }
    $end = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $elapsedMs = ($end - $start) * 1000.0 / $freq
    return [PSCustomObject]@{ Ms = $elapsedMs; Found = $found }
}

function Run-Scenario {
    param($Conn, [string]$Label, [int]$Count)

    Write-Host ""
    Write-Host "[$Label] collecting $Count samples..." -ForegroundColor Yellow

    # Establish a baseline hash before timing.
    $baseline = Get-Dump $Conn
    if (-not $baseline) { $baseline = "" }
    $prevHash = $baseline.GetHashCode()

    $samples = [System.Collections.ArrayList]::new()
    $missed = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $m = Measure-Echo $Conn ([ref]$prevHash)
        [void]$samples.Add([double]$m.Ms)
        if (-not $m.Found) { $missed++ }
    }

    $arr = [double[]]$samples
    return @{
        label  = $Label
        count  = $arr.Count
        missed = $missed
        p50    = [Math]::Round((Percentile $arr 50), 2)
        p90    = [Math]::Round((Percentile $arr 90), 2)
        p99    = [Math]::Round((Percentile $arr 99), 2)
        max    = [Math]::Round((($arr | Measure-Object -Maximum).Maximum), 2)
        mean   = [Math]::Round((($arr | Measure-Object -Average).Average), 2)
        stddev = [Math]::Round((Get-StdDev $arr), 2)
    }
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "psmux input-latency benchmark (keystroke-to-echo)" -ForegroundColor Cyan
Write-Host ("  session=$Session  stamp=$Stamp  samples=$Samples") -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$conn = Connect-Persistent $Session

# Let the shell settle and prime the dump-state channel.
for ($i = 0; $i -lt 25; $i++) {
    $d = Get-Dump $conn
    if ($d) { break }
    Start-Sleep -Milliseconds 200
}

$scenarios = @{}

# ── (A) IDLE ──────────────────────────────────────────────────────────────
$scenarios["IDLE"] = Run-Scenario $conn "IDLE" $Samples

# ── (B) UNDER_LOAD ────────────────────────────────────────────────────────
# Kick off a long-running output stream in the pane so echo latency is
# measured while the renderer is busy draining pane output.
& $PSMUX send-keys -t $Session '1..200000 | %{ "load $_" }' Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$scenarios["UNDER_LOAD"] = Run-Scenario $conn "UNDER_LOAD" $Samples

# ── (C) LARGE_SCROLLBACK ──────────────────────────────────────────────────
# Fill the scrollback buffer, wait for the burst to finish (prompt returns),
# then measure with a large history present.
& $PSMUX send-keys -t $Session '1..5000 | %{ "fill $_" }' Enter 2>&1 | Out-Null
$settled = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    $cap = & $PSMUX capture-pane -t $Session -p 2>&1 | Out-String
    if ($cap -match "PS [A-Z]:\\" -or $cap -match "PS [A-Z]:/") { $settled = $true; break }
}
if (-not $settled) { Start-Sleep -Seconds 5 }
$scenarios["LARGE_SCROLLBACK"] = Run-Scenario $conn "LARGE_SCROLLBACK" $Samples

# ── Close socket (do NOT kill the session) ────────────────────────────────
try { $conn.writer.Close() } catch {}
try { $conn.reader.Close() } catch {}
try { $conn.tcp.Close() } catch {}

# ──────────────────────────────────────────────────────────────────────────
# Persist metrics
# ──────────────────────────────────────────────────────────────────────────

$cpu = ""
try { $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name } catch {}

$result = @{
    benchmark = "input_latency_keystroke_to_echo"
    stamp     = $Stamp
    session   = $Session
    samples   = $Samples
    cpu       = $cpu
    timestamp = (Get-Date -Format "o")
    scenarios = $scenarios
}

$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }
$outPath = "$metricsDir\bench_input-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content $outPath -Encoding UTF8

# ──────────────────────────────────────────────────────────────────────────
# Summary table
# ──────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host "Keystroke-to-echo latency (ms)" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host ("{0,-18} {1,7} {2,7} {3,7} {4,7} {5,7} {6,7} {7,6}" -f `
    "Scenario", "p50", "p90", "p99", "max", "mean", "stddev", "miss") -ForegroundColor Yellow

foreach ($name in @("IDLE", "UNDER_LOAD", "LARGE_SCROLLBACK")) {
    $s = $scenarios[$name]
    if (-not $s) { continue }
    Write-Host ("{0,-18} {1,7:F1} {2,7:F1} {3,7:F1} {4,7:F1} {5,7:F1} {6,7:F1} {7,6}" -f `
        $s.label, $s.p50, $s.p90, $s.p99, $s.max, $s.mean, $s.stddev, $s.missed)
}

Write-Host ""
Write-Host "Metrics written to: $outPath" -ForegroundColor DarkGray
Write-Host ""
