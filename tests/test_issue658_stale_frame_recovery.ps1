# Issue #658: an attached client must never be able to get stuck on a stale
# frame, and a window switch must always reach it.
#
# WHAT WAS REPORTED
# -----------------
# Since 9093e03 ("push one frame per pty batch, and stop an idle client
# re-asking for a screen that has not changed") an attached client had no way to
# recover from a single missed server push. The idle arm of the client's
# `should_dump` was a hard `false`, and the same commit spent `force_dump` on
# the REQUEST rather than on the reply, so there was no latch left to retry
# with. One push that did not land pinned the display on a stale frame: status
# bar tabs stopped switching, keys stopped echoing, both processes sat at near
# zero CPU, and only detach plus re-attach brought it back.
#
# WHAT WAS MEASURED BEFORE ANYTHING WAS CHANGED
# ---------------------------------------------
# On the shipped binary at e70323c, all of it under a real attached client:
#
#   * The freeze itself did NOT reproduce. A 25 minute hunt with four CPU
#     burners running, a 250 ms ticker in one window, and a window switch every
#     9 seconds, comparing the CLIENT's visible console screen against the
#     server's own `capture-pane` every 700 ms: 660 samples, longest run of
#     samples where the client trailed the server by more than 12 ticks = 0.
#   * A sweep of 14 server side changes (rename-window, status-left,
#     status-right, new-window, select-window both ways, a user option used by
#     the status bar, display-message, window-status-format, split-window,
#     status off and on again) all reached the client within 2.5 s. Nothing was
#     lost.
#   * The NC lie IS real. Over one persistent control connection that sent
#     `select-window` and `dump-state` so that both landed in one server request
#     batch, the server answered the dump-state with "NC" - literally "nothing
#     has changed" - 3 times in 40 single switches, and 9 times in 10 when the
#     batch was widened with filler requests. The bottom of loop push repaired
#     it milliseconds later, which is why no screen ever showed it.
#
# So the push is reliable TODAY, and the two things that are actually wrong are
# a server that lies in its reply and a client that has nothing to fall back on
# if a push ever does go missing. Both are fixed; this suite pins both.
#
# THE CELLS
# ---------
# 1. THE FLOOR. An idle attached client must ask the server for a screen at
#    least once per IDLE_FLOOR_MS. This is the whole of the reporter's primary
#    fix and it is what bounds any missed push at a second instead of for ever.
#    Measured by counting the client's own socket reads through PSMUX_PTY_TRACE
#    stage 'c', the same instrument tests/test_idle_socket_traffic.ps1 uses.
# 2. THE FLOOR IS A FLOOR. The same measurement must stay under the 5 lines/sec
#    quiet gate that test_idle_socket_traffic.ps1 asserts idle means, so the
#    floor can never turn back into the 187/sec request/reply spin that 9093e03
#    removed.
# 3. IDLE CPU. Both processes must still be idle with the floor in place.
# 4. DELIVERY. A window switch between two idle windows must reach the client's
#    SCREEN every time. This is the user facing half of the NC fix: the `NC`
#    decision is pinned exactly in tests-rs/test_issue658_nc_decision.rs, and
#    this makes sure tightening it did not cost delivery.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue658_stale_frame_recovery.ps1

param(
    [string]$Binary = "",
    [int]$IdleSecs = 10,
    # The floor is one request per second. Half of that is the failure line: a
    # client that asks less often than this is not keeping a floor at all.
    [double]$MinLinesPerSec = 0.5,
    # test_idle_socket_traffic.ps1's own quiet gate, repeated here so the floor
    # is checked against it in the same breath.
    [double]$QuietLinesPerSec = 5,
    [int]$Switches = 12
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green;    $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;      $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow;   $script:TestsSkipped++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function Write-Test($m) { Write-Host "`n[$m]" -ForegroundColor Cyan }

if (-not $Binary) {
    $Binary = $env:PSMUX_TEST_EXE
}
if (-not $Binary) {
    $Binary = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
}
if (-not $Binary) {
    $Binary = (Get-Command psmux -EA SilentlyContinue).Source
}
if (-not $Binary -or -not (Test-Path $Binary)) { Write-Host "psmux not found"; exit 1 }
Write-Info "binary under test: $Binary"

# This shell's own session routing must never leak into the session under test.
foreach ($v in @('PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE','PSMUX_PANE_ID','PSMUX_SOCKET','TMUX','TMUX_PANE','PSMUX','PSMUX_PTY_TRACE','PSMUX_NO_FRAME_WAKE')) {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}

$NS = "i658_$PID"
$SESS = "s658"
$COLS = 110
$ROWS = 30
$work = Join-Path $env:TEMP "psmux_i658_$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$exeName = [IO.Path]::GetFileName($Binary)

function P { & $Binary -L $NS @args 2>&1 | Out-String }

# ── the console screen oracle ────────────────────────────────────────────────
# capture-pane returns pane CONTENT, which is the server's copy. The only thing
# that can tell a stale client from a live one is what the CLIENT painted, so
# read its console screen buffer directly.
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
$conread = Join-Path $work "conread.exe"
if (Test-Path $csc) {
    & $csc /nologo /platform:x64 "/out:$conread" (Join-Path $PSScriptRoot "conread.cs") 2>&1 | Out-Null
}

# ── the session ──────────────────────────────────────────────────────────────
# Both panes write ONE marker and then sleep, so neither produces a byte for the
# rest of the run: "idle" here means the pane is silent, not merely quiet.
$idleA = "MRKAAAAAAA"
$idleB = "MRKBBBBBBB"
function Start-Session {
    # Retried: a server that is still coming up answers "no server running", and
    # a single attempt turns that into a failure about the wrong thing.
    $up = $false
    for ($attempt = 0; $attempt -lt 3 -and -not $up; $attempt++) {
        P new-session -d -s $SESS -x $COLS -y $ROWS pwsh -NoLogo -NoProfile -Command "[Console]::Out.Write('$idleA'); Start-Sleep -Seconds 900" | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 15000) {
            & $Binary -L $NS has-session -t $SESS 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $up = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $up) { Start-Sleep -Milliseconds 800 }
    }
    P new-window -t "${SESS}:" pwsh -NoLogo -NoProfile -Command "[Console]::Out.Write('$idleB'); Start-Sleep -Seconds 900" | Out-Null
    Start-Sleep -Milliseconds 1200
    P select-window -t "${SESS}:0" | Out-Null
    Start-Sleep -Milliseconds 800
}

# An attached client needs a REAL console, which this shell cannot give it, so
# it is launched through a .cmd under its own cmd.exe. The .cmd also scrubs the
# routing variables a second time: they are inherited, not read from a file.
function Start-Client {
    param([string]$TracePrefix = "")
    $launch = Join-Path $work "attach_$NS.cmd"
    $traceLine = if ($TracePrefix) { "set PSMUX_PTY_TRACE=$TracePrefix" } else { "set PSMUX_PTY_TRACE=" }
    Set-Content -Path $launch -Encoding ASCII -Value @(
        "@echo off",
        "set PSMUX_SESSION=",
        "set PSMUX_SESSION_NAME=",
        "set PSMUX_PANE=",
        "set TMUX=",
        "set TMUX_PANE=",
        "set NO_COLOR=",
        $traceLine,
        "`"$Binary`" -L $NS attach -t $SESS"
    )
    $launcher = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $launch -PassThru -WindowStyle Minimized
    $clientPid = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000 -and $clientPid -eq 0) {
        Start-Sleep -Milliseconds 400
        $found = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcher.Id)" -EA SilentlyContinue |
            Where-Object { $_.Name -eq $exeName } | Select-Object -ExpandProperty ProcessId)
        if ($found.Count -ge 1) { $clientPid = [int]$found[0] }
    }
    return [pscustomobject]@{ Launcher = $launcher; ClientPid = $clientPid }
}

# Only PIDs this suite started are ever ended, and never by image name: other
# agents build and test the same binary on this machine at the same time.
function Stop-Client {
    param($C)
    if (-not $C) { return }
    if ($C.ClientPid -gt 0) { try { Stop-Process -Id $C.ClientPid -Force -EA SilentlyContinue } catch {} }
    try { if (-not $C.Launcher.HasExited) { Stop-Process -Id $C.Launcher.Id -Force -EA SilentlyContinue } } catch {}
}

# Client socket reads inside one window, from the trace files the client and
# server each write as <prefix>.<pid>. Stage 'c' is "the client's socket reader
# read a whole line", which is one NC or one frame.
function Measure-ClientReads {
    param([string]$TracePrefix, [int]$Seconds)
    $sizes0 = @{}
    Get-ChildItem "$TracePrefix.*" -EA SilentlyContinue | ForEach-Object { $sizes0[$_.Name] = $_.Length }
    $w = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Seconds
    $w.Stop()
    $c = 0
    Get-ChildItem "$TracePrefix.*" -EA SilentlyContinue | ForEach-Object {
        $start = if ($sizes0.ContainsKey($_.Name)) { $sizes0[$_.Name] } else { 0 }
        # Both psmux processes still hold these files open, so share write access.
        $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($start, 'Begin') | Out-Null
            $sr = New-Object IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $ln = $sr.ReadLine()
                if (-not $ln -or $ln.StartsWith('#')) { continue }
                if (($ln -split ' ')[1] -eq 'c') { $c++ }
            }
        } finally { $fs.Close() }
    }
    return [pscustomobject]@{
        Seconds = [math]::Round($w.Elapsed.TotalSeconds, 2)
        Reads   = $c
        PerSec  = [math]::Round($c / $w.Elapsed.TotalSeconds, 2)
    }
}

# ══════════════════════════════════════════════════════════════════════════════
Write-Test "cells 1-3: an idle client keeps a floor under the push, and stays idle"

$tracePrefix = Join-Path $work "trace_$PID"
Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue
Start-Session
$c1 = Start-Client -TracePrefix $tracePrefix

if ($c1.ClientPid -eq 0) {
    Write-Fail "the attached client never came up, so nothing below was measured"
} else {
    Write-Info "client pid $($c1.ClientPid), server pid $(P display-message -p '#{pid}')"
    Start-Sleep -Seconds 6   # let attach traffic finish before the window opens

    . (Join-Path $PSScriptRoot "perf_metrics_common.ps1")
    $srvPid = Get-PerfServerPid -Ns $NS -Session $SESS
    $roles = [ordered]@{ server = $srvPid; client = $c1.ClientPid }

    # 10s, not 3 or 4: the resolution of this measurement is one scheduler tick
    # (15.6 ms) over the window, so a 4 s window quantises to 0.39% per tick and
    # a couple of stray ticks read as 3%. Over 10 s the same noise is 0.16% and
    # three 20 s windows of each build measured 0.00% either side of the floor.
    $idleCpu = Measure-PerfIdleCpu -Roles $roles -Seconds 10
    $m = Measure-ClientReads -TracePrefix $tracePrefix -Seconds $IdleSecs
    Write-Info ("idle window {0}s: {1} client socket reads, {2} per second" -f $m.Seconds, $m.Reads, $m.PerSec)

    # ── cell 1: the floor exists ─────────────────────────────────────────────
    if ($m.PerSec -ge $MinLinesPerSec) {
        Write-Pass ("an idle attached client asks the server for a screen {0} times a second, at or above the {1}/sec floor" -f $m.PerSec, $MinLinesPerSec)
    } else {
        Write-Fail ("an idle attached client asks the server for a screen {0} times a second, under the {1}/sec floor - with no floor at all, the ONLY way it learns anything is a server push, and one push that does not land leaves the display stale until the user detaches and attaches again (#658)" -f $m.PerSec, $MinLinesPerSec)
    }

    # ── cell 2: and it is only a floor ───────────────────────────────────────
    if ($m.PerSec -lt $QuietLinesPerSec) {
        Write-Pass ("...and only a floor: {0} lines/sec is under the {1}/sec quiet gate that tests/test_idle_socket_traffic.ps1 asserts idle means" -f $m.PerSec, $QuietLinesPerSec)
    } else {
        Write-Fail ("{0} lines/sec is at or over the {1}/sec quiet gate - the floor has turned back into the request/reply spin commit 9093e03 removed (187/sec). Check that the NC handler still stamps last_dump_time" -f $m.PerSec, $QuietLinesPerSec)
    }

    # ── cell 3: idle is still idle ───────────────────────────────────────────
    $srvCpu = if ($idleCpu.pct_of_one_core.Contains("server")) { [double]$idleCpu.pct_of_one_core["server"] } else { -1 }
    $cliCpu = if ($idleCpu.pct_of_one_core.Contains("client")) { [double]$idleCpu.pct_of_one_core["client"] } else { -1 }
    Write-Info ("idle CPU over {0} ms: server {1}% of one core, client {2}%" -f $idleCpu.window_ms, $srvCpu, $cliCpu)
    if ($srvCpu -lt 0 -or $cliCpu -lt 0) {
        Write-Skip "could not sample both processes, so idle CPU was not asserted"
    } elseif ($srvCpu -le 10 -and $cliCpu -le 10) {
        Write-Pass ("both processes are still idle with the floor in place: server {0}%, client {1}% of one core" -f $srvCpu, $cliCpu)
    } else {
        Write-Fail ("idle CPU is server {0}%, client {1}% of one core - one request and one 2 byte reply per second cannot cost this, so something is spinning" -f $srvCpu, $cliCpu)
    }
}
Stop-Client $c1
& $Binary -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue

# ══════════════════════════════════════════════════════════════════════════════
Write-Test "cell 4: a window switch between two idle windows reaches the client's screen"

if (-not (Test-Path $conread)) {
    Write-Skip "conread.exe could not be built, so the client's screen could not be read"
} else {
    Start-Session
    $c2 = Start-Client
    if ($c2.ClientPid -eq 0) {
        Write-Fail "the attached client never came up, so window switching was not measured"
    } else {
        Start-Sleep -Seconds 4
        $missed = 0
        $slowest = 0
        for ($i = 0; $i -lt $Switches; $i++) {
            $idx = $i % 2
            $want = if ($idx -eq 0) { $idleA } else { $idleB }
            $other = if ($idx -eq 0) { $idleB } else { $idleA }
            P select-window -t "${SESS}:$idx" | Out-Null
            # Poll rather than sample once: a single early read would call a
            # frame that is still crossing the socket a dropped one.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ok = $false
            while ($sw.ElapsedMilliseconds -lt 6000) {
                Start-Sleep -Milliseconds 150
                $screen = (& $conread $c2.ClientPid 2>&1 | Out-String)
                if (($screen -match $want) -and -not ($screen -match $other)) { $ok = $true; break }
            }
            if ($ok) {
                if ($sw.ElapsedMilliseconds -gt $slowest) { $slowest = $sw.ElapsedMilliseconds }
            } else {
                $missed++
                Write-Info ("switch $i to :$idx never reached the client (server says active window is $((P display-message -p -t $SESS '#{window_index}').Trim()))")
            }
        }
        if ($missed -eq 0) {
            Write-Pass ("all $Switches switches between two idle windows reached the client's screen, slowest in $slowest ms")
        } else {
            Write-Fail ("$missed of $Switches switches never reached the client's screen. A window switch sets only meta_dirty, so it is carried by the bottom of loop push and by nothing else: check that push and the NC fast path in server/mod.rs, which must refuse NC while meta_dirty is set (#658)")
        }
    }
    Stop-Client $c2
    & $Binary -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
}

# ── teardown ─────────────────────────────────────────────────────────────────
& $Binary -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force $work -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow
exit $script:TestsFailed
