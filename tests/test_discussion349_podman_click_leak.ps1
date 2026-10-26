# Discussion #349 (follow-up, comment 17754744): pane_wants_click must not
# forward SGR click reports into an interactive podman container that has not
# enabled mouse input, even after command output fills the screen.
#
# This replays the reporter's EXACT scenario: real visible psmux window, real
# podman alpine container, real screen fill, and REAL mouse CLICKS injected
# into the psmux client console via WriteConsoleInput.
#
# Requires: podman with a started machine. Skips gracefully if unavailable.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_disc349_click"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Cyan }

# Leak signature: SGR click triplets echoed as text (e.g. "0;37;26M", "0;48;26m")
$LeakPattern = '\d+;\d+;\d+[Mm]'

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

$INJ = "$env:TEMP\psmux_mouse_move_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$INJ (Join-Path $PSScriptRoot "mouse_move_injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $INJ)) { Write-Fail "mouse_move_injector.exe failed to compile"; exit 1 }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Discussion #349 follow-up: podman container mouse-CLICK leak ===" -ForegroundColor Cyan
Cleanup

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$ok = $false
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path "$psmuxDir\$SESSION.port") { $ok = $true; break } }
if (-not $ok) { Write-Fail "session did not start"; exit 1 }
Start-Sleep -Seconds 4

Write-Host "`n[Test 1] podman run -it alpine sh inside the pane" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "podman run -it --rm alpine sh" Enter
$prompted = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
    if ($cap -match '/ #') { $prompted = $true; break }
}
if ($prompted) { Write-Pass "container shell prompt visible" } else { Write-Fail "container shell prompt never appeared"; Cleanup; exit 1 }

$cmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
Write-Info "pane_current_command = '$cmd'"

Write-Host "`n[Test 2] baseline click on fresh container screen leaks nothing" -ForegroundColor Yellow
& $INJ $proc.Id click 30 10
Start-Sleep -Seconds 2
$cap1 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap1 -notmatch $LeakPattern) { Write-Pass "no SGR click leak on fresh screen" }
else { Write-Fail "SGR click leak on fresh screen: $($cap1 -split "`n" | Where-Object { $_ -match $LeakPattern } | Select-Object -First 2)" }

Write-Host "`n[Test 3] THE REPORTED BUG: click after ls fills the screen" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "ls -la /usr/bin | head -60" Enter
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $SESSION "ls -la /etc" Enter
Start-Sleep -Seconds 3

& $INJ $proc.Id click 20 12
Start-Sleep -Milliseconds 800
& $INJ $proc.Id click 25 14
Start-Sleep -Seconds 2
$cap2 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap2 -notmatch $LeakPattern) {
    Write-Pass "no SGR click leak on a filled container screen (discussion #349 clicks fixed)"
} else {
    $sample = ($cap2 -split "`n" | Where-Object { $_ -match $LeakPattern } | Select-Object -First 2) -join ' / '
    Write-Fail "SGR click leaked into container tty (discussion #349 click regression): $sample"
}

Write-Host "`n[Test 4] container still healthy after clicks" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "echo DISC349_CLICK_ALIVE" Enter
Start-Sleep -Seconds 2
$cap3 = (& $PSMUX capture-pane -t $SESSION -p 2>&1) | Out-String
if ($cap3 -match 'DISC349_CLICK_ALIVE') { Write-Pass "container shell still executes commands" }
else { Write-Fail "container shell unresponsive after clicks" }

& $PSMUX send-keys -t $SESSION "exit" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)  Skipped: $($script:TestsSkipped)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
