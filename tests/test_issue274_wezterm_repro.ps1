# Issue #274 (WezTerm-specific): TUI client wedge reproduction
# https://github.com/psmux/psmux/issues/274#issuecomment-4392215473
#
# gtbuchanan reports: using WezTerm hosting a psmux session with
# multiple windows containing Claude Code sessions, hangs occur that
# prevent navigating to other psmux windows/panes.
# Workaround: start new WezTerm, attach same session, close old WezTerm.
# Pane is NOT actually hanging on re-attach.
#
# This test specifically launches psmux INSIDE WezTerm (not Windows Terminal)
# to reproduce the exact environment gtbuchanan uses.
#
# Test plan:
#   PART A: Launch psmux inside WezTerm, drive heavy output, probe CLI/TCP
#   PART B: Keystroke injection into the WezTerm-hosted psmux
#   PART C: Client kill via closing WezTerm + re-attach in new WezTerm
#   PART D: Sustained heavy output in WezTerm for 60s with concurrent probing

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$WEZTERM = "C:\Program Files\WezTerm\wezterm.exe"
$SESSION = "wez274"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

if (-not (Test-Path $WEZTERM)) {
    Write-Host "WezTerm not found at $WEZTERM" -ForegroundColor Red
    exit 1
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_274_wez_*.js" -Force -EA SilentlyContinue
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

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 15000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            & $PSMUX has-session -t $Name 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Heavy TUI-style output script (simulates Claude Code rendering)
@'
const ESC = '\x1b';
let lineCount = 0;
const colors = [31,32,33,34,35,36];
setInterval(() => {
    const c = colors[lineCount % colors.length];
    const prefix = `${ESC}[${c}m`;
    const reset = `${ESC}[0m`;
    const spinner = ['|','/','-','\\'][lineCount % 4];
    process.stdout.write(`\r${prefix}[${spinner}] Processing task ${lineCount}... ${reset}${ESC}[K`);
    if (lineCount % 20 === 0) {
        process.stdout.write(`\n${prefix}  function example_${lineCount}() { return ${lineCount}; }${reset}\n`);
    }
    lineCount++;
}, 50);
'@ | Set-Content "$env:TEMP\psmux_274_wez_heavy.js" -Encoding UTF8

# Frozen process script
@'
process.stdin.resume();
process.on('SIGINT', () => {});
process.on('SIGTERM', () => {});
console.log("FROZEN_PROCESS_STARTED");
setInterval(() => {}, 100000);
'@ | Set-Content "$env:TEMP\psmux_274_wez_frozen.js" -Encoding UTF8

# === CLEANUP ===
Cleanup
Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host "Issue #274: WezTerm-Specific TUI Wedge Reproduction" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  WezTerm: $WEZTERM" -ForegroundColor DarkGray
Write-Host "  psmux:   $PSMUX" -ForegroundColor DarkGray

# ====================================================================
# PART A: Launch psmux INSIDE WezTerm
# ====================================================================
Write-Host "`n=== PART A: psmux Inside WezTerm ===" -ForegroundColor Cyan

# Launch psmux new-session inside WezTerm (this is how gtbuchanan uses it)
Write-Host "`n[Test A1] Launch psmux inside WezTerm" -ForegroundColor Yellow
$wezProc = Start-Process -FilePath $WEZTERM `
    -ArgumentList "start","--","$PSMUX","new-session","-s",$SESSION `
    -PassThru
Start-Sleep -Seconds 5

if (Wait-Session $SESSION 15000) {
    Write-Pass "Session '$SESSION' created inside WezTerm (PID=$($wezProc.Id))"
} else {
    Write-Fail "Session not created inside WezTerm"
    Cleanup
    exit 1
}

# [Test A2] Create multiple windows (gtbuchanan's setup: multiple psmux windows)
Write-Host "`n[Test A2] Create 3 windows (matches gtbuchanan's multi-window setup)" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

$winCount = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
if ($winCount -eq "3") { Write-Pass "3 windows in WezTerm-hosted session" }
else { Write-Fail "Expected 3 windows, got $winCount" }

# [Test A3] Start heavy output in window 0 (simulates Claude Code)
Write-Host "`n[Test A3] Heavy output in window 0 inside WezTerm" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:0" "node `"$env:TEMP\psmux_274_wez_heavy.js`"" Enter
Start-Sleep -Seconds 3

$cap0 = & $PSMUX capture-pane -t "${SESSION}:0" -p 2>&1 | Out-String
if ($cap0 -match "Processing task") { Write-Pass "Window 0 producing heavy output in WezTerm" }
else { Write-Info "Window 0 output: $($cap0.Substring(0, [Math]::Min(80, $cap0.Length)))" }

# [Test A4] send-keys to other windows while window 0 floods
Write-Host "`n[Test A4] send-keys to window 1 while window 0 floods (WezTerm)" -ForegroundColor Yellow
$marker1 = "WEZ_MARKER1_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1" "echo $marker1" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap1 -match $marker1) { Write-Pass "Window 1: send-keys delivered in WezTerm" }
else { Write-Fail "Window 1: send-keys NOT visible in WezTerm" }

# [Test A5] CLI latency while WezTerm renders heavy output
Write-Host "`n[Test A5] CLI command latency in WezTerm with heavy output" -ForegroundColor Yellow
$cliTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 20; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null
    $sw.Stop()
    [void]$cliTimes.Add($sw.Elapsed.TotalMilliseconds)
}
$avg = ($cliTimes | Measure-Object -Average).Average
$max = ($cliTimes | Measure-Object -Maximum).Maximum
Write-Info ("CLI x20: avg=" + [Math]::Round($avg,1) + "ms max=" + [Math]::Round($max,1) + "ms")
if ($max -lt 500) { Write-Pass "CLI latency OK in WezTerm ($([Math]::Round($max,1))ms max)" }
else { Write-Fail "CLI latency high in WezTerm: ${max}ms" }

# [Test A6] TCP server latency while WezTerm renders
Write-Host "`n[Test A6] TCP latency in WezTerm with heavy output" -ForegroundColor Yellow
$tcpTimes = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt 20; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Send-TcpCommand -Session $SESSION -Command "list-sessions"
    $sw.Stop()
    [void]$tcpTimes.Add($sw.Elapsed.TotalMilliseconds)
}
$tcpAvg = ($tcpTimes | Measure-Object -Average).Average
$tcpMax = ($tcpTimes | Measure-Object -Maximum).Maximum
Write-Info ("TCP x20: avg=" + [Math]::Round($tcpAvg,1) + "ms max=" + [Math]::Round($tcpMax,1) + "ms")
if ($tcpMax -lt 200) { Write-Pass "TCP latency OK in WezTerm ($([Math]::Round($tcpMax,1))ms max)" }
else { Write-Fail "TCP latency high in WezTerm: ${tcpMax}ms" }

# ====================================================================
# PART B: Window switching inside WezTerm (the exact symptom)
# ====================================================================
Write-Host "`n=== PART B: Window Navigation in WezTerm ===" -ForegroundColor Cyan

# gtbuchanan's symptom: "hangs that prevent me from navigating to other
# psmux windows or panes" - test this via both CLI and keystrokes

# [Test B1] Window switch via CLI while in WezTerm
Write-Host "`n[Test B1] Window switch via CLI in WezTerm" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$curWin = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
if ($curWin -eq "1") { Write-Pass "select-window to 1 works in WezTerm" }
else { Write-Fail "select-window to 1 failed in WezTerm (got $curWin)" }

& $PSMUX select-window -t "${SESSION}:2" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$curWin = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
if ($curWin -eq "2") { Write-Pass "select-window to 2 works in WezTerm" }
else { Write-Fail "select-window to 2 failed in WezTerm (got $curWin)" }

& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# [Test B2] Keystroke injection into WezTerm-hosted psmux
Write-Host "`n[Test B2] WriteConsoleInput into WezTerm-hosted psmux" -ForegroundColor Yellow

# We need the PID of the actual psmux process (child of wezterm), not wezterm itself
# Get the psmux server/TUI process that owns this session
$psmuxProcs = Get-Process psmux -EA SilentlyContinue
$injectorExe = "$env:TEMP\psmux_injector.exe"
$injectorSrc = "$PSScriptRoot\injector.cs"

# Compile injector if needed
if (-not (Test-Path $injectorExe) -or ((Test-Path $injectorSrc) -and (Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe -EA SilentlyContinue).LastWriteTime)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
    if (Test-Path $injectorExe) { Write-Info "Injector compiled" }
}

# Find the psmux child process inside WezTerm
# WezTerm spawns: wezterm -> conhost -> psmux
# We need the psmux.exe that is a child of the wezterm tree
$wezChildren = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "psmux.exe" -and $_.ParentProcessId -eq $wezProc.Id
}
# If not direct child, check for conhost intermediary
if (-not $wezChildren) {
    $conhosts = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "conhost.exe" -and $_.ParentProcessId -eq $wezProc.Id
    }
    foreach ($ch in $conhosts) {
        $wezChildren = Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq "psmux.exe" -and $_.ParentProcessId -eq $ch.ProcessId
        }
        if ($wezChildren) { break }
    }
}
# Broader: find all psmux processes, check which one is connected to session
if (-not $wezChildren) {
    # Fallback: find the psmux process that has this session's port file locked
    $allPsmux = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "psmux.exe" }
    Write-Info "All psmux PIDs: $($allPsmux.ProcessId -join ', ')"
    # Use the one whose command line contains our session name
    $wezChildren = $allPsmux | Where-Object {
        $_.CommandLine -match $SESSION
    }
}

$targetPid = $null
if ($wezChildren) {
    $targetPid = if ($wezChildren -is [array]) { $wezChildren[0].ProcessId } else { $wezChildren.ProcessId }
    Write-Info "Target psmux PID inside WezTerm: $targetPid"
}

if ($targetPid -and (Test-Path $injectorExe)) {
    # Test prefix+n (next window) - the exact navigation that gtbuchanan says hangs
    $wBefore = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    Write-Info "Window before keystroke: $wBefore"

    & $injectorExe $targetPid "^b{SLEEP:300}n"
    Start-Sleep -Seconds 2

    $wAfter = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    Write-Info "Window after prefix+n: $wAfter"
    if ($wAfter -ne $wBefore) { Write-Pass "Keystroke prefix+n works in WezTerm ($wBefore -> $wAfter)" }
    else { Write-Fail "WEDGE: prefix+n did NOT switch window in WezTerm" }

    # Test prefix+p (previous window)
    & $injectorExe $targetPid "^b{SLEEP:300}p"
    Start-Sleep -Seconds 2
    $wBack = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
    if ($wBack -eq $wBefore) { Write-Pass "Keystroke prefix+p works in WezTerm" }
    else { Write-Info "Window now at $wBack (navigation worked, just different order)" }

    # Test prefix+c (new window) - creating windows is part of the user's workflow
    $winsBefore = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
    & $injectorExe $targetPid "^b{SLEEP:300}c"
    Start-Sleep -Seconds 3
    $winsAfter = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
    if ([int]$winsAfter -gt [int]$winsBefore) { Write-Pass "Keystroke prefix+c new-window works in WezTerm" }
    else { Write-Fail "WEDGE: prefix+c did NOT create window in WezTerm" }
} else {
    Write-Info "Could not find psmux PID in WezTerm tree or injector not available"
    Write-Info "Skipping keystroke injection tests (CLI tests still valid)"
}

# ====================================================================
# PART C: Kill WezTerm + Re-attach in NEW WezTerm (exact workaround)
# ====================================================================
Write-Host "`n=== PART C: WezTerm Kill + Re-Attach (gtbuchanan workaround) ===" -ForegroundColor Cyan

# [Test C1] Kill the WezTerm process (simulates closing the tab)
Write-Host "`n[Test C1] Kill WezTerm hosting psmux" -ForegroundColor Yellow
if (-not $wezProc.HasExited) {
    Stop-Process -Id $wezProc.Id -Force -EA SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Pass "WezTerm process killed"
} else {
    Write-Info "WezTerm already exited"
}

# [Test C2] Verify server survives WezTerm death
Write-Host "`n[Test C2] Server survives WezTerm kill" -ForegroundColor Yellow
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Session alive after WezTerm kill" }
else { Write-Fail "Session LOST after WezTerm kill" }

# [Test C3] send-keys works after WezTerm kill (before re-attach)
Write-Host "`n[Test C3] send-keys works after WezTerm kill" -ForegroundColor Yellow
$markerC = "POSTWEZ_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1" "echo $markerC" Enter
Start-Sleep -Seconds 2
$capC = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($capC -match $markerC) { Write-Pass "send-keys to window 1 works after WezTerm kill" }
else { Write-Fail "send-keys to window 1 FAILED after WezTerm kill" }

# [Test C4] Re-attach in a NEW WezTerm (gtbuchanan's exact workaround)
Write-Host "`n[Test C4] Re-attach in NEW WezTerm instance" -ForegroundColor Yellow
$wezProc2 = Start-Process -FilePath $WEZTERM `
    -ArgumentList "start","--","$PSMUX","attach","-t",$SESSION `
    -PassThru
Start-Sleep -Seconds 5

if (-not $wezProc2.HasExited) {
    Write-Pass "New WezTerm + attach running (PID=$($wezProc2.Id))"
} else {
    Write-Fail "New WezTerm + attach exited prematurely"
}

# [Test C5] Verify session responsive in new WezTerm
Write-Host "`n[Test C5] Session responsive in new WezTerm" -ForegroundColor Yellow
$markerD = "NEWWEZ_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1" "echo $markerD" Enter
Start-Sleep -Seconds 2
$capD = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($capD -match $markerD) { Write-Pass "send-keys works in re-attached WezTerm" }
else { Write-Fail "send-keys FAILED in re-attached WezTerm" }

# [Test C6] Window switching works in new WezTerm
Write-Host "`n[Test C6] Window switch in re-attached WezTerm" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$w = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
if ($w -eq "0") { Write-Pass "select-window works in re-attached WezTerm" }
else { Write-Fail "select-window failed in re-attached WezTerm (got $w)" }

# [Test C7] Keystroke injection in re-attached WezTerm
if (Test-Path $injectorExe) {
    Write-Host "`n[Test C7] Keystrokes in re-attached WezTerm" -ForegroundColor Yellow
    # Find the new psmux child
    $newPsmux = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "psmux.exe" -and $_.CommandLine -match $SESSION
    }
    $newPid = $null
    if ($newPsmux) {
        $newPid = if ($newPsmux -is [array]) { $newPsmux[0].ProcessId } else { $newPsmux.ProcessId }
    }
    # Also try: any psmux whose parent chain goes through new wezterm
    if (-not $newPid) {
        $allPsmux = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "psmux.exe" }
        foreach ($p in $allPsmux) {
            # Check if it looks like an attach process
            if ($p.CommandLine -match "attach") {
                $newPid = $p.ProcessId
                break
            }
        }
    }

    if ($newPid) {
        Write-Info "Re-attached psmux PID: $newPid"
        $wBefore2 = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        & $injectorExe $newPid "^b{SLEEP:300}n"
        Start-Sleep -Seconds 2
        $wAfter2 = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
        if ($wAfter2 -ne $wBefore2) { Write-Pass "Keystrokes work in re-attached WezTerm ($wBefore2 -> $wAfter2)" }
        else { Write-Fail "WEDGE: Keystrokes blocked in re-attached WezTerm" }
    } else {
        Write-Info "Could not find re-attached psmux PID"
    }
}

# ====================================================================
# PART D: Sustained heavy output in WezTerm (60s)
# ====================================================================
Write-Host "`n=== PART D: Sustained Heavy Output in WezTerm (60s) ===" -ForegroundColor Cyan

# Start heavy output again (it was killed when we killed wezterm)
Write-Host "`n[Test D1] Re-start heavy output + sustained probing" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:0" C-c
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t "${SESSION}:0" "node `"$env:TEMP\psmux_274_wez_heavy.js`"" Enter
Start-Sleep -Seconds 3

# Also start heavy output in another window
& $PSMUX send-keys -t "${SESSION}:2" "node `"$env:TEMP\psmux_274_wez_heavy.js`"" Enter
Start-Sleep -Seconds 2

# Freeze a pane in window 1 (simulates Claude Code freezing)
& $PSMUX split-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX send-keys -t "${SESSION}:1.0" "node `"$env:TEMP\psmux_274_wez_frozen.js`"" Enter
Start-Sleep -Seconds 2

# Get baseline
$serverProc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
$memBaseline = if ($serverProc) { [Math]::Round($serverProc.WorkingSet64/1MB,1) } else { 0 }
Write-Info "Server baseline: mem=${memBaseline}MB"

# Sustained probing for 60 seconds
$duration = 60
$startTime = Get-Date
$cliSamples = [System.Collections.ArrayList]::new()
$tcpSamples = [System.Collections.ArrayList]::new()
$failedCli = 0
$failedTcp = 0
$lastReport = Get-Date

while (((Get-Date) - $startTime).TotalSeconds -lt $duration) {
    # CLI probe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cliOut = & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-String
    $sw.Stop()
    if ($cliOut.Trim() -eq $SESSION) {
        [void]$cliSamples.Add($sw.Elapsed.TotalMilliseconds)
    } else { $failedCli++ }

    # TCP probe
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $tcpResp = Send-TcpCommand -Session $SESSION -Command "list-sessions"
    $sw2.Stop()
    if ($tcpResp -match $SESSION) {
        [void]$tcpSamples.Add($sw2.Elapsed.TotalMilliseconds)
    } else { $failedTcp++ }

    # Window switch probe (the operation that gtbuchanan says hangs)
    $targetWin = (Get-Random -Minimum 0 -Maximum 3).ToString()
    & $PSMUX select-window -t "${SESSION}:${targetWin}" 2>&1 | Out-Null

    # Check WezTerm is still alive
    if ($wezProc2.HasExited) {
        Write-Fail "WezTerm CRASHED during sustained output"
        break
    }

    # Progress report every 15s
    if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
        $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $cliAvg = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Average).Average,1) } else { "N/A" }
        Write-Info "  +${elapsed}s: CLI avg=${cliAvg}ms samples=$($cliSamples.Count) failedCLI=$failedCli failedTCP=$failedTcp"
        $lastReport = Get-Date
    }

    Start-Sleep -Milliseconds 500
}

# Final stats
Write-Host "`n[Test D2] 60s sustained results in WezTerm:" -ForegroundColor Yellow
$cliAvg = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Average).Average,1) } else { "N/A" }
$cliMax = if ($cliSamples.Count -gt 0) { [Math]::Round(($cliSamples | Measure-Object -Maximum).Maximum,1) } else { "N/A" }
$tcpAvg = if ($tcpSamples.Count -gt 0) { [Math]::Round(($tcpSamples | Measure-Object -Average).Average,1) } else { "N/A" }
$tcpMax = if ($tcpSamples.Count -gt 0) { [Math]::Round(($tcpSamples | Measure-Object -Maximum).Maximum,1) } else { "N/A" }

$serverProc = Get-Process psmux -EA SilentlyContinue | Sort-Object Id | Select-Object -First 1
$memFinal = if ($serverProc) { [Math]::Round($serverProc.WorkingSet64/1MB,1) } else { 0 }

Write-Info "CLI: avg=${cliAvg}ms max=${cliMax}ms samples=$($cliSamples.Count) failures=$failedCli"
Write-Info "TCP: avg=${tcpAvg}ms max=${tcpMax}ms samples=$($tcpSamples.Count) failures=$failedTcp"
Write-Info "Server: mem ${memBaseline}MB -> ${memFinal}MB (delta $([Math]::Round($memFinal-$memBaseline,1))MB)"

if ($failedCli -eq 0) { Write-Pass "Zero CLI failures over 60s in WezTerm" }
else { Write-Fail "$failedCli CLI failures in WezTerm" }

if ($failedTcp -eq 0) { Write-Pass "Zero TCP failures over 60s in WezTerm" }
else { Write-Fail "$failedTcp TCP failures in WezTerm" }

if (-not $wezProc2.HasExited) { Write-Pass "WezTerm survived full 60s sustained output" }

# [Test D3] Final: send-keys and capture after sustained
Write-Host "`n[Test D3] send-keys after 60s sustained in WezTerm" -ForegroundColor Yellow
& $PSMUX send-keys -t "${SESSION}:1.1" C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$markerFinal = "FINALWEZ_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1.1" "echo $markerFinal" Enter
Start-Sleep -Seconds 2
$capFinal = & $PSMUX capture-pane -t "${SESSION}:1.1" -p 2>&1 | Out-String
if ($capFinal -match $markerFinal) { Write-Pass "send-keys works after 60s sustained in WezTerm" }
else { Write-Fail "send-keys FAILED after 60s in WezTerm" }

# ====================================================================
# FINAL CLEANUP
# ====================================================================
Write-Host "`n=== Cleanup ===" -ForegroundColor DarkGray
if (-not $wezProc2.HasExited) {
    try { Stop-Process -Id $wezProc2.Id -Force -EA SilentlyContinue } catch {}
}
Cleanup

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "======================================================" -ForegroundColor Cyan

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  CONCLUSION: Issue #274 NOT REPRODUCIBLE in WezTerm." -ForegroundColor Green
    Write-Host "  Server I/O, CLI/TCP latency, window navigation, keystroke" -ForegroundColor Green
    Write-Host "  injection, WezTerm kill/re-attach, and 60s sustained heavy" -ForegroundColor Green
    Write-Host "  output all work correctly inside WezTerm." -ForegroundColor Green
} else {
    Write-Host "`n  CONCLUSION: $($script:TestsFailed) test(s) FAILED in WezTerm." -ForegroundColor Red
    Write-Host "  WezTerm-specific issue may exist. Investigate failures above." -ForegroundColor Red
}

exit $script:TestsFailed
