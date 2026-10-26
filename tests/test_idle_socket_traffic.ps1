# An idle attached client must not talk to its server in a loop.
#
# WHY THIS TEST EXISTS
# --------------------
# The event driven input path replaced several poll intervals with wakes. One of
# those wakes fired on every line the client read off its socket, including the
# server's "NC" reply, which means "nothing has changed". That is self
# sustaining: the NC wakes the client's input wait, the loop goes round and sends
# another dump-state, the server answers NC, and that NC wakes the loop again. A
# request/reply spin at TCP round-trip rate between two processes that both have
# nothing to do, costing up to 92% of a core across the pair.
#
# It shipped. Three separate CPU sampling runs failed to catch it, because this
# machine runs other work and the innocent build sampled as high as 13% of a
# core while the broken one sometimes sampled at 1%. The bug is bistable: it only
# latches when the client's refresh gate lets a request through immediately after
# an NC, so a handful of clean samples proves nothing.
#
# Counting events instead of sampling CPU makes it deterministic and immune to
# whatever else the machine is doing. Measured over a 10s idle window with a
# silent pane, client socket reads per second:
#
#   before the wake was added       0.1 to 192
#   with the wake firing on NC      3332 to 8660
#   with the NC gate               0.1 to 189
#
# The two populations are separated by more than an order of magnitude, so the
# threshold below is nowhere near either one.
#
# WHAT "IDLE" MEANS HERE
# ----------------------
# The pane runs tests/echo_load_child.cs with no filler output, so the pane
# produces nothing, and nothing is typed. Every line crossing the socket in the
# measurement window is therefore the client and server talking among
# themselves.
#
# IDLE IS SILENT, NOT CHEAP: THE SECOND CEILING
# ---------------------------------------------
# The 600/sec ceiling above catches the wake spin and nothing smaller, and the
# "0.1 to 192" spread quoted for the healthy build is the tell: 192 lines/sec is
# not a refresh cadence, it is the SAME request/reply loop latching through a
# different door. An idle client has no refresh cadence at all. It sends
# dump-state when it has a reason to (a key went out, the terminal resized, the
# server told it to) and otherwise waits, because the server pushes a frame
# whenever pane state changes.
#
# The door was `force_dump`, the client's "send one dump-state now" flag. It was
# cleared at the BOTTOM of the client loop, and every early `continue` in that
# loop -- no frame this iteration, a frame identical to the last one, a frame
# that failed to parse -- skips the bottom. So one latched flag re-sent
# dump-state on every iteration, for ever, and the server answered "NC" in two
# bytes, which is why nothing looked like traffic and why three CPU sampling
# runs disagreed with each other. Measured on e49fd97 over an 8 s window with a
# settled pwsh prompt and nothing typed: 2402 client socket reads, 2402 of them
# the 3 byte "NC", 187 per second. It also drags the server's process table
# walker in behind it, because every dump-state runs the automatic-rename check:
# 7 CreateToolhelp32Snapshot walks in that same idle window, at 9 to 11 ms each,
# none of which an idle server has any reason to do.
#
# So this suite asserts TWICE on one measurement: the loose ceiling keeps
# catching the wake spin, and `QuietLinesPerSec` asserts what idle actually is.
# With the flag cleared on the request that satisfies it, the same window
# measures 0 to 2 lines in ten seconds. The two populations are 0.2/sec against
# 187/sec, so the 5/sec gate sits two orders of magnitude below the bug and
# still leaves room for a frame the server legitimately pushes while "idle"
# (a status clock tick, an alert flag clearing).
#
# TWO CELLS, BECAUSE THE LATCH IS BISTABLE
# ----------------------------------------
# Cell 1 attaches and types nothing. Whether the latch catches there is a race
# on the first dump-state reply, so the same unfixed build measured 0.1, 6.9 and
# 183 lines/sec across three runs of cell 1. A gate that only fails half the time
# is how this shipped twice already.
#
# Cell 2 arms it on purpose, and needs nothing but one keystroke and a pane that
# does not answer:
#   * the pane is `pwsh -Command "Start-Sleep -Seconds 600"`, which reads its
#     input and writes NOTHING, so the key produces no pane output,
#   * one key goes into the client's console (tests/keylat.cs, `--n 1`), which
#     sets `force_dump`,
#   * the server therefore has nothing new and answers "NC", so the client's
#     loop takes the `!got_frame` continue and never reaches the bottom where
#     the flag was being cleared.
# From there an unfixed client re-sends for ever, with nothing on either side to
# break the cycle. Measured: 148 to 190 lines/sec on the unfixed client in this
# cell, every run, against 0.1 with the flag cleared on the request. Cell 2 is
# asserted on the quiet gate only - the loose ceiling is cell 1's history.
#
# WHAT IS RECORDED
# ----------------
# The whole point of this suite is a cost an idle pair is paying, so the same
# idle window that counts socket lines also samples the server's and the
# client's working set, private bytes, thread count and CPU, the CPU reported as
# a percentage of one core over that window. No extra sleep is added for it: the
# snapshots are taken at the two ends of the window this suite was already
# sitting through, which is the window the assertion is about. Sampling the CPU
# is not the assertion - the header above is the record of why counting events
# is - but a build that keeps the line count down by spinning somewhere else is
# then visible instead of invisible.
#
# The result lands in %USERPROFILE%\.psmux-test-data\metrics\ with the schema 2
# envelope shared by every perf gate (tests\perf_metrics_common.ps1), so the
# build that produced a number is recorded with it and tests\perf_summary.ps1
# can line this suite up against the others. Never inside the repo.

param(
    [string]$Binary = "",
    [int]$Secs = 10,
    # Generous on purpose: a healthy client was measured up to 192 lines/sec and
    # the spin starts at 3332. Anything in between is already a bug worth
    # looking at, and this will not fire on cadence noise.
    [int]$MaxLinesPerSec = 600,
    # The second, tight ceiling. See IDLE IS SILENT, NOT CHEAP above.
    [int]$QuietLinesPerSec = 5
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\perf_metrics_common.ps1"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:Cells = [ordered]@{}
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

if (-not $Binary -and $env:PSMUX_EXE) { $Binary = $env:PSMUX_EXE }
if (-not $Binary) {
    $cmd = Get-Command psmux -EA SilentlyContinue
    if (-not $cmd) { Write-Fail "psmux not found on PATH and no -Binary given"; exit 1 }
    $Binary = $cmd.Source
}
if (-not (Test-Path $Binary)) { Write-Fail "binary not found: $Binary"; exit 1 }
Write-Info "binary under test: $Binary"

foreach ($v in @('PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_SOCKET','PSMUX_PANE_ID','PSMUX_PTY_TRACE','PSMUX_NO_FRAME_WAKE')) {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}

$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "target\release"
New-Item -ItemType Directory -Force -Path $build | Out-Null
$EchoChild = Join-Path $build "echo_load_child.exe"
$KeyLat = Join-Path $build "keylat.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { Write-Fail "csc.exe not found at $csc"; exit 1 }
# keylat is only used to put ONE key into the client's console for cell 2.
foreach ($pair in @(@("echo_load_child", $EchoChild), @("keylat", $KeyLat))) {
    $src = Join-Path $PSScriptRoot "$($pair[0]).cs"
    if ((-not (Test-Path $pair[1])) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $pair[1]).LastWriteTime)) {
        & $csc /nologo /optimize "/out:$($pair[1])" $src | Out-Null
    }
    if (-not (Test-Path $pair[1])) { Write-Fail "could not build $($pair[0]).exe"; exit 1 }
}

$work = Join-Path $env:TEMP "psmux_idle_traffic"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$exeName = [IO.Path]::GetFileName($Binary)
function OwnPids { @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -EA SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $Binary } | Select-Object -ExpandProperty ProcessId) }

# One cell: attach a client with `$PaneCmd` in the pane, optionally put ONE
# keystroke into the client's console, wait for the screen to settle, then count
# the lines the client's socket reader takes off the wire for `$Secs`.
# Returns lines per second, or -1 if the session never came up.
function Measure-IdleLines {
    param([string]$Cell, [string[]]$PaneCmd, [switch]$InjectKey)
    $ns = "idletraf$Cell$PID"
    $tracePrefix = Join-Path $work "trace_${Cell}_$PID"
    Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue
    $before = OwnPids
    # Launch through a .cmd so PSMUX_PTY_TRACE reaches both the client and the
    # server it spawns, and so this shell's own session routing cannot leak in.
    $launcher = Join-Path $work "launch_${Cell}_$PID.cmd"
    $paneQuoted = ($PaneCmd | ForEach-Object { "`"$_`"" }) -join " "
    Set-Content -Path $launcher -Encoding ASCII -Value @(
        "@echo off",
        "set PSMUX_SESSION=",
        "set PSMUX_SESSION_NAME=",
        "set PSMUX_PTY_TRACE=$tracePrefix",
        "`"$Binary`" -L $ns new-session -s idle $paneQuoted"
    )
    $client = Start-Process -FilePath $launcher -PassThru
    $deadline = (Get-Date).AddSeconds(25)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if ((& $Binary -L $ns ls 2>&1 | Out-String) -match 'idle:') { $up = $true; break }
    }
    $lines = -1
    if ($up) {
        Start-Sleep -Seconds 5    # let startup traffic finish before the window opens
        if ($InjectKey) {
            # The client's console is the one the launcher's cmd.exe owns, so the
            # key goes to the psmux client process the launcher started, not to
            # the launcher. Whether the echo ever appears is irrelevant here:
            # sending the key is what arms `force_dump`.
            $target = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($client.Id)" -EA SilentlyContinue |
                Where-Object { $_.Name -eq $exeName } | Select-Object -ExpandProperty ProcessId)
            if ($target.Count -ge 1) {
                & $KeyLat --pid $target[0] --label "arm" --out (Join-Path $work "arm_$PID.txt") `
                    --mode single --n 1 --warmup 0 --gap 0 --timeout 500 --oracle "cell:0,0" --noerase | Out-Null
            } else {
                Write-Info "could not find the client process under the launcher, so no key was injected"
            }
            Start-Sleep -Seconds 3    # let the keystroke's frames finish
        }
        # Record each trace file's size so only the measurement window is counted.
        $sizes0 = @{}
        Get-ChildItem "$tracePrefix.*" -EA SilentlyContinue | ForEach-Object { $sizes0[$_.Name] = $_.Length }
        # The two ends of the SAME window the line count is taken over. The
        # server is found by its <ns>__idle.pid anchor, never by image name: a
        # warm standby shares this binary and this namespace but never the
        # anchor, and this machine routinely runs psmux servers belonging to
        # other sessions.
        $srvPid = Get-PerfServerPid -Ns $ns -Session "idle"
        $roles = [ordered]@{}
        if ($srvPid -gt 0) { $roles["server"] = $srvPid }
        $cliPid = Get-PerfClientPid -Binary $Binary -Ns $ns -ServerPid $srvPid
        if ($cliPid -gt 0) { $roles["client"] = $cliPid }
        $resBefore = if ($roles.Count -gt 0) { Get-PerfResourceSnapshot $roles } else { $null }
        $w = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Seconds $Secs
        $w.Stop()
        $resAfter = if ($resBefore) { Get-PerfResourceSnapshot $roles } else { $null }

        $c = 0
        Get-ChildItem "$tracePrefix.*" -EA SilentlyContinue | ForEach-Object {
            $start = if ($sizes0.ContainsKey($_.Name)) { $sizes0[$_.Name] } else { 0 }
            # Share write access: both psmux processes still hold these files open.
            $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Seek($start, 'Begin') | Out-Null
                $sr = New-Object IO.StreamReader($fs)
                while (-not $sr.EndOfStream) {
                    $ln = $sr.ReadLine()
                    if (-not $ln -or $ln.StartsWith('#')) { continue }
                    # Stage 'c' is "the client's socket reader read a whole line".
                    if (($ln -split ' ')[1] -eq 'c') { $c++ }
                }
            } finally { $fs.Close() }
        }
        $lines = [math]::Round($c / $w.Elapsed.TotalSeconds, 1)
        Write-Info ("{0}: idle window {1:N1}s, {2} client socket reads, {3} per second" -f $Cell, $w.Elapsed.TotalSeconds, $c, $lines)
        if ($resBefore -and $resAfter) {
            $idleCpu = Get-PerfCpuDelta $resBefore $resAfter ([double]$w.Elapsed.TotalMilliseconds) 100.0
            $script:Cells[$Cell] = [ordered]@{
                cell                  = $Cell
                pane_command          = ($PaneCmd -join " ")
                key_injected          = [bool]$InjectKey
                window_ms             = [math]::Round($w.Elapsed.TotalMilliseconds, 0)
                client_socket_reads   = $c
                lines_per_sec         = $lines
                idle_start            = (Get-PerfMemorySummary $resBefore)
                idle_end              = (Get-PerfMemorySummary $resAfter)
                idle_cpu_pct_of_core  = $idleCpu
            }
            Write-Info (Format-PerfResourceLine $resAfter "idle end   ")
            Write-Info ("idle cpu, % of a core : " + (@($idleCpu.Keys | ForEach-Object { "{0} {1:F2}%" -f $_, $idleCpu[$_] }) -join "  "))
        } else {
            # Still record what was measured: a missing process is a reason to
            # have no memory row, not a reason to lose the line count.
            $script:Cells[$Cell] = [ordered]@{
                cell                = $Cell
                pane_command        = ($PaneCmd -join " ")
                key_injected        = [bool]$InjectKey
                window_ms           = [math]::Round($w.Elapsed.TotalMilliseconds, 0)
                client_socket_reads = $c
                lines_per_sec       = $lines
            }
            Write-Info "neither the server nor the client could be identified, so no memory or CPU was sampled"
        }
    } else {
        Write-Fail "$Cell : the attached session never came up, so idle traffic was not measured"
    }

    # Teardown
    & $Binary -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    try { if (-not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue } } catch {}
    foreach ($p in (OwnPids)) { if ($before -notcontains $p) { try { Stop-Process -Id $p -Force -EA SilentlyContinue } catch {} } }
    Remove-Item $launcher -Force -EA SilentlyContinue
    Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue
    Remove-Item (Join-Path $work "arm_$PID.txt") -Force -EA SilentlyContinue
    return $lines
}

function Assert-Cell {
    param([string]$Cell, [double]$Lines, [switch]$QuietOnly)
    if ($Lines -lt 0) { return }
    if (-not $QuietOnly) {
        if ($Lines -lt $MaxLinesPerSec) {
            Write-Pass ("{0}: an idle attached client reads {1} socket lines/sec, under the {2}/sec ceiling" -f $Cell, $Lines, $MaxLinesPerSec)
        } else {
            Write-Fail ("{0}: an idle attached client reads {1} socket lines/sec, over the {2}/sec ceiling - the client and server are in a request/reply loop with nothing to say; check what wakes the client's input wait" -f $Cell, $Lines, $MaxLinesPerSec)
        }
    }
    # The same measurement, against what idle actually is. See IDLE IS SILENT,
    # NOT CHEAP in the header.
    if ($Lines -lt $QuietLinesPerSec) {
        Write-Pass ("{0}: an idle attached client reads {1} socket lines/sec, under the {2}/sec quiet gate" -f $Cell, $Lines, $QuietLinesPerSec)
    } else {
        Write-Fail ("{0}: an idle attached client reads {1} socket lines/sec, over the {2}/sec quiet gate - an idle client should send nothing and read nothing: the server pushes frames, so a steady stream of 3 byte NC replies means a dump-state request is being re-sent with no reason to (check every early 'continue' in the client loop against what force_dump means)" -f $Cell, $Lines, $QuietLinesPerSec)
    }
}

Write-Host "--- cell 1: silent pane, nothing typed ---" -ForegroundColor DarkCyan
$lines = Measure-IdleLines -Cell "silent" -PaneCmd @($EchoChild)
Assert-Cell -Cell "silent pane" -Lines $lines

Write-Host "--- cell 2: one keystroke into a pane that answers nothing ---" -ForegroundColor DarkCyan
$lines2 = Measure-IdleLines -Cell "armed" -PaneCmd @("pwsh","-NoLogo","-NoProfile","-Command","Start-Sleep -Seconds 600") -InjectKey
Assert-Cell -Cell "after one keystroke" -Lines $lines2 -QuietOnly

# Outside the repo, with the envelope every other perf gate carries.
$jsonPath = Write-PerfMetrics -Suite "test_idle_socket_traffic" -Binary $Binary -FileStem "idle-socket-traffic" -Data ([ordered]@{
    idle_window_seconds   = $Secs
    max_lines_per_sec     = $MaxLinesPerSec
    quiet_lines_per_sec   = $QuietLinesPerSec
    cells                 = $script:Cells
    lines_per_sec_stats   = (Get-PerfStats (@($script:Cells.Keys | ForEach-Object { $script:Cells[$_].lines_per_sec })) 1)
    failed                = $script:TestsFailed
})
if ($jsonPath) { Write-Info "samples: $jsonPath" }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
