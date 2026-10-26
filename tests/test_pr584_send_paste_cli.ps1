# PR #584: send-paste CLI transport hardening.
# Claims: valid base64 forwarded exactly once; missing, malformed, or multiple
# payloads rejected with an error; -t target syntax preserved.
# Baseline (master 3.3.8): all invalid shapes exited 0 silently.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "tpr584"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 500 }
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== PR #584: send-paste CLI ===" -ForegroundColor Cyan

# Test 1: valid single-line payload is pasted into the pane
Write-Host "[Test 1] valid base64 payload pastes" -ForegroundColor Yellow
& $PSMUX send-paste -t $SESSION (B64 "PASTE_MARKER_584") 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Seconds 1
$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($rc -eq 0 -and $cap -match "PASTE_MARKER_584") { Write-Pass "payload pasted (exit 0)" }
else { Write-Fail "exit=$rc, marker in capture: $($cap -match 'PASTE_MARKER_584')" }

# Test 2: multiline UTF-8 payload survives the base64 frame
Write-Host "[Test 2] multiline UTF-8 payload" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX send-paste -t $SESSION (B64 "MULTI_ONE_584`nMULTI_TWO_584 cafeé") 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Seconds 1
$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($rc -eq 0 -and $cap -match "MULTI_ONE_584" -and $cap -match "MULTI_TWO_584") { Write-Pass "both lines arrived (exit 0)" }
else { Write-Fail "exit=$rc one=$($cap -match 'MULTI_ONE_584') two=$($cap -match 'MULTI_TWO_584')" }

# Test 3: malformed base64 rejected non-zero
Write-Host "[Test 3] malformed payload rejected" -ForegroundColor Yellow
$out = (& $PSMUX send-paste -t $SESSION "not base64!!" 2>&1 | Out-String).Trim()
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Pass "malformed rejected (exit $rc): $out" }
else { Write-Fail "malformed accepted with exit 0" }

# Test 4: missing payload rejected non-zero
Write-Host "[Test 4] missing payload rejected" -ForegroundColor Yellow
$out = (& $PSMUX send-paste -t $SESSION 2>&1 | Out-String).Trim()
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Pass "missing rejected (exit $rc)" }
else { Write-Fail "missing payload accepted with exit 0" }

# Test 5: two payloads rejected non-zero (no silent last-wins)
Write-Host "[Test 5] multiple payloads rejected" -ForegroundColor Yellow
$out = (& $PSMUX send-paste -t $SESSION "YQ==" "Yg==" 2>&1 | Out-String).Trim()
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Pass "two payloads rejected (exit $rc)" }
else { Write-Fail "two payloads accepted with exit 0" }

# Test 6: dangling -t rejected non-zero
Write-Host "[Test 6] dangling -t rejected" -ForegroundColor Yellow
$out = (& $PSMUX send-paste "-t" 2>&1 | Out-String).Trim()
$rc = $LASTEXITCODE
if ($rc -ne 0) { Write-Pass "dangling -t rejected (exit $rc)" }
else { Write-Fail "dangling -t accepted with exit 0" }

# Test 7: payload that decodes but LOOKS like a flag is still accepted as payload
Write-Host "[Test 7] payload order robustness: -t after payload" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX send-paste (B64 "ORDER_584") -t $SESSION 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Seconds 1
$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($rc -eq 0 -and $cap -match "ORDER_584") { Write-Pass "payload before -t works" }
else { Write-Fail "exit=$rc marker=$($cap -match 'ORDER_584')" }

# Test 8: TCP server path unchanged (raw send-paste frame still lands)
Write-Host "[Test 8] raw TCP send-paste frame" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$reader = [System.IO.StreamReader]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
$null = $reader.ReadLine()
$writer.Write("send-paste $(B64 'TCP_PASTE_584')`n"); $writer.Flush()
Start-Sleep -Seconds 1
$tcp.Close()
$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($cap -match "TCP_PASTE_584") { Write-Pass "TCP frame pasted" }
else { Write-Fail "TCP frame did not land in pane" }

Cleanup

# === Win32 TUI visual verification (Strategy A) ===
Write-Host "`n=== TUI verification ===" -ForegroundColor Cyan
$T = "tpr584tui"
& $PSMUX kill-session -t $T 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$T -PassThru
Start-Sleep -Seconds 4
& $PSMUX send-paste -t $T (B64 "TUI_PASTE_584") 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap = (& $PSMUX capture-pane -t $T -p 2>&1 | Out-String)
if ($cap -match "TUI_PASTE_584") { Write-Pass "TUI attached: paste visible in live pane" }
else { Write-Fail "TUI attached: paste not visible" }
$sn = (& $PSMUX display-message -t $T -p '#{session_name}' 2>&1 | Out-String).Trim()
if ($sn -eq $T) { Write-Pass "TUI attached: session responsive after paste" }
else { Write-Fail "TUI attached: display-message got '$sn'" }
& $PSMUX kill-session -t $T 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
