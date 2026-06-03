# Reproduction test for Issue #303: command-prompt keybindings don't open prompt
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "repro303"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"

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

function Get-DumpState {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("dump-state`n"); $writer.Flush()
    try { $resp = $reader.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    if ($resp -and $resp.Length -gt 50) {
        return $resp | ConvertFrom-Json
    }
    return $null
}

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== ISSUE #303 REPRODUCTION ===" -ForegroundColor Cyan

# === TEST 1: Default binding - prefix + , (rename-window) via keystroke injection ===
Write-Host "`n[Test 1] Default binding: prefix+, (rename-window) via keystroke injection" -ForegroundColor Yellow

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Session not created" -ForegroundColor Red
    exit 1
}
Write-Host "  Session created, PID=$($proc.Id)" -ForegroundColor Gray

# Check mode before
$stateBefore = Get-DumpState -Session $SESSION
Write-Host "  Mode BEFORE keypress: '$($stateBefore.mode)'"

# Inject Ctrl+B then comma
Write-Host "  Injecting: Ctrl+B, (comma)..."
& $injectorExe $proc.Id "^b{SLEEP:500},"
Start-Sleep -Seconds 2

# Check mode after
$stateAfter = Get-DumpState -Session $SESSION
Write-Host "  Mode AFTER keypress: '$($stateAfter.mode)'"

# Check if mode is CommandPrompt or some prompt type
$modeStr = "$($stateAfter.mode)"
if ($modeStr -match "CommandPrompt|Rename|command_prompt|rename") {
    Write-Host "  [PASS] Prompt opened after prefix+comma" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE CONFIRMED] No prompt opened. Mode is: '$modeStr'" -ForegroundColor Red
    # Let's also check the overlay field and other state
    Write-Host "  Full state overlay: $($stateAfter.overlay)"
    Write-Host "  Windows count: $($stateAfter.windows.Count)"
}

# Escape back to normal mode just in case
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === TEST 2: command-prompt command via TCP (manual command mode) ===
Write-Host "`n[Test 2] command-prompt via TCP (simulate manual command)" -ForegroundColor Yellow

# Send command-prompt command via TCP
$resp = Send-TcpCommand -Session $SESSION -Command "command-prompt -I '#W' 'rename-window `"%%`"'"
Write-Host "  TCP response: $resp"

Start-Sleep -Seconds 1
$stateAfterTcp = Get-DumpState -Session $SESSION
Write-Host "  Mode after TCP command-prompt: '$($stateAfterTcp.mode)'"

if ("$($stateAfterTcp.mode)" -match "CommandPrompt|command_prompt") {
    Write-Host "  [PASS] command-prompt opens via TCP" -ForegroundColor Green
} else {
    Write-Host "  [INFO] command-prompt via TCP mode: '$($stateAfterTcp.mode)'" -ForegroundColor Yellow
}

# Escape
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === TEST 3: Rebind comma to command-prompt and test ===
Write-Host "`n[Test 3] Rebind comma to 'command-prompt -I `"#W`" `"rename-window %%`"'" -ForegroundColor Yellow

# Rebind via TCP
$bindResp = Send-TcpCommand -Session $SESSION -Command "bind-key , command-prompt -I '#W' 'rename-window `"%%`"'"
Write-Host "  bind-key response: $bindResp"
Start-Sleep -Milliseconds 500

# Now inject prefix+comma again
Write-Host "  Injecting: Ctrl+B, (comma) with new binding..."
& $injectorExe $proc.Id "^b{SLEEP:500},"
Start-Sleep -Seconds 2

$stateRebound = Get-DumpState -Session $SESSION
Write-Host "  Mode after rebound prefix+comma: '$($stateRebound.mode)'"

if ("$($stateRebound.mode)" -match "CommandPrompt|command_prompt") {
    Write-Host "  [PASS] command-prompt opens with rebound key" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE CONFIRMED] command-prompt binding still broken. Mode: '$($stateRebound.mode)'" -ForegroundColor Red
}

# Escape
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === TEST 4: prefix+$ (rename-session) via default binding ===
Write-Host "`n[Test 4] Default binding: prefix+`$ (rename-session)" -ForegroundColor Yellow

& $injectorExe $proc.Id "^b{SLEEP:500}`$"
Start-Sleep -Seconds 2

$stateDollar = Get-DumpState -Session $SESSION
Write-Host "  Mode after prefix+`$: '$($stateDollar.mode)'"

if ("$($stateDollar.mode)" -match "CommandPrompt|Rename|command_prompt|rename") {
    Write-Host "  [PASS] Rename prompt opened after prefix+`$" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE CONFIRMED] No prompt opened for rename-session. Mode: '$($stateDollar.mode)'" -ForegroundColor Red
}

# Escape
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === TEST 5: prefix+: (command-prompt itself, the control case) ===
Write-Host "`n[Test 5] Control test: prefix+: (command-prompt) should open prompt" -ForegroundColor Yellow

& $injectorExe $proc.Id "^b{SLEEP:500}:"
Start-Sleep -Seconds 2

$stateColon = Get-DumpState -Session $SESSION
Write-Host "  Mode after prefix+colon: '$($stateColon.mode)'"

if ("$($stateColon.mode)" -match "CommandPrompt|command_prompt") {
    Write-Host "  [PASS] prefix+: opens command prompt (control case works)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Even prefix+: failed to open command prompt!" -ForegroundColor Red
}

# Cleanup
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== REPRODUCTION COMPLETE ===" -ForegroundColor Cyan
