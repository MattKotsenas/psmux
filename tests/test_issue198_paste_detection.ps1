# Issue #198: paste-detection off should bypass character buffering entirely
# Tests that setting paste-detection off actually stops the paste interception

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue198"
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
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

# Verify session exists
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

Write-Host "`n=== Issue #198: paste-detection Tests ===" -ForegroundColor Cyan

# === TEST 1: show-options returns paste-detection default ===
Write-Host "`n[Test 1] Default paste-detection value" -ForegroundColor Yellow
$default = (& $PSMUX show-options -g -v "paste-detection" -t $SESSION 2>&1).Trim()
if ($default -eq "on") { Write-Pass "Default paste-detection is 'on'" }
else { Write-Fail "Expected default 'on', got '$default'" }

# === TEST 2: set-option paste-detection off via CLI ===
Write-Host "`n[Test 2] Set paste-detection off via CLI" -ForegroundColor Yellow
& $PSMUX set-option -g paste-detection off -t $SESSION 2>&1 | Out-Null
$val = (& $PSMUX show-options -g -v "paste-detection" -t $SESSION 2>&1).Trim()
if ($val -eq "off") { Write-Pass "paste-detection set to 'off' via CLI" }
else { Write-Fail "Expected 'off', got '$val'" }

# === TEST 3: set-option paste-detection on (toggle back) ===
Write-Host "`n[Test 3] Toggle paste-detection back on" -ForegroundColor Yellow
& $PSMUX set-option -g paste-detection on -t $SESSION 2>&1 | Out-Null
$val2 = (& $PSMUX show-options -g -v "paste-detection" -t $SESSION 2>&1).Trim()
if ($val2 -eq "on") { Write-Pass "paste-detection toggled back to 'on'" }
else { Write-Fail "Expected 'on', got '$val2'" }

# === TEST 4: TCP path also sets paste-detection ===
Write-Host "`n[Test 4] Set paste-detection off via TCP" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "set-option -g paste-detection off"
$val3 = (& $PSMUX show-options -g -v "paste-detection" -t $SESSION 2>&1).Trim()
if ($val3 -eq "off") { Write-Pass "paste-detection set to 'off' via TCP" }
else { Write-Fail "Expected 'off' via TCP, got '$val3'" }

# === TEST 5: dump-state reflects paste_detection value ===
Write-Host "`n[Test 5] dump-state JSON includes paste_detection=false" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$reader = [System.IO.StreamReader]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
$null = $reader.ReadLine()
$writer.Write("dump-state`n"); $writer.Flush()
$stream.ReadTimeout = 5000
$dumpResp = $reader.ReadLine()
$tcp.Close()

if ($dumpResp -match '"paste_detection"\s*:\s*false') {
    Write-Pass "dump-state shows paste_detection: false"
} else {
    Write-Fail "dump-state does not show paste_detection: false"
}

# === TEST 6: Config file sets paste-detection ===
Write-Host "`n[Test 6] Config file sets paste-detection off" -ForegroundColor Yellow
$confFile = "$env:TEMP\psmux_test_198.conf"
"set -g paste-detection off" | Set-Content -Path $confFile -Encoding UTF8
$cfgSession = "test_issue198_cfg"
& $PSMUX kill-session -t $cfgSession 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$cfgSession.*" -Force -EA SilentlyContinue
$env:PSMUX_CONFIG_FILE = $confFile
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$cfgSession,"-d" -WindowStyle Hidden
$env:PSMUX_CONFIG_FILE = $null
Start-Sleep -Seconds 4
& $PSMUX has-session -t $cfgSession 2>$null
if ($LASTEXITCODE -eq 0) {
    $cfgVal = (& $PSMUX show-options -g -v "paste-detection" -t $cfgSession 2>&1).Trim()
    if ($cfgVal -eq "off") { Write-Pass "Config file applied paste-detection off" }
    else { Write-Fail "Config file paste-detection expected 'off', got '$cfgVal'" }
    & $PSMUX kill-session -t $cfgSession 2>&1 | Out-Null
} else {
    Write-Fail "Config session creation failed"
}
Remove-Item $confFile -Force -EA SilentlyContinue
Remove-Item "$psmuxDir\$cfgSession.*" -Force -EA SilentlyContinue

# === TEST 7: TUI Visual Verification with paste-detection off ===
Write-Host "`n[Test 7] TUI Visual: paste-detection off in attached session" -ForegroundColor Yellow
$tuiSession = "test_198_tui"
& $PSMUX kill-session -t $tuiSession 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$tuiSession.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$tuiSession -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $tuiSession 2>$null
if ($LASTEXITCODE -eq 0) {
    # Set paste-detection off on the TUI session
    & $PSMUX set-option -g paste-detection off -t $tuiSession 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500

    # Verify option applied
    $tuiVal = (& $PSMUX show-options -g -v "paste-detection" -t $tuiSession 2>&1).Trim()
    if ($tuiVal -eq "off") { Write-Pass "TUI session paste-detection set to off" }
    else { Write-Fail "TUI session paste-detection expected 'off', got '$tuiVal'" }

    # Verify TUI session is functional (basic command works)
    & $PSMUX send-keys -t $tuiSession "echo TUI_WORKS_198" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t $tuiSession -p 2>&1 | Out-String
    if ($cap -match "TUI_WORKS_198") { Write-Pass "TUI session functional with paste-detection off" }
    else { Write-Fail "TUI send-keys/capture-pane failed" }

    # Cleanup TUI
    & $PSMUX kill-session -t $tuiSession 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
} else {
    Write-Fail "TUI session creation failed"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}
Remove-Item "$psmuxDir\$tuiSession.*" -Force -EA SilentlyContinue

# === TEST 8: WriteConsoleInput + paste-detection off = characters pass through directly ===
Write-Host "`n[Test 8] WriteConsoleInput: characters with paste-detection off" -ForegroundColor Yellow
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

$injectSession = "test_198_inject"
& $PSMUX kill-session -t $injectSession 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$injectSession.*" -Force -EA SilentlyContinue

# Launch with input debug logging
$env:PSMUX_INPUT_DEBUG = "1"
$procInj = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$injectSession -PassThru
$env:PSMUX_INPUT_DEBUG = $null
Start-Sleep -Seconds 4

& $PSMUX has-session -t $injectSession 2>$null
if ($LASTEXITCODE -eq 0) {
    # Set paste-detection off
    & $PSMUX set-option -g paste-detection off -t $injectSession 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Clear the pane
    & $PSMUX send-keys -t $injectSession "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Inject "echo PASTE_TEST_198" + Enter rapidly via WriteConsoleInput
    # This simulates what Windows Terminal does when pasting clipboard content
    & $injectorExe $procInj.Id "echo PASTE_TEST_198{ENTER}"
    Start-Sleep -Seconds 3

    # Capture pane output
    $capInj = & $PSMUX capture-pane -t $injectSession -p 2>&1 | Out-String
    if ($capInj -match "PASTE_TEST_198") {
        Write-Pass "Injected characters appeared in pane (paste-detection off)"
    } else {
        Write-Fail "Injected characters did NOT appear in pane. Capture: $($capInj.Substring(0, [Math]::Min(200, $capInj.Length)))"
    }

    # Check input debug log for paste-related entries
    $logPath = "$psmuxDir\input_debug.log"
    if (Test-Path $logPath) {
        $logContent = Get-Content $logPath -Raw -EA SilentlyContinue
        if ($logContent -match "send-paste") {
            Write-Fail "BUG CONFIRMED: characters were sent as send-paste even with paste-detection off"
            # Show relevant log lines
            $pasteLines = Get-Content $logPath | Where-Object { $_ -match "paste" } | Select-Object -Last 10
            Write-Host "    Input log (paste lines):" -ForegroundColor DarkYellow
            $pasteLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
        } elseif ($logContent -match "stage2") {
            Write-Fail "BUG CONFIRMED: characters entered stage2 paste buffering even with paste-detection off"
        } else {
            Write-Pass "No paste buffering detected in input log"
        }
    } else {
        Write-Host "    (input_debug.log not found, skipping log analysis)" -ForegroundColor DarkGray
    }

    # Cleanup
    & $PSMUX kill-session -t $injectSession 2>&1 | Out-Null
    try { Stop-Process -Id $procInj.Id -Force -EA SilentlyContinue } catch {}
} else {
    Write-Fail "Inject session creation failed"
    try { Stop-Process -Id $procInj.Id -Force -EA SilentlyContinue } catch {}
}
Remove-Item "$psmuxDir\$injectSession.*" -Force -EA SilentlyContinue

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
