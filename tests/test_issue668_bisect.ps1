# Issue #668: `send-keys C-c` stops interrupting a flooding pane, but ONLY
# after the full test_issue274_tui_wedge_repro sequence has run.
#
# This file is the bisect harness, not a product test. It replays the #274
# suite's phases CUMULATIVELY and, after each set, interrupts a flooding node
# in window 2 and measures whether the child actually dies. The phase set is
# chosen by PSMUX_I668_PHASE (A, AB, ABC, ABCD, ABCDE) because the sanctioned
# runner discovers suites by glob and cannot pass parameters.
#
#   A  three windows, heavy TUI output in window 0, marker echoes, latency loops
#   B  compile injector, attach a TUI client, injector prefix+n / prefix+p
#   C  split window 1, frozen (SIGINT-ignoring) child in 1.0, TCP dump-state
#   D  force kill the client, send-keys after the kill, fresh attach, injector
#   E  heavy output in 1.1 and 2, a third client, the 90s probing loop
#
# The measurement prints everything needed to tell the candidate mechanisms
# apart: the pane's process tree, the console process list psmux itself saw,
# the server's ctrl_c trace for this exact call, and, for every process in the
# chain, RTL_USER_PROCESS_PARAMETERS.ConsoleFlags -- bit 0 is the inherited
# "ignore Ctrl+C" state that SetConsoleCtrlHandler(NULL, TRUE) sets and that no
# Win32 API reports.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test668_bisect"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

# Default to phase A alone. Unset, this file is picked up by the runner's glob
# like any other suite, and the full set spends ninety seconds flooding before
# it measures anything, which does not fit the runner's 240 s default. Phase A
# still asserts the thing that matters (C-c interrupts a flooding pane child)
# and finishes in well under a minute; the longer sets are for a bisect, where
# the caller sets the variable deliberately.
$PHASES = $env:PSMUX_I668_PHASE
if (-not $PHASES) { $PHASES = "A" }
$PHASES = $PHASES.ToUpper()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Diag($msg) { Write-Host "  [DIAG] $msg" -ForegroundColor DarkYellow }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux_668_*.js" -Force -EA SilentlyContinue
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
        if ($reader.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
        $writer.Write("$Command`n"); $writer.Flush()
        $stream.ReadTimeout = 10000
        try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch { return "TCP_ERROR: $_" }
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
$script:CtrlFlagsExe = "$env:TEMP\psmux_668_ctrlflags.exe"
function Build-CtrlFlags {
    $src = "$PSScriptRoot\ctrlflags.cs"
    if (-not (Test-Path $src)) { return $false }
    if ((Test-Path $script:CtrlFlagsExe) -and
        (Get-Item $script:CtrlFlagsExe).LastWriteTime -gt (Get-Item $src).LastWriteTime) { return $true }
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { return $false }
    & $csc /nologo /optimize /out:$script:CtrlFlagsExe $src 2>&1 | Out-Null
    return (Test-Path $script:CtrlFlagsExe)
}

function Get-Descendants {
    param([int]$RootPid)
    $out = @()
    if ($RootPid -le 0) { return $out }
    $q = [System.Collections.Queue]::new(); $q.Enqueue($RootPid)
    while ($q.Count -gt 0) {
        $id = $q.Dequeue()
        foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -EA SilentlyContinue)) {
            $out += [pscustomobject]@{ Name = $c.Name; Pid = [int]$c.ProcessId; Ppid = $id }
            $q.Enqueue([int]$c.ProcessId)
        }
    }
    return $out
}

function Get-ServerPid {
    foreach ($ext in @("pid", "server.pid")) {
        $f = "$psmuxDir\$SESSION.$ext"
        if (Test-Path $f) {
            $v = (Get-Content $f -Raw -EA SilentlyContinue)
            if ($v) { $n = 0; if ([int]::TryParse($v.Trim().Split()[0], [ref]$n)) { return $n } }
        }
    }
    return 0
}

function Show-CtrlFlags {
    param([string]$Label, [int[]]$Pids)
    if (-not (Test-Path $script:CtrlFlagsExe)) { return }
    $ids = @($Pids | Where-Object { $_ -gt 0 })
    if (-not $ids.Count) { return }
    $lines = & $script:CtrlFlagsExe @ids 2>&1
    foreach ($l in $lines) { Write-Diag "$Label $l" }
}

$script:DebugLog = "$psmuxDir\mouse_debug.log"
function Get-DebugLogLength {
    if (Test-Path $script:DebugLog) { return (Get-Item $script:DebugLog).Length }
    return 0
}
function Show-CtrlCTrace {
    param([long]$Since)
    if (-not (Test-Path $script:DebugLog)) { Write-Diag "no mouse_debug.log (PSMUX_MOUSE_DEBUG not set?)"; return }
    try {
        $fs = [System.IO.File]::Open($script:DebugLog, 'Open', 'Read', 'ReadWrite')
        $fs.Seek($Since, 'Begin') | Out-Null
        $sr = [System.IO.StreamReader]::new($fs)
        $txt = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
    } catch { Write-Diag "debug log read failed: $_"; return }
    $n = 0
    foreach ($line in ($txt -split "`r?`n")) {
        if ($line -match 'ctrl_c|ctrl_break') { Write-Diag "trace | $line"; $n++ }
    }
    if ($n -eq 0) { Write-Diag "trace | <no ctrl_c lines appeared in the server log for this call>" }
}

# ---------------------------------------------------------------------------
# The measurement: interrupt the flooding node in window 2 and see if it dies
# ---------------------------------------------------------------------------
# The flood script numbers every line it prints, so the highest number on the
# pane is a clock of the CHILD's own progress. Compared against how long the
# child has been alive (20 lines/second by construction) it says whether the
# child is running freely or is stalled inside its console writes.
function Get-PaneTick {
    param([string]$Target)
    $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
    $best = -1
    foreach ($m in [regex]::Matches($cap, 'Processing task (\d+)')) {
        $v = [int]$m.Groups[1].Value
        if ($v -gt $best) { $best = $v }
    }
    return $best
}

function Show-ThreadState {
    param([string]$Label, [int]$ProcPid)
    $p = Get-Process -Id $ProcPid -EA SilentlyContinue
    if (-not $p) { Write-Diag "$Label pid=$ProcPid <gone>"; return }
    $main = $p.Threads | Sort-Object { $_.TotalProcessorTime } -Descending | Select-Object -First 1
    $age = [Math]::Round(((Get-Date) - $p.StartTime).TotalSeconds, 1)
    Write-Diag ("$Label pid=$ProcPid age=${age}s cpu=" + [Math]::Round($p.TotalProcessorTime.TotalSeconds, 2) +
        "s mainthread state=$($main.ThreadState) wait=$($main.WaitReason)")
}

function Measure-Interrupt {
    param([string]$Tag, [string]$Target = "${SESSION}:2")

    $panePid = 0
    try { $panePid = [int](& $PSMUX display-message -t $Target -p '#{pane_pid}' 2>&1 | Out-String).Trim() } catch { }
    $before = @(Get-Descendants -RootPid $panePid)
    $nodes = @($before | Where-Object { $_.Name -eq 'node.exe' })
    $cmd = (& $PSMUX display-message -t $Target -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
    $srvPid = Get-ServerPid

    Write-Host "`n[$Tag] interrupt $Target (phases=$PHASES)" -ForegroundColor Yellow
    Write-Diag "pane_pid=$panePid current_command=$cmd children=$(if ($before.Count) { ($before | ForEach-Object { "$($_.Name):$($_.Pid)" }) -join ',' } else { '<none>' })"
    Write-Diag "server_pid=$srvPid node_children=$($nodes.Count)"
    Show-CtrlFlags -Label "before" -Pids (@($srvPid, $panePid) + @($nodes | ForEach-Object { $_.Pid }))

    if (-not $nodes.Count) {
        Write-Fail "$Tag no node child to interrupt (pane runs '$cmd')"
        return $false
    }

    $nodePid = $nodes[0].Pid
    $np = Get-Process -Id $nodePid -EA SilentlyContinue
    $nodeAge = if ($np) { ((Get-Date) - $np.StartTime).TotalSeconds } else { 0 }
    $tick0 = Get-PaneTick -Target $Target
    $tps = $script:TicksPerSec
    $expected = [int]($nodeAge * $tps)
    Write-Diag ("$Tag before: node age=" + [Math]::Round($nodeAge, 1) + "s screen_tick=$tick0 expected~$expected lag=" +
        $(if ($tick0 -ge 0) { [Math]::Round(($expected - $tick0) / $tps, 1) } else { '?' }) + "s")
    Show-ThreadState -Label "$Tag before node" -ProcPid $nodePid

    $mark = Get-DebugLogLength
    & $PSMUX send-keys -t $Target C-c 2>&1 | Out-Null
    $rc = $LASTEXITCODE

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $died = $false
    while ($sw.ElapsedMilliseconds -lt 30000) {
        $alive = @($nodes | Where-Object { Get-Process -Id $_.Pid -EA SilentlyContinue })
        if (-not $alive.Count) { $died = $true; break }
        Start-Sleep -Milliseconds 200
    }
    $ms = $sw.ElapsedMilliseconds

    Show-CtrlCTrace -Since $mark
    if ($died) {
        Write-Pass "$Tag C-c killed the flooding child in ${ms}ms (send-keys rc=$rc)"
        return $true
    }

    Write-Fail "$Tag C-c did NOT kill the flooding child within ${ms}ms (send-keys rc=$rc)"
    Show-ThreadState -Label "$Tag after node" -ProcPid $nodePid
    $tick1 = Get-PaneTick -Target $Target
    Write-Diag "$Tag after: screen_tick=$tick1 (was $tick0) -> child advanced $(($tick1 - $tick0)) lines while a live child would have made $([int](30 * $script:TicksPerSec))"
    $after = @(Get-Descendants -RootPid $panePid)
    Write-Diag "after children=$(if ($after.Count) { ($after | ForEach-Object { "$($_.Name):$($_.Pid)" }) -join ',' } else { '<none>' })"
    Show-CtrlFlags -Label "after" -Pids (@($srvPid, $panePid) + @($nodes | ForEach-Object { $_.Pid }))
    $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
    ($cap -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) |
        ForEach-Object { Write-Diag "| $_" }
    return $false
}

function Start-Flood {
    param([string]$Target)
    & $PSMUX send-keys -t $Target "node `"$env:TEMP\psmux_668_heavy_tui.js`"" Enter 2>&1 | Out-Null
}

function Wait-Flood {
    param([string]$Target, [int]$TimeoutMs = 15000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $panePid = 0
    try { $panePid = [int](& $PSMUX display-message -t $Target -p '#{pane_pid}' 2>&1 | Out-String).Trim() } catch { }
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (@(Get-Descendants -RootPid $panePid | Where-Object { $_.Name -eq 'node.exe' }).Count) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# ===========================================================================
Cleanup
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Issue #668 bisect: phases=$PHASES" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Info "psmux: $PSMUX"
if (Build-CtrlFlags) { Write-Info "ConsoleFlags probe: $script:CtrlFlagsExe" }
else { Write-Info "ConsoleFlags probe unavailable" }

$rate = 50
if ($env:PSMUX_I668_RATE) { $rate = [int]$env:PSMUX_I668_RATE }
$script:TicksPerSec = [double](1000.0 / $rate)
Write-Info "flood interval = ${rate}ms"
(@'
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
}, __RATE__);
'@ -replace '__RATE__', $rate) | Set-Content "$env:TEMP\psmux_668_heavy_tui.js" -Encoding UTF8

@'
process.stdin.resume();
process.on('SIGINT', () => {});
process.on('SIGTERM', () => {});
console.log("FROZEN_PROCESS_STARTED");
setInterval(() => {}, 100000);
'@ | Set-Content "$env:TEMP\psmux_668_frozen.js" -Encoding UTF8

# --- PHASE A -------------------------------------------------------------
Write-Host "`n=== PHASE A ===" -ForegroundColor Cyan
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1
$winCount = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
Write-Info "windows=$winCount"

Start-Flood -Target "${SESSION}:0"
Start-Sleep -Seconds 3

$m1 = "W1_MARKER_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:1" "echo $m1" Enter
$m2 = "W2_MARKER_$(Get-Random)"
& $PSMUX send-keys -t "${SESSION}:2" "echo $m2" Enter
Start-Sleep -Seconds 2

for ($i = 0; $i -lt 20; $i++) { & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null }
for ($i = 0; $i -lt 20; $i++) { $null = Send-TcpCommand -Session $SESSION -Command "list-sessions" }
Write-Info "phase A done"

$injectorExe = "$env:TEMP\psmux_injector.exe"
$tuiProc = $null; $freshProc = $null; $stressProc = $null

# --- PHASE B -------------------------------------------------------------
if ($PHASES.Length -ge 2) {
    Write-Host "`n=== PHASE B ===" -ForegroundColor Cyan
    $injectorSrc = "$PSScriptRoot\injector.cs"
    $needCompile = (-not (Test-Path $injectorExe)) -or ((Test-Path $injectorSrc) -and (Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe -EA SilentlyContinue).LastWriteTime)
    if ($needCompile -and (Test-Path $injectorSrc)) {
        & "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
    }
    $tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
    Start-Sleep -Seconds 4
    Write-Info "TUI client pid=$($tuiProc.Id) exited=$($tuiProc.HasExited)"
    & $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    if (Test-Path $injectorExe) {
        & $injectorExe $tuiProc.Id "^b{SLEEP:300}n" | Out-Null
        Start-Sleep -Seconds 2
        & $injectorExe $tuiProc.Id "^b{SLEEP:300}p" | Out-Null
        Start-Sleep -Seconds 2
    }
    Write-Info "phase B done"
}

# --- PHASE C -------------------------------------------------------------
if ($PHASES.Length -ge 3) {
    Write-Host "`n=== PHASE C ===" -ForegroundColor Cyan
    & $PSMUX select-window -t "${SESSION}:1" 2>&1 | Out-Null
    & $PSMUX split-window -t "${SESSION}:1" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t "${SESSION}:1.0" "node `"$env:TEMP\psmux_668_frozen.js`"" Enter
    Start-Sleep -Seconds 3
    $mc = "ALIVE_PANE_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:1.1" "echo $mc" Enter
    Start-Sleep -Seconds 2
    $null = Send-TcpCommand -Session $SESSION -Command "dump-state"
    Write-Info "phase C done"
}

# --- PHASE D -------------------------------------------------------------
if ($PHASES.Length -ge 4) {
    Write-Host "`n=== PHASE D ===" -ForegroundColor Cyan
    if ($tuiProc -and -not $tuiProc.HasExited) {
        Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }
    $md = "POSTKILL_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:1.1" "echo $md" Enter
    Start-Sleep -Seconds 2
    $freshProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
    Start-Sleep -Seconds 4
    Write-Info "fresh client pid=$($freshProc.Id) exited=$($freshProc.HasExited)"
    $mf = "FRESH_ATTACH_$(Get-Random)"
    & $PSMUX send-keys -t "${SESSION}:2" "echo $mf" Enter
    Start-Sleep -Seconds 2
    if ((Test-Path $injectorExe) -and -not $freshProc.HasExited) {
        & $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        & $injectorExe $freshProc.Id "^b{SLEEP:300}n" | Out-Null
        Start-Sleep -Seconds 2
    }
    if ($freshProc -and -not $freshProc.HasExited) { Stop-Process -Id $freshProc.Id -Force -EA SilentlyContinue }
    Start-Sleep -Seconds 1
    Write-Info "phase D done"
}

# --- PHASE E -------------------------------------------------------------
if ($PHASES.Length -ge 5) {
    Write-Host "`n=== PHASE E ===" -ForegroundColor Cyan
    Start-Flood -Target "${SESSION}:1.1"
    Start-Flood -Target "${SESSION}:2"
    Start-Sleep -Seconds 3
    $stressProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SESSION -PassThru
    Start-Sleep -Seconds 3
    Write-Info "stress client pid=$($stressProc.Id) exited=$($stressProc.HasExited)"
    $dur = 90
    if ($env:PSMUX_I668_FLOOD) { $dur = [int]$env:PSMUX_I668_FLOOD }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $dur) {
        & $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-Null
        $null = Send-TcpCommand -Session $SESSION -Command "list-sessions"
        Start-Sleep -Milliseconds 500
    }
    Write-Info "phase E done ($dur s)"
}

# --- MEASUREMENT ---------------------------------------------------------
# Window 2 must be flooding. In ABCDE it already is (phase E started it);
# otherwise start one and let it settle for the same few seconds.
if (-not (@(Get-Descendants -RootPid ([int](& $PSMUX display-message -t "${SESSION}:2" -p '#{pane_pid}' 2>&1 | Out-String).Trim()) | Where-Object { $_.Name -eq 'node.exe' }).Count)) {
    Start-Flood -Target "${SESSION}:2"
    if (-not (Wait-Flood -Target "${SESSION}:2")) { Write-Fail "flood never started in window 2" }
    Start-Sleep -Seconds 3
}

$null = Measure-Interrupt -Tag "M1"

# Second measurement on a FRESH child in the same pane: tells a sticky pane /
# console state apart from a one-off miss.
Start-Sleep -Seconds 2
Start-Flood -Target "${SESSION}:2"
if (Wait-Flood -Target "${SESSION}:2") {
    Start-Sleep -Seconds 3
    $null = Measure-Interrupt -Tag "M2"
} else {
    Write-Info "M2 skipped: no second flood started"
}

# Control: a pane that took no part in the sequence beyond phase A.
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
$ctrlWin = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
Start-Flood -Target "${SESSION}:$ctrlWin"
if (Wait-Flood -Target "${SESSION}:$ctrlWin") {
    Start-Sleep -Seconds 3
    $null = Measure-Interrupt -Tag "M3-freshwindow" -Target "${SESSION}:$ctrlWin"
} else {
    Write-Info "M3 skipped: no flood in the control window"
}

# --- CLEANUP -------------------------------------------------------------
foreach ($p in @($tuiProc, $freshProc, $stressProc)) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
}
Cleanup

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  phases=$PHASES  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
exit $script:TestsFailed
