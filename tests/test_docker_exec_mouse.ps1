# Docker env: mouse behaviour of a NON-SSH interactive attach inside the
# container (docker exec + container-side ConPTY harness, conhost build
# 20348 = ConPTY WITHOUT mouse support - the exact #457 environment, but on
# the LOCAL client path instead of the SSH path).
#
# What this proves:
#   GATE  - with `mouse on`, attaching on a real 20348 ConPTY must NOT emit
#           mouse-enable sequences (ESC[?1000h/1002h/1003h/1006h/1015h) into
#           the wire stream. On these builds one click after such an enable
#           crashes conhost 0xc0000409 and kills the session (#457).
#   ABUSE - adversarial SGR mouse reports typed AT the client (click, wheel,
#           motion floods - the #349 hover-leak class) must not kill the
#           client or the session, must not leak "[<0;15;5M"-style garbage
#           into the pane, and must leave keyboard input healthy.
#   FAKE  - with the PSMUX_FAKE_WIN_BUILD seam pretending build 26100, the
#           attach must still survive the same abuse (documents the
#           enabled-path behaviour on this conhost).
#
# Session names <= 9 chars (status bar truncation - see docker gotchas).

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "test_docker_exec_lib.ps1")

$SESSION = "dkrms"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# SGR mouse reports as hex (ESC [ < b ; x ; y M/m)
$CLICK_PRESS   = "1b5b3c303b31353b354d"    # left press  at (15,5)
$CLICK_RELEASE = "1b5b3c303b31353b356d"    # left release at (15,5)
$WHEEL_UP      = "1b5b3c36343b34303b31304d" # wheel up at (40,10)
$MOTION        = "1b5b3c33353b32303b354d"   # motion (btn 35) at (20,5)
$ENABLE_RE     = "\x1b\[\?10(00|02|03|05|06|15)h"
$LEAK_RE       = "<\d+;\d+;\d+[Mm]|\d+;\d+;\d+[Mm]"

Write-Host "`n=== docker-exec mouse suite (non-SSH attach, real build-20348 ConPTY) ===" -ForegroundColor Cyan
Resolve-DockerEnv
Install-AttachHarness
Invoke-CExec "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1

if (-not (New-ContainerSession $SESSION)) {
    Write-Fail "session '$SESSION' never reached a shell prompt inside the container"
    exit 1
}
Invoke-CExec "psmux set-option -g mouse on" | Out-Null
$mouseOpt = (Invoke-CExec "psmux show-options -g -v mouse").Trim()
if ($mouseOpt -match "on") { Write-Pass "mouse option is on ('$mouseOpt')" }
else { Write-Fail "could not enable mouse option, got '$mouseOpt'" }

# --- Test 1: attach renders with mouse on ---
Write-Host "`n[1] attach renders with mouse on" -ForegroundColor Yellow
$h = Start-AttachHarness -Name "ms1" -Command "psmux attach -t $SESSION"
if (Wait-TuiRender $h "\[$SESSION\] 0:") { Write-Pass "TUI rendered" }
else { Write-Fail "TUI never rendered; log: $(Get-HarnessLog $h)" }

# --- Test 2: #457-class gate on the local attach path ---
Write-Host "`n[2] no mouse-enable sequences on a build-20348 ConPTY" -ForegroundColor Yellow
Start-Sleep -Seconds 2
Send-HarnessCtrl $h "CR"     # nudge one more frame through
Start-Sleep -Seconds 2
$stream = Get-HarnessStream $h
if ($stream -notmatch $ENABLE_RE) { Write-Pass "wire stream clean of ESC[?1000h/1002h/1003h/1006h/1015h" }
else { Write-Fail "MOUSE-ENABLE EMITTED on a ConPTY that cannot accept mouse input (#457 class)" }

# --- Test 3: SGR click does not kill the client or the session ---
Write-Host "`n[3] adversarial SGR click survival" -ForegroundColor Yellow
Send-HarnessHex $h ($CLICK_PRESS + $CLICK_RELEASE)
Start-Sleep -Seconds 2
if (Test-HarnessClientAlive $h) { Write-Pass "client alive after SGR click" }
else { Write-Fail "client DIED on SGR click: $(Get-HarnessLog $h)" }
Send-HarnessCtrl $h "TEXT echo ALIVE_AFTER_CLICK"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "ALIVE_AFTER_CLICK") {
    Write-Pass "keyboard input healthy after click"
} else { Write-Fail "keyboard input dead after click" }

# --- Test 4: click bytes must not leak into the pane as garbage text ---
Write-Host "`n[4] no mouse-report garbage leaked into the pane" -ForegroundColor Yellow
Invoke-CExec "psmux send-keys -t $SESSION clear Enter" | Out-Null
Start-Sleep -Seconds 2
Send-HarnessHex $h ($CLICK_PRESS + $CLICK_RELEASE + $CLICK_PRESS + $CLICK_RELEASE)
Start-Sleep -Seconds 2
$cap = Invoke-CExec "psmux capture-pane -t $SESSION -p"
if ($cap -notmatch $LEAK_RE) { Write-Pass "pane free of SGR fragments after clicks" }
else { Write-Fail "SGR mouse bytes leaked into the pane as text: $($cap.Trim())" }

# --- Test 5: wheel scroll works (enters copy-mode scrollback, tmux parity) ---
# PROVEN in this env: one SGR wheel-up puts the attached client into copy
# mode, so typed text is ABSORBED (not dead) until `q` exits. That is the
# correct tmux behaviour and doubles as proof the wheel is actually decoded
# through the container ConPTY input path.
Write-Host "`n[5] SGR wheel flood (x10): scrolls into copy mode, q recovers" -ForegroundColor Yellow
Send-HarnessHex $h ($WHEEL_UP * 10)
Start-Sleep -Seconds 2
if (Test-HarnessClientAlive $h) { Write-Pass "client alive after wheel flood" }
else { Write-Fail "client DIED on wheel flood: $(Get-HarnessLog $h)" }
Send-HarnessCtrl $h "TEXT echo WHEEL_PROBE"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -notmatch "WHEEL_PROBE") {
    Write-Pass "wheel entered copy-mode scrollback (typed probe absorbed - tmux parity)"
} else { Write-Fail "wheel did NOT scroll (probe reached the pane - mouse wheel inert in docker env)" }
Send-HarnessCtrl $h "TYPE q"     # exit copy mode
Start-Sleep -Seconds 1
Send-HarnessHex $h "03"          # Ctrl+C clears any stray prompt input
Start-Sleep -Seconds 1
Send-HarnessCtrl $h "TEXT echo WHEEL_RECOVER"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "WHEEL_RECOVER") {
    Write-Pass "q exited copy mode; input healthy again"
} else { Write-Fail "input did not recover after q" }

# --- Test 6: motion/hover flood (#349 leak class) ---
Write-Host "`n[6] SGR motion flood (x30, hover class)" -ForegroundColor Yellow
Send-HarnessHex $h ($MOTION * 10)
Send-HarnessHex $h ($MOTION * 10)
Send-HarnessHex $h ($MOTION * 10)
Start-Sleep -Seconds 2
if (Test-HarnessClientAlive $h) { Write-Pass "client alive after motion flood" }
else { Write-Fail "client DIED on motion flood: $(Get-HarnessLog $h)" }
$cap = Invoke-CExec "psmux capture-pane -t $SESSION -p"
if ($cap -notmatch $LEAK_RE) { Write-Pass "no motion reports leaked into the pane (#349 parity)" }
else { Write-Fail "motion reports leaked into the pane: $($cap.Trim())" }
Send-HarnessCtrl $h "TEXT echo MOTION_PROBE"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "MOTION_PROBE") {
    Write-Pass "hover motion did not steal input (no spurious copy-mode entry)"
} else { Write-Fail "input absorbed after motion flood (motion wrongly entered a mode)" }

# --- Test 7: rapid click flood; session must survive ---
Write-Host "`n[7] rapid click flood (x20)" -ForegroundColor Yellow
Send-HarnessHex $h (($CLICK_PRESS + $CLICK_RELEASE) * 10)
Send-HarnessHex $h (($CLICK_PRESS + $CLICK_RELEASE) * 10)
Start-Sleep -Seconds 3
if (Test-ContainerSession $SESSION) { Write-Pass "session survived click flood" }
else { Write-Fail "SESSION DIED under click flood" }
if (Test-HarnessClientAlive $h) { Write-Pass "client survived click flood" }
else { Write-Fail "client DIED under click flood: $(Get-HarnessLog $h)" }

# --- Test 8: end-to-end input health after all abuse ---
Write-Host "`n[8] keyboard round-trip after all mouse abuse" -ForegroundColor Yellow
Send-HarnessCtrl $h "TEXT echo MOUSE_OK_457"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "MOUSE_OK_457") {
    Write-Pass "input still healthy end-to-end"
} else { Write-Fail "input dead after mouse abuse" }

# --- Test 9: detach still works ---
Write-Host "`n[9] prefix+d detach after abuse" -ForegroundColor Yellow
Send-HarnessHex $h "0264"
Start-Sleep -Seconds 3
if (-not (Test-HarnessClientAlive $h)) { Write-Pass "clean detach" }
else { Write-Fail "detach broken after mouse abuse"; Stop-AttachHarness $h }
if (Test-ContainerSession $SESSION) { Write-Pass "session intact after detach" }
else { Write-Fail "session gone after detach" }

# --- Test 10: PSMUX_FAKE_WIN_BUILD=26100 (enabled-path seam) ---
Write-Host "`n[10] fake build 26100: attach + click abuse must still survive" -ForegroundColor Yellow
$hf = Start-AttachHarness -Name "ms2" -Command "psmux attach -t $SESSION" -EnvVars @{ PSMUX_FAKE_WIN_BUILD = "26100" }
if (Wait-TuiRender $hf "\[$SESSION\] ") { Write-Pass "fake-build attach rendered" }
else { Write-Fail "fake-build attach never rendered; log: $(Get-HarnessLog $hf)" }
Start-Sleep -Seconds 2
$fstream = Get-HarnessStream $hf
if ($fstream -match $ENABLE_RE) {
    Write-Host "  [INFO] fake-build attach emitted mouse-enable sequences (enabled path active)" -ForegroundColor DarkCyan
} else {
    Write-Host "  [INFO] fake-build attach emitted no mouse-enable sequences (local path uses WinAPI mouse)" -ForegroundColor DarkCyan
}
Send-HarnessHex $hf ($CLICK_PRESS + $CLICK_RELEASE)
Send-HarnessHex $hf ($WHEEL_UP * 5)
Start-Sleep -Seconds 2
if (Test-HarnessClientAlive $hf) { Write-Pass "fake-build client alive after click+wheel" }
else { Write-Fail "fake-build client DIED: $(Get-HarnessLog $hf)" }
Send-HarnessCtrl $hf "TYPE q"    # wheel put us in copy mode; exit it first
Start-Sleep -Seconds 1
Send-HarnessHex $hf "03"
Start-Sleep -Seconds 1
Send-HarnessCtrl $hf "TEXT echo FAKE_BUILD_OK"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "FAKE_BUILD_OK") {
    Write-Pass "fake-build input healthy"
} else { Write-Fail "fake-build input dead" }
Send-HarnessHex $hf "0264"
Start-Sleep -Seconds 2
Stop-AttachHarness $hf

# --- Teardown ---
Invoke-CExec "psmux kill-session -t $SESSION" | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
