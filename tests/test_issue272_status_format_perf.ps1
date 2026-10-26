# Issue #272: status-format #(cmd) re-spawns subprocess per frame push
#
# CLAIM: A slow #(...) helper in status-format causes typing lag because
# expand_format() is called on every state_dirty push (~30/s during typing),
# and run_shell_command spawns a fresh subprocess each time.
#
# This test PROVES (or disproves) the claim with measurements.

$ErrorActionPreference = "Continue"
$PSMUX = "$PSScriptRoot\..\target\release\psmux.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Metric($name, $value, $unit = "ms") { Write-Host ("  [METRIC] {0}: {1:N1}{2}" -f $name, $value, $unit) -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\*.port" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\*.key" -Force -EA SilentlyContinue
}

function Send-Tcp {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

function Connect-Persistent {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    return @{ tcp=$tcp; writer=$writer; reader=$reader; stream=$stream }
}

function Get-Dump {
    param($conn)
    $conn.writer.Write("dump-state`n"); $conn.writer.Flush()
    $best = $null
    $conn.tcp.ReceiveTimeout = 2000
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $conn.reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 50) { $best = $line }
        if ($best) { $conn.tcp.ReceiveTimeout = 50 }
    }
    $conn.tcp.ReceiveTimeout = 10000
    return $best
}

function Percentile($arr, $pct) {
    if ($arr.Count -eq 0) { return 0 }
    $sorted = [double[]]($arr | Sort-Object)
    $idx = [Math]::Floor(($pct / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
}

# Prepare the slow helper script
$helperPs1 = "$env:TEMP\psmux_issue272_helper.ps1"
@'
$port = Get-ChildItem "$env:USERPROFILE\.psmux\*.port" -EA SilentlyContinue | Where-Object { $_.Name -ne "__warm__.port" } | Select-Object -First 1
if ($port) {
  $d = [int]([DateTime]::Now - $port.CreationTime).TotalSeconds
  $h = [math]::Floor($d / 3600); $m = [math]::Floor(($d % 3600) / 60)
  if ($h -gt 0) { "{0}h {1}m" -f $h, $m } else { "{0}m" -f $m }
}
'@ | Set-Content -Path $helperPs1 -Encoding UTF8

# Also prepare a fast helper for comparison
$fastHelperBat = "$env:TEMP\psmux_issue272_fast.bat"
"@echo ok" | Set-Content -Path $fastHelperBat -Encoding ASCII

Write-Host "`n=== Issue #272 Verification: status-format #(cmd) subprocess spawn cost ===" -ForegroundColor Cyan
Write-Host "Helper script: $helperPs1"

# === BASELINE: How slow IS the helper? ===
Write-Host "`n[Baseline] How long does the slow helper actually take?" -ForegroundColor Yellow
$baselineTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & powershell -NoProfile -ExecutionPolicy Bypass -File $helperPs1 2>&1 | Out-Null
    $sw.Stop()
    [void]$baselineTimes.Add($sw.Elapsed.TotalMilliseconds)
}
$blAvg = ($baselineTimes | Measure-Object -Average).Average
$blMin = ($baselineTimes | Measure-Object -Minimum).Minimum
$blMax = ($baselineTimes | Measure-Object -Maximum).Maximum
Metric "powershell helper avg" $blAvg
Metric "powershell helper min" $blMin
Metric "powershell helper max" $blMax

if ($blAvg -gt 100) {
    Write-Pass "Helper is genuinely slow ($([math]::Round($blAvg))ms avg) - matches issue description"
} else {
    Write-Host "  [INFO] Helper is faster than expected on this system" -ForegroundColor Yellow
}

$baselineFast = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & cmd /c $fastHelperBat 2>&1 | Out-Null
    $sw.Stop()
    [void]$baselineFast.Add($sw.Elapsed.TotalMilliseconds)
}
$bfAvg = ($baselineFast | Measure-Object -Average).Average
Metric "cmd .bat helper avg" $bfAvg

# === TEST 1: Build a config and start session WITH slow #(...) in status-format ===
Cleanup

$confSlow = "$env:TEMP\psmux_issue272_slow.conf"
$helperEsc = $helperPs1 -replace '\\', '/'
@"
set -g status on
set -g status-style "bg=#4d94c2,fg=default"
set -g status-format[0] "TEST #(powershell -NoProfile -ExecutionPolicy Bypass -File $helperEsc) END"
"@ | Set-Content -Path $confSlow -Encoding UTF8

Write-Host "`n[Test 1] Start session with SLOW #(...) helper in status-format[0]" -ForegroundColor Yellow
$env:PSMUX_CONFIG_FILE = $confSlow
$SESSION = "issue272_slow"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Session created with slow helper config" }
else { Write-Fail "Session failed to start"; exit 1 }

# Verify the format is configured
$sf0 = & $PSMUX show-options -g -v "status-format[0]" -t $SESSION 2>&1
Write-Host "  status-format[0] = $sf0" -ForegroundColor DarkGray

# === TEST 2: Measure how often the helper is invoked during state_dirty pushes ===
# Strategy: install a "tracer" - a helper that appends to a file each invocation
# Then trigger state changes via send-keys and count the file lines.

$tracer = "$env:TEMP\psmux_issue272_tracer.ps1"
$tracerLog = "$env:TEMP\psmux_issue272_tracer.log"
@"
Add-Content -Path '$tracerLog' -Value "[$(Get-Date -Format 'HH:mm:ss.fff')]"
'tracer'
"@ | Set-Content -Path $tracer -Encoding UTF8

# Cleanup, restart with tracer
Cleanup
$confTracer = "$env:TEMP\psmux_issue272_tracer.conf"
$tracerEsc = $tracer -replace '\\', '/'
@"
set -g status on
set -g status-format[0] "T #(powershell -NoProfile -ExecutionPolicy Bypass -File $tracerEsc) X"
"@ | Set-Content -Path $confTracer -Encoding UTF8

$env:PSMUX_CONFIG_FILE = $confTracer
$SESSION = "issue272_tracer"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $tracerLog -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n[Test 2] Count subprocess spawns during 5 seconds of activity" -ForegroundColor Yellow

# Get baseline count (idle session)
Start-Sleep -Seconds 2
$idleCount = if (Test-Path $tracerLog) { (Get-Content $tracerLog).Count } else { 0 }
Metric "Tracer invocations after 2s idle" $idleCount "calls"

# Now connect a frame receiver (PERSISTENT mode) and trigger redraws
$conn = Connect-Persistent -Session $SESSION
$startCount = if (Test-Path $tracerLog) { (Get-Content $tracerLog).Count } else { 0 }

# Subscribe to frames so state_dirty actually pushes
$conn.writer.Write("subscribe-frames`n"); $conn.writer.Flush()
Start-Sleep -Milliseconds 200

# Trigger continuous redraws by sending characters
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 30; $i++) {
    & $PSMUX send-keys -t $SESSION "a" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 100
}
$sw.Stop()

Start-Sleep -Seconds 1
$endCount = if (Test-Path $tracerLog) { (Get-Content $tracerLog).Count } else { 0 }
$invocationsDuringActivity = $endCount - $startCount
Metric "Tracer invocations during 3s activity" $invocationsDuringActivity "calls"
Metric "Effective spawn rate" ($invocationsDuringActivity / 3.0) "calls/s"

if ($invocationsDuringActivity -gt 10) {
    Write-Pass "BUG CONFIRMED: helper invoked $invocationsDuringActivity times during 3s of typing"
    Write-Host "    -> Issue claims ~30/s during typing; observed $($invocationsDuringActivity / 3.0) calls/s" -ForegroundColor Red
} elseif ($invocationsDuringActivity -gt 3) {
    Write-Host "  [PARTIAL] Helper invoked $invocationsDuringActivity times - more than expected but less than 30/s" -ForegroundColor Yellow
} else {
    Write-Host "  [INFO] Helper invoked only $invocationsDuringActivity times - bug may not reproduce or be milder" -ForegroundColor Yellow
}

$conn.tcp.Close()

# === TEST 3: Measure echo latency WITH slow helper vs WITHOUT ===
Write-Host "`n[Test 3] Compare keystroke echo latency: SLOW helper vs NO helper" -ForegroundColor Yellow

# Test 3a: WITH slow helper
Cleanup
$env:PSMUX_CONFIG_FILE = $confSlow
& $PSMUX new-session -d -s "perf_slow" 2>&1 | Out-Null
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null

$conn = Connect-Persistent -Session "perf_slow"
$conn.writer.Write("subscribe-frames`n"); $conn.writer.Flush()
Start-Sleep -Milliseconds 500

# Drain any pending frames
$conn.tcp.ReceiveTimeout = 200
for ($j = 0; $j -lt 50; $j++) {
    try { $line = $conn.reader.ReadLine() } catch { break }
    if ($null -eq $line) { break }
}

$slowEchoTimes = [System.Collections.ArrayList]::new()
$freq = [System.Diagnostics.Stopwatch]::Frequency

for ($i = 0; $i -lt 10; $i++) {
    # Get baseline state hash
    $baseline = Get-Dump $conn
    $prevHash = if ($baseline) { $baseline.GetHashCode() } else { 0 }

    $startTick = [System.Diagnostics.Stopwatch]::GetTimestamp()
    & $PSMUX send-keys -t "perf_slow" "x" 2>&1 | Out-Null

    $found = $false
    $maxTicks = $freq  # 1 second timeout
    while (([System.Diagnostics.Stopwatch]::GetTimestamp() - $startTick) -lt $maxTicks) {
        $dump = Get-Dump $conn
        if ($dump -and $dump.GetHashCode() -ne $prevHash) {
            $endTick = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $elapsedMs = ($endTick - $startTick) * 1000.0 / $freq
            [void]$slowEchoTimes.Add($elapsedMs)
            $found = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    Start-Sleep -Milliseconds 200
}
$conn.tcp.Close()

if ($slowEchoTimes.Count -gt 0) {
    $slowAvg = ($slowEchoTimes | Measure-Object -Average).Average
    $slowP50 = Percentile $slowEchoTimes 50
    $slowP90 = Percentile $slowEchoTimes 90
    $slowMax = ($slowEchoTimes | Measure-Object -Maximum).Maximum
    Metric "WITH slow helper - echo avg" $slowAvg
    Metric "WITH slow helper - echo p50" $slowP50
    Metric "WITH slow helper - echo p90" $slowP90
    Metric "WITH slow helper - echo max" $slowMax
}

# Test 3b: WITHOUT helper (default config)
Cleanup
& $PSMUX new-session -d -s "perf_baseline" 2>&1 | Out-Null
Start-Sleep -Seconds 3

$conn = Connect-Persistent -Session "perf_baseline"
$conn.writer.Write("subscribe-frames`n"); $conn.writer.Flush()
Start-Sleep -Milliseconds 500
$conn.tcp.ReceiveTimeout = 200
for ($j = 0; $j -lt 50; $j++) {
    try { $line = $conn.reader.ReadLine() } catch { break }
    if ($null -eq $line) { break }
}

$baseEchoTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 10; $i++) {
    $baseline = Get-Dump $conn
    $prevHash = if ($baseline) { $baseline.GetHashCode() } else { 0 }

    $startTick = [System.Diagnostics.Stopwatch]::GetTimestamp()
    & $PSMUX send-keys -t "perf_baseline" "x" 2>&1 | Out-Null

    $found = $false
    $maxTicks = $freq
    while (([System.Diagnostics.Stopwatch]::GetTimestamp() - $startTick) -lt $maxTicks) {
        $dump = Get-Dump $conn
        if ($dump -and $dump.GetHashCode() -ne $prevHash) {
            $endTick = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $elapsedMs = ($endTick - $startTick) * 1000.0 / $freq
            [void]$baseEchoTimes.Add($elapsedMs)
            $found = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    Start-Sleep -Milliseconds 200
}
$conn.tcp.Close()

if ($baseEchoTimes.Count -gt 0) {
    $baseAvg = ($baseEchoTimes | Measure-Object -Average).Average
    $baseP50 = Percentile $baseEchoTimes 50
    $baseP90 = Percentile $baseEchoTimes 90
    Metric "NO helper - echo avg" $baseAvg
    Metric "NO helper - echo p50" $baseP50
    Metric "NO helper - echo p90" $baseP90
}

# Compare
if ($slowEchoTimes.Count -gt 0 -and $baseEchoTimes.Count -gt 0) {
    $delta = $slowAvg - $baseAvg
    $ratio = if ($baseAvg -gt 0) { $slowAvg / $baseAvg } else { 0 }
    Metric "Echo lag delta (slow - baseline)" $delta
    Metric "Slowdown ratio" $ratio "x"

    if ($delta -gt 50) {
        Write-Pass "BUG CONFIRMED: slow helper adds ${delta}ms ($([math]::Round($ratio,1))x) latency to typing"
    } else {
        Write-Host "  [INFO] Slow helper adds only $([math]::Round($delta,1))ms - bug impact is mild here" -ForegroundColor Yellow
    }
}

# === Cleanup ===
Cleanup
Remove-Item $helperPs1 -EA SilentlyContinue
Remove-Item $fastHelperBat -EA SilentlyContinue
Remove-Item $tracer -EA SilentlyContinue
Remove-Item $tracerLog -EA SilentlyContinue
Remove-Item $confSlow -EA SilentlyContinue
Remove-Item $confTracer -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
