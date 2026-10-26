# Issue #490: whitespace not preserved by send-keys
# 'echo "a           a"' arrives as 'echo "a a"' and leading spaces are stripped.
# Proof strategy: run Read-Host in the pane and have the app print the EXACT
# string it received wrapped in brackets, then capture-pane and compare.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue490"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

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
    $null = $reader.ReadLine()
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

function Start-ReadHostProbe {
    # Arms a Read-Host in the pane that echoes back exactly what it received
    & $PSMUX send-keys -t $SESSION '$x = Read-Host; Write-Host ("BRACKET=<" + $x + ">")' Enter
    Start-Sleep -Seconds 2
}

function Get-BracketValue {
    $captured = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    # last BRACKET=<...> occurrence
    $ms = [regex]::Matches($captured, "BRACKET=<([^>]*)>")
    if ($ms.Count -gt 0) { return $ms[$ms.Count-1].Groups[1].Value }
    return $null
}

# Setup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }
Start-Sleep -Seconds 2

Write-Host "`n=== Issue #490: send-keys whitespace preservation ===" -ForegroundColor Cyan

# === TEST 1: inner run of spaces preserved (CLI path) ===
Write-Host "`n[Test 1] Inner spaces preserved via CLI send-keys" -ForegroundColor Yellow
Start-ReadHostProbe
& $PSMUX send-keys -t $SESSION 'a           a' C-m
Start-Sleep -Seconds 2
$val = Get-BracketValue
if ($val -eq 'a           a') { Write-Pass "inner spaces preserved: <$val>" }
else { Write-Fail "expected <a           a> (11 spaces), got <$val>" }

# === TEST 2: leading spaces preserved (CLI path) ===
Write-Host "`n[Test 2] Leading spaces preserved via CLI send-keys" -ForegroundColor Yellow
Start-ReadHostProbe
& $PSMUX send-keys -t $SESSION '   lead' C-m
Start-Sleep -Seconds 2
$val = Get-BracketValue
if ($val -eq '   lead') { Write-Pass "leading spaces preserved: <$val>" }
else { Write-Fail "expected <   lead>, got <$val>" }

# === TEST 3: trailing spaces preserved (CLI path) ===
Write-Host "`n[Test 3] Trailing spaces preserved via CLI send-keys" -ForegroundColor Yellow
Start-ReadHostProbe
& $PSMUX send-keys -t $SESSION 'trail   ' C-m
Start-Sleep -Seconds 2
$val = Get-BracketValue
if ($val -eq 'trail   ') { Write-Pass "trailing spaces preserved: <$val>" }
else { Write-Fail "expected <trail   >, got <$val>" }

# === TEST 4: multiple space-separated args still joined with single space (tmux behavior) ===
# tmux: send-keys one two -> sends "onetwo" actually? No: tmux sends each arg as keys
# without separator. psmux historic behavior joins with space; keep whatever passes
# the single-arg cases and just record behavior here.
Write-Host "`n[Test 4] send-keys -l literal flag with spaces" -ForegroundColor Yellow
Start-ReadHostProbe
& $PSMUX send-keys -t $SESSION -l 'lit  eral'
& $PSMUX send-keys -t $SESSION C-m
Start-Sleep -Seconds 2
$val = Get-BracketValue
if ($val -eq 'lit  eral') { Write-Pass "-l literal spaces preserved: <$val>" }
else { Write-Fail "expected <lit  eral>, got <$val>" }

# === TEARDOWN ===
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
