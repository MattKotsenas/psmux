# Docker env: interactive attach INSIDE the container via docker exec + a
# container-side ConPTY harness - NO SSH anywhere on the attach path.
#
# Proves the `docker exec -it <container> psmux attach` user experience:
# the TUI renders through the container's own conhost (build 20348), typed
# keystrokes round-trip into the pane, prefix keybindings and the command
# prompt work, detach leaves the session alive, re-attach works.
#
# Prereqs: psmux-dev container running (docker\Run-PsmuxDev.ps1) with psmux
# installed inside (cargo install --path .). Session names must stay <= 9
# chars or the status bar truncates them (see docker gotchas).

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "test_docker_exec_lib.ps1")

$SESSION = "dkrei"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "`n=== docker-exec interactive attach (non-SSH) ===" -ForegroundColor Cyan
Resolve-DockerEnv
Install-AttachHarness
Invoke-CExec "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1

# --- Setup: detached session inside the container ---
if (-not (New-ContainerSession $SESSION)) {
    Write-Fail "session '$SESSION' never reached a shell prompt inside the container"
    exit 1
}
if (Test-ContainerSession $SESSION) { Write-Pass "session created inside container (has-session exit 0)" }
else { Write-Fail "has-session says '$SESSION' does not exist" }

# --- Test 1: interactive attach renders the TUI ---
Write-Host "`n[1] attach renders the TUI through the container ConPTY" -ForegroundColor Yellow
$h = Start-AttachHarness -Name "ei1" -Command "psmux attach -t $SESSION"
if (Wait-TuiRender $h "\[$SESSION\] 0:") { Write-Pass "status bar '[$SESSION] 0:' in the raw VT stream" }
else { Write-Fail "TUI never rendered; log: $(Get-HarnessLog $h)" }

# --- Test 2: typed keystrokes round-trip into the pane ---
Write-Host "`n[2] typed keystrokes reach the pane shell" -ForegroundColor Yellow
Send-HarnessCtrl $h "TEXT echo DKREXEC_MARK_1"
Start-Sleep -Seconds 3
$cap = Invoke-CExec "psmux capture-pane -t $SESSION -p"
if ($cap -match "DKREXEC_MARK_1") { Write-Pass "typed command executed in the pane" }
else { Write-Fail "pane capture missing marker: $cap" }
if (Wait-HarnessMatch $h "DKREXEC_MARK_1" 10) { Write-Pass "pane output echoed back down the attach stream" }
else { Write-Fail "marker never appeared in the VT stream" }

# --- Test 3: prefix+c creates a window (keybinding dispatch path) ---
Write-Host "`n[3] prefix+c new window" -ForegroundColor Yellow
$winsBefore = (Invoke-CExec "psmux display-message -t $SESSION -p #{session_windows}").Trim()
Send-HarnessHex $h "0263"   # Ctrl+B c
Start-Sleep -Seconds 4
$winsAfter = (Invoke-CExec "psmux display-message -t $SESSION -p #{session_windows}").Trim()
if ([int]$winsAfter -eq ([int]$winsBefore + 1)) { Write-Pass "session_windows $winsBefore -> $winsAfter" }
else { Write-Fail "expected $([int]$winsBefore + 1) windows, got '$winsAfter'" }

# --- Test 4: prefix+: command prompt executes a command ---
Write-Host "`n[4] prefix+: command prompt (rename-window)" -ForegroundColor Yellow
Send-HarnessHex $h "023a"   # Ctrl+B :
Start-Sleep -Seconds 2
Send-HarnessCtrl $h "TEXT rename-window dkrwin"
Start-Sleep -Seconds 3
$wname = (Invoke-CExec "psmux display-message -t $SESSION -p #{window_name}").Trim()
if ($wname -eq "dkrwin") { Write-Pass "command prompt renamed window to '$wname'" }
else { Write-Fail "window_name expected 'dkrwin', got '$wname'" }

# --- Test 5: prefix+d detaches; client exits; session survives ---
Write-Host "`n[5] prefix+d detach" -ForegroundColor Yellow
Send-HarnessHex $h "0264"   # Ctrl+B d
Start-Sleep -Seconds 3
if (-not (Test-HarnessClientAlive $h)) { Write-Pass "client exited on detach (CHILD_EXIT logged)" }
else { Write-Fail "client still running after prefix+d"; Stop-AttachHarness $h }
if (Test-ContainerSession $SESSION) { Write-Pass "session survived the detach" }
else { Write-Fail "session died on detach" }

# --- Test 6: re-attach works after detach ---
Write-Host "`n[6] re-attach" -ForegroundColor Yellow
$h2 = Start-AttachHarness -Name "ei2" -Command "psmux attach -t $SESSION"
if (Wait-TuiRender $h2 "\[$SESSION\] ") { Write-Pass "re-attach rendered the TUI again" }
else { Write-Fail "re-attach never rendered; log: $(Get-HarnessLog $h2)" }
Send-HarnessCtrl $h2 "TEXT echo DKREXEC_MARK_2"
Start-Sleep -Seconds 3
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "DKREXEC_MARK_2") {
    Write-Pass "input healthy after re-attach"
} else { Write-Fail "typed input dead after re-attach" }
Send-HarnessHex $h2 "0264"
Start-Sleep -Seconds 2
Stop-AttachHarness $h2

# --- Teardown ---
Invoke-CExec "psmux kill-session -t $SESSION" | Out-Null
Start-Sleep -Seconds 1
if (-not (Test-ContainerSession $SESSION)) { Write-Pass "kill-session cleaned up" }
else { Write-Fail "session still present after kill-session" }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
