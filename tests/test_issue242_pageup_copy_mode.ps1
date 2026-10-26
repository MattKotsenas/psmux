# Issue #242: bind-key page-up does enter copy mode
# Tests that pressing PageUp enters copy mode (tmux default behavior)
# Verifies: root table binding for PageUp -> copy-mode -u, copy-mode -u command,
# and that the binding appears in list-keys output.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue242"
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
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 2000)
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
    $stream.ReadTimeout = $TimeoutMs
    try { $resp = $reader.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    return $resp
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
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

Write-Host "`n=== Issue #242: PageUp enters copy mode ===" -ForegroundColor Cyan

# ============================================================
# PART A: list-keys verification (binding exists)
# ============================================================
Write-Host "`n--- Part A: list-keys verification ---" -ForegroundColor Yellow

# Test 1: PageUp binding lives in the PREFIX table, not root (issue #488,
# tmux parity: tmux binds PPage only in the prefix table, so a bare PageUp
# reaches the running application).
Write-Host "[Test 1] PageUp prefix table binding in list-keys (tmux parity, #488)" -ForegroundColor Yellow
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
$inPrefix = $keys -match "(?i)prefix.*(PageUp|PPage).*copy-mode"
$inRoot = $keys -match "(?i)-T root.*(PageUp|PPage).*copy-mode"
if ($inPrefix -and -not $inRoot) {
    Write-Pass "PageUp -> copy-mode -u in prefix table only (tmux default)"
} elseif ($inRoot) {
    Write-Fail "PageUp must NOT be bound in root table by default (issue #488). Keys output:`n$keys"
} else {
    Write-Fail "PageUp binding not found in prefix table. Keys output:`n$keys"
}

# Test 2: prefix [ still works for copy-mode
Write-Host "[Test 2] prefix [ copy-mode binding still present" -ForegroundColor Yellow
if ($keys -match "bind-key.*-T prefix.*\[.*copy-mode") {
    Write-Pass "prefix [ -> copy-mode binding present"
} else {
    Write-Fail "prefix [ binding missing"
}

# ============================================================
# PART B: CLI copy-mode -u command
# ============================================================
Write-Host "`n--- Part B: CLI copy-mode -u command ---" -ForegroundColor Yellow

# Test 3: copy-mode -u via CLI enters copy mode
Write-Host "[Test 3] copy-mode -u enters copy mode" -ForegroundColor Yellow
& $PSMUX copy-mode -u -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1

# Verify via dump-state (copy_mode is in the layout leaf, not a top-level mode field)
$conn = Connect-Persistent -Session $SESSION
$state = Get-Dump $conn
if ($state) {
    if ($state -match '"copy_mode"\s*:\s*true') {
        Write-Pass "copy-mode -u entered CopyMode"
    } else {
        Write-Fail "Expected copy_mode:true in dump-state"
    }
} else {
    Write-Fail "Could not get dump-state"
}
$conn.tcp.Close()

# Exit copy mode
& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Test 4: plain copy-mode (without -u) enters copy mode
Write-Host "[Test 4] plain copy-mode enters CopyMode" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1
$conn2 = Connect-Persistent -Session $SESSION
$state2 = Get-Dump $conn2
if ($state2) {
    if ($state2 -match '"copy_mode"\s*:\s*true') {
        Write-Pass "plain copy-mode entered CopyMode"
    } else {
        Write-Fail "Expected copy_mode:true in dump-state"
    }
} else {
    Write-Fail "Could not get dump-state for plain copy-mode"
}
$conn2.tcp.Close()

# Exit copy mode
& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# PART C: TCP server path (fire-and-forget, verify via dump-state)
# ============================================================
Write-Host "`n--- Part C: TCP server path ---" -ForegroundColor Yellow

# Test 5: copy-mode -u via TCP enters copy mode (no OK response expected)
Write-Host "[Test 5] copy-mode -u via raw TCP" -ForegroundColor Yellow
Send-TcpCommand -Session $SESSION -Command "copy-mode -u" -TimeoutMs 1000 | Out-Null
Start-Sleep -Seconds 1

$conn3 = Connect-Persistent -Session $SESSION
$state3 = Get-Dump $conn3
if ($state3 -and ($state3 -match '"copy_mode"\s*:\s*true')) {
    Write-Pass "TCP copy-mode -u entered CopyMode"
} else {
    Write-Fail "TCP copy-mode -u did not enter CopyMode"
}
$conn3.tcp.Close()

& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Test 6: plain copy-mode via TCP
Write-Host "[Test 6] copy-mode via raw TCP" -ForegroundColor Yellow
Send-TcpCommand -Session $SESSION -Command "copy-mode" -TimeoutMs 1000 | Out-Null
Start-Sleep -Seconds 1

$conn4 = Connect-Persistent -Session $SESSION
$state4 = Get-Dump $conn4
if ($state4 -and ($state4 -match '"copy_mode"\s*:\s*true')) {
    Write-Pass "TCP copy-mode entered CopyMode"
} else {
    Write-Fail "TCP copy-mode did not enter CopyMode"
}
$conn4.tcp.Close()

& $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Send-TcpCommand -Session $SESSION -Command "send-keys Escape" | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# PART D: Edge cases
# ============================================================
Write-Host "`n--- Part D: Edge cases ---" -ForegroundColor Yellow

# Test 8: User can unbind PageUp if they want
Write-Host "[Test 8] unbind-key PageUp works" -ForegroundColor Yellow
$resp5 = Send-TcpCommand -Session $SESSION -Command "unbind-key -T root PageUp"
Start-Sleep -Milliseconds 500
$keys2 = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
if ($keys2 -notmatch "(?i)root.*(PageUp|PPage).*copy-mode") {
    Write-Pass "PageUp successfully unbound from root table"
} else {
    Write-Fail "PageUp still in root table after unbind"
}

# Test 9: Re-bind PageUp to a custom command
Write-Host "[Test 9] rebind PageUp to custom command" -ForegroundColor Yellow
$resp6 = Send-TcpCommand -Session $SESSION -Command "bind-key -T root PageUp display-message test242"
Start-Sleep -Milliseconds 500
$keys3 = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
if ($keys3 -match "(?i)root.*(PageUp|PPage).*display-message") {
    Write-Pass "PageUp rebound to display-message in root table"
} else {
    Write-Fail "Rebind failed. Keys: $keys3"
}

# ============================================================
# PART E: Win32 TUI Visual Verification
# ============================================================
Write-Host "`n--- Part E: TUI Visual Verification ---" -ForegroundColor Yellow

$SESSION_TUI = "issue242_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 5

# Verify session is alive
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    # Test 9: TUI session responds to copy-mode -u via CLI
    Write-Host "[Test 9] TUI responds to copy-mode -u" -ForegroundColor Yellow
    & $PSMUX copy-mode -u -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Use direct TCP dump instead of Connect-Persistent for reliability
    $tuiPort = (Get-Content "$psmuxDir\$SESSION_TUI.port" -Raw).Trim()
    $tuiKey = (Get-Content "$psmuxDir\$SESSION_TUI.key" -Raw).Trim()
    $tuiTcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$tuiPort)
    $tuiTcp.NoDelay = $true
    $tuiStream = $tuiTcp.GetStream()
    $tuiWriter = [System.IO.StreamWriter]::new($tuiStream)
    $tuiReader = [System.IO.StreamReader]::new($tuiStream)
    $tuiWriter.Write("AUTH $tuiKey`n"); $tuiWriter.Flush()
    $null = $tuiReader.ReadLine()
    $tuiWriter.Write("dump-state`n"); $tuiWriter.Flush()
    $tuiStream.ReadTimeout = 3000
    $tuiBest = $null
    for ($j = 0; $j -lt 50; $j++) {
        try { $tl = $tuiReader.ReadLine() } catch { break }
        if ($null -eq $tl) { break }
        if ($tl -ne "NC" -and $tl.Length -gt 100) { $tuiBest = $tl }
        if ($tuiBest) { $tuiStream.ReadTimeout = 50 }
    }
    $tuiTcp.Close()
    
    if ($tuiBest -and ($tuiBest -match '"copy_mode"\s*:\s*true')) {
        Write-Pass "TUI entered CopyMode via copy-mode -u"
    } else {
        Write-Fail "TUI did not enter CopyMode"
    }
    
    # Exit copy mode
    & $PSMUX send-keys -t $SESSION_TUI Escape 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    # Test 10: list-keys from TUI session shows the PREFIX PageUp binding
    # (issue #488 tmux parity: no root PageUp default).
    Write-Host "[Test 10] TUI list-keys includes prefix PageUp" -ForegroundColor Yellow
    $tuiKeys = & $PSMUX list-keys -t $SESSION_TUI 2>&1 | Out-String
    if ($tuiKeys -match "(?i)prefix.*(PageUp|PPage)") {
        Write-Pass "TUI prefix table has PageUp binding (tmux parity)"
    } else {
        Write-Fail "TUI prefix table missing PageUp binding"
    }
} else {
    Write-Fail "TUI session failed to start"
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
