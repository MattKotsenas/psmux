# Issue #489: split-window does not support -e (environment)
# tmux: split-window/new-window accept repeatable -e KEY=VALUE applied to the
# spawned pane's environment.
# Proof: split with -e TESTVAR=hello489, then echo $env:TESTVAR in the new pane.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue489"
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

Write-Host "`n=== Issue #489: split-window -e environment ===" -ForegroundColor Cyan

# === TEST 1: split-window -e is accepted (no error) ===
Write-Host "`n[Test 1] split-window -e accepted" -ForegroundColor Yellow
$out = & $PSMUX split-window -t $SESSION -e TESTVAR=hello489 2>&1 | Out-String
Start-Sleep -Seconds 3
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2" -and $out -notmatch "error|unknown|invalid") { Write-Pass "split-window -e created pane 2 without error" }
else { Write-Fail "panes=$panes output=$out" }

# === TEST 2: the new pane actually has the variable ===
Write-Host "`n[Test 2] Environment variable set in new pane" -ForegroundColor Yellow
Start-Sleep -Seconds 2
& $PSMUX send-keys -t $SESSION 'Write-Host ("EV=<" + $env:TESTVAR + ">")' Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "EV=<hello489>") { Write-Pass "TESTVAR=hello489 visible in new pane" }
else { Write-Fail "TESTVAR not set in pane. Capture:`n$cap" }

# === TEST 3: multiple -e flags ===
Write-Host "`n[Test 3] Multiple -e flags" -ForegroundColor Yellow
& $PSMUX split-window -t $SESSION -e AAA=one -e BBB=two 2>&1 | Out-Null
Start-Sleep -Seconds 4
& $PSMUX send-keys -t $SESSION 'Write-Host ("MULTI=<" + $env:AAA + "," + $env:BBB + ">")' Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "MULTI=<one,two>") { Write-Pass "multiple -e vars set" }
else { Write-Fail "multiple -e vars missing. Capture:`n$cap" }

# === TEST 4: new-window -e ===
Write-Host "`n[Test 4] new-window -e" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -e WVAR=win489 2>&1 | Out-Null
Start-Sleep -Seconds 4
& $PSMUX send-keys -t $SESSION 'Write-Host ("WV=<" + $env:WVAR + ">")' Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "WV=<win489>") { Write-Pass "new-window -e var set" }
else { Write-Fail "new-window -e var missing. Capture:`n$cap" }

# === TEST 5: -e combined with -c (the reporter's exact combo) ===
Write-Host "`n[Test 5] split-window -c <dir> -e VAR=VAL combo" -ForegroundColor Yellow
& $PSMUX split-window -t $SESSION -c "C:/Windows" -e CHERE_INVOKING=1 2>&1 | Out-Null
Start-Sleep -Seconds 4
& $PSMUX send-keys -t $SESSION 'Write-Host ("COMBO=<" + $env:CHERE_INVOKING + "|" + (Get-Location).Path + ">")' Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "COMBO=<1\|C:\\Windows>") { Write-Pass "-c and -e both applied" }
else { Write-Fail "combo failed. Capture:`n$cap" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
