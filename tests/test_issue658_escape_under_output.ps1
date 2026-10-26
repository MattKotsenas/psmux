# Issue #658 part 3: a bare Escape must not be held hostage by a busy pane.
#
# THE MECHANISM
# -------------
# The client waits on console input and a pushed frame together
# (`InputSource::read_timeout`, src/ssh_input.rs). A lone Escape is not handed
# on at once: it is held for ESC_COALESCE_MS so an ESC followed by a CR still
# reaches the pane as one Alt+Enter (#611). The only thing that releases it when
# no second key arrives is the `esc.expire()` at the foot of that loop.
#
# The frame arm left the loop through an early `return`, jumping straight over
# that expire. So while frames kept arriving, which is exactly what a busy pane
# produces, nothing in the loop could reach the held Escape's deadline.
#
# WHAT WAS MEASURED ON THE UNMODIFIED BINARY
# ------------------------------------------
# The swallow did NOT reproduce at any frame rate this machine could drive. A
# real VK_ESCAPE record injected into an attached client's console input buffer
# while a sibling pane produced output, with the target pane running a key
# logger that writes every char code it reads to a file:
#
#   idle sibling pane          6 of 6 delivered, 138 to 160 ms
#   sibling ticking at 20 ms   5 of 5 delivered, 130 to 161 ms
#   sibling flooding flat out  6 of 6 delivered, 130 to 161 ms
#   five flooding panes, 200x50 console
#                              6 of 6 delivered, 138 to 153 ms
#
# The frame wake consumes one auto-reset event per wait, so for the Escape to
# be held for ever the frames would have to arrive faster than the client can go
# round its loop, indefinitely. It never did here. The hole in the code is real
# and is fixed - the arm now expires the Escape before it returns, pinned with
# no console at all by tests-rs/test_issue658_frame_wake_escape.rs - and this
# script is the end to end guard on the delivery itself: an Escape typed into a
# client whose panes are flooding must still land in the active pane, promptly.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue658_escape_under_output.ps1

param(
    [string]$Binary = "",
    [int]$Runs = 6,
    # Generous against the 138 to 161 ms measured above, which is dominated by
    # this script's own 50 ms sampling and the logger's file append, not by
    # psmux. Anything near a second means the key was held.
    [int]$MaxDeliveryMs = 1500,
    [int]$Floods = 3
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function Write-Test($m) { Write-Host "`n[$m]" -ForegroundColor Cyan }

if (-not $Binary) { $Binary = $env:PSMUX_TEST_EXE }
if (-not $Binary) { $Binary = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $Binary) { $Binary = (Get-Command psmux -EA SilentlyContinue).Source }
if (-not $Binary -or -not (Test-Path $Binary)) { Write-Host "psmux not found"; exit 1 }
Write-Info "binary under test: $Binary"

foreach ($v in @('PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE','PSMUX_PANE_ID','TMUX','TMUX_PANE','PSMUX','PSMUX_PTY_TRACE','PSMUX_NO_FRAME_WAKE')) {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}

$NS = "e658_$PID"
$SESS = "e658"
$work = Join-Path $env:TEMP "psmux_e658_$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$exeName = [IO.Path]::GetFileName($Binary)
function P { & $Binary -L $NS @args 2>&1 | Out-String }

# ── the injector ─────────────────────────────────────────────────────────────
# send-keys would prove nothing here: it goes straight to the server and never
# touches the client's input path, which is where the Escape was being held. The
# key has to arrive as a real KEY_EVENT record in the client's own console input
# buffer.
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
$injector = Join-Path $work "injector.exe"
if (Test-Path $csc) {
    & $csc /nologo /platform:x64 "/out:$injector" (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $injector)) {
    Write-Skip "injector.exe could not be built, so no real Escape record could be delivered"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed:  0"
    Write-Host "  Failed:  0"
    Write-Host "  Skipped: 1"
    exit 0
}

# ── the panes ────────────────────────────────────────────────────────────────
# Pane 0 reads keys and writes what it read to a file, and produces NOTHING
# itself: the target of the Escape must not be the source of the frames, or the
# test would be measuring its own stimulus.
$keylog = Join-Path $work "keylog.txt"
$logger = Join-Path $work "esclogger.ps1"
@'
param($log)
Set-Content -Path $log -Value "START" -Encoding ascii
while ($true) {
    try { $k = [Console]::ReadKey($true) } catch { Start-Sleep -Milliseconds 20; continue }
    Add-Content -Path $log -Value ("char=0x{0:X2} key={1}" -f [int]$k.KeyChar, $k.Key) -Encoding ascii
}
'@ | Set-Content -Path $logger -Encoding ASCII

# The frame source: rewrites its own first row as fast as it can, so the client's
# frame wake fires continuously. Written with [Console]::Out.Write because
# NO_COLOR, which some shells export, strips escapes out of Write-Host.
$flood = Join-Path $work "escflood.ps1"
@'
$e = [char]27
$i = 0
while ($true) { $i++; [Console]::Out.Write("$e[H$e[2KF$i") }
'@ | Set-Content -Path $flood -Encoding ASCII

# Retried: a server that is still coming up answers "no server running", and a
# single attempt turns that into a failure about the wrong thing.
$up = $false
for ($attempt = 0; $attempt -lt 3 -and -not $up; $attempt++) {
    P new-session -d -s $SESS -x 160 -y 40 pwsh -NoLogo -NoProfile -File $logger $keylog | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        & $Binary -L $NS has-session -t $SESS 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $up = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $up) { Start-Sleep -Milliseconds 800 }
}
for ($f = 0; $f -lt $Floods; $f++) {
    P split-window -t "${SESS}:0" pwsh -NoLogo -NoProfile -File $flood | Out-Null
    Start-Sleep -Milliseconds 700
}
P select-pane -t "${SESS}:0.0" | Out-Null
Start-Sleep -Milliseconds 800
$panes = (P list-panes -t "${SESS}:0" -F "#{pane_index}:#{pane_active}").Trim() -replace "\r?\n", " "
Write-Info "panes (index:active): $panes"

# ── the client ───────────────────────────────────────────────────────────────
$launch = Join-Path $work "attach.cmd"
Set-Content -Path $launch -Encoding ASCII -Value @(
    "@echo off",
    "set PSMUX_SESSION=",
    "set PSMUX_SESSION_NAME=",
    "set PSMUX_PANE=",
    "set TMUX=",
    "set TMUX_PANE=",
    "set NO_COLOR=",
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

Write-Test "a bare Escape reaches the active pane while $Floods sibling panes flood"

if ($clientPid -eq 0) {
    Write-Fail "the attached client never came up, so no Escape was delivered"
} else {
    Write-Info "client pid $clientPid"
    Start-Sleep -Seconds 4
    $lost = 0
    $slowest = 0
    $lats = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $before = @(Select-String -Path $keylog -Pattern 'char=0x1B' -EA SilentlyContinue).Count
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $injector $clientPid "{ESC}" | Out-Null
        $ms = -1
        while ($sw.ElapsedMilliseconds -lt 8000) {
            Start-Sleep -Milliseconds 50
            $after = @(Select-String -Path $keylog -Pattern 'char=0x1B' -EA SilentlyContinue).Count
            if ($after -gt $before) { $ms = $sw.ElapsedMilliseconds; break }
        }
        if ($ms -lt 0) {
            $lost++
        } else {
            $lats += $ms
            if ($ms -gt $slowest) { $slowest = $ms }
        }
    }
    Write-Info ("deliveries: $($lats.Count) of $Runs, latencies " + ($lats -join ', ') + " ms")
    if ($lost -gt 0) {
        Write-Fail ("$lost of $Runs Escapes never reached the pane. A lone Escape is held for its coalescing window and only `esc.expire()` releases it; the frame arm of InputSource::read_timeout returns early, so it must run that expire before it does (#658)")
    } elseif ($slowest -gt $MaxDeliveryMs) {
        Write-Fail ("every Escape arrived but the slowest took $slowest ms, over the ${MaxDeliveryMs} ms ceiling - a held Escape is being carried past its deadline by arriving frames (#658)")
    } else {
        Write-Pass ("all $Runs Escapes reached the active pane while $Floods panes flooded, slowest in $slowest ms")
    }
}

# ── teardown: only PIDs this suite created, never by image name ──────────────
if ($clientPid -gt 0) { try { Stop-Process -Id $clientPid -Force -EA SilentlyContinue } catch {} }
& $Binary -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 1000
try { if (-not $launcher.HasExited) { Stop-Process -Id $launcher.Id -Force -EA SilentlyContinue } } catch {}
Remove-Item -Recurse -Force $work -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow
exit $script:TestsFailed
