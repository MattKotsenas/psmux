# bench_ipc_compare.ps1 - IPC latency + cold-launch comparison benchmark for psmux
#
# Authoring-only benchmark. The lead executes this serially against a
# PRE-CREATED base session named 'bench_ipc' (default). This script does NOT
# create that base session and does NOT kill it. It only creates/cleans up
# its own temporary cmpN sessions in PART 2.
#
# Measures:
#   PART 1A - CLI latency: cold-process display-message round-trip (p50/p90/p99/min/max)
#   PART 1B - RAW TCP round-trip over ONE persistent socket (p50/p90/p99)
#   PART 2  - Cold launch-to-usable: psmux vs wt.exe vs pwsh.exe (p50/p90)
#
# ALL timing is via System.Diagnostics.Stopwatch.

param(
    [string]$Session = "bench_ipc",
    [string]$Stamp   = "manual"
)

$ErrorActionPreference = "Continue"

$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# ── Guard: base session must already exist (lead pre-creates it) ──
if (-not (Test-Path "$psmuxDir\$Session.port")) {
    Write-Host "SESSION_NOT_READY"
    exit 2
}

# ── Helper: percentile of an array (linear-index, sorted ascending) ──
function Percentile {
    param($arr, [double]$pct)
    if (-not $arr -or @($arr).Count -eq 0) { return 0 }
    $sorted = @($arr | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 1) { return [double]$sorted[0] }
    $idx = [int][math]::Floor(($n - 1) * ($pct / 100.0))
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $n) { $idx = $n - 1 }
    return [double]$sorted[$idx]
}

function Round1 { param($v) [math]::Round([double]$v, 1) }

Write-Host ""
Write-Host ("=" * 76)
Write-Host "     PSMUX IPC LATENCY + COLD-LAUNCH COMPARISON BENCHMARK"
Write-Host ("=" * 76)
Write-Host "  Base session: $Session   Stamp: $Stamp"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════
# PART 1A: CLI LATENCY - cold-process display-message round-trip
# ══════════════════════════════════════════════════════════════════════════
Write-Host ("-" * 76)
Write-Host "  PART 1A: CLI LATENCY (display-message, 50 samples)"
Write-Host ("-" * 76)

$cliLatencies = @()
$CLI_SAMPLES = 50
for ($i = 0; $i -lt $CLI_SAMPLES; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = & $PSMUX display-message -t $Session -p '#{session_name}' 2>$null
    } catch {}
    $sw.Stop()
    $cliLatencies += $sw.Elapsed.TotalMilliseconds
}

$cli_p50 = Round1 (Percentile $cliLatencies 50)
$cli_p90 = Round1 (Percentile $cliLatencies 90)
$cli_p99 = Round1 (Percentile $cliLatencies 99)
$cli_min = Round1 (($cliLatencies | Measure-Object -Minimum).Minimum)
$cli_max = Round1 (($cliLatencies | Measure-Object -Maximum).Maximum)

Write-Host ("  CLI display-message: p50={0}ms p90={1}ms p99={2}ms min={3}ms max={4}ms" -f `
    $cli_p50, $cli_p90, $cli_p99, $cli_min, $cli_max)

# ══════════════════════════════════════════════════════════════════════════
# PART 1B: RAW TCP ROUND-TRIP - ONE persistent socket, reused per iteration
# ══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host ("-" * 76)
Write-Host "  PART 1B: RAW TCP ROUND-TRIP (persistent socket, 100 samples)"
Write-Host ("-" * 76)

$tcpLatencies = @()
$tcp_p50 = 0; $tcp_p90 = 0; $tcp_p99 = 0
$tcp_ok = $false
$tcp = $null

try {
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key"  -Raw).Trim()

    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 5000
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $false
    $reader = New-Object System.IO.StreamReader($stream)

    # Authenticate
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $auth = $reader.ReadLine()
    if ($auth -ne "OK") { throw "Auth failed: $auth" }

    # Upgrade to persistent connection (stays open across commands)
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    Start-Sleep -Milliseconds 100

    $TCP_SAMPLES = 100
    for ($i = 0; $i -lt $TCP_SAMPLES; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # REUSE the same persistent writer/reader every iteration.
        $writer.Write("list-sessions`n")
        $writer.Flush()
        $stream.ReadTimeout = 5000
        $null = $reader.ReadLine()
        $sw.Stop()
        $tcpLatencies += $sw.Elapsed.TotalMilliseconds
    }

    $tcp_ok = $true
    $tcp_p50 = Round1 (Percentile $tcpLatencies 50)
    $tcp_p90 = Round1 (Percentile $tcpLatencies 90)
    $tcp_p99 = Round1 (Percentile $tcpLatencies 99)

    Write-Host ("  RAW TCP list-sessions: p50={0}ms p90={1}ms p99={2}ms" -f $tcp_p50, $tcp_p90, $tcp_p99)
} catch {
    Write-Host ("  RAW TCP FAILED: {0}" -f $_.Exception.Message)
} finally {
    if ($tcp) { try { $tcp.Close() } catch {} }
}

# ══════════════════════════════════════════════════════════════════════════
# PART 2: COLD LAUNCH-TO-USABLE COMPARISON (psmux vs wt vs pwsh)
# ══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host ("-" * 76)
Write-Host "  PART 2: COLD LAUNCH-TO-USABLE (>=10 iterations each)"
Write-Host ("-" * 76)

$ITERS = 10

# ── (i) psmux: kill-server + clean, then time launch until TCP-connectable ──
$psmuxLaunch = @()
Write-Host "  [psmux] cold launch-to-usable..."
for ($i = 0; $i -lt $ITERS; $i++) {
    $cmpSession = "cmp$i"
    $cmpPort = "$psmuxDir\$cmpSession.port"
    $cmpKey  = "$psmuxDir\$cmpSession.key"

    # Clean slate: kill any prior server, clear stale port/key files.
    try { & $PSMUX kill-server 2>$null | Out-Null } catch {}
    Start-Sleep -Milliseconds 500
    Remove-Item $cmpPort -Force -ErrorAction SilentlyContinue
    Remove-Item $cmpKey  -Force -ErrorAction SilentlyContinue

    $proc = $null
    $usableMs = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $PSMUX `
            -ArgumentList "new-session", "-s", $cmpSession, "-d" `
            -PassThru -WindowStyle Hidden

        # Wait until port file appears AND a TcpClient connect succeeds.
        $connected = $false
        while ($sw.Elapsed.TotalSeconds -lt 15) {
            if (Test-Path $cmpPort) {
                try {
                    $p = (Get-Content $cmpPort -Raw).Trim()
                    if ($p) {
                        $probe = [System.Net.Sockets.TcpClient]::new()
                        $probe.Connect("127.0.0.1", [int]$p)
                        $probe.Close()
                        $connected = $true
                        break
                    }
                } catch {}
            }
            Start-Sleep -Milliseconds 25
        }
        $sw.Stop()
        if ($connected) { $usableMs = $sw.Elapsed.TotalMilliseconds }
    } catch {
        $sw.Stop()
    } finally {
        # Tear down this temp session (never touch the base $Session).
        try { & $PSMUX kill-session -t $cmpSession 2>$null | Out-Null } catch {}
        if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Remove-Item $cmpPort -Force -ErrorAction SilentlyContinue
        Remove-Item $cmpKey  -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $usableMs) { $psmuxLaunch += $usableMs }
    Start-Sleep -Milliseconds 200
}

$psmux_p50 = if ($psmuxLaunch.Count) { Round1 (Percentile $psmuxLaunch 50) } else { $null }
$psmux_p90 = if ($psmuxLaunch.Count) { Round1 (Percentile $psmuxLaunch 90) } else { $null }
Write-Host ("    psmux launch: p50={0}ms p90={1}ms (n={2})" -f $psmux_p50, $psmux_p90, $psmuxLaunch.Count)

# ── (ii) wt.exe: only if available; poll MainWindowHandle until non-zero ──
$wtCmd = Get-Command wt -EA SilentlyContinue
$wt_available = [bool]$wtCmd
$wtLaunch = @()
if ($wt_available) {
    Write-Host "  [wt] cold launch-to-window..."
    for ($i = 0; $i -lt $ITERS; $i++) {
        $proc = $null
        $usableMs = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $proc = Start-Process -FilePath "wt" -PassThru
            $shown = $false
            while ($sw.Elapsed.TotalSeconds -lt 8) {
                try {
                    $h = (Get-Process -Id $proc.Id -ErrorAction Stop).MainWindowHandle
                    if ($h -ne 0) { $shown = $true; break }
                } catch { break }
                Start-Sleep -Milliseconds 25
            }
            $sw.Stop()
            if ($shown) { $usableMs = $sw.Elapsed.TotalMilliseconds }
        } catch {
            $sw.Stop()
        } finally {
            if ($proc) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        if ($null -ne $usableMs) { $wtLaunch += $usableMs }
        Start-Sleep -Milliseconds 200
    }
    $wt_p50 = if ($wtLaunch.Count) { Round1 (Percentile $wtLaunch 50) } else { $null }
    $wt_p90 = if ($wtLaunch.Count) { Round1 (Percentile $wtLaunch 90) } else { $null }
    Write-Host ("    wt launch: p50={0}ms p90={1}ms (n={2})" -f $wt_p50, $wt_p90, $wtLaunch.Count)
} else {
    $wt_p50 = $null
    $wt_p90 = $null
    Write-Host "    wt.exe not available - skipping (graceful)."
}

# ── (iii) pwsh.exe: time until process exits (-NoProfile -Command exit) ──
$pwshLaunch = @()
Write-Host "  [pwsh] cold launch-to-exit..."
for ($i = 0; $i -lt $ITERS; $i++) {
    $proc = $null
    $usableMs = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList '-NoProfile', '-Command', 'exit' `
            -PassThru
        $exited = $proc.WaitForExit(15000)
        $sw.Stop()
        if ($exited) { $usableMs = $sw.Elapsed.TotalMilliseconds }
    } catch {
        $sw.Stop()
    } finally {
        if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
    }
    if ($null -ne $usableMs) { $pwshLaunch += $usableMs }
    Start-Sleep -Milliseconds 100
}

$pwsh_p50 = if ($pwshLaunch.Count) { Round1 (Percentile $pwshLaunch 50) } else { $null }
$pwsh_p90 = if ($pwshLaunch.Count) { Round1 (Percentile $pwshLaunch 90) } else { $null }
Write-Host ("    pwsh launch: p50={0}ms p90={1}ms (n={2})" -f $pwsh_p50, $pwsh_p90, $pwshLaunch.Count)

# ══════════════════════════════════════════════════════════════════════════
# RESULT OBJECT + JSON OUTPUT
# ══════════════════════════════════════════════════════════════════════════
$cpuName = ""
try { $cpuName = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Name).Trim() } catch {}

$result = @{
    metadata = @{
        stamp        = $Stamp
        session      = $Session
        cpu          = $cpuName
        wt_available = $wt_available
        timestamp    = (Get-Date).ToString("o")
        logical_cpus = [Environment]::ProcessorCount
    }
    cli_latency = @{
        samples = $CLI_SAMPLES
        p50 = $cli_p50; p90 = $cli_p90; p99 = $cli_p99; min = $cli_min; max = $cli_max
    }
    tcp_latency = @{
        ok = $tcp_ok
        samples = @($tcpLatencies).Count
        p50 = $tcp_p50; p90 = $tcp_p90; p99 = $tcp_p99
    }
    cold_launch = @{
        psmux = @{ p50 = $psmux_p50; p90 = $psmux_p90; n = $psmuxLaunch.Count }
        wt    = @{ available = $wt_available; p50 = $wt_p50; p90 = $wt_p90; n = $wtLaunch.Count }
        pwsh  = @{ p50 = $pwsh_p50; p90 = $pwsh_p90; n = $pwshLaunch.Count }
    }
}

$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null }
$jsonPath = "$metricsDir\bench_ipc_compare-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

# ══════════════════════════════════════════════════════════════════════════
# ALIGNED SUMMARY TABLE
# ══════════════════════════════════════════════════════════════════════════
function Fmt { param($v) if ($null -eq $v) { "n/a" } else { "{0}ms" -f $v } }

Write-Host ""
Write-Host ("=" * 76)
Write-Host "     SUMMARY"
Write-Host ("=" * 76)
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "Metric", "p50", "p90", "p99")
Write-Host ("  " + ("-" * 66))
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "CLI display-message", (Fmt $cli_p50), (Fmt $cli_p90), (Fmt $cli_p99))
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "RAW TCP list-sessions", (Fmt $tcp_p50), (Fmt $tcp_p90), (Fmt $tcp_p99))
Write-Host ("  " + ("-" * 66))
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "Cold launch", "p50", "p90", "n")
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "  psmux", (Fmt $psmux_p50), (Fmt $psmux_p90), $psmuxLaunch.Count)
if ($wt_available) {
    Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "  wt.exe", (Fmt $wt_p50), (Fmt $wt_p90), $wtLaunch.Count)
} else {
    Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "  wt.exe", "n/a", "n/a", "unavailable")
}
Write-Host ("  {0,-28} {1,12} {2,12} {3,12}" -f "  pwsh.exe", (Fmt $pwsh_p50), (Fmt $pwsh_p90), $pwshLaunch.Count)
Write-Host ("=" * 76)
Write-Host ""
Write-Host "  JSON written: $jsonPath"
Write-Host "  Base session '$Session' left untouched."
Write-Host ""

exit 0
