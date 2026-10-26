# Discussion #349: mouse motion escape sequences ("35;128;51M...") leak into an
# interactive podman container terminal after command output fills the screen.
#
# CONTRACT: bare motion (SGR 35) is gated on pane_wants_hover() (explicit
#   DECSET 1002/1003) in the live server mouse path.
#   The byte-level gate contract is pinned by
#   tests-rs/test_discussion349_podman_motion_leak.rs.
#
# This layer replays the reporter's EXACT scenario with a real visible psmux
# window, a real podman alpine container, real screen fill, and REAL mouse
# MOVE events injected into the psmux client console via WriteConsoleInput.
#
# Requires: podman with a started machine. Skips gracefully if unavailable.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_discussion349_podman_motion_leak.ps1

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_disc349"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Cyan }

# The leak signature: SGR mouse triplets echoed as text ("35;104;37M" etc.)
$LeakPattern = '\d+;\d+;\d+[Mm]'

# ── Podman availability ──────────────────────────────────────────────────────
if (Test-Path 'C:\Program Files\RedHat\Podman') { $env:Path += ';C:\Program Files\RedHat\Podman' }
$podman = Get-Command podman -EA SilentlyContinue
$podmanReady = $false
if ($podman) {
    & podman info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & podman image exists alpine 2>$null
        if ($LASTEXITCODE -ne 0) { & podman pull alpine 2>&1 | Out-Null }
        & podman image exists alpine 2>$null
        if ($LASTEXITCODE -eq 0) { $podmanReady = $true }
    }
}
if (-not $podmanReady) {
    Write-Skip "podman not available or machine not started; cannot run the container repro"
    exit 0
}

# ── Compile the mouse MOVE injector ──────────────────────────────────────────
$INJ = "$env:TEMP\psmux_mouse_move_injector.exe"
if (-not (Test-Path $INJ)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$INJ (Join-Path $PSScriptRoot "mouse_move_injector.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $INJ)) { Write-Fail "mouse_move_injector.exe failed to compile"; exit 1 }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Discussion #349: podman container mouse-motion leak ===" -ForegroundColor Cyan
Cleanup

# ── Setup: VISIBLE psmux window (pwsh default shell, mouse default = on) ─────
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$ok = $false
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path "$psmuxDir\$SESSION.port") { $ok = $true; break } }
if (-not $ok) { Write-Fail "session did not start"; exit 1 }
Start-Sleep -Seconds 4

# ── [Test 1] Interactive podman container starts in the pane ─────────────────
Write-Host "`n[Test 1] podman run -it alpine sh inside the pane" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "podman run -it --rm alpine sh" Enter
$prompted = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
    if ($cap -match '/ #') { $prompted = $true; break }
}
if ($prompted) { Write-Pass "container shell prompt visible" }
else { Write-Fail "container shell prompt never appeared"; Cleanup; exit 1 }

$cmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
Write-Info "pane_current_command = '$cmd'"
if ($cmd -match "podman") { Write-Pass "foreground is podman (the exact non-shell foreground the bug needs)" }
else { Write-Fail "expected podman foreground, got '$cmd'" }

# ── [Test 2] Baseline: mouse motion on a FRESH screen leaks nothing ──────────
Write-Host "`n[Test 2] baseline motion on fresh container screen" -ForegroundColor Yellow
& $INJ $proc.Id move 30 10 5 3 1 15
Start-Sleep -Seconds 2
$cap1 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap1 -notmatch $LeakPattern) { Write-Pass "no SGR leak on fresh screen" }
else { Write-Fail "SGR leak on fresh screen: $($cap1 -split "`n" | Where-Object { $_ -match $LeakPattern } | Select-Object -First 2)" }

# ── [Test 3] THE REPORTED BUG: fill the screen with ls, then move the mouse ──
Write-Host "`n[Test 3] motion after ls fills the screen (the reported leak)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "ls -la /usr/bin | head -60" Enter
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $SESSION "ls -la /etc" Enter
Start-Sleep -Seconds 3

& $INJ $proc.Id move 40 10 5 3 1 15
Start-Sleep -Seconds 2
$cap2 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap2 -notmatch $LeakPattern) {
    Write-Pass "no SGR motion leak on a filled container screen (discussion #349 fixed)"
} else {
    $sample = ($cap2 -split "`n" | Where-Object { $_ -match $LeakPattern } | Select-Object -First 2) -join ' / '
    Write-Fail "SGR motion leaked into container tty (discussion #349 regression): $sample"
}

# ── [Test 4] Container is still healthy and interactive after the motion ─────
Write-Host "`n[Test 4] container session healthy after motion storm" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "echo DISC349_ALIVE" Enter
Start-Sleep -Seconds 2
$cap3 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap3 -match 'DISC349_ALIVE') { Write-Pass "container shell still executes commands" }
else { Write-Fail "container shell unresponsive after motion" }

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "session alive" } else { Write-Fail "session died" }

# ── [Test 5] Win32 TUI sanity: session still drives via CLI ──────────────────
Write-Host "`n[Test 5] TUI window still functional (CLI-driven)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "exit" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
$wins = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
if ($wins -match '^\d+$') { Write-Pass "display-message responds (windows=$wins)" }
else { Write-Fail "display-message failed: '$wins'" }

# ── Teardown ─────────────────────────────────────────────────────────────────
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)  Skipped: $($script:TestsSkipped)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
