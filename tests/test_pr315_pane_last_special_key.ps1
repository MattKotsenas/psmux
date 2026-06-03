# PR #315: #{pane_last_special_key} / #{pane_last_special_key_ms} E2E test
# Tests that non-text keys on the interactive input route are tracked
# and exposed via format variables.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "pr315_test"
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

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 15000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
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

# Compile injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (Test-Path "tests\injector.cs") {
    & $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null
}
$hasInjector = Test-Path $injectorExe

Cleanup
Start-Sleep -Seconds 1

Write-Host "`n=== PR #315: pane_last_special_key E2E Tests ===" -ForegroundColor Cyan

# ================================================================
# PART A: Format variables resolve (empty before any interactive key)
# ================================================================
Write-Host "`n--- Part A: Format Variables Resolve ---" -ForegroundColor Yellow

& $PSMUX new-session -d -s $SESSION
if (-not (Wait-Session $SESSION)) {
    Write-Fail "Session creation failed"
    exit 1
}
Start-Sleep -Seconds 3

Write-Host "`n[Test 1] pane_last_special_key is empty before any interactive key" -ForegroundColor Yellow
$sk = (& $PSMUX display-message -t $SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
if ($sk -eq "") { Write-Pass "pane_last_special_key is empty initially" }
else { Write-Fail "Expected empty, got: '$sk'" }

Write-Host "`n[Test 2] pane_last_special_key_ms is empty before any interactive key" -ForegroundColor Yellow
$skms = (& $PSMUX display-message -t $SESSION -p '#{pane_last_special_key_ms}' 2>&1 | Out-String).Trim()
if ($skms -eq "") { Write-Pass "pane_last_special_key_ms is empty initially" }
else { Write-Fail "Expected empty, got: '$skms'" }

Write-Host "`n[Test 3] pane_last_text_input is empty before any interactive key" -ForegroundColor Yellow
$lti = (& $PSMUX display-message -t $SESSION -p '#{pane_last_text_input}' 2>&1 | Out-String).Trim()
if ($lti -eq "") { Write-Pass "pane_last_text_input is empty initially" }
else { Write-Fail "Expected empty, got: '$lti'" }

# ================================================================
# PART B: Injected route (send-keys) does NOT update special key signal
# ================================================================
Write-Host "`n--- Part B: Injected Route Does NOT Update Signal ---" -ForegroundColor Yellow

Write-Host "`n[Test 4] send-keys does NOT update pane_last_special_key" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$sk2 = (& $PSMUX display-message -t $SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
if ($sk2 -eq "") { Write-Pass "send-keys Escape did NOT update pane_last_special_key (injected route)" }
else { Write-Fail "send-keys should NOT update signal, got: '$sk2'" }

Write-Host "`n[Test 5] send-keys text does NOT update pane_last_text_input" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "hello" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$lti2 = (& $PSMUX display-message -t $SESSION -p '#{pane_last_text_input}' 2>&1 | Out-String).Trim()
if ($lti2 -eq "") { Write-Pass "send-keys text did NOT update pane_last_text_input (injected route)" }
else { Write-Fail "send-keys should NOT update signal, got: '$lti2'" }

# ================================================================
# PART C: TCP server path
# ================================================================
Write-Host "`n--- Part C: TCP Server Path ---" -ForegroundColor Yellow

Write-Host "`n[Test 6] TCP display-message resolves pane_last_special_key" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "display-message -p #{pane_last_special_key}"
# Should be empty since no interactive key was pressed
if ($resp -ne $null -and $resp -ne "TIMEOUT" -and $resp -ne "AUTH_FAILED") { 
    Write-Pass "TCP display-message resolved pane_last_special_key: '$resp'" 
}
else { Write-Fail "TCP display-message failed: '$resp'" }

Write-Host "`n[Test 7] TCP display-message resolves pane_last_special_key_ms" -ForegroundColor Yellow
$resp2 = Send-TcpCommand -Session $SESSION -Command "display-message -p #{pane_last_special_key_ms}"
if ($resp2 -ne $null -and $resp2 -ne "TIMEOUT" -and $resp2 -ne "AUTH_FAILED") { 
    Write-Pass "TCP display-message resolved pane_last_special_key_ms: '$resp2'" 
}
else { Write-Fail "TCP display-message failed: '$resp2'" }

# ================================================================
# PART D: Interactive route via keystroke injection (PROVES it works)
# ================================================================
Write-Host "`n--- Part D: Interactive Route via Keystroke Injection ---" -ForegroundColor Yellow

Cleanup
Start-Sleep -Seconds 1

$TUI_SESSION = "pr315_tui"
& $PSMUX kill-session -t $TUI_SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$TUI_SESSION.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$TUI_SESSION -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $TUI_SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI session failed to start"
    exit 1
}
Write-Pass "TUI session alive"

if ($hasInjector) {
    Write-Host "`n[Test 8] Escape key via interactive route updates pane_last_special_key" -ForegroundColor Yellow
    & $injectorExe $proc.Id "{ESC}"
    Start-Sleep -Seconds 1
    $sk3 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
    if ($sk3 -eq "Escape") { Write-Pass "pane_last_special_key = 'Escape' after Escape keystroke" }
    else { Write-Fail "Expected 'Escape', got: '$sk3'" }

    $skms3 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key_ms}' 2>&1 | Out-String).Trim()
    if ($skms3 -match '^\d+$' -and [int]$skms3 -lt 5000) { Write-Pass "pane_last_special_key_ms = ${skms3}ms (reasonable)" }
    else { Write-Fail "Expected numeric ms value, got: '$skms3'" }

    Write-Host "`n[Test 9] Enter key via interactive route updates pane_last_special_key" -ForegroundColor Yellow
    & $injectorExe $proc.Id "{ENTER}"
    Start-Sleep -Seconds 1
    $sk4 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
    if ($sk4 -eq "Enter") { Write-Pass "pane_last_special_key = 'Enter' after Enter keystroke" }
    else { Write-Fail "Expected 'Enter', got: '$sk4'" }

    Write-Host "`n[Test 10] Text key via interactive route updates pane_last_text_input (NOT special)" -ForegroundColor Yellow
    & $injectorExe $proc.Id "a"
    Start-Sleep -Seconds 1
    $lti3 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_text_input}' 2>&1 | Out-String).Trim()
    if ($lti3 -match '^\d+$') { Write-Pass "pane_last_text_input = ${lti3}ms after text keystroke" }
    else { Write-Fail "Expected numeric ms, got: '$lti3'" }
    # special key should still be Enter (not updated by text key)
    $sk5 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
    if ($sk5 -eq "Enter") { Write-Pass "pane_last_special_key still 'Enter' after text key (not overwritten)" }
    else { Write-Fail "Expected 'Enter' unchanged, got: '$sk5'" }

    Write-Host "`n[Test 11] Ctrl+C via interactive route updates pane_last_special_key" -ForegroundColor Yellow
    & $injectorExe $proc.Id "^c"
    Start-Sleep -Seconds 1
    $sk6 = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
    if ($sk6 -eq "C-c") { Write-Pass "pane_last_special_key = 'C-c' after Ctrl+C" }
    else { Write-Fail "Expected 'C-c', got: '$sk6'" }

    Write-Host "`n[Test 12] Combined format string works" -ForegroundColor Yellow
    $combined = (& $PSMUX display-message -t $TUI_SESSION -p '#{pane_last_special_key} #{pane_last_special_key_ms}' 2>&1 | Out-String).Trim()
    if ($combined -match '^C-c \d+$') { Write-Pass "Combined format: '$combined'" }
    else { Write-Fail "Expected 'C-c <ms>', got: '$combined'" }
} else {
    Write-Host "  [SKIP] Injector not available, skipping interactive route tests" -ForegroundColor DarkGray
}

# ================================================================
# PART E: TUI CLI-based visual verification
# ================================================================
Write-Host "`n--- Part E: TUI CLI-Based Visual Verification ---" -ForegroundColor Yellow

Write-Host "`n[Test 13] TUI session functional after keystroke injection" -ForegroundColor Yellow
& $PSMUX has-session -t $TUI_SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI session still alive after all tests" }
else { Write-Fail "TUI session died" }

Write-Host "`n[Test 14] Split and verify pane_last_special_key per pane" -ForegroundColor Yellow
& $PSMUX split-window -v -t $TUI_SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1
$panes = (& $PSMUX display-message -t $TUI_SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split created 2 panes" }
else { Write-Fail "TUI: expected 2 panes, got $panes" }

# New pane should have empty special key (no interactive key pressed in it yet)
$newPaneSk = (& $PSMUX display-message -t "${TUI_SESSION}:.1" -p '#{pane_last_special_key}' 2>&1 | Out-String).Trim()
if ($newPaneSk -eq "") { Write-Pass "New pane has empty pane_last_special_key" }
else { Write-Fail "New pane should have empty special key, got: '$newPaneSk'" }

# Cleanup
& $PSMUX kill-session -t $TUI_SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
