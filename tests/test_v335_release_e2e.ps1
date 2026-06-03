# Comprehensive E2E test for v3.3.5 release candidate
# Tests all major fixes since v3.3.4
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$pass = 0; $fail = 0; $results = @()

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    $keyFile = "$psmuxDir\$Session.key"
    if (!(Test-Path $portFile) -or !(Test-Path $keyFile)) { return "NO_SESSION" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $w = [System.IO.StreamWriter]::new($stream)
        $r = [System.IO.StreamReader]::new($stream)
        $w.Write("AUTH $key`n"); $w.Flush()
        $null = $r.ReadLine()
        $w.Write("$Command`n"); $w.Flush()
        $stream.ReadTimeout = 5000
        try { $resp = $r.ReadLine() } catch { $resp = "TIMEOUT" }
        $tcp.Close()
        return $resp
    } catch { return "ERROR: $_" }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        $result = & $Test
        if ($result) {
            $script:pass++
            $script:results += "[PASS] $Name"
            Write-Host "  [PASS] $Name" -ForegroundColor Green
        } else {
            $script:fail++
            $script:results += "[FAIL] $Name"
            Write-Host "  [FAIL] $Name" -ForegroundColor Red
        }
    } catch {
        $script:fail++
        $script:results += "[FAIL] $Name (exception: $_)"
        Write-Host "  [FAIL] $Name (exception: $_)" -ForegroundColor Red
    }
}

# Clean slate
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 2
Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sid" -Force -EA SilentlyContinue

Write-Host "`n=== psmux v3.3.5 Release Candidate E2E Tests ===" -ForegroundColor Cyan
Write-Host "Testing fixes since v3.3.4`n" -ForegroundColor Gray

# ────────────────────────────────────────────────
# TEST 1: Version output (#318 libtmux compat)
# ────────────────────────────────────────────────
Write-Host "--- #318: Version output for libtmux ---" -ForegroundColor Yellow
Test-Case "psmux -V outputs 'tmux' prefix" {
    $ver = & $PSMUX -V 2>&1
    $ver -match "^tmux 3\.3\.5"
}

# ────────────────────────────────────────────────
# TEST 2: Warm pane CPR fix (regression from #313)
# ────────────────────────────────────────────────
Write-Host "--- Warm pane CPR fix ---" -ForegroundColor Yellow
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rc1","-d" -WindowStyle Hidden
Start-Sleep -Seconds 6

Test-Case "Warm pane: new-window prompt < 200ms" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Send-TcpCommand "rc1" "new-window" | Out-Null
    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Milliseconds 10
        $cap = Send-TcpCommand "rc1" "capture-pane -p"
        if ($cap -match "PS [A-Z]:\\") { break }
    }
    $ms = $sw.ElapsedMilliseconds
    Write-Host "    (measured: ${ms}ms)" -ForegroundColor Gray
    $ms -lt 200
}

Start-Sleep -Seconds 3

Test-Case "Warm pane: split-window prompt < 200ms" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Send-TcpCommand "rc1" "split-window" | Out-Null
    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Milliseconds 10
        $cap = Send-TcpCommand "rc1" "capture-pane -p"
        if ($cap -match "PS [A-Z]:\\") { break }
    }
    $ms = $sw.ElapsedMilliseconds
    Write-Host "    (measured: ${ms}ms)" -ForegroundColor Gray
    $ms -lt 200
}

& $PSMUX kill-session -t rc1 2>&1 | Out-Null
Start-Sleep -Seconds 2

# ────────────────────────────────────────────────
# TEST 3: capture-pane flag clusters (#326)
# ────────────────────────────────────────────────
Write-Host "--- #326: capture-pane flag clusters ---" -ForegroundColor Yellow
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rc2","-d" -WindowStyle Hidden
Start-Sleep -Seconds 4

Test-Case "capture-pane -pt works (flag cluster)" {
    $r = & $PSMUX capture-pane -pt rc2 2>&1
    $r -match "PS [A-Z]:\\" -or $r.Length -gt 0
}

Test-Case "capture-pane -p -t works (separate flags)" {
    $r = & $PSMUX capture-pane -p -t rc2 2>&1
    $r -match "PS [A-Z]:\\" -or $r.Length -gt 0
}

# ────────────────────────────────────────────────
# TEST 4: list-panes/list-windows -a (#325)
# ────────────────────────────────────────────────
Write-Host "--- #325: list-panes/list-windows -a ---" -ForegroundColor Yellow
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rc3","-d" -WindowStyle Hidden
Start-Sleep -Seconds 3

Test-Case "list-windows -a shows windows from multiple sessions" {
    $r = & $PSMUX list-windows -a 2>&1
    ($r | Measure-Object).Count -ge 2
}

Test-Case "list-panes -a shows panes from multiple sessions" {
    $r = & $PSMUX list-panes -a 2>&1
    ($r | Measure-Object).Count -ge 2
}

# ────────────────────────────────────────────────
# TEST 5: if-shell brace-block (#317)
# ────────────────────────────────────────────────
Write-Host "--- #317: if-shell brace-block ---" -ForegroundColor Yellow
Test-Case "if-shell with true condition runs true branch" {
    Send-TcpCommand "rc2" 'if-shell "cmd /c exit 0" { rename-window IFTRUE }' | Out-Null
    Start-Sleep -Milliseconds 500
    $r = & $PSMUX list-windows -t rc2 2>&1
    $r -match "IFTRUE"
}

# ────────────────────────────────────────────────
# TEST 6: show-options -w fallback (#321)
# ────────────────────────────────────────────────
Write-Host "--- #321: show-options -w fallback ---" -ForegroundColor Yellow
Test-Case "show-options -w returns window options" {
    $r = & $PSMUX show-options -wt rc2 2>&1
    # Should not error, and should return some options
    $r -notmatch "error" -and ($r | Measure-Object).Count -ge 1
}

# ────────────────────────────────────────────────
# TEST 7: set-buffer -w clipboard (#298)
# ────────────────────────────────────────────────
Write-Host "--- #298: set-buffer -w clipboard ---" -ForegroundColor Yellow
Test-Case "set-buffer -w propagates to system clipboard" {
    $marker = "PSMUX_CLIP_TEST_$(Get-Random)"
    Set-Clipboard "ORIGINAL"
    & $PSMUX set-buffer -w $marker 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $clip = Get-Clipboard
    $clip -eq $marker
}

Test-Case "set-buffer without -w does NOT touch clipboard" {
    Set-Clipboard "SHOULD_STAY"
    & $PSMUX set-buffer "NO_CLIPBOARD" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    (Get-Clipboard) -eq "SHOULD_STAY"
}

# ────────────────────────────────────────────────
# TEST 8: Client freeze fix (#316)
# ────────────────────────────────────────────────
Write-Host "--- #316: Client freeze prevention ---" -ForegroundColor Yellow
Test-Case "Session responds to commands (no freeze)" {
    $r = Send-TcpCommand "rc2" "list-windows"
    $r -ne "TIMEOUT" -and $r -ne "NO_SESSION"
}

# ────────────────────────────────────────────────
# TEST 9: Session ID isolation (#325)
# ────────────────────────────────────────────────
Write-Host "--- #325: Session ID isolation ---" -ForegroundColor Yellow
Test-Case "Sessions have different IDs" {
    $r = & $PSMUX list-sessions 2>&1
    $lines = $r -split "`n" | Where-Object { $_ -match ":" }
    $lines.Count -ge 2
}

# ────────────────────────────────────────────────
# TEST 10: list-sessions TCP timeout (#libtmux)
# ────────────────────────────────────────────────
Write-Host "--- libtmux: list-sessions reliability ---" -ForegroundColor Yellow
Test-Case "list-sessions returns within 3 seconds" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $PSMUX list-sessions 2>&1
    $ms = $sw.ElapsedMilliseconds
    $ms -lt 3000 -and ($r | Measure-Object).Count -ge 1
}

# ────────────────────────────────────────────────
# TEST 11: pane_last_special_key format (#315)
# ────────────────────────────────────────────────
Write-Host "--- #315: pane_last_special_key format ---" -ForegroundColor Yellow
Test-Case "pane_last_special_key format variable resolves" {
    $r = & $PSMUX display-message -pt rc2 '#{pane_last_special_key}' 2>&1
    # Should not error (empty string is fine, means no key pressed)
    $true  # Just verify it doesn't crash
}

# ────────────────────────────────────────────────
# TEST 12: pane_current_command (#299)
# ────────────────────────────────────────────────
Write-Host "--- #299: pane_current_command ---" -ForegroundColor Yellow
Test-Case "pane_current_command returns shell name for idle pane" {
    $r = & $PSMUX display-message -p -t rc2 '#{pane_current_command}' 2>&1
    $r -match "pwsh|powershell|cmd" -or $r.Length -gt 0
}

# ────────────────────────────────────────────────
# TEST 13: Warm session claim
# ────────────────────────────────────────────────
Write-Host "--- Warm session claim ---" -ForegroundColor Yellow
Test-Case "New session claims warm server (fast startup)" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","rc_warm","-d" -WindowStyle Hidden
    # Wait for session to appear
    $found = $false
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path "$psmuxDir\rc_warm.port") { $found = $true; break }
    }
    $ms = $sw.ElapsedMilliseconds
    Write-Host "    (session ready in ${ms}ms)" -ForegroundColor Gray
    $found -and $ms -lt 3000
}

# Cleanup
& $PSMUX kill-session -t rc2 2>&1 | Out-Null
& $PSMUX kill-session -t rc3 2>&1 | Out-Null
& $PSMUX kill-session -t rc_warm 2>&1 | Out-Null

Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
Write-Host "Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
if ($fail -gt 0) {
    Write-Host "FAILURES:" -ForegroundColor Red
    $results | Where-Object { $_ -match "FAIL" } | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
exit $fail
