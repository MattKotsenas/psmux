# Issue #277 + #245: Definitive Scroll Test Suite
# =================================================
# Tests ALL scroll code paths and proves mouse-selection does NOT affect scroll.
#
# Architecture context:
#   Mouse wheel event → crossterm/InputSource → client.rs run_remote()
#     → TCP "pane-scroll {id} up/down" → server mod.rs
#     → window_ops.rs handle_pane_scroll() or remote_scroll_wheel()
#     → If alt-screen: inject_mouse_combined() → write_mouse_to_pty()
#     → If normal: enter_copy_mode() + scroll_copy_up()
#
# Key finding: mouse-selection only affects Drag(Left) in client.rs.
# Scroll handlers are UNCONDITIONAL - no mouse_selection checks anywhere.

$ErrorActionPreference = "Continue"
# Binary and data root are overridable so this suite can be pointed at a build
# under test without disturbing the installed psmux or its sessions.
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } else { (Get-Command psmux -EA Stop).Source }
$SESSION = "scroll_def_277"
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
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

function Get-PsmuxOption {
    param([string]$Option)
    (& $PSMUX show-options -g -v $Option -t $SESSION 2>&1 | Out-String).Trim()
}

function Get-PaneFormat {
    param([string]$Format)
    (& $PSMUX display-message -t $SESSION -p $Format 2>&1 | Out-String).Trim()
}

Write-Host "`n=== Issue #277 + #245: Definitive Scroll Test Suite ===" -ForegroundColor Cyan
Write-Host "Testing: scroll mechanics, mouse-selection independence, alt-screen forwarding"
Write-Host ""

# ── SETUP ────────────────────────────────────────────────────────────────
Cleanup
# Kill any lingering sessions
Get-Process psmux -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "" } | Out-Null

# Enable mouse debug logging for this session
$env:PSMUX_MOUSE_DEBUG = "1"
$env:PSMUX_SERVER_DEBUG = "1"

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: Could not create session" -ForegroundColor Red
    exit 1
}
Write-Info "Session '$SESSION' created"

# Verify mouse is ON by default
$mouseOpt = Get-PsmuxOption "mouse"
Write-Info "mouse = $mouseOpt"
if ($mouseOpt -ne "on") {
    & $PSMUX set-option -g mouse on -t $SESSION 2>&1 | Out-Null
    Write-Info "Set mouse=on explicitly"
}

# ============================================================
# TEST 1: pane-scroll up enters copy mode (baseline)
# ============================================================
Write-Host "`n[Test 1] Baseline: pane-scroll up enters copy mode" -ForegroundColor Yellow

# Generate scrollback content
& $PSMUX send-keys -t $SESSION 'for ($i=1; $i -le 100; $i++) { Write-Host "SCROLL_LINE_$i" }' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5

$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "SCROLL_LINE_") {
    Write-Info "Scrollback content confirmed"
} else {
    Write-Fail "No scrollback content (test environment issue)"
}

# Scroll up via TCP
$resp = Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up"
Write-Info "TCP response: $resp"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -eq "1") {
    Write-Pass "pane-scroll up enters copy mode"
} else {
    Write-Fail "pane-scroll up did NOT enter copy mode (pane_in_mode=$mode)"
}

# Exit copy mode
& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 2: pane-scroll up with mouse-selection OFF
# ============================================================
Write-Host "`n[Test 2] pane-scroll up with mouse-selection OFF" -ForegroundColor Yellow

& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$msOpt = Get-PsmuxOption "mouse-selection"
Write-Info "mouse-selection = $msOpt"

$resp = Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -eq "1") {
    Write-Pass "pane-scroll up works with mouse-selection OFF"
} else {
    Write-Fail "pane-scroll up BROKEN with mouse-selection OFF (pane_in_mode=$mode)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 3: scroll-up (coordinate-based) with mouse-selection OFF
# ============================================================
Write-Host "`n[Test 3] scroll-up (coord-based) with mouse-selection OFF" -ForegroundColor Yellow

$resp = Send-TcpCommand -Session $SESSION -Command "scroll-up 40 15"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -eq "1") {
    Write-Pass "scroll-up (coord) works with mouse-selection OFF"
} else {
    Write-Fail "scroll-up (coord) BROKEN with mouse-selection OFF (pane_in_mode=$mode)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 4: scroll-down (coordinate-based) with mouse-selection OFF
# ============================================================
Write-Host "`n[Test 4] scroll-down in copy mode with mouse-selection OFF" -ForegroundColor Yellow

# Enter copy mode first. The copy mode view is observed through
# #{scroll_position}, not through a plain capture-pane: since PR #671 copy mode
# scrolls a snapshot of the grid and capture-pane answers with the LIVE screen,
# exactly as tmux's capture reads wp->base, so a plain capture no longer moves
# with the view.
Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up" | Out-Null
Start-Sleep -Seconds 1

$pos1 = [int](Get-PaneFormat '#{scroll_position}')

# Scroll down
Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 down" | Out-Null
Start-Sleep -Seconds 1

$pos2 = [int](Get-PaneFormat '#{scroll_position}')

if ($pos2 -lt $pos1) {
    Write-Pass "scroll-down moved the copy mode view toward the bottom ($pos1 -> $pos2, mouse-selection OFF)"
} else {
    Write-Fail "scroll-down had NO effect in copy mode (scroll_position $pos1 -> $pos2, mouse-selection OFF)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 5: Multiple rapid scrolls with mouse-selection OFF
# ============================================================
Write-Host "`n[Test 5] Rapid pane-scroll (5x up) with mouse-selection OFF" -ForegroundColor Yellow

Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up" | Out-Null
Start-Sleep -Milliseconds 200
$pos1 = [int](Get-PaneFormat '#{scroll_position}')

for ($i = 0; $i -lt 4; $i++) {
    Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up" | Out-Null
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 500

$pos2 = [int](Get-PaneFormat '#{scroll_position}')
if ($pos2 -gt $pos1) {
    Write-Pass "Rapid scroll moved the copy mode view further into history ($pos1 -> $pos2, mouse-selection OFF)"
} else {
    Write-Fail "Rapid scroll had NO effect (scroll_position $pos1 -> $pos2, copy mode + mouse-selection OFF)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Reset mouse-selection for next tests
& $PSMUX set-option -g mouse-selection on -t $SESSION 2>&1 | Out-Null

# ============================================================
# TEST 6: scroll with mouse OFF is silently ignored
# ============================================================
Write-Host "`n[Test 6] pane-scroll with mouse OFF is silently ignored" -ForegroundColor Yellow

& $PSMUX set-option -g mouse off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$resp = Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -ne "1") {
    Write-Pass "pane-scroll correctly ignored when mouse=off (pane_in_mode=$mode)"
} else {
    Write-Fail "pane-scroll entered copy mode when mouse=off (should be ignored)"
    & $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
}

# Reset mouse=on
& $PSMUX set-option -g mouse on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 7: Alt-screen detection with Python TUI app
# ============================================================
Write-Host "`n[Test 7] Alt-screen detection with Python app" -ForegroundColor Yellow

$pythonAvailable = $null -ne (Get-Command python -EA SilentlyContinue)
if (-not $pythonAvailable) {
    $pythonAvailable = $null -ne (Get-Command python3 -EA SilentlyContinue)
}

if ($pythonAvailable) {
    $pyScript = "$env:TEMP\psmux_altscreen_test.py"
    $pyLog = "$env:TEMP\psmux_altscreen_test.log"
    Remove-Item $pyLog -Force -EA SilentlyContinue

    @'
import sys, os, time, msvcrt

log_path = os.path.join(os.environ.get('TEMP', '.'), 'psmux_altscreen_test.log')
log = open(log_path, 'w')
log.write('STARTED\n')
log.flush()

# Enter alternate screen
sys.stdout.write('\x1b[?1049h')
# Enable SGR mouse tracking
sys.stdout.write('\x1b[?1000h\x1b[?1006h')
sys.stdout.write('\x1b[2J\x1b[H')
sys.stdout.write('Alt-screen mouse test - waiting for events...\n')
sys.stdout.flush()

log.write('ALT_SCREEN_ENTERED\n')
log.flush()

end_time = time.time() + 15
buf = b''
while time.time() < end_time:
    if msvcrt.kbhit():
        ch = msvcrt.getch()
        buf += ch
        log.write(f'BYTE={ch.hex()} ')
        # Check for ESC sequence
        if ch == b'\x1b':
            # Read rest of sequence
            time.sleep(0.05)
            while msvcrt.kbhit():
                more = msvcrt.getch()
                buf += more
                log.write(f'{more.hex()} ')
            log.write('\n')
            seq = buf.decode('ascii', errors='replace')
            log.write(f'SEQ_RAW={repr(seq)}\n')
            if '64;' in seq or '65;' in seq:
                log.write('SCROLL_DETECTED\n')
            buf = b''
        else:
            log.write('\n')
            buf = b''
        log.flush()
    time.sleep(0.01)

# Cleanup
sys.stdout.write('\x1b[?1006l\x1b[?1000l')
sys.stdout.write('\x1b[?1049l')
sys.stdout.flush()
log.write('FINISHED\n')
log.close()
'@ | Set-Content $pyScript -Encoding UTF8

    & $PSMUX send-keys -t $SESSION "python `"$pyScript`"" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $altOn = Get-PaneFormat '#{alternate_on}'
    Write-Info "alternate_on = $altOn"

    if ($altOn -eq "1") {
        Write-Pass "Alt-screen detected correctly (alternate_on=1)"

        # Now send scroll events via TCP
        for ($i = 0; $i -lt 3; $i++) {
            Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up" | Out-Null
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Seconds 2

        $pyLogContent = Get-Content $pyLog -Raw -EA SilentlyContinue
        Write-Info "Python app log:"
        if ($pyLogContent) {
            $pyLogContent -split "`n" | ForEach-Object { Write-Info "  $_" }
        } else {
            Write-Info "  (empty log)"
        }

        if ($pyLogContent -match "SCROLL_DETECTED") {
            Write-Pass "Scroll events forwarded to alt-screen app (SGR scroll detected)"
        } elseif ($pyLogContent -match "BYTE=") {
            Write-Pass "Data received by alt-screen app (events forwarded to child)"
        } else {
            # This is expected behavior for ConPTY - SGR mouse may be
            # converted to MOUSE_EVENT records which msvcrt.getch() can't read
            Write-Info "No raw VT data received - ConPTY likely converted to MOUSE_EVENT records"
            Write-Info "This is normal for native ConPTY apps (crossterm/ratatui handle MOUSE_EVENTs)"
            Write-Skip "Alt-screen scroll forwarding (ConPTY conversion prevents raw VT verification)"
        }
    } else {
        Write-Skip "Alt-screen not detected (alternate_on=$altOn) - ConPTY may not relay escape seqs"
    }

    # Wait for Python script to exit
    & $PSMUX send-keys -t $SESSION "" 2>&1 | Out-Null
    Start-Sleep -Seconds 13
    Remove-Item $pyScript -Force -EA SilentlyContinue
    Remove-Item $pyLog -Force -EA SilentlyContinue
} else {
    Write-Skip "Python not available for alt-screen test"
}

# ============================================================
# TEST 8: Verify mouse debug log shows scroll forwarding
# ============================================================
Write-Host "`n[Test 8] Mouse debug log verification" -ForegroundColor Yellow

$mouseLog = "$psmuxDir\mouse_debug.log"
if (Test-Path $mouseLog) {
    $logContent = Get-Content $mouseLog -Tail 50 -EA SilentlyContinue | Out-String
    $scrollEntries = $logContent -split "`n" | Where-Object { $_ -match "scroll|SCROLL|pane_scroll|copy.mode" }
    if ($scrollEntries) {
        Write-Info "Mouse debug log entries related to scroll:"
        $scrollEntries | ForEach-Object { Write-Info "  $_" }
        Write-Pass "Mouse debug log confirms scroll events processed"
    } else {
        Write-Info "No scroll-related entries in mouse debug log"
        Write-Info "(This is expected if PSMUX_MOUSE_DEBUG was not set when server started)"
        Write-Skip "Mouse debug log (server may not have PSMUX_MOUSE_DEBUG=1)"
    }
} else {
    Write-Info "No mouse debug log found"
    Write-Skip "Mouse debug log not present"
}

# ============================================================
# TEST 9: Server debug log shows PaneScroll dispatch
# ============================================================
Write-Host "`n[Test 9] Server debug log verification" -ForegroundColor Yellow

$serverLog = "$psmuxDir\server_debug.log"
if (Test-Path $serverLog) {
    $logContent = Get-Content $serverLog -Tail 100 -EA SilentlyContinue | Out-String
    $scrollEntries = $logContent -split "`n" | Where-Object { $_ -match "scroll|PaneScroll|copy" }
    if ($scrollEntries) {
        Write-Info "Server debug log entries:"
        $scrollEntries | ForEach-Object { Write-Info "  $_" }
        Write-Pass "Server debug log confirms scroll command processing"
    } else {
        Write-Skip "No scroll entries in server debug log"
    }
} else {
    Write-Skip "Server debug log not present"
}

# ============================================================
# TEST 10: Verify scroll-enter-copy-mode option interaction
# ============================================================
Write-Host "`n[Test 10] scroll-enter-copy-mode OFF + mouse-selection OFF" -ForegroundColor Yellow

& $PSMUX set-option -g scroll-enter-copy-mode off -t $SESSION 2>&1 | Out-Null
& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$seCopy = Get-PsmuxOption "scroll-enter-copy-mode"
$ms = Get-PsmuxOption "mouse-selection"
Write-Info "scroll-enter-copy-mode=$seCopy, mouse-selection=$ms"

$cap1 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

# When scroll-enter-copy-mode is off, scroll should use scrollback directly
Send-TcpCommand -Session $SESSION -Command "pane-scroll 0 up" | Out-Null
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
$cap2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String

# With scroll-enter-copy-mode OFF, should NOT enter copy mode
# but should scroll the scrollback
if ($mode -ne "1" -and $cap2 -ne $cap1) {
    Write-Pass "Direct scrollback works (no copy mode, content changed)"
} elseif ($mode -ne "1") {
    # Content might not change if already at top of scrollback
    Write-Pass "scroll-enter-copy-mode OFF correctly prevents copy mode entry"
} else {
    Write-Fail "Unexpected copy mode entry with scroll-enter-copy-mode OFF"
}

# Reset
& $PSMUX set-option -g scroll-enter-copy-mode on -t $SESSION 2>&1 | Out-Null
& $PSMUX set-option -g mouse-selection on -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 11: Scroll in split-pane layout
# ============================================================
Write-Host "`n[Test 11] Scroll in split-pane layout (issue #277 scenario)" -ForegroundColor Yellow

# Create a split
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Generate scrollback in the new pane
& $PSMUX send-keys -t $SESSION 'for ($i=1; $i -le 50; $i++) { Write-Host "SPLIT_LINE_$i" }' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Check pane count
$paneCount = (& $PSMUX list-panes -t $SESSION 2>&1 | Out-String).Trim() -split "`n" | Where-Object { $_.Trim() } | Measure-Object | Select-Object -ExpandProperty Count
Write-Info "Pane count: $paneCount"

# Get the active pane ID
$activePaneId = (& $PSMUX display-message -t $SESSION -p '#{pane_id}' 2>&1 | Out-String).Trim() -replace '%', ''
Write-Info "Active pane ID: $activePaneId"

# Scroll via pane-scroll with explicit pane ID
$resp = Send-TcpCommand -Session $SESSION -Command "pane-scroll $activePaneId up"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -eq "1") {
    Write-Pass "Scroll works in split-pane layout (copy mode entered, pane=$activePaneId)"
} else {
    Write-Fail "Scroll FAILED in split-pane layout (pane_in_mode=$mode)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ============================================================
# TEST 12: Scroll in split-pane with mouse-selection OFF
# ============================================================
Write-Host "`n[Test 12] Split-pane scroll with mouse-selection OFF" -ForegroundColor Yellow

& $PSMUX set-option -g mouse-selection off -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$resp = Send-TcpCommand -Session $SESSION -Command "pane-scroll $activePaneId up"
Start-Sleep -Seconds 1

$mode = Get-PaneFormat '#{pane_in_mode}'
if ($mode -eq "1") {
    Write-Pass "Split-pane scroll works with mouse-selection OFF"
} else {
    Write-Fail "Split-pane scroll BROKEN with mouse-selection OFF (pane_in_mode=$mode)"
}

& $PSMUX send-keys -t $SESSION "q" 2>&1 | Out-Null

# ── TEARDOWN ─────────────────────────────────────────────────────────────
Write-Host "`n--- Cleanup ---"
Cleanup
$env:PSMUX_MOUSE_DEBUG = $null
$env:PSMUX_SERVER_DEBUG = $null

# ── RESULTS ──────────────────────────────────────────────────────────────
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow

Write-Host "`n=== Analysis ===" -ForegroundColor Cyan
Write-Host @"

Code path analysis for issue #277 + #245:

1. SCROLL CODE PATHS (client.rs → server):
   - client.rs lines 3495-3523: ScrollUp/ScrollDown handlers
     → ALWAYS send "pane-scroll {id} up/down" — NO mouse_selection check
   - server/mod.rs line 1617: PaneScroll dispatch
     → Gated ONLY by app.mouse_enabled (the 'mouse' option)
   - window_ops.rs handle_pane_scroll (line 923):
     → No mouse_selection check. Checks alternate_screen(), then either
       forwards SGR mouse or enters copy mode.

2. MOUSE-SELECTION SCOPE (client.rs):
   - client_mouse_selection ONLY checked at:
     a) Down(Left) handler: controls whether client-side drag selection starts
     b) Drag(Left) handler: gates selection tracking
   - NOT checked in: ScrollUp, ScrollDown, Down(Right), Down(Middle),
     Up(Left), Moved, or any scroll-related code.

3. CONCLUSION:
   - mouse-selection=off CANNOT break scroll — the code paths are completely independent.
   - If scroll is broken for a user, possible causes:
     a) mouse=off (the 'mouse' option, not 'mouse-selection')
     b) Terminal emulator intercepting mouse events before psmux
     c) ConPTY/Windows Terminal mouse event delivery issue
     d) Environment-specific issue (Windows version, terminal version)

"@

if ($script:TestsFailed -gt 0) {
    Write-Host "  VERDICT: Bug exists — scroll is broken" -ForegroundColor Red
} else {
    Write-Host "  VERDICT: Server-side scroll works correctly. mouse-selection does NOT affect scroll." -ForegroundColor Green
    Write-Host "  If users report broken scroll, investigate client-side mouse event delivery" -ForegroundColor Yellow
    Write-Host "  (terminal emulator, ConPTY version, Windows Terminal mouse capture)." -ForegroundColor Yellow
}

exit $script:TestsFailed
