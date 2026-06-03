# Issue #325: All sessions share the same session ID ($0) / list-panes -a broken
# Tests that:
# 1. Each session gets a unique session_id ($N)
# 2. list-panes -a returns panes from ALL sessions
# 3. list-windows -a returns windows from ALL sessions
# 4. Format variables expand correctly in cross-session queries

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    @("i325_a", "i325_b", "i325_c", "i325_tui") | ForEach-Object {
        & $PSMUX kill-session -t $_ 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 1
    @("i325_a", "i325_b", "i325_c", "i325_tui") | ForEach-Object {
        Remove-Item "$psmuxDir\$_.*" -Force -EA SilentlyContinue
    }
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
    $stream.ReadTimeout = 5000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# === SETUP ===
Cleanup
Start-Sleep -Seconds 1

Write-Host "`n=== Issue #325: Session ID Uniqueness & Cross-Session Listing ===" -ForegroundColor Cyan

# Create 3 sessions
& $PSMUX new-session -d -s i325_a 2>&1 | Out-Null
if (Wait-Session "i325_a") { Write-Pass "i325_a created" }
else { Write-Fail "i325_a creation failed"; exit 1 }

& $PSMUX new-session -d -s i325_b 2>&1 | Out-Null
if (Wait-Session "i325_b") { Write-Pass "i325_b created" }
else { Write-Fail "i325_b creation failed"; exit 1 }

& $PSMUX new-session -d -s i325_c 2>&1 | Out-Null
if (Wait-Session "i325_c") { Write-Pass "i325_c created" }
else { Write-Fail "i325_c creation failed"; exit 1 }

# ================================================================
# PART A: Session ID Uniqueness
# ================================================================
Write-Host "`n--- Part A: Session ID Uniqueness ---" -ForegroundColor Yellow

Write-Host "`n[Test 1] Each session has a unique session_id" -ForegroundColor Yellow
$id_a = (& $PSMUX display-message -t i325_a -p '#{session_id}' 2>&1 | Out-String).Trim()
$id_b = (& $PSMUX display-message -t i325_b -p '#{session_id}' 2>&1 | Out-String).Trim()
$id_c = (& $PSMUX display-message -t i325_c -p '#{session_id}' 2>&1 | Out-String).Trim()

Write-Host "    i325_a=$id_a, i325_b=$id_b, i325_c=$id_c"
if ($id_a -match '^\$\d+$') { Write-Pass "i325_a has valid session_id format: $id_a" }
else { Write-Fail "i325_a has invalid session_id: '$id_a'" }

if ($id_b -match '^\$\d+$') { Write-Pass "i325_b has valid session_id format: $id_b" }
else { Write-Fail "i325_b has invalid session_id: '$id_b'" }

if ($id_c -match '^\$\d+$') { Write-Pass "i325_c has valid session_id format: $id_c" }
else { Write-Fail "i325_c has invalid session_id: '$id_c'" }

if ($id_a -ne $id_b -and $id_b -ne $id_c -and $id_a -ne $id_c) {
    Write-Pass "All session_ids are unique"
} else {
    Write-Fail "BUG: Session IDs are NOT unique: $id_a, $id_b, $id_c"
}

Write-Host "`n[Test 2] list-sessions -F shows unique session_ids" -ForegroundColor Yellow
$lsOutput = & $PSMUX list-sessions -F '#{session_id} #{session_name} #{session_windows}' 2>&1 | Out-String
$lines = $lsOutput.Trim().Split("`n") | Where-Object { $_ -match "i325_" }
$ids = $lines | ForEach-Object { ($_ -split ' ')[0] }
Write-Host "    Output: $($lines -join ' | ')"

if ($ids.Count -ge 3) { Write-Pass "list-sessions returned $($ids.Count) sessions with i325_ prefix" }
else { Write-Fail "Expected 3 sessions, got $($ids.Count)" }

$uniqueIds = $ids | Select-Object -Unique
if ($uniqueIds.Count -eq $ids.Count) { Write-Pass "All session_ids in list-sessions are unique" }
else { Write-Fail "BUG: Duplicate session_ids in list-sessions output" }

# ================================================================
# PART B: list-panes -a (cross-session)
# ================================================================
Write-Host "`n--- Part B: list-panes -a Cross-Session ---" -ForegroundColor Yellow

Write-Host "`n[Test 3] list-panes -a returns panes from ALL sessions" -ForegroundColor Yellow
$lpOutput = & $PSMUX list-panes -a 2>&1 | Out-String
$lpLines = $lpOutput.Trim().Split("`n") | Where-Object { $_ -match "i325_" }
Write-Host "    Lines: $($lpLines.Count)"

$sessionsInOutput = @{}
foreach ($line in $lpLines) {
    if ($line -match '^(i325_\w+):') { $sessionsInOutput[$Matches[1]] = $true }
}

if ($sessionsInOutput.ContainsKey("i325_a")) { Write-Pass "list-panes -a contains i325_a" }
else { Write-Fail "list-panes -a missing i325_a" }
if ($sessionsInOutput.ContainsKey("i325_b")) { Write-Pass "list-panes -a contains i325_b" }
else { Write-Fail "list-panes -a missing i325_b" }
if ($sessionsInOutput.ContainsKey("i325_c")) { Write-Pass "list-panes -a contains i325_c" }
else { Write-Fail "list-panes -a missing i325_c" }

Write-Host "`n[Test 4] list-panes -a -F with format string" -ForegroundColor Yellow
$lpFmt = & $PSMUX list-panes -a -F '#{session_id}:#{window_id}.#{pane_id} #{pane_current_command}' 2>&1 | Out-String
$lpFmtLines = $lpFmt.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }
Write-Host "    Lines: $($lpFmtLines.Count)"

if ($lpFmtLines.Count -ge 3) { Write-Pass "list-panes -a -F returned $($lpFmtLines.Count) panes" }
else { Write-Fail "Expected >= 3 panes, got $($lpFmtLines.Count)" }

# Verify session_ids in list-panes are unique per session
$paneSessionIds = $lpFmtLines | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique
if ($paneSessionIds.Count -ge 3) { Write-Pass "list-panes -a shows $($paneSessionIds.Count) unique session_ids" }
else { Write-Fail "Expected >= 3 unique session_ids in list-panes -a" }

# ================================================================
# PART C: list-windows -a (cross-session)
# ================================================================
Write-Host "`n--- Part C: list-windows -a Cross-Session ---" -ForegroundColor Yellow

# Add a second window to i325_b to test multi-window
& $PSMUX new-window -t i325_b 2>&1 | Out-Null
Start-Sleep -Seconds 1

Write-Host "`n[Test 5] list-windows -a returns windows from ALL sessions" -ForegroundColor Yellow
$lwOutput = & $PSMUX list-windows -a 2>&1 | Out-String
$lwLines = $lwOutput.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }
Write-Host "    Lines: $($lwLines.Count)"

if ($lwLines.Count -ge 4) { Write-Pass "list-windows -a returned $($lwLines.Count) windows (3 sessions, 1 has 2 windows)" }
else { Write-Fail "Expected >= 4 windows, got $($lwLines.Count)" }

Write-Host "`n[Test 6] list-windows -a -F with format string" -ForegroundColor Yellow
$lwFmt = & $PSMUX list-windows -a -F '#{session_name}:#{window_index} #{window_panes}' 2>&1 | Out-String
$lwFmtLines = $lwFmt.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }
Write-Host "    Output:"
foreach ($l in $lwFmtLines) { Write-Host "      $l" }

$sessionsInWin = @{}
foreach ($l in $lwFmtLines) {
    if ($l -match '^(i325_\w+):') { $sessionsInWin[$Matches[1]] = $true }
}
if ($sessionsInWin.Count -ge 3) { Write-Pass "list-windows -a shows windows from $($sessionsInWin.Count) sessions" }
else { Write-Fail "Expected windows from 3 sessions, got $($sessionsInWin.Count)" }

# ================================================================
# PART D: list-panes -a with split panes
# ================================================================
Write-Host "`n--- Part D: list-panes -a with Split Panes ---" -ForegroundColor Yellow

# Split a pane in i325_c
& $PSMUX split-window -t i325_c 2>&1 | Out-Null
Start-Sleep -Seconds 1

Write-Host "`n[Test 7] list-panes -a with split pane shows all panes" -ForegroundColor Yellow
$lpAll = & $PSMUX list-panes -a 2>&1 | Out-String
$lpAllLines = $lpAll.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }

$cPanes = $lpAllLines | Where-Object { $_ -match "^i325_c:" }
if ($cPanes.Count -ge 2) { Write-Pass "i325_c shows $($cPanes.Count) panes (split)" }
else { Write-Fail "i325_c expected >= 2 panes, got $($cPanes.Count)" }

$totalPanes = $lpAllLines.Count
if ($totalPanes -ge 5) { Write-Pass "Total panes across all sessions: $totalPanes (expected >= 5)" }
else { Write-Fail "Expected >= 5 total panes, got $totalPanes" }

# ================================================================
# PART E: TCP Server Path
# ================================================================
Write-Host "`n--- Part E: TCP Server Path ---" -ForegroundColor Yellow

Write-Host "`n[Test 8] TCP list-panes -s returns panes for each session" -ForegroundColor Yellow
foreach ($sess in @("i325_a", "i325_b", "i325_c")) {
    $resp = Send-TcpCommand -Session $sess -Command "list-panes -s"
    if ($resp -and $resp -match "${sess}:") { Write-Pass "TCP $sess list-panes -s returns correct session prefix" }
    else { Write-Fail "TCP $sess list-panes -s unexpected: '$resp'" }
}

Write-Host "`n[Test 9] TCP session_id is unique per session" -ForegroundColor Yellow
$tcpIds = @()
foreach ($sess in @("i325_a", "i325_b", "i325_c")) {
    $resp = Send-TcpCommand -Session $sess -Command "display-message -p #{session_id}"
    $tcpIds += $resp
    Write-Host "    $sess session_id via TCP: $resp"
}
$uniqueTcpIds = $tcpIds | Select-Object -Unique
if ($uniqueTcpIds.Count -eq 3) { Write-Pass "All 3 TCP session_ids are unique" }
else { Write-Fail "TCP session_ids not unique: $($tcpIds -join ', ')" }

# ================================================================
# PART F: Edge Cases
# ================================================================
Write-Host "`n--- Part F: Edge Cases ---" -ForegroundColor Yellow

Write-Host "`n[Test 10] list-panes without -a only shows target session" -ForegroundColor Yellow
$lpSingle = & $PSMUX list-panes -t i325_a 2>&1 | Out-String
$singleLines = $lpSingle.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }
$hasBorC = ($lpSingle -match "i325_b" -or $lpSingle -match "i325_c")
if (-not $hasBorC) { Write-Pass "list-panes without -a only shows target session" }
else { Write-Fail "list-panes without -a leaked other sessions" }

Write-Host "`n[Test 11] list-windows without -a only shows target session" -ForegroundColor Yellow
$lwSingle = & $PSMUX list-windows -t i325_a 2>&1 | Out-String
$hasOther = ($lwSingle -match "i325_b" -or $lwSingle -match "i325_c")
if (-not $hasOther) { Write-Pass "list-windows without -a only shows target session" }
else { Write-Fail "list-windows without -a leaked other sessions" }

# ================================================================
# PART G: Win32 TUI Visual Verification
# ================================================================
Write-Host "`n--- Part G: Win32 TUI Visual Verification ---" -ForegroundColor Yellow

Write-Host "`n[Test 12] TUI visual proof" -ForegroundColor Yellow
$tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","i325_tui" -PassThru
Start-Sleep -Seconds 4

# Verify TUI session is functional
& $PSMUX has-session -t i325_tui 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI session i325_tui is alive" }
else { Write-Fail "TUI session i325_tui failed to start" }

# list-panes -a from TUI session should include both TUI and detached sessions
$tuiPanes = & $PSMUX list-panes -a 2>&1 | Out-String
$tuiPaneLines = $tuiPanes.Trim().Split("`n") | Where-Object { $_.Trim() -ne "" }
if ($tuiPaneLines.Count -ge 6) { Write-Pass "TUI: list-panes -a shows $($tuiPaneLines.Count) panes (including TUI + detached)" }
else { Write-Fail "TUI: list-panes -a shows $($tuiPaneLines.Count) panes (expected >= 6)" }

# Verify TUI session has unique session_id
$tuiId = (& $PSMUX display-message -t i325_tui -p '#{session_id}' 2>&1 | Out-String).Trim()
$existingIds = @($id_a, $id_b, $id_c)
if ($tuiId -notin $existingIds) { Write-Pass "TUI session has unique session_id: $tuiId" }
else { Write-Fail "TUI session_id $tuiId collides with existing: $($existingIds -join ',')" }

# Cleanup TUI
& $PSMUX kill-session -t i325_tui 2>&1 | Out-Null
try { Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
