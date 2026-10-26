# Docker environment: issue #457 mouse-enable gate on a REAL pre-22523 ConPTY.
#
# The psmux-dev container is windowsservercore-ltsc2022 = Windows build 20348,
# a ConPTY that CANNOT accept mouse input. Issue #457: psmux used to
# force-enable mouse reporting over SSH anyway (raw 32-byte WriteFile); the
# first click then crashed conhost (0xc0000409) and killed the session. The
# fix gates send_mouse_enable() on build >= 22523.
#
# Unlike tests/test_issue457_ssh_mouse_gate.ps1 (which FAKES the build via
# PSMUX_FAKE_WIN_BUILD on the dev host), this test proves the gate on a REAL
# 20348 kernel through a REAL SSH attach:
#   1. ssh_input.log inside the container reports build 20348 and SUPPRESSED
#   2. the raw VT stream reaching the host terminal contains NO mouse-enable
#      sequences (ESC[?1000h / 1002h / 1003h / 1006h) - ground truth
#   3. adversarial SGR click/scroll reports sent into the attach do NOT crash
#      the session (the original bug killed it with one click)
#   4. the pane still accepts keystrokes afterwards

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\test_docker_ssh_lib.ps1"

$SESSION = "dkr457"   # short: default status-left truncates ~9 chars, name must fit for stream match
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

Write-Host "`n=== Docker/SSH issue #457 mouse gate (real build 20348) ===" -ForegroundColor Cyan
$ip = Get-ContainerIP
Write-Host "  container IP: $ip"

# clean slate; session with mouse ON (worst case for the gate)
Invoke-CSsh $ip "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1
Invoke-CSsh $ip "Remove-Item `"`$env:USERPROFILE\.psmux\ssh_input.log`" -Force -EA SilentlyContinue" | Out-Null
New-ContainerSession $ip $SESSION
Invoke-CSsh $ip "psmux set-option -g mouse on" | Out-Null
Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -ne 0) { Write-Fail "setup: session not created"; exit 1 }

# remote wrapper enabling the SSH-input debug log before attaching
$attachScript = @"
`$env:PSMUX_SSH_DEBUG = '1'
`$env:PSMUX_MOUSE_DEBUG = '1'
psmux attach -t $SESSION
"@
$local = Join-Path $env:TEMP "psmux_docker_attach457.ps1"
Set-Content -Path $local -Value $attachScript -Encoding UTF8
Invoke-CSsh $ip "New-Item -ItemType Directory -Force C:\psmux_test | Out-Null" | Out-Null
if (-not (Copy-ToContainer $ip $local "C:/psmux_test/attach457.ps1")) { Write-Fail "scp failed"; exit 1 }

# --- attach interactively over SSH ---
Write-Host "`n[Test 1] Attach over SSH with mouse on" -ForegroundColor Yellow
$sess = Start-InteractiveSsh $ip "pwsh -NoProfile -File C:\psmux_test\attach457.ps1"
if (Wait-TuiRender $sess "$SESSION" 35) { Write-Pass "TUI attached and rendered over SSH" }
else { Write-Fail "attach never rendered"; Stop-InteractiveSsh $sess; exit 1 }
Start-Sleep -Seconds 3   # let the SSH-input module finish init + any mouse-enable attempt

# --- Test 2: ssh_input.log proves the gate on the REAL build ---
Write-Host "`n[Test 2] ssh_input.log gate evidence" -ForegroundColor Yellow
$log = Invoke-CSsh $ip "Get-Content `"`$env:USERPROFILE\.psmux\ssh_input.log`" -Raw -EA SilentlyContinue"
if ($log -match "Windows build 20348") { Write-Pass "log reports REAL build 20348" }
else { Write-Fail "log missing build 20348 line. log: $log" }

if ($log -match "SUPPRESSED") { Write-Pass "send_mouse_enable SUPPRESSED on real 20348" }
else { Write-Fail "BUG #457 CLASS: no SUPPRESSED line on build 20348" }

if ($log -notmatch "writing mouse-enable VT sequences" -and $log -notmatch "WriteFile ok=1 written=32") {
    Write-Pass "zero mouse-enable writes attempted"
} else { Write-Fail "BUG #457 STILL PRESENT: mouse-enable written on 20348" }

# --- Test 3: ground truth - no mouse-enable escapes in the SSH stream ---
Write-Host "`n[Test 3] Raw VT stream has no mouse-enable sequences" -ForegroundColor Yellow
$stream = Get-StreamText $sess
$esc = [char]27
$badSeqs = @("$esc[?1000h", "$esc[?1002h", "$esc[?1003h", "$esc[?1006h")
$found = @($badSeqs | Where-Object { $stream.Contains($_) })
if ($found.Count -eq 0) { Write-Pass "no ESC[?1000h/1002h/1003h/1006h in stream ($($stream.Length) bytes checked)" }
else { Write-Fail "mouse-enable escaped to the terminal: $($found -join ', ')" }

# --- Test 4: adversarial click + scroll reports must not kill anything ---
Write-Host "`n[Test 4] SGR click/scroll reports do not crash session" -ForegroundColor Yellow
Send-Text $sess "$esc[<0;5;5M$esc[<0;5;5m"      # left click press+release
Start-Sleep -Milliseconds 800
Send-Text $sess "$esc[<64;10;5M$esc[<65;10;5M"  # wheel up + down
Start-Sleep -Seconds 2

if (-not $sess.Proc.HasExited) { Write-Pass "ssh attach still alive after click+scroll reports" }
else { Write-Fail "attach DIED after mouse reports (conhost crash class)" }

Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -eq 0) { Write-Pass "session survived mouse reports" }
else { Write-Fail "SESSION KILLED by mouse reports (issue #457 crash)" }

# --- Test 5: pane still accepts keystrokes afterwards ---
Write-Host "`n[Test 5] Input path still healthy" -ForegroundColor Yellow
Send-Text $sess "echo CLICK_SURVIVED`r"
Start-Sleep -Seconds 3
$cap = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($cap -match "CLICK_SURVIVED") { Write-Pass "keystrokes still reach pane after mouse reports" }
else { Write-Fail "input broken after mouse reports" }

# teardown
Send-RawBytes $sess @(0x02); Start-Sleep -Milliseconds 500; Send-Text $sess "d"
Start-Sleep -Seconds 2
Stop-InteractiveSsh $sess
Invoke-CSsh $ip "psmux kill-session -t $SESSION" | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
