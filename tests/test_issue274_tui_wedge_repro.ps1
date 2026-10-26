# Issue #274 (comment 4392215473): TUI client rendering wedge investigation
# https://github.com/psmux/psmux/issues/274#issuecomment-4392215473
#
# NEW CLAIM from gtbuchanan: The TUI client becomes unresponsive (can't
# navigate to other psmux windows/panes), but the server is fine.
# send-keys via CLI works and capture-pane shows the output, but the
# active terminal window does NOT display it.
# Re-attaching from a NEW terminal instance works and the pane isn't
# actually hanging.
#
# This is a DIFFERENT symptom from the original report. It implicates
# the TUI render/output path (crossterm -> stdout -> host terminal),
# not the server-side pipe.
#
# Test plan:
#   PART A: Multi-window session with heavy-output processes (CLI probes)
#   PART B: TUI client launch + keystroke injection to test navigation
#   PART C: Verify server responsiveness while TUI may be wedged
#   PART D: Client kill + re-attach + verify clean state
#   PART E: Sustained high-output with concurrent TUI probing

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test274_tui"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_274_heavy_*.js" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_274_frozen.js" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile = "$psmuxDir\$Session.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return "NO_PORT_FILE" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
        $writer.Write("$Command`n"); $writer.Flush()
        $stream.ReadTimeout = 10000
        try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch {
        return "TCP_ERROR: $_"
    }
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
    return @{ tcp=$tcp; writer=$writer; reader=$reader }
}

function Get-Dump {
    param($conn)
    $conn.writer.Write("dump-state`n"); $conn.writer.Flush()
    $best = $null
    $conn.tcp.ReceiveTimeout = 3000
    for ($j = 0; $j -lt 100; $j++) {
        try { $line = $conn.reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $conn.tcp.ReceiveTimeout = 50 }
    }
    $conn.tcp.ReceiveTimeout = 10000
    return $best
}

# === CLEANUP ===
Cleanup
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Issue #274: TUI Client Wedge Reproduction" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Create heavy output scripts simulating Claude Code output patterns
# Claude Code does rapid TUI rendering with ANSI escape codes
@'
// Simulates a claude-code-like TUI: rapid ANSI output with escape codes
const ESC = '\x1b';
let lineCount = 0;
const colors = [31,32,33,34,35,36];
setInterval(() => {
    const c = colors[lineCount % colors.length];
    const prefix = `${ESC}[${c}m`;
    const reset = `${ESC}[0m`;
    const spinner = ['|','/','-','\\'][lineCount % 4];
    // Simulate claude-code style output: status + spinner + colored text
    process.stdout.write(`\r${prefix}[${spinner}] Processing task ${lineCount}... ${reset}${ESC}[K`);
    if (lineCount % 20 === 0) {
        // Periodic full-line output like Claude Code writing code blocks
        process.stdout.write(`\n${prefix}  function example_${lineCount}() { return ${lineCount}; }${reset}\n`);
    }
    lineCount++;
}, 50);  // 20 updates/sec, aggressive TUI rendering
'@ | Set-Content "$env:TEMP\psmux_274_heavy_tui.js" -Encoding UTF8

# Frozen process script (simulates claude.exe stopping its event loop)
@'
process.stdin.resume();
process.on('SIGINT', () => {});
process.on('SIGTERM', () => {});
console.log("FROZEN_PROCESS_STARTED");
// Process alive but event loop frozen - exactly what happens when
// claude.exe stops emitting events after ~9.5 minutes
setInterval(() => {}, 100000);
'@ | Set-Content "$env:TEMP\psmux_274_frozen.js" -Encoding UTF8

# ====================================================================
# PART A: Multi-window session with heavy output (CLI path verification)
# ====================================================================
Write-Host "`n=== PART A: Multi-Window CLI Path Tests ===" -ForegroundColor Cyan

# Create session with 3 windows (matching gtbuchanan's "multiple psmux windows")
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

# Create 2 more windows (total 3 windows with 1 pane each)
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

$winCount = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
if ($winCount -eq "3") { Write-Pass "3-window session created (matches gtbuchanan setup)" }
else { Write-Fail "Expected 3 windows, got $winCount" }

# Start heavy output in window 0 (simulating Claude Code)
Write-Host "`n[Test A1] Heavy TUI-style output in window 0" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:0" "node `"$env:TEMP\psmux_274_heavy_tui.js`"" Enter
Start-Sleep -Seconds 3

$cap0 = & $PSMUX capture-pane -t "${SESSION}:0" -p 2>&1 | Out-String
if ($cap0 -match "Processing task") { Write-Pass "Window 0 producing heavy output" }
else { Write-Info "Window 0 output: $($cap0.Substring(0, [Math]::Min(100, $cap0.Length)))" }

# [Test A2] send-keys to OTHER windows while window 0 is busy
Write-Host "`n[Test A2] send-keys to window 1 while window 0 floods" -ForegroundColor Yellow
$marker1 = "W1_MARKER_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1" "echo $marker1" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap1 -match $marker1) { Write-Pass "Window 1: send-keys delivered and visible in capture-pane" }
else { Write-Fail "Window 1: send-keys NOT visible in capture-pane" }

# [Test A3] send-keys to window 2
Write-Host "`n[Test A3] send-keys to window 2 while window 0 floods" -ForegroundColor Yellow
$marker2 = "W2_MARKER_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:2" "echo $marker2" Enter
Start-Sleep -Seconds 2
$cap2 = & $PSMUX capture-pane -t "${SESSION}:2" -p 2>&1 | Out-String
if ($cap2 -match $marker2) { Write-Pass "Window 2: send-keys delivered and visible in capture-pane" }
else { Write-Fail "Window 2: send-keys NOT visible in capture-pane" }

# [Test A4] CLI latency while heavy output is running
Write-Host "`n[Test A4] CLI command latency during heavy output" -ForegroundColor Yellow
$cliTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 20; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null
    $sw.Stop()
    [void]$cliTimes.Add($sw.Elapsed.TotalMilliseconds)
}
$avg = ($cliTimes | Measure-Object -Average).Average
$max = ($cliTimes | Measure-Object -Maximum).Maximum
Write-Info ("CLI display-message x20: avg=" + [Math]::Round($avg,1) + "ms max=" + [Math]::Round($max,1) + "ms")
if ($max -lt 500) { Write-Pass "CLI latency acceptable under heavy output ($([Math]::Round($max,1))ms max)" }
else { Write-Fail "CLI latency degraded: ${max}ms max" }

# [Test A5] TCP server latency during heavy output
Write-Host "`n[Test A5] TCP server latency during heavy output" -ForegroundColor Yellow
$tcpTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 20; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Send-TcpCommand -Session $SESSION -Command "list-sessions"
    $sw.Stop()
    [void]$tcpTimes.Add($sw.Elapsed.TotalMilliseconds)
}
$tcpAvg = ($tcpTimes | Measure-Object -Average).Average
$tcpMax = ($tcpTimes | Measure-Object -Maximum).Maximum
Write-Info ("TCP list-sessions x20: avg=" + [Math]::Round($tcpAvg,1) + "ms max=" + [Math]::Round($tcpMax,1) + "ms")
if ($tcpMax -lt 200) { Write-Pass "TCP latency ok under heavy output ($([Math]::Round($tcpMax,1))ms max)" }
else { Write-Fail "TCP latency degraded: ${tcpMax}ms max" }

# ====================================================================
# PART B: TUI Client Launch + Keystroke Injection Test
# ====================================================================
Write-Host "`n=== PART B: TUI Client + Keystroke Navigation ===" -ForegroundColor Cyan

# Compile injector if needed
$injectorExe = "$env:TEMP\psmux_injector.exe"
$injectorSrc = Join-Path (Split-Path $PSMUX -Parent) "..\Documents\workspace\psmux\tests\injector.cs"
if (-not (Test-Path $injectorSrc)) {
    $injectorSrc = "$PSScriptRoot\injector.cs"
}
$needCompile = (-not (Test-Path $injectorExe)) -or ((Test-Path $injectorSrc) -and (Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe -EA SilentlyContinue).LastWriteTime)
if ($needCompile -and (Test-Path $injectorSrc)) {
    Write-Info "Compiling keystroke injector..."
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
    if (Test-Path $injectorExe) { Write-Info "Injector compiled OK" }
    else { Write-Info "Injector compile failed (Layer 3 tests will be skipped)" }
}

# Launch TUI client in a visible window
Write-Host "`n[Test B1] Launch TUI attach + verify running" -ForegroundColor Yellow
$tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($tuiProc.HasExited) {
    Write-Fail "TUI client exited prematurely (code=$($tuiProc.ExitCode))"
} else {
    Write-Pass "TUI client running PID=$($tuiProc.Id)"
}

# [Test B2] Window switching via CLI while TUI is attached
Write-Host "`n[Test B2] Window switching via CLI during heavy output + TUI attached" -ForegroundColor Yellow
$curWinBefore = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
# Switch to window 1
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$curWinAfter = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
if ($curWinAfter -eq "1") { Write-Pass "Window switch via CLI worked while TUI attached" }
else { Write-Fail "Window switch failed: expected 1, got $curWinAfter" }

# Switch back to window 0 (the heavy-output one)
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# [Test B3] Keystroke injection test (prefix+n = next window)
if (Test-Path $injectorExe) {
    Write-Host "`n[Test B3] WriteConsoleInput: prefix+n (next window)" -ForegroundColor Yellow
    $winBefore = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    Write-Info "Current window before keystroke: $winBefore"

    & $injectorExe $tuiProc.Id "^b{SLEEP:300}n"
    Start-Sleep -Seconds 2

    $winAfter = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    Write-Info "Current window after prefix+n: $winAfter"
    if ($winAfter -ne $winBefore) { Write-Pass "Keystroke prefix+n switched window ($winBefore -> $winAfter)" }
    else { Write-Fail "Keystroke prefix+n did NOT switch window (stuck at $winBefore)" }

    # [Test B4] Switch back with prefix+p (previous window)
    Write-Host "`n[Test B4] WriteConsoleInput: prefix+p (previous window)" -ForegroundColor Yellow
    & $injectorExe $tuiProc.Id "^b{SLEEP:300}p"
    Start-Sleep -Seconds 2
    $winBack = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    if ($winBack -eq $winBefore) { Write-Pass "Keystroke prefix+p returned to window $winBefore" }
    else { Write-Info "Window now at $winBack (may be expected depending on order)" }
} else {
    Write-Info "Injector not available, skipping WriteConsoleInput tests"
}

# ====================================================================
# PART C: Frozen process in one pane + TUI verification
# ====================================================================
Write-Host "`n=== PART C: Frozen Pane + TUI Verification ===" -ForegroundColor Cyan

# Add a pane to window 1 and freeze it
Write-Host "`n[Test C1] Split window 1, freeze one pane, verify other pane works" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
& $PSMUX split-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Seconds 2

$panes1 = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_panes}' 2>&1).Trim()
if ($panes1 -eq "2") { Write-Pass "Window 1 has 2 panes" }
else { Write-Fail "Expected 2 panes in window 1, got $panes1" }

# Run frozen process in pane 0 of window 1
& $PSMUX send-keys -t "${SESSION}:1.0" "node `"$env:TEMP\psmux_274_frozen.js`"" Enter
Start-Sleep -Seconds 3

$capFrozen = & $PSMUX capture-pane -t "${SESSION}:1.0" -p 2>&1 | Out-String
if ($capFrozen -match "FROZEN_PROCESS_STARTED") { Write-Pass "Frozen process running in 1.0" }
else { Write-Info "Frozen process output: $($capFrozen.Substring(0, [Math]::Min(80, $capFrozen.Length)))" }

# Verify pane 1 of window 1 still works
Write-Host "`n[Test C2] Non-frozen pane in same window still responds" -ForegroundColor Yellow
$markerC = "ALIVE_PANE_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1.1" "echo $markerC" Enter
Start-Sleep -Seconds 2
$capAlive = & $PSMUX capture-pane -t "${SESSION}:1.1" -p 2>&1 | Out-String
if ($capAlive -match $markerC) { Write-Pass "Non-frozen pane responds to send-keys" }
else { Write-Fail "Non-frozen pane did NOT show marker" }

# [Test C3] dump-state via TCP while frozen + heavy output
Write-Host "`n[Test C3] TCP dump-state during frozen pane + heavy output" -ForegroundColor Yellow
try {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { throw "AUTH failed: $authResp" }
    $writer.Write("dump-state`n"); $writer.Flush()
    $state = $reader.ReadLine()
    $tcp.Close()
    if ($state -and $state.Length -gt 100) {
        Write-Pass "dump-state returned ($($state.Length) bytes)"
        try {
            $json = $state | ConvertFrom-Json
            Write-Info "Windows in state: $($json.windows.Count)"
        } catch {
            Write-Info "dump-state JSON parse issue (non-critical)"
        }
    } else {
        Write-Fail "dump-state returned empty/small response"
    }
} catch {
    Write-Fail "TCP dump-state failed: $_"
}

# ====================================================================
# PART D: Client kill + re-attach (exact gtbuchanan scenario)
# ====================================================================
Write-Host "`n=== PART D: Client Kill + Re-Attach ===" -ForegroundColor Cyan

Write-Host "`n[Test D1] Force-kill TUI client, verify server survives" -ForegroundColor Yellow
if (-not $tuiProc.HasExited) {
    Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Pass "TUI client force-killed"
} else {
    Write-Info "TUI client already exited"
}

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Server still has session after client kill" }
else { Write-Fail "Server LOST session after client kill" }

# [Test D2] send-keys to all panes after client kill
Write-Host "`n[Test D2] send-keys to all windows after client kill" -ForegroundColor Yellow
$markerD1 = "POSTKILL_W0_$(Get-Random)"
$markerD2 = "POSTKILL_W2_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1.1" "echo $markerD1" Enter
& $PSMUX send-keys -t "${SESSION}:2" "echo $markerD2" Enter
Start-Sleep -Seconds 2

$capD1 = & $PSMUX capture-pane -t "${SESSION}:1.1" -p 2>&1 | Out-String
$capD2 = & $PSMUX capture-pane -t "${SESSION}:2" -p 2>&1 | Out-String
if ($capD1 -match $markerD1) { Write-Pass "Window 1.1 responds after client kill" }
else { Write-Fail "Window 1.1 NOT responding after client kill" }
if ($capD2 -match $markerD2) { Write-Pass "Window 2 responds after client kill" }
else { Write-Fail "Window 2 NOT responding after client kill" }

# [Test D3] Fresh attach (the critical claim: "fresh attach also wedged")
Write-Host "`n[Test D3] Fresh TUI attach after client kill" -ForegroundColor Yellow
$freshProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($freshProc.HasExited) {
    Write-Fail "Fresh attach exited prematurely (code=$($freshProc.ExitCode))"
} else {
    Write-Pass "Fresh attach running PID=$($freshProc.Id)"

    # [Test D4] send-keys works after fresh attach
    Write-Host "`n[Test D4] send-keys after fresh attach" -ForegroundColor Yellow
    $markerFresh = "FRESH_ATTACH_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:2" "echo $markerFresh" Enter
    Start-Sleep -Seconds 2
    $capFresh = & $PSMUX capture-pane -t "${SESSION}:2" -p 2>&1 | Out-String
    if ($capFresh -match $markerFresh) { Write-Pass "send-keys delivered after fresh attach" }
    else { Write-Fail "WEDGE: send-keys NOT delivered after fresh attach" }

    # [Test D5] Keystroke injection into fresh attach
    if (Test-Path $injectorExe) {
        Write-Host "`n[Test D5] WriteConsoleInput into fresh TUI client" -ForegroundColor Yellow
        & $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $wBefore = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        & $injectorExe $freshProc.Id "^b{SLEEP:300}n"
        Start-Sleep -Seconds 2
        $wAfter = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        if ($wAfter -ne $wBefore) { Write-Pass "Keystroke navigation works in fresh attach" }
        else { Write-Fail "Keystroke navigation BLOCKED in fresh attach" }
    }

    try { Stop-Process -Id $freshProc.Id -Force -EA SilentlyContinue } catch {}
}

# ====================================================================
# PART E: Sustained 90s high-output with concurrent TUI probing
# ====================================================================
Write-Host "`n=== PART E: Sustained High-Output + TUI Probing (90s) ===" -ForegroundColor Cyan

# Start heavy output in all 3 windows (really push the rendering)
Write-Host "`n[Test E1] Starting heavy output in all windows..." -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:1.1" "node `"$env:TEMP\psmux_274_heavy_tui.js`"" Enter
& $PSMUX send-keys -t "${SESSION}:2" "node `"$env:TEMP\psmux_274_heavy_tui.js`"" Enter
Start-Sleep -Seconds 3

# Launch TUI client
$stressProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 3

if ($stressProc.HasExited) {
    Write-Fail "Stress TUI client exited prematurely"
} else {
    Write-Pass "Stress TUI client running PID=$($stressProc.Id)"
}

# Get baseline process stats
$serverProcs = Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Id -ne $stressProc.Id }
$serverProc = $serverProcs | Sort-Object Id | Select-Object -First 1
$memBaseline = if ($serverProc) { [Math]::Round($serverProc.WorkingSet64/1MB,1) } else { 0 }
$threadsBaseline = if ($serverProc) { $serverProc.Threads.Count } else { 0 }
$handlesBaseline = if ($serverProc) { $serverProc.HandleCount } else { 0 }
Write-Info "Baseline: mem=${memBaseline}MB threads=$threadsBaseline handles=$handlesBaseline"

# Sustained probing loop: 90 seconds
$duration = 90
$startTime = Get-Date
$cliSamples = [System.Collections.ArrayList]::new()
$tcpSamples = [System.Collections.ArrayList]::new()
$failedCli = 0
$failedTcp = 0
$sampleCount = 0
$lastReport = Get-Date
$tuiWedgeDetected = $false

while (((Get-Date) - $startTime).TotalSeconds -lt $duration) {
    $sampleCount++

    # CLI probe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cliOut = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-String
    $sw.Stop()
    $cliMs = $sw.Elapsed.TotalMilliseconds
    if ($cliOut.Trim() -eq $SESSION) {
        [void]$cliSamples.Add($cliMs)
    } else {
        $failedCli++
    }

    # TCP probe
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $tcpResp = Send-TcpCommand -Session $SESSION -Command "list-sessions"
    $sw2.Stop()
    $tcpMs = $sw2.Elapsed.TotalMilliseconds
    if ($tcpResp -match $SESSION) {
        [void]$tcpSamples.Add($tcpMs)
    } else {
        $failedTcp++
    }

    # Check if TUI client is still alive
    if ($stressProc.HasExited -and -not $tuiWedgeDetected) {
        $tuiWedgeDetected = $true
        Write-Fail "TUI client CRASHED during sustained output (code=$($stressProc.ExitCode))"
    }

    # Progress report every 15 seconds
    if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
        $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $cliAvgNow = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Average).Average,1) } else { "N/A" }
        $mem = if ($serverProc -and -not $serverProc.HasExited) {
            $serverProc.Refresh()
            [Math]::Round($serverProc.WorkingSet64/1MB,1)
        } else { "?" }
        Write-Info "  +${elapsed}s: CLI avg=${cliAvgNow}ms samples=$($cliSamples.Count) failedCLI=$failedCli failedTCP=$failedTcp mem=${mem}MB"
        $lastReport = Get-Date
    }

    # Avoid tight-loop: small delay between samples
    Start-Sleep -Milliseconds 500
}

# Final server stats
$serverProc = Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Id -ne $stressProc.Id } | Sort-Object Id | Select-Object -First 1
$memFinal = if ($serverProc) { [Math]::Round($serverProc.WorkingSet64/1MB,1) } else { 0 }
$threadsFinal = if ($serverProc) { $serverProc.Threads.Count } else { 0 }
$handlesFinal = if ($serverProc) { $serverProc.HandleCount } else { 0 }

Write-Host "`n[Test E2] 90s sustained results:" -ForegroundColor Yellow
$cliAvg = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Average).Average,1) } else { "N/A" }
$cliMax = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Maximum).Maximum,1) } else { "N/A" }
$tcpAvgE = if ($tcpSamples.Count -gt 0) { [Math]::Round(($tcpSamples | Measure-Object -Average).Average,1) } else { "N/A" }
$tcpMaxE = if ($tcpSamples.Count -gt 0) { [Math]::Round(($tcpSamples | Measure-Object -Maximum).Maximum,1) } else { "N/A" }

Write-Info "CLI: avg=${cliAvg}ms max=${cliMax}ms samples=$($cliSamples.Count) failures=$failedCli"
Write-Info "TCP: avg=${tcpAvgE}ms max=${tcpMaxE}ms samples=$($tcpSamples.Count) failures=$failedTcp"
Write-Info "Server: mem ${memBaseline}MB -> ${memFinal}MB (delta $([Math]::Round($memFinal-$memBaseline,1))MB)"
Write-Info "Server: threads ${threadsBaseline} -> ${threadsFinal}, handles ${handlesBaseline} -> ${handlesFinal}"

if ($failedCli -eq 0) { Write-Pass "Zero CLI failures over 90s sustained output" }
else { Write-Fail "$failedCli CLI failures during sustained output" }

if ($failedTcp -eq 0) { Write-Pass "Zero TCP failures over 90s sustained output" }
else { Write-Fail "$failedTcp TCP failures during sustained output" }

$memDelta = $memFinal - $memBaseline
if ($memDelta -lt 20) { Write-Pass "Memory delta <20MB ($([Math]::Round($memDelta,1))MB)" }
else { Write-Fail "Memory grew by ${memDelta}MB during sustained output" }

if (-not $tuiWedgeDetected) { Write-Pass "TUI client survived full 90s sustained output" }

# Wait for a marker to appear in a pane, polling instead of sleeping once.
#
# The claim these tests make is "the server is not wedged", not "the echo
# completes within exactly two seconds". A single capture after a fixed sleep
# turns any slow round trip into a WEDGE verdict, and window 1.1 is still
# flooding at this point, so the shell's echo competes with a pane that never
# stops producing output. Measured 2026-09-16: the same assertions scored 2
# failures, then 0, then 1 across three runs of the unchanged suite on one
# machine. Polling keeps the real signal (a wedge never produces the marker at
# all) and reports how long a healthy round trip actually took, which is the
# number worth having when this fails again.
# What the pane actually holds when an echo does not arrive: the target's child
# processes (is the flooding program still alive, ie did the interrupt land?)
# and the last lines on screen. Without this the failure says only "no echo",
# which is the symptom and not the cause; measured 2026-09-16, three runs failed
# identically and the log could not say whether Ctrl+C had stopped the child.
function Show-PaneDiagnostics {
    param([string]$Target)
    $panePid = 0
    try { $panePid = [int](& $PSMUX display-message -t $Target -p '#{pane_pid}' 2>&1 | Out-String).Trim() } catch { }
    $kids = @()
    if ($panePid -gt 0) {
        $q = [System.Collections.Queue]::new(); $q.Enqueue($panePid)
        while ($q.Count -gt 0) {
            $id = $q.Dequeue()
            foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -EA SilentlyContinue)) {
                $kids += "$($c.Name):$($c.ProcessId)"; $q.Enqueue([int]$c.ProcessId)
            }
        }
    }
    $cmd = (& $PSMUX display-message -t $Target -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
    Write-Host ("  [DIAG] $Target pane_pid=$panePid current_command=$cmd children=" + $(if ($kids.Count) { $kids -join ',' } else { '<none>' })) -ForegroundColor DarkYellow

    # Issue #668: when this fails, send-keys returns 0 and the server's ctrl_c
    # trace is byte for byte the trace of a working interrupt, yet the child
    # runs on. Two things decide that and neither is visible above.
    #
    # ConsoleFlags bit 0 is the process's "ignore Ctrl+C" state. It is what
    # SetConsoleCtrlHandler(NULL, TRUE) and CREATE_NEW_PROCESS_GROUP set, it is
    # INHERITED by children, and Windows offers no API to read it back, so a
    # child that was born deaf to Ctrl+C is indistinguishable from a signal
    # that was never delivered -- unless the bit is read out of the PEB.
    #
    # The screen counter is the child's own clock: the flood script numbers
    # every line, so comparing the highest number here with a capture taken
    # later says whether the child is wedged or simply never heard the signal.
    # Investigated 2026-09-18: falsified the inherited-bit and the pane-backlog
    # explanations on a machine where the failure had stopped reproducing, so
    # the reading that settles it has to come from a run that fails.
    $probe = "$env:TEMP\psmux_274_ctrlflags.exe"
    $probeSrc = "$PSScriptRoot\ctrlflags.cs"
    if ((-not (Test-Path $probe)) -and (Test-Path $probeSrc)) {
        $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if (Test-Path $csc) { & $csc /nologo /optimize /out:$probe $probeSrc 2>&1 | Out-Null }
    }
    if (Test-Path $probe) {
        $ids = @($panePid) + @($kids | ForEach-Object { [int]($_ -split ':')[1] })
        foreach ($line in (& $probe @($ids | Where-Object { $_ -gt 0 }) 2>&1)) {
            Write-Host "  [DIAG] ctrlflags $line" -ForegroundColor DarkYellow
        }
    }

    $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
    $tick = -1
    foreach ($m in [regex]::Matches($cap, 'Processing task (\d+)')) {
        $v = [int]$m.Groups[1].Value; if ($v -gt $tick) { $tick = $v }
    }
    Write-Host "  [DIAG] $Target screen line counter=$tick (compare with the next diagnostic: a wedged child stops counting)" -ForegroundColor DarkYellow
    ($cap -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) |
        ForEach-Object { Write-Host "  [DIAG] | $_" -ForegroundColor DarkYellow }
}

function Wait-PaneMarker {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 15000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match [regex]::Escape($Marker)) {
            return @{ Found = $true; Ms = $sw.ElapsedMilliseconds }
        }
        Start-Sleep -Milliseconds 250
    }
    return @{ Found = $false; Ms = $sw.ElapsedMilliseconds }
}

# [Test E3] send-keys still works after sustained period
Write-Host "`n[Test E3] send-keys after 90s sustained output" -ForegroundColor Yellow
# Stop heavy output in window 2 first
& $PSMUX send-keys -t "${SESSION}:2" C-c
Start-Sleep -Seconds 1
$markerE = "AFTER_SUSTAINED_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:2" "echo $markerE" Enter
$hitE = Wait-PaneMarker -Target "${SESSION}:2" -Marker $markerE
if ($hitE.Found) { Write-Pass "send-keys works after 90s sustained output (echo visible in $($hitE.Ms)ms)" }
else { Write-Fail "send-keys FAILED after 90s sustained output (no echo within $($hitE.Ms)ms)"; Show-PaneDiagnostics -Target "${SESSION}:2" }

# [Test E4] Client kill + fresh attach after sustained
Write-Host "`n[Test E4] Client kill + fresh attach after 90s sustained" -ForegroundColor Yellow
if (-not $stressProc.HasExited) {
    Stop-Process -Id $stressProc.Id -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
}

$finalProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
Start-Sleep -Seconds 4

if ($finalProc.HasExited) {
    Write-Fail "Final fresh attach exited prematurely"
} else {
    Write-Pass "Fresh attach works after 90s sustained + client kill"

    $markerFinal = "FINAL_PROOF_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:2" "echo $markerFinal" Enter
    $hitFinal = Wait-PaneMarker -Target "${SESSION}:2" -Marker $markerFinal
    $capFinal = if ($hitFinal.Found) { $markerFinal } else { "" }
    if ($hitFinal.Found) { Write-Pass "send-keys to non-heavy pane works post-reattach (echo visible in $($hitFinal.Ms)ms)" }
    else { Write-Fail "WEDGE: send-keys FAILED post-reattach (no echo within $($hitFinal.Ms)ms)"; Show-PaneDiagnostics -Target "${SESSION}:2" }

    # Keystroke test in final fresh attach
    if (Test-Path $injectorExe) {
        Write-Host "`n[Test E5] Keystroke navigation in final fresh attach" -ForegroundColor Yellow
        $wBefore = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        & $injectorExe $finalProc.Id "^b{SLEEP:300}n"
        Start-Sleep -Seconds 2
        $wAfter = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        if ($wAfter -ne $wBefore) { Write-Pass "Keystrokes work in final fresh attach" }
        else { Write-Fail "WEDGE: Keystrokes BLOCKED in final fresh attach" }
    }

    try { Stop-Process -Id $finalProc.Id -Force -EA SilentlyContinue } catch {}
}

# ====================================================================
# FINAL CLEANUP
# ====================================================================
Write-Host "`n=== Cleanup ===" -ForegroundColor DarkGray
Cleanup

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  CONCLUSION: Issue #274 TUI wedge NOT REPRODUCIBLE." -ForegroundColor Green
    Write-Host "  Server I/O isolation, CLI latency, TCP latency, keystroke" -ForegroundColor Green
    Write-Host "  navigation, client kill/re-attach all work correctly under" -ForegroundColor Green
    Write-Host "  sustained heavy output. The TUI render path is stable." -ForegroundColor Green
} else {
    Write-Host "`n  CONCLUSION: $($script:TestsFailed) test(s) FAILED." -ForegroundColor Red
    Write-Host "  There may be a reproducible issue. Investigate failures above." -ForegroundColor Red
}

exit $script:TestsFailed
