# Docker environment: INTERACTIVE psmux attach over SSH.
#
# Drives a REAL "ssh -tt ... psmux attach" from the host into the psmux-dev
# container. stdin bytes are genuine keystrokes travelling through the SSH
# channel into the remote ConPTY (the exact path a human user exercises);
# stdout is the raw VT stream psmux renders for the terminal.
#
# Proves, inside the docker env (Windows build 20348):
#   1. the TUI draws over SSH (status bar reaches the client)
#   2. typed keystrokes reach the pane shell (echo marker round-trip)
#   3. prefix Ctrl+B keybindings work over SSH (prefix+c = new window)
#   4. the command prompt works over SSH (prefix+: new-window)
#   5. resize-window while attached does NOT lock input (issue #376 class)
#   6. prefix+d detaches cleanly and the session survives
#   7. re-attach works after detach

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\test_docker_ssh_lib.ps1"

$SESSION = "dkr_int"   # short: default status-left truncates ~9 chars, name must fit for stream match
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

Write-Host "`n=== Docker/SSH interactive attach tests ===" -ForegroundColor Cyan
$ip = Get-ContainerIP
Write-Host "  container IP: $ip"

# clean slate + detached session to attach to
Invoke-CSsh $ip "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1
New-ContainerSession $ip $SESSION
Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -ne 0) { Write-Fail "setup: session not created"; exit 1 }

# --- Test 1: attach draws the TUI over SSH ---
Write-Host "`n[Test 1] Interactive attach renders TUI" -ForegroundColor Yellow
$sess = Start-InteractiveSsh $ip "psmux attach -t $SESSION"
if (Wait-TuiRender $sess "$SESSION" 35) { Write-Pass "status bar with session name arrived over SSH" }
else { Write-Fail "TUI never drew (no session name in stream)"; Stop-InteractiveSsh $sess; exit 1 }

# --- Test 2: typed keystrokes reach the pane shell ---
Write-Host "`n[Test 2] Keystrokes reach pane" -ForegroundColor Yellow
Send-Text $sess "echo INTERACTIVE_MARKER`r"
Start-Sleep -Seconds 3
$cap = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($cap -match "INTERACTIVE_MARKER") { Write-Pass "typed command executed in pane (capture-pane proof)" }
else { Write-Fail "typed command did not reach pane" }

# --- Test 3: prefix keybinding Ctrl+B c = new-window ---
Write-Host "`n[Test 3] Prefix+c keybinding over SSH" -ForegroundColor Yellow
$winsBefore = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_windows}'").Trim()
Send-RawBytes $sess @(0x02)   # Ctrl+B
Start-Sleep -Milliseconds 600
Send-Text $sess "c"
Start-Sleep -Seconds 3
$winsAfter = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_windows}'").Trim()
if ([int]$winsAfter -gt [int]$winsBefore) { Write-Pass "prefix+c created window ($winsBefore -> $winsAfter)" }
else { Write-Fail "prefix+c did not create window ($winsBefore -> $winsAfter)" }

# --- Test 4: command prompt prefix+: new-window ---
Write-Host "`n[Test 4] Command prompt over SSH" -ForegroundColor Yellow
Send-RawBytes $sess @(0x02)
Start-Sleep -Milliseconds 600
Send-Text $sess ":"
Start-Sleep -Milliseconds 800
Send-Text $sess "new-window`r"
Start-Sleep -Seconds 3
$winsCmd = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_windows}'").Trim()
if ([int]$winsCmd -gt [int]$winsAfter) { Write-Pass "command prompt new-window worked ($winsAfter -> $winsCmd)" }
else { Write-Fail "command prompt new-window failed ($winsAfter -> $winsCmd)" }

# --- Test 5: resize while attached must not lock input (issue #376 class) ---
Write-Host "`n[Test 5] Resize does not lock input" -ForegroundColor Yellow
Invoke-CSsh $ip "psmux resize-window -t $SESSION -x 100 -y 30" | Out-Null
Start-Sleep -Seconds 2
Send-Text $sess "echo AFTER_RESIZE_OK`r"
Start-Sleep -Seconds 3
$capR = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($capR -match "AFTER_RESIZE_OK") { Write-Pass "input still works after resize (no #376 lockup)" }
else { Write-Fail "INPUT LOCKED after resize (issue #376 class bug in docker env)" }

# --- Test 6: prefix+d detach, session survives ---
Write-Host "`n[Test 6] Detach and session survival" -ForegroundColor Yellow
Send-RawBytes $sess @(0x02)
Start-Sleep -Milliseconds 600
Send-Text $sess "d"
$exited = $sess.Proc.WaitForExit(15000)
if ($exited) { Write-Pass "prefix+d detached (ssh client exited)" }
else { Write-Fail "ssh client still running after prefix+d" }
Stop-InteractiveSsh $sess

Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -eq 0) { Write-Pass "session survived detach" }
else { Write-Fail "session died on detach" }

# --- Test 7: re-attach works ---
Write-Host "`n[Test 7] Re-attach" -ForegroundColor Yellow
$sess2 = Start-InteractiveSsh $ip "psmux attach -t $SESSION"
if (Wait-TuiRender $sess2 "$SESSION" 35) { Write-Pass "re-attach rendered TUI again" }
else { Write-Fail "re-attach did not render" }
Send-Text $sess2 "echo REATTACH_MARKER`r"
Start-Sleep -Seconds 3
$cap2 = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($cap2 -match "REATTACH_MARKER") { Write-Pass "keystrokes work after re-attach" }
else { Write-Fail "keystrokes broken after re-attach" }

# teardown
Send-RawBytes $sess2 @(0x02); Start-Sleep -Milliseconds 500; Send-Text $sess2 "d"
Start-Sleep -Seconds 2
Stop-InteractiveSsh $sess2
Invoke-CSsh $ip "psmux kill-session -t $SESSION" | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
