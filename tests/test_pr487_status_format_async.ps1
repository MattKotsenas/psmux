# PR #487: status-bar #() must expand ASYNCHRONOUSLY on the server auto-push path
#
# THE BUG
# -------
# src/server/mod.rs has two structurally identical render blocks:
#   ~1997  the DumpState handler (client polls for a frame)  -> HAD the guard
#   ~5553  "Server-push: proactively send frames to attached clients"
#          which fires on every state_dirty tick, i.e. every PTY output burst
#                                                          -> HAD NO GUARD
# Without crate::format::AsyncFormatGuard, #() expansion takes the SYNC branch:
# Command::output() runs inline on the single server event loop, which is the
# same thread that delivers keystrokes to ConPTY. The sync branch writes the TTL
# cache but deliberately does not read it, so every push spawns a fresh process.
#
# TMUX PARITY (local tmux source checkout, format.c format_job_get)
# tmux ALWAYS runs #() via job_run(..., JOB_NOWAIT, ...) and rate limits it to at
# most once per second. It never runs a #() inline on the event loop.
#
# THE MEASUREMENT
# ---------------
# Default status-interval is 15s, so the async TTL is 15s. In a 6 second window
# the correct number of #() spawns is ZERO once the cache is warm, whether the
# pane is idle or flooding output. A synchronous expansion instead spawns once
# per push, so the count tracks pane output rate.
#
#   master (before fix):  idle 0 spawns / busy 32 spawns in 6s
#   correct:              idle 0 spawns / busy 0 spawns in 6s
#
# A REAL ATTACHED CLIENT IS REQUIRED. A raw PERSISTENT socket only receives the
# status-interval tick (~1.7/s) and never exercises the output driven push path,
# so it silently "passes" against the broken build.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "pr487_fmt"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

$countFile = "$env:TEMP\pr487_fmt_count.txt"
$titleFile = "$env:TEMP\pr487_fmt_title.txt"

function Count-Lines($path) {
    if (-not (Test-Path $path)) { return 0 }
    try { return @(Get-Content $path -EA Stop).Count } catch { return -1 }
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Flood the pane with output for $Seconds and report how many times the #()
# command in the status bar actually executed.
function Measure-SpawnsUnderLoad {
    param([string]$Counter, [int]$Seconds = 6)
    Remove-Item $Counter -Force -EA SilentlyContinue
    & $PSMUX send-keys -t $SESSION "1..20000 | ForEach-Object { `"line `$_ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`" }" Enter 2>&1 | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Seconds
    $sw.Stop()
    $n = Count-Lines $Counter
    & $PSMUX send-keys -t $SESSION "C-c" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    return @{ Spawns = $n; Sec = $sw.Elapsed.TotalSeconds }
}

# Time a fixed pane workload end to end (user visible throughput).
function Measure-Workload {
    param([string]$Label, [int]$TimeoutSec = 90)
    $marker = "DONE_" + $Label
    & $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX send-keys -t $SESSION "1..3000 | ForEach-Object { `"row `$_ xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`" }; `"$marker`"" Enter 2>&1 | Out-Null
    $found = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        if ($cap -match [regex]::Escape($marker)) { $found = $true; break }
        Start-Sleep -Milliseconds 150
    }
    $sw.Stop()
    return @{ Found = $found; Sec = $sw.Elapsed.TotalSeconds }
}

Write-Host "`n=== PR #487: async #() on the server auto-push path ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray
Cleanup
Remove-Item $countFile,$titleFile -Force -EA SilentlyContinue

# A REAL attached TUI client. This is what drives the auto-push block.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "attached session did not come up"; exit 1 }
Write-Info "attached client pid $($proc.Id)"

$interval = (& $PSMUX show-options -g -v status-interval -t $SESSION 2>&1 | Out-String).Trim()
Write-Info "status-interval = $interval (async TTL)"

# ---------------------------------------------------------------------------
# TEST 1: status-right #() spawn accounting, idle vs heavy pane output
# ---------------------------------------------------------------------------
Write-Host "`n[Test 1] status-right #() spawn count: idle vs heavy pane output" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status-right "#(cmd /c echo x>>$countFile)" 2>&1 | Out-Null
Start-Sleep -Seconds 3   # let the first expansion warm the TTL cache

Remove-Item $countFile -Force -EA SilentlyContinue
Start-Sleep -Seconds 6
$idle = Count-Lines $countFile
Write-Info "IDLE (no pane output):    $idle spawns in 6.0s"

$busy = Measure-SpawnsUnderLoad -Counter $countFile -Seconds 6
Write-Info ("BUSY (heavy pane output): {0} spawns in {1:N1}s" -f $busy.Spawns, $busy.Sec)

# With a 15s TTL and a warm cache, 6 seconds of ANY activity should produce at
# most one refresh. Allow 2 for scheduling slack. The broken build produced 32.
if ($busy.Spawns -le 2) {
    Write-Pass "#() stayed TTL rate-limited under load ($($busy.Spawns) spawns) - ASYNC, tmux parity"
} else {
    Write-Fail "#() spawned $($busy.Spawns) times in 6s of pane output (idle was $idle) - SYNCHRONOUS on the auto-push path"
}

if ($busy.Spawns -gt ($idle + 2)) {
    Write-Fail "spawn count tracks pane OUTPUT rather than the TTL clock (idle $idle vs busy $($busy.Spawns)) - inline expansion on the push path"
} else {
    Write-Pass "spawn count tracks the TTL clock, not the pane output rate"
}

# ---------------------------------------------------------------------------
# TEST 2: user visible throughput cost of a SLOW status #()
# ---------------------------------------------------------------------------
Write-Host "`n[Test 2] does a slow status #() throttle the pane pipeline?" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status-right "plainstatus" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$ctrl = Measure-Workload -Label "CTRL"
Write-Info ("CONTROL   (no #()):        found={0}  {1:N2}s" -f $ctrl.Found, $ctrl.Sec)

& $PSMUX set-option -t $SESSION -g status-right "#(cmd /c ping -n 2 127.0.0.1 >nul)" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$treat = Measure-Workload -Label "SLOW"
Write-Info ("TREATMENT (slow ~1s #()):  found={0}  {1:N2}s" -f $treat.Found, $treat.Sec)

if (-not $ctrl.Found) {
    Write-Fail "control workload never completed - harness problem"
} elseif (-not $treat.Found) {
    Write-Fail "slow #() workload never completed - server loop fully blocked"
} else {
    $ratio = $treat.Sec / [Math]::Max($ctrl.Sec, 0.01)
    Write-Info ("slowdown factor: {0:N1}x" -f $ratio)
    if ($ratio -lt 3) { Write-Pass ("slow #() cost only {0:N1}x - expansion is ASYNC" -f $ratio) }
    else { Write-Fail ("identical workload {0:N1}x slower ({1:N2}s vs {2:N2}s) - SYNCHRONOUS expansion blocking the loop" -f $ratio, $treat.Sec, $ctrl.Sec) }
}

# ---------------------------------------------------------------------------
# TEST 3: set-titles-string #() was expanded outside the guard on BOTH paths
# ---------------------------------------------------------------------------
Write-Host "`n[Test 3] set-titles-string #() on the render path" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status-right "plainstatus" 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION -g set-titles on 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION -g set-titles-string "#(cmd /c echo t>>$titleFile)" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$title = Measure-SpawnsUnderLoad -Counter $titleFile -Seconds 6
Write-Info ("set-titles-string #() spawns under load: {0} in {1:N1}s" -f $title.Spawns, $title.Sec)
if ($title.Spawns -le 2) { Write-Pass "set-titles-string #() is TTL rate-limited - ASYNC" }
else { Write-Fail "set-titles-string #() spawned $($title.Spawns) times in 6s - SYNCHRONOUS on the render path" }
& $PSMUX set-option -t $SESSION -g set-titles off 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# TEST 4: REGRESSION GUARD for d981d94 - one-shot #() must stay SYNCHRONOUS
# ---------------------------------------------------------------------------
Write-Host "`n[Test 4] one-shot display-message -p '#(cmd)' still returns real output" -ForegroundColor Yellow
$oneshot = (& $PSMUX display-message -t $SESSION -p "#(cmd /c echo ONESHOT_OK)" 2>&1 | Out-String).Trim()
Write-Info "display-message -p output: '$oneshot'"
if ($oneshot -match "ONESHOT_OK") { Write-Pass "one-shot #() still expands synchronously (async mode did not leak)" }
else { Write-Fail "one-shot #() returned '$oneshot' - expected ONESHOT_OK; the async guard leaked out of the render path" }

# ---------------------------------------------------------------------------
# TEST 5: Win32 TUI - the attached session is still healthy and rendering
# ---------------------------------------------------------------------------
Write-Host "`n[Test 5] Win32 TUI still functional with a #() status bar" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status-right "#(cmd /c echo LIVE)" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" } else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$zoom = (& $PSMUX display-message -t $SESSION -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($zoom -eq "1") { Write-Pass "TUI: resize-pane -Z zoomed" } else { Write-Fail "TUI: zoom expected 1, got '$zoom'" }

# The async #() eventually lands and repaints: status-right resolves to LIVE.
$resolved = $false
for ($i = 0; $i -lt 30; $i++) {
    $sr = (& $PSMUX display-message -t $SESSION -p '#{status-right}' 2>&1 | Out-String).Trim()
    if ($sr -match "LIVE") { $resolved = $true; break }
    Start-Sleep -Milliseconds 400
}
if ($resolved) { Write-Pass "async #() result eventually reaches the status bar (not stuck empty)" }
else { Write-Info "status-right format variable did not resolve to LIVE (informational)" }

# ---------------------------------------------------------------------------
& $PSMUX send-keys -t $SESSION "C-c" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $countFile,$titleFile -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
