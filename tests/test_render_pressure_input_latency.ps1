# Render-pressure input-latency regression (PR #487 follow-up, vntrevx report)
#
# BACKGROUND
# ----------
# PR #487 fixed status-bar #() expanding synchronously on the server auto-push
# path. A field report on that PR described a broader worry: a TUI repainting a
# pane at 30fps (NO #() anywhere) producing stutter and delayed-feeling
# keyboard delivery, i.e. high-frequency pane output starving the same event
# loop that delivers input. This test encodes that scenario as a regression
# guard: a synthetic ANSI repaint flood plus input-latency assertions.
#
# Measured on master after #487 (2026-07-27, uncapped per-cell-color flood,
# ~59 distinct frames/sec): server RTT p50 0.1ms, server CPU 3 percent, pane
# echo latency identical to idle. Thresholds below are set far above those
# numbers so the test only fires on a real architectural regression, not on
# machine noise.
#
# WHY A REAL ATTACHED CLIENT
# --------------------------
# The output-driven auto-push block only runs with a frame receiver attached.
# A raw PERSISTENT socket does not exercise it (that false pass is how the
# #487 regression survived). Everything here runs against a real attached TUI.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "renderpressure"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Pct($arr, $p) {
    if ($arr.Count -eq 0) { return -1 }
    $s = [double[]]($arr | Sort-Object)
    return $s[[Math]::Floor(($p/100.0) * ($s.Count - 1))]
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Self-contained: write the 30fps animation script at runtime.
$animPath = Join-Path $env:TEMP "psmux_render_pressure_anim.ps1"
@'
$esc = [char]27
[Console]::Write("$esc[?25l")
$frame = 0
while ($true) {
    $sb = [System.Text.StringBuilder]::new(262144)
    [void]$sb.Append("$esc[H")
    for ($r = 0; $r -lt 35; $r++) {
        for ($col = 0; $col -lt 100; $col++) {
            $c = (($frame + $r * 7 + $col * 3) % 200) + 16
            $ch = [char](33 + (($frame + $col) % 90))
            [void]$sb.Append("$esc[38;5;${c}m$ch")
        }
        [void]$sb.Append("$esc[0m`n")
    }
    [Console]::Write($sb.ToString())
    $frame++
    Start-Sleep -Milliseconds 33
}
'@ | Set-Content -Path $animPath -Encoding UTF8

# End-to-end echo latency into pane B: send-keys "echo MARKER" Enter, poll
# capture-pane until the marker shows. Same machinery in every phase, so the
# idle-vs-load DELTA is the signal (CLI spawn overhead subtracts out).
function Measure-EchoLatency {
    param([string]$PaneTarget, [int]$Samples, [string]$Tag)
    $lat = [System.Collections.ArrayList]::new()
    $timeouts = 0
    for ($i = 0; $i -lt $Samples; $i++) {
        $m = "RP${Tag}${i}X$(Get-Random -Maximum 99999)"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $PSMUX send-keys -t $PaneTarget "echo $m" Enter 2>&1 | Out-Null
        $found = $false
        while ($sw.ElapsedMilliseconds -lt 10000) {
            $cap = & $PSMUX capture-pane -t $PaneTarget -p 2>&1 | Out-String
            if ($cap -match $m) { $found = $true; break }
            Start-Sleep -Milliseconds 10
        }
        $sw.Stop()
        if ($found) { [void]$lat.Add($sw.Elapsed.TotalMilliseconds) } else { $timeouts++ }
        Start-Sleep -Milliseconds 150
    }
    return @{ Lat = $lat; Timeouts = $timeouts }
}

# Server loop RTT over TCP, reconnecting per failure (the server may recycle
# one-shot connections between command batches).
function Measure-Rtt {
    param([int]$Samples)
    $times = [System.Collections.ArrayList]::new()
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = $null; $w = $null; $r = $null; $st = $null
    for ($i = 0; $i -lt $Samples; $i++) {
        try {
            if ($null -eq $tcp -or -not $tcp.Connected) {
                $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                $tcp.NoDelay = $true
                $st = $tcp.GetStream()
                $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
                $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $w.Write("list-sessions`n"); $w.Flush()
            $st.ReadTimeout = 8000
            $null = $r.ReadLine()
            $sw.Stop()
            [void]$times.Add($sw.Elapsed.TotalMilliseconds)
        } catch { try { $tcp.Close() } catch {}; $tcp = $null }
        Start-Sleep -Milliseconds 30
    }
    try { $tcp.Close() } catch {}
    return $times
}

Write-Host "`n=== render-pressure input-latency regression ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray
Cleanup

# Real attached client + two panes: A = animation, B = shell we type into.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "attached session did not come up"; exit 1 }
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3
$panes = @(& $PSMUX list-panes -t $SESSION -F '#{pane_id}' 2>&1)
$paneA = $panes[0].ToString().Trim()
$paneB = $panes[-1].ToString().Trim()
Write-Info "panes A=$paneA (animation) B=$paneB (shell), client pid $($proc.Id)"

# ---------------------------------------------------------------------------
# Phase 1: idle baseline
# ---------------------------------------------------------------------------
Write-Host "`n[Phase 1] idle baseline" -ForegroundColor Yellow
$idle = Measure-EchoLatency -PaneTarget $paneB -Samples 8 -Tag "I"
$idleP50 = Pct $idle.Lat 50
Write-Info ("idle echo latency: p50={0:N1}ms p90={1:N1}ms timeouts={2}" -f $idleP50, (Pct $idle.Lat 90), $idle.Timeouts)
if ($idle.Timeouts -eq 0 -and $idleP50 -gt 0) { Write-Pass "idle baseline established" }
else { Write-Fail "idle baseline unusable (timeouts=$($idle.Timeouts))"; Cleanup; exit 1 }

# ---------------------------------------------------------------------------
# Phase 2: 30fps heavy repaint in pane A
# ---------------------------------------------------------------------------
Write-Host "`n[Phase 2] 30fps per-cell-color repaint in pane A" -ForegroundColor Yellow
& $PSMUX send-keys -t $paneA "pwsh -NoProfile -ExecutionPolicy Bypass -File '$animPath'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5

# Sanity gate: the animation must actually be advancing, otherwise the rest
# of the test is measuring an idle pane and passing means nothing.
$c1 = & $PSMUX capture-pane -t $paneA -p 2>&1 | Out-String
Start-Sleep -Milliseconds 400
$c2 = & $PSMUX capture-pane -t $paneA -p 2>&1 | Out-String
if (($c1 -ne $c2) -and ($c1.Trim().Length -gt 300)) { Write-Pass "animation flood is live and advancing" }
else { Write-Fail "animation did not start - load phase is not real, aborting"; Cleanup; try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}; exit 1 }

$load = Measure-EchoLatency -PaneTarget $paneB -Samples 8 -Tag "L"
$loadP50 = Pct $load.Lat 50
$loadP90 = Pct $load.Lat 90
Write-Info ("load echo latency: p50={0:N1}ms p90={1:N1}ms timeouts={2}" -f $loadP50, $loadP90, $load.Timeouts)

$rtt = Measure-Rtt -Samples 40
$rttP50 = Pct $rtt 50
$rttP90 = Pct $rtt 90
Write-Info ("server RTT under load: p50={0:N1}ms p90={1:N1}ms max={2:N1}ms (n={3})" -f $rttP50, $rttP90, (Pct $rtt 100), $rtt.Count)

# ---------------------------------------------------------------------------
# Assertions. Post-#487 reference numbers: RTT p50 0.1ms, echo delta ~0.
# Thresholds are deliberately generous (10-25x reference) so only a real
# regression trips them.
# ---------------------------------------------------------------------------
Write-Host "`n[Assertions]" -ForegroundColor Yellow
if ($load.Timeouts -gt 0) {
    Write-Fail "echo marker TIMED OUT $($load.Timeouts) time(s) under repaint load - pane pipeline starved"
} else {
    Write-Pass "no echo timeouts under repaint load"
}

if ($rtt.Count -ge 10 -and $rttP90 -lt 50) {
    Write-Pass ("server loop responsive under repaint load (RTT p90 {0:N1}ms < 50ms)" -f $rttP90)
} else {
    Write-Fail ("server loop degraded under repaint load (RTT p90 {0:N1}ms, n={1})" -f $rttP90, $rtt.Count)
}

$ratio = if ($idleP50 -gt 0) { $loadP50 / $idleP50 } else { 999 }
Write-Info ("echo latency ratio load/idle: {0:N2}x" -f $ratio)
if ($ratio -lt 5 -and $loadP50 -lt 1000) {
    Write-Pass ("input echo latency stable under repaint load ({0:N2}x idle)" -f $ratio)
} else {
    Write-Fail ("input echo latency degraded: {0:N1}ms vs idle {1:N1}ms ({2:N1}x) - render pressure is starving input delivery" -f $loadP50, $idleP50, $ratio)
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
& $PSMUX send-keys -t $paneA "C-c" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $animPath -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
