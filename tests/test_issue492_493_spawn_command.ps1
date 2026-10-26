# Issue #492: new-window "C:/Program Files/Git/bin/bash.exe" fails (space in quoted path)
# Issue #493: new-window <command> always wraps the command in powershell.exe -NoLogo -Command
# Proof strategy:
#   - #492: create window with quoted path containing a space, verify the pane is
#     actually running bash (uname output, pane_current_command).
#   - #493: create window with an explicit exe, then inspect the pane PID's
#     process name and command line: it must BE the exe, not a powershell wrapper.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue492"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }
Start-Sleep -Seconds 2

Write-Host "`n=== Issue #492/#493: window command spawning ===" -ForegroundColor Cyan

# === TEST 1 (#492): quoted path with space spawns the exe ===
Write-Host "`n[Test 1] new-window with quoted space path runs bash" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "C:/Program Files/Git/bin/bash.exe" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$cmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
& $PSMUX send-keys -t $SESSION 'echo MARK492_$(uname -o)' Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "MARK492_Msys" -or $cmd -match "bash") { Write-Pass "bash running in new window (cmd=$cmd)" }
else { Write-Fail "bash NOT running. pane_current_command=$cmd Capture:`n$cap" }
& $PSMUX kill-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

# === TEST 2 (#493): pane process is the exe itself, not a powershell wrapper ===
# Direct spawn applies to EXPLICIT paths (the reporters' case). Bare names
# like plain `cmd.exe` keep the shell wrapper for console stdin semantics.
Write-Host "`n[Test 2] new-window with explicit cmd path spawns cmd directly (no powershell wrapper)" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "C:/Windows/System32/cmd.exe" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$panePid = (& $PSMUX display-message -t $SESSION -p '#{pane_pid}' 2>&1 | Out-String).Trim()
if ($panePid -match '^\d+$') {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$panePid" -EA SilentlyContinue
    $pname = $proc.Name
    $pcmdline = $proc.CommandLine
    Write-Host "  pane_pid=$panePid name=$pname cmdline=$pcmdline"
    if ($pname -match "^cmd") { Write-Pass "pane process IS cmd.exe (no wrapper)" }
    elseif ($pname -match "powershell") { Write-Fail "BUG #493: pane process is powershell wrapper: $pcmdline" }
    else { Write-Fail "unexpected pane process: $pname" }
} else {
    Write-Fail "could not get pane_pid, got: $panePid"
}
& $PSMUX kill-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

# === TEST 3 (#493): quoted exe with args spawns exe directly ===
Write-Host "`n[Test 3] new-window with exe+args spawns exe directly" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "C:/Program Files/Git/bin/bash.exe --login -i" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$panePid = (& $PSMUX display-message -t $SESSION -p '#{pane_pid}' 2>&1 | Out-String).Trim()
if ($panePid -match '^\d+$') {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$panePid" -EA SilentlyContinue
    $pname = $proc.Name
    Write-Host "  pane_pid=$panePid name=$pname cmdline=$($proc.CommandLine)"
    if ($pname -match "^bash") { Write-Pass "pane process IS bash.exe with args (no wrapper)" }
    elseif ($pname -match "powershell") { Write-Fail "BUG: powershell wrapper for exe+args: $($proc.CommandLine)" }
    else { Write-Fail "unexpected pane process: $pname" }
} else { Write-Fail "could not get pane_pid, got: $panePid" }
& $PSMUX kill-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

# === TEST 4 (#492): split-window with quoted space path also works ===
Write-Host "`n[Test 4] split-window with quoted space path" -ForegroundColor Yellow
& $PSMUX split-window -t $SESSION "C:/Program Files/Git/bin/bash.exe" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$panePid = (& $PSMUX display-message -t $SESSION -p '#{pane_pid}' 2>&1 | Out-String).Trim()
if ($panePid -match '^\d+$') {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$panePid" -EA SilentlyContinue
    if ($proc.Name -match "^bash") { Write-Pass "split-window spawned bash directly" }
    else { Write-Fail "split pane process: $($proc.Name) cmdline: $($proc.CommandLine)" }
} else { Write-Fail "could not get pane_pid" }

# === TEST 5: shell-syntax command still works (pipeline needs a shell) ===
Write-Host "`n[Test 5] command with shell syntax still runs" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "echo shellmark495 && cmd /k" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "shellmark495") { Write-Pass "shell-syntax command produced output" }
else { Write-Fail "shell-syntax command failed. Capture:`n$cap" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
