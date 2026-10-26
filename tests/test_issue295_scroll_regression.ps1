# Issue #295: fallback scroll requests preserve scroll-mode behavior
# =================================================================
# This script exercises coordinate-based scroll-up/scroll-down requests and
# scroll-enter-copy-mode. It does not exercise the client's semantic
# pane-scroll request or child mouse metadata.
#
# This test proves:
# 1. Mouse options round-trip through the server
# 2. Fallback scroll requests are accepted
# 3. scroll-enter-copy-mode controls copy-mode entry

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test295_scroll"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkGray }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile = "$psmuxDir\$Session.key"
    if (-not (Test-Path $portFile)) { return "PORT_FILE_MISSING" }
    if (-not (Test-Path $keyFile)) { return "KEY_FILE_MISSING" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
        $writer.Write("$Command`n"); $writer.Flush()
        $stream.ReadTimeout = 5000
        try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch {
        return "CONNECTION_FAILED: $_"
    }
}

function Connect-Persistent {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    return @{ tcp=$tcp; writer=$writer; reader=$reader }
}

function Get-Dump {
    param($conn)
    $conn.writer.Write("dump-state`n"); $conn.writer.Flush()
    $best = $null
    $conn.tcp.ReceiveTimeout = 3000
    for ($j = 0; $j -lt 100; $j++) {
        try { $line = $conn.reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $conn.tcp.ReceiveTimeout = 50 }
    }
    $conn.tcp.ReceiveTimeout = 10000
    return $best
}

# === SETUP ===
Write-Host "`n=== Issue #295: fallback scroll request regression ===" -ForegroundColor Cyan
Cleanup

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}
Write-Pass "Session '$SESSION' created"

# Configure mouse
& $PSMUX set-option -g mouse on -t $SESSION 2>&1 | Out-Null
& $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION 2>&1 | Out-Null
& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# === TEST 1: Verify mouse options applied ===
Write-Host "`n[Test 1] Mouse options configured correctly" -ForegroundColor Yellow
$mouseVal = (& $PSMUX show-options -g -v mouse -t $SESSION 2>&1 | Out-String).Trim()
$scrollVal = (& $PSMUX show-options -g -v scroll-enter-copy-mode -t $SESSION 2>&1 | Out-String).Trim()
$mselVal = (& $PSMUX show-options -g -v mouse-selection -t $SESSION 2>&1 | Out-String).Trim()

if ($mouseVal -eq "on") { Write-Pass "mouse=on" }
else { Write-Fail "mouse expected on, got: $mouseVal" }

if ($scrollVal -eq "off") { Write-Pass "scroll-enter-copy-mode=off" }
else { Write-Fail "scroll-enter-copy-mode expected off, got: $scrollVal" }

if ($mselVal -eq "off") { Write-Pass "mouse-selection=off" }
else { Write-Fail "mouse-selection expected off, got: $mselVal" }

# === TEST 2: TCP scroll-up/scroll-down command works (server path) ===
Write-Host "`n[Test 2] TCP scroll commands accepted" -ForegroundColor Yellow
# Note: scroll-up/scroll-down are fire-and-forget (no response on TCP socket)
# They queue CtrlReq::ScrollUp/ScrollDown to the server loop.
# Success = no error/disconnect (empty response is expected).
$resp = Send-TcpCommand -Session $SESSION -Command "scroll-up 10 10"
if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "scroll-up accepted via TCP (fire-and-forget)" }
else { Write-Fail "scroll-up unexpected response: $resp" }

$resp = Send-TcpCommand -Session $SESSION -Command "scroll-down 10 10"
if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "scroll-down accepted via TCP (fire-and-forget)" }
else { Write-Fail "scroll-down unexpected response: $resp" }

# === TEST 3: Scroll in normal pane (scroll-enter-copy-mode=off) ===
Write-Host "`n[Test 3] Scroll in normal pane with scroll-enter-copy-mode=off" -ForegroundColor Yellow
# Generate scrollback content
& $PSMUX send-keys -t $SESSION "for /L %i in (1,1,100) do @echo LINE_%i" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Scroll up via TCP (server path - fire-and-forget)
$resp = Send-TcpCommand -Session $SESSION -Command "scroll-up 10 10"
if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "Scroll-up in normal pane accepted" }
else { Write-Fail "Scroll-up in normal pane: $resp" }

# Verify we did NOT enter copy mode (scroll-enter-copy-mode=off means direct scrollback)
$conn = Connect-Persistent -Session $SESSION
$state = Get-Dump $conn
$conn.tcp.Close()

if ($state) {
    $json = $state | ConvertFrom-Json
    # Check mode is not copy mode
    $mode = $json.mode
    if ($mode -eq "Normal" -or $mode -eq "Passthrough" -or $null -eq $mode) {
        Write-Pass "Did not enter copy mode (scroll-enter-copy-mode=off working)"
    } else {
        Write-Info "Mode after scroll: $mode"
        if ($mode -ne "CopyMode") { Write-Pass "Not in copy mode (mode=$mode)" }
        else { Write-Fail "Entered copy mode unexpectedly with scroll-enter-copy-mode=off" }
    }
} else {
    Write-Fail "Could not get dump-state"
}

# === TEST 4: Fallback scroll requests while a paging app runs ===
Write-Host "`n[Test 4] Fallback scroll requests with paging app" -ForegroundColor Yellow
# Launch a command that uses alt-screen (more/less equivalent on Windows)
& $PSMUX send-keys -t $SESSION "powershell -NoProfile -Command `"1..200 | Out-Host -Paging`"" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Verify scroll commands are accepted (fire-and-forget, no response expected)
$resp = Send-TcpCommand -Session $SESSION -Command "scroll-down 10 10"
if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "Scroll-down accepted with TUI in pane" }
else { Write-Fail "Scroll-down with TUI: $resp" }

$resp = Send-TcpCommand -Session $SESSION -Command "scroll-up 10 10"
if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "Scroll-up accepted with TUI in pane" }
else { Write-Fail "Scroll-up with TUI: $resp" }

# Exit the paging command
& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
& $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
Start-Sleep -Seconds 2

# === TEST 5: Verify scroll-enter-copy-mode=on enters copy mode on scroll-up ===
Write-Host "`n[Test 5] scroll-enter-copy-mode=on enters copy mode" -ForegroundColor Yellow
& $PSMUX set-option -g scroll-enter-copy-mode on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$alternateOn = (& $PSMUX display-message -p -t $SESSION '#{alternate_on}' 2>&1 | Out-String).Trim()
$inModeBefore = (& $PSMUX display-message -p -t $SESSION '#{pane_in_mode}' 2>&1 | Out-String).Trim()
if ($alternateOn -ne "0") { Write-Fail "Precondition failed: alternate_on=$alternateOn" }
if ($inModeBefore -ne "0") { Write-Fail "Precondition failed: pane_in_mode=$inModeBefore" }

$resp = Send-TcpCommand -Session $SESSION -Command "scroll-up 10 10"
Start-Sleep -Seconds 1

$inModeAfter = (& $PSMUX display-message -p -t $SESSION '#{pane_in_mode}' 2>&1 | Out-String).Trim()
if ($inModeAfter -eq "1") { Write-Pass "scroll-enter-copy-mode=on correctly enters copy mode" }
else { Write-Fail "Expected pane_in_mode=1 after scroll-up, got: $inModeAfter" }

# Reset: exit copy mode if entered
& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# === TEST 6: Attached-client fallback request smoke test ===
Write-Host "`n[Test 6] Attached-client fallback request smoke test" -ForegroundColor Yellow
$SESSION_TUI = "test295_tui_proof"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$psmuxExe = (Get-Command psmux -EA Stop).Source
$proc = Start-Process -FilePath $psmuxExe -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Attached client session creation failed"
} else {
    Write-Pass "Attached client session created"

    # Configure mouse
    & $PSMUX set-option -g mouse on -t $SESSION_TUI 2>&1 | Out-Null
    & $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION_TUI 2>&1 | Out-Null

    # Generate scrollback
    & $PSMUX send-keys -t $SESSION_TUI "for /L %i in (1,1,50) do @echo SCROLL_LINE_%i" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Send scroll via TCP (fire-and-forget)
    $resp = Send-TcpCommand -Session $SESSION_TUI -Command "scroll-up 10 10"
    if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "Attached client: scroll-up via TCP accepted" }
    else { Write-Fail "Attached client: scroll-up response: $resp" }

    $resp = Send-TcpCommand -Session $SESSION_TUI -Command "scroll-down 10 10"
    if ($null -eq $resp -or $resp -eq "" -or $resp -eq "OK" -or $resp -eq "TIMEOUT") { Write-Pass "Attached client: scroll-down via TCP accepted" }
    else { Write-Fail "Attached client: scroll-down response: $resp" }
}

# Cleanup TUI
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

exit $script:TestsFailed
