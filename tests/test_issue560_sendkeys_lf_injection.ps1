# Issue #560: send-keys -l with a raw 0x0A payload cut the wire line and the tail
# ran as a psmux command against the caller's session (command injection).
# The fix escapes 0x0A/0x0D in quote_arg so no raw line terminator reaches the
# server's read_line. This test proves the injection is closed while the control
# (same payload, space instead of newline) still delivers into the pane.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = 'test560nl'
$LF = [char]10
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Pane { (& $PSMUX capture-pane -p -t $S 2>&1 | Where-Object { $_ -match '\S' } | Select-Object -Last 1) }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S -c C:\Temp
Start-Sleep -Seconds 3

Write-Host "=== Issue #560: send-keys LF injection ===" -ForegroundColor Cyan

# Control: identical payload with a space instead of the LF -> delivered, nothing executes
& $PSMUX send-keys -t "${S}:0" -l "CTRL_HEAD rename-window pwnedCTRL"
Start-Sleep -Milliseconds 1200
$ctrlName = (& $PSMUX display-message -p -t $S '#{window_name}').Trim()
if ($ctrlName -ne 'pwnedCTRL') { Pass "control: space payload did not execute rename (name=$ctrlName)" }
else { Fail "control invalid: space payload executed a rename" }

# Test: same payload with a real 0x0A. The tail must NOT execute.
& $PSMUX send-keys -t "${S}:0" -l ("TEST_HEAD" + $LF + "rename-window pwnedTEST")
Start-Sleep -Milliseconds 1200
$testName = (& $PSMUX display-message -p -t $S '#{window_name}').Trim()
if ($testName -ne 'pwnedTEST') { Pass "0x0A tail did NOT execute as a command (name=$testName)" }
else { Fail "INJECTION: 0x0A tail executed 'rename-window pwnedTEST'" }

# The literal text (including the escaped newline marker) should still reach the pane head.
$pane = Pane
if ($pane -match 'TEST_HEAD') { Pass "payload head reached the pane" }
else { Fail "payload head missing from pane: [$pane]" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
