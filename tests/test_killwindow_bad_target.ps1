# kill-window with an unresolvable target must ERROR and kill NOTHING.
#
# tmux 3.4 parity (verified live):
#   kill-window -t sess:badname  -> "can't find window: badname", exit 1, no change
#   kill-window -t sess:99       -> "can't find window: 99", exit 1, no change
#   kill-window -t @99           -> "can't find window: @99", exit 1, no change
#
# The psmux bug: an unresolvable window NAME target silently fell back to the
# ACTIVE window, so `kill-window -t sess:typo` killed whatever was focused
# (and ended the whole session when it was the only window).

$ErrorActionPreference = "Continue"
$PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe"
if (-not (Test-Path $PSMUX)) { $PSMUX = (Get-Command psmux -EA Stop).Source }
$NS = "kwbad$PID"
$SESSION = "kw"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Get-WindowCount {
    $out = (& $PSMUX -L $NS display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
    if ($out -match '^\d+$') { return [int]$out } else { return -1 }
}

function Send-Tcp($Command) {
    $port = (Get-Content "$psmuxDir\$($NS)__$SESSION.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$($NS)__$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    $resp = $null
    try { $resp = $reader.ReadLine() } catch {}
    $tcp.Close()
    return $resp
}

try {
    $env:PSMUX_NO_WARM = "1"
    & $PSMUX -L $NS new-session -d -s $SESSION -x 100 -y 30 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 400; & $PSMUX -L $NS has-session -t $SESSION 2>$null } while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
    if ($LASTEXITCODE -ne 0) { Write-Fail "setup: session never came up"; exit 1 }

    # Three windows so a wrong kill is visible without ending the session.
    & $PSMUX -L $NS new-window -t $SESSION 2>&1 | Out-Null
    & $PSMUX -L $NS new-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $base = Get-WindowCount
    if ($base -ne 3) { Write-Fail "setup: expected 3 windows, got $base"; exit 1 }
    Write-Host "`n=== kill-window bad target tests (CLI path) ===" -ForegroundColor Cyan

    # --- Test 1: nonexistent window NAME (the reported bug) ---
    & $PSMUX -L $NS kill-window -t "${SESSION}:definitelynotawindow" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 3) { Write-Pass "bad NAME target killed nothing (still 3 windows)" }
    else { Write-Fail "bad NAME target changed window count: 3 -> $c" }

    # --- Test 2: nonexistent window INDEX ---
    & $PSMUX -L $NS kill-window -t "${SESSION}:99" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 3) { Write-Pass "bad INDEX target killed nothing" }
    else { Write-Fail "bad INDEX target changed window count: 3 -> $c" }

    # --- Test 3: nonexistent @id ---
    & $PSMUX -L $NS kill-window -t "@99" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 3) { Write-Pass "bad @id target killed nothing" }
    else { Write-Fail "bad @id target changed window count: 3 -> $c" }

    # --- Test 4: killw alias with bad name ---
    & $PSMUX -L $NS killw -t "${SESSION}:alsonotawindow" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 3) { Write-Pass "killw alias bad NAME killed nothing" }
    else { Write-Fail "killw alias bad NAME changed window count: 3 -> $c" }

    Write-Host "`n=== TCP server path ===" -ForegroundColor Cyan

    # --- Test 5: raw TCP one-shot with bad name ---
    $resp = Send-Tcp "kill-window -t ${SESSION}:tcpbadname"
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 3) { Write-Pass "TCP bad NAME killed nothing (resp: '$resp')" }
    else { Write-Fail "TCP bad NAME changed window count: 3 -> $c (resp: '$resp')" }

    Write-Host "`n=== Positive controls (valid kills must still work) ===" -ForegroundColor Cyan

    # --- Test 6: valid kill by good name still works ---
    & $PSMUX -L $NS rename-window -t $SESSION victimname 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $NS kill-window -t "${SESSION}:victimname" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 2) { Write-Pass "valid NAME kill removed exactly one window" }
    else { Write-Fail "valid NAME kill expected 2 windows, got $c" }

    # --- Test 7: kill-window with NO target kills the active window ---
    & $PSMUX -L $NS kill-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 1) { Write-Pass "bare session target still kills the active window" }
    else { Write-Fail "bare session target expected 1 window, got $c" }

    # --- Test 8: the original death scenario: single window, bad name ---
    & $PSMUX -L $NS kill-window -t "${SESSION}:lastbadname" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX -L $NS has-session -t $SESSION 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Pass "session SURVIVES a bad name kill on its last window" }
    else { Write-Fail "session DIED from a bad name kill (the reported bug)" }
}
finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-ChildItem $psmuxDir -Filter "$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
