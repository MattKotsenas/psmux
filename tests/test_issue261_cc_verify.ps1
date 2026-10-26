# Issue #261: Control mode doesn't work with iTerm2 terminal on macOS
# TANGIBLE VERIFICATION: Does -CC attach actually emit DCS + framed responses?
# Reporter claims: "exits without any output" on echo pipe, "freezes" on interactive

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue261"
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

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed - cannot continue"
    exit 1
}
Write-Host "Session '$SESSION' is alive" -ForegroundColor Green

Write-Host "`n=== PART A: Reporter's exact scenario - echo pipe to -CC attach ===" -ForegroundColor Cyan

# === Test 1: echo list-sessions | psmux -CC attach -t $SESSION ===
Write-Host "`n[Test 1] echo list-sessions | psmux -CC attach -t $SESSION" -ForegroundColor Yellow
$stdoutFile = "$env:TEMP\cc261_test1_stdout.bin"
$stderrFile = "$env:TEMP\cc261_test1_stderr.bin"
$proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c","echo list-sessions | `"$PSMUX`" -CC attach -t $SESSION" `
    -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
    -PassThru
$proc.WaitForExit(10000)
if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }

$bytes = [System.IO.File]::ReadAllBytes($stdoutFile)
$stderr = Get-Content $stderrFile -Raw -EA SilentlyContinue

Write-Host "  Stdout bytes: $($bytes.Length)"
if ($stderr) { Write-Host "  Stderr: $stderr" }

if ($bytes.Length -eq 0) {
    Write-Fail "ZERO bytes of output - reporter's claim CONFIRMED (bug exists)"
} else {
    Write-Pass "Got $($bytes.Length) bytes of output - reporter's claim REFUTED"
}

# === Test 2: First bytes are DCS opener \x1bP1000p (no trailing newline) ===
Write-Host "`n[Test 2] DCS opener bytes" -ForegroundColor Yellow
# Real tmux (tmux/control.c control_start()) writes exactly 7 bytes for the
# DCS opener with NO trailing newline -- the next byte on the wire is '%'
# from the immediately-following "%begin ..." line (see
# src/server/connection.rs's own comment on this). This was previously
# expecting an 8th byte of 0x0A that tmux never sends, which made every
# real (correct) response -- e.g. "...70 25" ('%') -- look like a mismatch.
$dcsExpected = [byte[]]@(0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
if ($bytes.Length -ge 7) {
    $first7 = $bytes[0..6]
    $match = $true
    for ($i = 0; $i -lt 7; $i++) {
        if ($first7[$i] -ne $dcsExpected[$i]) { $match = $false; break }
    }
    if ($match) {
        Write-Pass "DCS opener \x1bP1000p found at byte 0"
    } else {
        $hex = ($first7 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Write-Fail "DCS opener not found. First 7 bytes: $hex"
    }
} else {
    Write-Fail "Not enough bytes for DCS check (got $($bytes.Length))"
}

# === Test 3: %begin/%end framing with session data ===
Write-Host "`n[Test 3] %begin/%end framing around list-sessions response" -ForegroundColor Yellow
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$hasBegin = $text -match '%begin'
$hasEnd = $text -match '%end'
$hasSessionName = $text -match $SESSION
if ($hasBegin -and $hasEnd -and $hasSessionName) {
    Write-Pass "%begin + session name '$SESSION' + %end found in response"
} else {
    Write-Fail "Missing framing. begin=$hasBegin end=$hasEnd session=$hasSessionName"
    Write-Host "  Raw text (safe chars): $(($text -replace '[^\x20-\x7E]','?'))"
}

# === Test 4: Reporter's exact syntax with -d flag ===
Write-Host "`n[Test 4] echo list-sessions | psmux -CC attach -d $SESSION (reporter used -d not -t)" -ForegroundColor Yellow
$stdoutFile4 = "$env:TEMP\cc261_test4_stdout.bin"
$proc4 = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c","echo list-sessions | `"$PSMUX`" -CC attach -d $SESSION" `
    -NoNewWindow -RedirectStandardOutput $stdoutFile4 -RedirectStandardError "$env:TEMP\cc261_test4_stderr.bin" `
    -PassThru
$proc4.WaitForExit(10000)
if (-not $proc4.HasExited) { $proc4.Kill(); $proc4.WaitForExit() }

$bytes4 = [System.IO.File]::ReadAllBytes($stdoutFile4)
if ($bytes4.Length -gt 0) {
    $text4 = [System.Text.Encoding]::UTF8.GetString($bytes4)
    if ($text4 -match '%begin' -and $text4 -match $SESSION) {
        Write-Pass "-d syntax: $($bytes4.Length) bytes, session data present"
    } else {
        Write-Fail "-d syntax: got $($bytes4.Length) bytes but no session data"
    }
} else {
    Write-Fail "-d syntax: ZERO bytes - this syntax may be broken"
}

Write-Host "`n=== PART B: Interactive -CC attach emits DCS immediately ===" -ForegroundColor Cyan

# === Test 5: -CC attach without stdin pipe emits DCS before blocking ===
Write-Host "`n[Test 5] -CC attach emits DCS bytes before blocking on stdin" -ForegroundColor Yellow
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PSMUX
$psi.Arguments = "-CC attach -t $SESSION"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardInput = $true
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)

# Wait up to 3 seconds for initial output
$ms = New-Object System.IO.MemoryStream
$buf = New-Object byte[] 4096
$got = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Milliseconds 100
    try {
        $task = $p.StandardOutput.BaseStream.ReadAsync($buf, 0, $buf.Length)
        if ($task.Wait(200)) {
            $n = $task.Result
            if ($n -gt 0) { $ms.Write($buf, 0, $n); $got = $true }
            if ($n -eq 0) { break }
        } else { if ($got) { break } }
    } catch { break }
}
$ccBytes = $ms.ToArray()
Write-Host "  Received $($ccBytes.Length) bytes within 3 seconds"

if ($ccBytes.Length -ge 7) {
    $first7cc = $ccBytes[0..6]
    $matchDCS = $true
    for ($i = 0; $i -lt 7; $i++) {
        if ($first7cc[$i] -ne $dcsExpected[$i]) { $matchDCS = $false; break }
    }
    if ($matchDCS) {
        Write-Pass "DCS emitted immediately on interactive -CC attach (NOT frozen)"
    } else {
        $hex = ($first7cc | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Write-Fail "First 7 bytes not DCS: $hex"
    }
} elseif ($ccBytes.Length -eq 0) {
    Write-Fail "ZERO bytes in 3 seconds - process froze before DCS (reporter's claim CONFIRMED)"
} else {
    Write-Fail "Only $($ccBytes.Length) bytes, expected at least 8 for DCS"
}

# Process should still be running (waiting on stdin)
if (-not $p.HasExited) {
    Write-Pass "Process still running (waiting for stdin commands - expected)"
} else {
    Write-Fail "Process exited prematurely with code $($p.ExitCode)"
}

# Send a command via stdin and read response
if (-not $p.HasExited) {
    Write-Host "`n[Test 6] Send list-windows via stdin to running -CC session" -ForegroundColor Yellow
    try {
        $p.StandardInput.WriteLine("list-windows")
        $p.StandardInput.Flush()
        
        # Read all response bytes with sufficient time for %begin and %end to arrive
        $ms2 = New-Object System.IO.MemoryStream
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        $gotEnd = $false
        while ($deadline.ElapsedMilliseconds -lt 5000 -and -not $gotEnd) {
            try {
                $task2 = $p.StandardOutput.BaseStream.ReadAsync($buf, 0, $buf.Length)
                if ($task2.Wait(500)) {
                    $n2 = $task2.Result
                    if ($n2 -gt 0) {
                        $ms2.Write($buf, 0, $n2)
                        $partial = [System.Text.Encoding]::UTF8.GetString($ms2.ToArray())
                        if ($partial -match '%end') { $gotEnd = $true }
                    } else { break }
                }
            } catch { break }
        }
        $cmdBytes = $ms2.ToArray()
        if ($cmdBytes.Length -gt 0) {
            $cmdText = [System.Text.Encoding]::UTF8.GetString($cmdBytes)
            if ($cmdText -match '%begin' -and $cmdText -match '%end') {
                Write-Pass "list-windows response framed in %begin/%end ($($cmdBytes.Length) bytes)"
            } elseif ($cmdText -match '%end' -and $cmdText -match 'pwsh|cmd') {
                # %begin may have been consumed by the prior read; response body + %end present
                Write-Pass "list-windows response received with %end + window data ($($cmdBytes.Length) bytes)"
            } else {
                Write-Fail "Response not properly framed: $(($cmdText -replace '[^\x20-\x7E]','?'))"
            }
        } else {
            Write-Fail "No response to list-windows command"
        }
    } catch {
        Write-Fail "Error sending command: $_"
    }
}

# Kill the interactive session
if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(3000) }

Write-Host "`n=== PART C: -C (single C, echo mode) parity ===" -ForegroundColor Cyan

# === Test 7: -C mode (echo, no DCS) ===
Write-Host "`n[Test 7] -C attach should NOT emit DCS (only -CC does)" -ForegroundColor Yellow
$stdoutFileC = "$env:TEMP\cc261_test7_stdout.bin"
$procC = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c","echo list-sessions | `"$PSMUX`" -C attach -t $SESSION" `
    -NoNewWindow -RedirectStandardOutput $stdoutFileC -RedirectStandardError "$env:TEMP\cc261_test7_stderr.bin" `
    -PassThru
$procC.WaitForExit(10000)
if (-not $procC.HasExited) { $procC.Kill(); $procC.WaitForExit() }

$bytesC = [System.IO.File]::ReadAllBytes($stdoutFileC)
if ($bytesC.Length -gt 0) {
    # -C should NOT start with DCS
    if ($bytesC[0] -eq 0x1B -and $bytesC.Length -ge 2 -and $bytesC[1] -eq 0x50) {
        Write-Fail "-C mode emits DCS (should only be for -CC)"
    } else {
        $textC = [System.Text.Encoding]::UTF8.GetString($bytesC)
        if ($textC -match '%begin') {
            Write-Pass "-C mode: no DCS, but %begin/%end framing present ($($bytesC.Length) bytes)"
        } else {
            Write-Fail "-C mode: got bytes but no %begin framing"
        }
    }
} else {
    Write-Fail "-C mode: ZERO bytes of output"
}

Write-Host "`n=== PART D: Raw TCP control mode dialog (simulating iTerm2) ===" -ForegroundColor Cyan

# === Test 8: Raw TCP CONTROL_NOECHO ===
Write-Host "`n[Test 8] Raw TCP: AUTH + CONTROL_NOECHO + list-sessions" -ForegroundColor Yellow
$portFile = "$psmuxDir\$SESSION.port"
$keyFile = "$psmuxDir\$SESSION.key"
if ((Test-Path $portFile) -and (Test-Path $keyFile)) {
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        
        # AUTH
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -eq "OK") { Write-Pass "TCP AUTH succeeded" }
        else { Write-Fail "TCP AUTH failed: $authResp" }
        
        # CONTROL_NOECHO
        $writer.Write("CONTROL_NOECHO`n"); $writer.Flush()
        Start-Sleep -Milliseconds 500
        
        # Read whatever the server sends after CONTROL_NOECHO
        $allBytes = New-Object System.IO.MemoryStream
        $tcpBuf = New-Object byte[] 4096
        $stream.ReadTimeout = 2000
        try {
            while ($true) {
                $n = $stream.Read($tcpBuf, 0, $tcpBuf.Length)
                if ($n -le 0) { break }
                $allBytes.Write($tcpBuf, 0, $n)
                $stream.ReadTimeout = 500
            }
        } catch {}
        
        $tcpBytes = $allBytes.ToArray()
        Write-Host "  Received $($tcpBytes.Length) bytes after CONTROL_NOECHO"
        
        if ($tcpBytes.Length -ge 7) {
            $tcpFirst7 = $tcpBytes[0..6]
            $tcpDCS = $true
            for ($i = 0; $i -lt 7; $i++) {
                if ($tcpFirst7[$i] -ne $dcsExpected[$i]) { $tcpDCS = $false; break }
            }
            if ($tcpDCS) {
                Write-Pass "TCP: DCS opener emitted after CONTROL_NOECHO"
            } else {
                $hex = ($tcpFirst7 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Fail "TCP: First 7 bytes not DCS: $hex"
            }
        } elseif ($tcpBytes.Length -eq 0) {
            Write-Fail "TCP: ZERO bytes after CONTROL_NOECHO (no DCS emitted)"
        } else {
            $hex = ($tcpBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            Write-Fail "TCP: Only $($tcpBytes.Length) bytes: $hex"
        }
        
        # Now send a command through the control channel
        $writer.Write("list-sessions`n"); $writer.Flush()
        Start-Sleep -Milliseconds 500
        
        $allBytes2 = New-Object System.IO.MemoryStream
        $stream.ReadTimeout = 2000
        try {
            while ($true) {
                $n = $stream.Read($tcpBuf, 0, $tcpBuf.Length)
                if ($n -le 0) { break }
                $allBytes2.Write($tcpBuf, 0, $n)
                $stream.ReadTimeout = 500
            }
        } catch {}
        
        $cmdResp = [System.Text.Encoding]::UTF8.GetString($allBytes2.ToArray())
        if ($cmdResp -match '%begin' -and $cmdResp -match '%end') {
            Write-Pass "TCP: list-sessions response properly framed in %begin/%end"
        } else {
            Write-Fail "TCP: list-sessions not properly framed: $cmdResp"
        }
        
        $tcp.Close()
    } catch {
        Write-Fail "TCP connection failed: $_"
    }
} else {
    Write-Fail "Port/key files not found"
}

# === Test 9: Only the documented bootstrap burst appears between DCS and
# the first command -- %window-add / %sessions-changed / %session-changed
# ARE expected here (src/control.rs emit_initial_state()): its own comment
# explains that without them "iTerm2 sits forever on -CC attach because it
# expects %session-changed / %window-add up front." What must NOT appear
# this early is anything gated on iTerm's acceptNotifications_ (e.g.
# %layout-change), which only opens after the kickoff command sequence.
Write-Host "`n[Test 9] Only the documented initial-state burst appears after DCS" -ForegroundColor Yellow
try {
    $tcp2 = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp2.NoDelay = $true; $tcp2.ReceiveTimeout = 5000
    $stream2 = $tcp2.GetStream()
    $writer2 = [System.IO.StreamWriter]::new($stream2)
    $reader2 = [System.IO.StreamReader]::new($stream2)
    
    $writer2.Write("AUTH $key`n"); $writer2.Flush()
    $null = $reader2.ReadLine()
    
    $writer2.Write("CONTROL_NOECHO`n"); $writer2.Flush()
    Start-Sleep -Milliseconds 500
    
    # Read all initial bytes
    $initBytes = New-Object System.IO.MemoryStream
    $stream2.ReadTimeout = 1000
    try {
        while ($true) {
            $n = $stream2.Read($tcpBuf, 0, $tcpBuf.Length)
            if ($n -le 0) { break }
            $initBytes.Write($tcpBuf, 0, $n)
            $stream2.ReadTimeout = 300
        }
    } catch {}
    
    $initText = [System.Text.Encoding]::UTF8.GetString($initBytes.ToArray())
    # %window-add / %sessions-changed / %session-changed are the documented,
    # required initial-state burst (see src/control.rs emit_initial_state).
    # Anything gated behind iTerm's acceptNotifications_ flag (e.g.
    # %layout-change) must NOT show up this early.
    $hasGatedNotif = $initText -match '%layout-change'
    if (-not $hasGatedNotif) {
        Write-Pass "No prematurely-gated notifications after DCS (matches real tmux)"
    } else {
        Write-Fail "Gated notification (%layout-change) leaked before acceptNotifications_ opens"
    }
    
    $tcp2.Close()
} catch {
    Write-Fail "TCP test 9 failed: $_"
}

Write-Host "`n=== PART E: Edge cases ===" -ForegroundColor Cyan

# === Test 10: -CC attach to non-existent session exits quickly ===
Write-Host "`n[Test 10] -CC attach to non-existent session" -ForegroundColor Yellow
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$procBad = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c","echo list-sessions | `"$PSMUX`" -CC attach -t nonexistent_session_999" `
    -NoNewWindow -RedirectStandardOutput "$env:TEMP\cc261_test10.bin" `
    -RedirectStandardError "$env:TEMP\cc261_test10_err.bin" `
    -PassThru
$procBad.WaitForExit(5000)
$sw.Stop()
if ($procBad.HasExited) {
    $elapsed = $sw.ElapsedMilliseconds
    if ($elapsed -lt 5000) {
        Write-Pass "Non-existent session exits in ${elapsed}ms (not hung)"
    } else {
        Write-Fail "Non-existent session took ${elapsed}ms to exit (too slow)"
    }
    $errText = Get-Content "$env:TEMP\cc261_test10_err.bin" -Raw -EA SilentlyContinue
    if ($errText) { Write-Host "  stderr: $($errText.Trim())" }
} else {
    $procBad.Kill()
    Write-Fail "Non-existent session HUNG (did not exit in 5s)"
}

# === Test 11: -CC attach with -d flag (detach others) ===
Write-Host "`n[Test 11] -CC attach -d (detach other clients)" -ForegroundColor Yellow
$psi11 = New-Object System.Diagnostics.ProcessStartInfo
$psi11.FileName = $PSMUX
$psi11.Arguments = "-CC attach -d -t $SESSION"
$psi11.UseShellExecute = $false
$psi11.RedirectStandardOutput = $true
$psi11.RedirectStandardInput = $true
$psi11.CreateNoWindow = $true
$p11 = [System.Diagnostics.Process]::Start($psi11)
Start-Sleep -Seconds 2

$ms11 = New-Object System.IO.MemoryStream
try {
    $task11 = $p11.StandardOutput.BaseStream.ReadAsync($buf, 0, $buf.Length)
    if ($task11.Wait(2000)) {
        $n11 = $task11.Result
        if ($n11 -gt 0) { $ms11.Write($buf, 0, $n11) }
    }
} catch {}
$bytes11 = $ms11.ToArray()
if ($bytes11.Length -ge 8 -and $bytes11[0] -eq 0x1B -and $bytes11[1] -eq 0x50) {
    Write-Pass "-CC attach -d emits DCS ($($bytes11.Length) bytes)"
} elseif ($bytes11.Length -eq 0) {
    Write-Fail "-CC attach -d produced ZERO bytes"
} else {
    Write-Fail "-CC attach -d: unexpected first bytes"
}
if (-not $p11.HasExited) { $p11.Kill(); $p11.WaitForExit(3000) }

Write-Host "`n=== PART F: Wire-level byte verification ===" -ForegroundColor Cyan

# === Test 12: Full hex dump of piped -CC response ===
Write-Host "`n[Test 12] Full wire dump analysis" -ForegroundColor Yellow
$hex = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
Write-Host "  Full hex ($($bytes.Length) bytes):"
# Print in 16-byte rows
for ($off = 0; $off -lt $bytes.Length; $off += 16) {
    $end = [Math]::Min($off + 15, $bytes.Length - 1)
    $hexRow = ($bytes[$off..$end] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $ascRow = ($bytes[$off..$end] | ForEach-Object { if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' } }) -join ''
    Write-Host ("  {0:X4}: {1,-48} {2}" -f $off, $hexRow, $ascRow)
}

# Check for ST closer at end
$lastTwo = if ($bytes.Length -ge 2) { $bytes[($bytes.Length-2)..($bytes.Length-1)] } else { @() }
if ($lastTwo.Count -eq 2 -and $lastTwo[0] -eq 0x1B -and $lastTwo[1] -eq 0x5C) {
    Write-Pass "ST closer (\x1b\\) found at end of response"
} else {
    $lastHex = if ($lastTwo.Count -ge 2) { '{0:X2} {1:X2}' -f $lastTwo[0],$lastTwo[1] } else { "N/A" }
    Write-Host "  Last 2 bytes: $lastHex (Note: ST may only be sent on clean session exit, not after each command)" -ForegroundColor DarkYellow
}

Write-Host "`n=== PART G: Win32 TUI Visual Verification ===" -ForegroundColor Cyan

# Launch a REAL psmux window and verify -CC works against it
$SESSION_TUI = "issue261_tui_proof"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Write-Host "`n[Test 13] Launch real TUI window" -ForegroundColor Yellow
$tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI session '$SESSION_TUI' is alive"
} else {
    Write-Fail "TUI session creation failed"
}

# Split window via CLI to prove TUI is functional
Write-Host "`n[Test 14] Drive TUI via CLI + verify -CC attach against live TUI" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Seconds 1
$wins = (& $PSMUX display-message -t $SESSION_TUI -p '#{session_windows}' 2>&1).Trim()
if ($wins -eq "2") { Write-Pass "TUI: new-window created (2 windows)" }
else { Write-Fail "TUI: expected 2 windows, got $wins" }

# Now -CC attach to the live TUI session
$stdoutFileTUI = "$env:TEMP\cc261_tui_cc.bin"
$procTUI = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c","echo list-windows | `"$PSMUX`" -CC attach -t $SESSION_TUI" `
    -NoNewWindow -RedirectStandardOutput $stdoutFileTUI -RedirectStandardError "$env:TEMP\cc261_tui_cc_err.bin" `
    -PassThru
$procTUI.WaitForExit(10000)
if (-not $procTUI.HasExited) { $procTUI.Kill(); $procTUI.WaitForExit() }

$bytesTUI = [System.IO.File]::ReadAllBytes($stdoutFileTUI)
if ($bytesTUI.Length -gt 0) {
    $textTUI = [System.Text.Encoding]::UTF8.GetString($bytesTUI)
    if ($bytesTUI[0] -eq 0x1B -and $bytesTUI[1] -eq 0x50 -and $textTUI -match '%begin') {
        Write-Pass "TUI: -CC attach to live TUI emits DCS + framed response ($($bytesTUI.Length) bytes)"
    } else {
        Write-Fail "TUI: -CC attach response malformed"
    }
} else {
    Write-Fail "TUI: -CC attach produced ZERO bytes against live TUI"
}

# Cleanup TUI
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Write-Host ""
Cleanup
Remove-Item "$env:TEMP\cc261_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  VERDICT: Issue #261 fix is WORKING. The reporter's claim that -CC attach" -ForegroundColor Green
    Write-Host "  produces no output is NOT reproducible on this build (commit 0f08d18)." -ForegroundColor Green
    Write-Host "  DCS opener, %begin/%end framing, and command responses all function correctly." -ForegroundColor Green
} else {
    Write-Host "`n  VERDICT: Issue #261 has REMAINING PROBLEMS." -ForegroundColor Red
}

exit $script:TestsFailed
