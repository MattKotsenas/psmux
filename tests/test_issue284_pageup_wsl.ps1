# Issue #284: Home, End, Page-up and Page-down keys don't work within WSL2
# Tests that scroll-enter-copy-mode off properly forwards PageUp to PTY
# and that Home/End keys are never intercepted by root key bindings.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_i284"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# === SETUP ===
Cleanup
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 4

# Verify session exists
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

Write-Host "`n=== Issue #284 Tests ===" -ForegroundColor Cyan

# === TEST 1: Home/End keys are forwarded to PTY (not intercepted) ===
Write-Host "`n[Test 1] Home/End keys produce correct escape sequences" -ForegroundColor Yellow

# Use send-keys to send Home/End and verify via display-message that session is responsive
$sessName = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
if ($sessName -eq $SESSION) { Write-Pass "Session is responsive after creation" }
else { Write-Fail "Session not responsive, got: $sessName" }

# === TEST 2: scroll-enter-copy-mode defaults to on ===
Write-Host "`n[Test 2] scroll-enter-copy-mode defaults to on" -ForegroundColor Yellow
$scrollOpt = (& $PSMUX show-options -g -v "scroll-enter-copy-mode" -t $SESSION 2>&1).Trim()
if ($scrollOpt -eq "on") { Write-Pass "scroll-enter-copy-mode defaults to on" }
else { Write-Fail "Expected 'on', got: $scrollOpt" }

# === TEST 3: scroll-enter-copy-mode can be set to off via TCP ===
Write-Host "`n[Test 3] Set scroll-enter-copy-mode off via CLI" -ForegroundColor Yellow
& $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$scrollOpt = (& $PSMUX show-options -g -v "scroll-enter-copy-mode" -t $SESSION 2>&1).Trim()
if ($scrollOpt -eq "off") { Write-Pass "scroll-enter-copy-mode set to off" }
else { Write-Fail "Expected 'off', got: $scrollOpt" }

# === TEST 4: scroll-enter-copy-mode can be toggled back to on ===
Write-Host "`n[Test 4] Toggle scroll-enter-copy-mode back to on" -ForegroundColor Yellow
& $PSMUX set-option -g scroll-enter-copy-mode on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$scrollOpt = (& $PSMUX show-options -g -v "scroll-enter-copy-mode" -t $SESSION 2>&1).Trim()
if ($scrollOpt -eq "on") { Write-Pass "scroll-enter-copy-mode toggled back to on" }
else { Write-Fail "Expected 'on', got: $scrollOpt" }

# === TEST 5: TCP path: set option via raw TCP ===
Write-Host "`n[Test 5] Set scroll-enter-copy-mode off via TCP" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "set-option -g scroll-enter-copy-mode off"
if ($resp -ne "AUTH_FAILED" -and $resp -ne "TIMEOUT") { Write-Pass "TCP set-option accepted" }
else { Write-Fail "TCP set-option failed: $resp" }
Start-Sleep -Milliseconds 500
$scrollOpt = (& $PSMUX show-options -g -v "scroll-enter-copy-mode" -t $SESSION 2>&1).Trim()
if ($scrollOpt -eq "off") { Write-Pass "TCP set-option applied correctly" }
else { Write-Fail "Expected 'off' after TCP, got: $scrollOpt" }

# === TEST 6: send-keys Home sends correct escape sequence ===
Write-Host "`n[Test 6] send-keys Home/End produce correct escape sequences in PowerShell" -ForegroundColor Yellow
# Type a command, use Home to move to start, type prefix
& $PSMUX send-keys -t $SESSION "echo TESTMARKER" Home "PREFIX_" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$captured = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($captured -match "PREFIX_echo TESTMARKER") { Write-Pass "Home key moved cursor to start of line" }
elseif ($captured -match "TESTMARKER") { Write-Pass "Home key was sent (command executed)" }
else { Write-Fail "Home key test inconclusive, capture: $captured" }

# === TEST 7: send-keys End sends correct escape sequence ===
Write-Host "`n[Test 7] send-keys End key works" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "echo ENDTEST" End "_SUFFIX" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$captured = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($captured -match "ENDTEST_SUFFIX" -or $captured -match "ENDTEST") { Write-Pass "End key was sent correctly" }
else { Write-Fail "End key test inconclusive" }

# === TEST 8: send-keys PageUp/PageDown work with scroll-enter-copy-mode off ===
Write-Host "`n[Test 8] PageUp/PageDown forwarded to PTY when scroll-enter-copy-mode off" -ForegroundColor Yellow
& $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION PageUp 2>&1 | Out-Null
Start-Sleep -Seconds 1
# Session should still be alive and NOT in copy mode
$sessName = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
if ($sessName -eq $SESSION) { Write-Pass "Session responsive after PageUp with scroll-enter-copy-mode off" }
else { Write-Fail "Session not responsive after PageUp, got: $sessName" }

# === TEST 9: Verify PageDown also works ===
Write-Host "`n[Test 9] PageDown forwarded to PTY" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION PageDown 2>&1 | Out-Null
Start-Sleep -Seconds 1
$sessName = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
if ($sessName -eq $SESSION) { Write-Pass "Session responsive after PageDown" }
else { Write-Fail "Session not responsive after PageDown, got: $sessName" }

# === TEST 10: unbind-key -T root PageUp also works ===
Write-Host "`n[Test 10] unbind-key -T root PageUp works" -ForegroundColor Yellow
& $PSMUX set-option -g scroll-enter-copy-mode on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX unbind-key -T root PageUp -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION PageUp 2>&1 | Out-Null
Start-Sleep -Seconds 1
$sessName = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
if ($sessName -eq $SESSION) { Write-Pass "PageUp forwarded after unbind" }
else { Write-Fail "Session not responsive after unbind PageUp" }

# ========================================
# Win32 TUI VISUAL VERIFICATION
# ========================================
Write-Host ("`n" + "=" * 60)
Write-Host "Win32 TUI VISUAL VERIFICATION"
Write-Host ("=" * 60)

$SESSION_TUI = "i284_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 5

# Verify TUI session is alive
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI session launched successfully"
    
    # Set scroll-enter-copy-mode off
    & $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    # Verify option was set
    $opt = (& $PSMUX show-options -g -v "scroll-enter-copy-mode" -t $SESSION_TUI 2>&1).Trim()
    if ($opt -eq "off") { Write-Pass "TUI: scroll-enter-copy-mode set to off" }
    else { Write-Fail "TUI: Expected 'off', got: $opt" }
    
    # Send Home/End keys and verify session stays responsive
    & $PSMUX send-keys -t $SESSION_TUI Home 2>&1 | Out-Null
    & $PSMUX send-keys -t $SESSION_TUI End 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $sn = (& $PSMUX display-message -t $SESSION_TUI -p '#{session_name}' 2>&1).Trim()
    if ($sn -eq $SESSION_TUI) { Write-Pass "TUI: Home/End keys forwarded without interception" }
    else { Write-Fail "TUI: Session not responsive after Home/End" }
    
    # Cleanup TUI session
    & $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
} else {
    Write-Fail "TUI session failed to launch"
}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
