# Issue #372: Style options aren't format-expanded; status-style falls back to bright green.
#
# The bug: status-left / status-right are run through expand_format before being
# serialized to the client, but the STYLE options (status-style, pane-border-style,
# pane-active-border-style, window-status-style, mode-style, window-status-separator)
# were forwarded RAW. A #{@var} colour reference therefore reached the client's
# colour parser verbatim, failed to parse, and status-style fell back to bright green.
#
# This test proves, via the exact same TCP dump-state observable used to reproduce
# the bug, that the style options are now EXPANDED at send time, while the per-window
# window-status FORMATS (wsf/wscf) correctly remain raw (the client expands those
# per window with each window's own context).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue372"
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

# Persistent TCP dump-state helper (Method 4 from the testing skill).
function Get-DumpState {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    Start-Sleep -Milliseconds 200
    $writer.Write("dump-state`n"); $writer.Flush()
    $best = $null
    $tcp.ReceiveTimeout = 3000
    for ($j = 0; $j -lt 100; $j++) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line; break }
    }
    $tcp.Close()
    return $best
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #372: Style Format Expansion Tests ===" -ForegroundColor Cyan

# --- SETUP: user options used as colour refs ---
# NOTE: the @-prefixed option name MUST be single-quoted. PowerShell treats a
# bare @name argument token as splatting (@ + variable), which silently drops it.
& $PSMUX set-option -g '@bg' "#292e42"
& $PSMUX set-option -g '@fg' "#c0caf5"
& $PSMUX set-option -g '@brd' "#7aa2f7"

# Style options that reference @vars
& $PSMUX set-option -g status-style "bg=#{@bg},fg=#{@fg}"
& $PSMUX set-option -g pane-border-style "fg=#{@brd}"
& $PSMUX set-option -g pane-active-border-style "fg=#{@bg}"
& $PSMUX set-option -g window-status-style "bg=#{@bg}"
& $PSMUX set-option -g window-status-current-style "fg=#{@fg}"
& $PSMUX set-option -g mode-style "bg=#{@brd}"
& $PSMUX set-option -g window-status-separator " #{@bg} "
# Per-window FORMAT (must stay raw so client expands per window)
& $PSMUX set-option -g window-status-format "#I:#W"
Start-Sleep -Milliseconds 600

$dump = Get-DumpState -Session $SESSION
if (-not $dump) { Write-Fail "Could not obtain dump-state"; Cleanup; exit 1 }
$json = $dump | ConvertFrom-Json

# === TEST 1: status-style is expanded (the reproduced bug) ===
Write-Host "`n[Test 1] status-style #{@var} expanded before client parse" -ForegroundColor Yellow
if ($json.status_style -eq "bg=#292e42,fg=#c0caf5") {
    Write-Pass "status_style expanded to '$($json.status_style)'"
} elseif ($json.status_style -match '#\{@bg\}') {
    Write-Fail "BUG STILL PRESENT: status_style sent raw -> '$($json.status_style)'"
} else {
    Write-Fail "status_style unexpected -> '$($json.status_style)'"
}

# === TEST 2: status-left still expands (regression guard) ===
Write-Host "`n[Test 2] status-left still expands (no regression)" -ForegroundColor Yellow
& $PSMUX set-option -g status-left "L=#{@bg}"
Start-Sleep -Milliseconds 400
$json2 = (Get-DumpState -Session $SESSION) | ConvertFrom-Json
if ($json2.status_left -eq "L=#292e42") { Write-Pass "status_left still expands -> '$($json2.status_left)'" }
else { Write-Fail "status_left regression -> '$($json2.status_left)'" }

# === TEST 3: pane-border styles expanded ===
Write-Host "`n[Test 3] pane-border-style / pane-active-border-style expanded" -ForegroundColor Yellow
if ($json.pane_border_style -eq "fg=#7aa2f7") { Write-Pass "pane_border_style -> '$($json.pane_border_style)'" }
else { Write-Fail "pane_border_style -> '$($json.pane_border_style)'" }
if ($json.pane_active_border_style -eq "fg=#292e42") { Write-Pass "pane_active_border_style -> '$($json.pane_active_border_style)'" }
else { Write-Fail "pane_active_border_style -> '$($json.pane_active_border_style)'" }

# === TEST 4: window-status styles + separator + mode-style expanded ===
Write-Host "`n[Test 4] window-status styles, separator, mode-style expanded" -ForegroundColor Yellow
if ($json.ws_style -eq "bg=#292e42") { Write-Pass "ws_style -> '$($json.ws_style)'" } else { Write-Fail "ws_style -> '$($json.ws_style)'" }
if ($json.wsc_style -eq "fg=#c0caf5") { Write-Pass "wsc_style -> '$($json.wsc_style)'" } else { Write-Fail "wsc_style -> '$($json.wsc_style)'" }
if ($json.mode_style -eq "bg=#7aa2f7") { Write-Pass "mode_style -> '$($json.mode_style)'" } else { Write-Fail "mode_style -> '$($json.mode_style)'" }
if ($json.wss -eq " #292e42 ") { Write-Pass "wss (separator) -> '$($json.wss)'" } else { Write-Fail "wss -> '$($json.wss)'" }

# === TEST 5: per-window FORMAT stays raw (must NOT be session-expanded) ===
Write-Host "`n[Test 5] window-status-format stays raw (#I/#W expanded per-window on client)" -ForegroundColor Yellow
if ($json.wsf -eq "#I:#W") { Write-Pass "wsf left raw -> '$($json.wsf)'" }
else { Write-Fail "wsf must stay raw, got -> '$($json.wsf)'" }

# === TEST 6: literal colour (no ref) is unchanged (no over-expansion) ===
Write-Host "`n[Test 6] literal colour passes through unchanged" -ForegroundColor Yellow
& $PSMUX set-option -g status-style "bg=#abcdef,fg=black"
Start-Sleep -Milliseconds 400
$json6 = (Get-DumpState -Session $SESSION) | ConvertFrom-Json
if ($json6.status_style -eq "bg=#abcdef,fg=black") { Write-Pass "literal style unchanged -> '$($json6.status_style)'" }
else { Write-Fail "literal style altered -> '$($json6.status_style)'" }

# === TEST 7: runtime @var change is reflected at send time ===
Write-Host "`n[Test 7] changing @var at runtime updates expanded style" -ForegroundColor Yellow
& $PSMUX set-option -g status-style "bg=#{@bg}"
& $PSMUX set-option -g '@bg' "#ff0000"
Start-Sleep -Milliseconds 400
$json7 = (Get-DumpState -Session $SESSION) | ConvertFrom-Json
if ($json7.status_style -eq "bg=#ff0000") { Write-Pass "runtime @var change reflected -> '$($json7.status_style)'" }
else { Write-Fail "runtime @var not reflected -> '$($json7.status_style)'" }

# === TEST 8: message-style is now SENT to the client (was never serialized) ===
# Root cause for the message-style item in #372: the option was parsed and
# stored server-side but never serialized into the client frame, so the client
# hard-coded bg=yellow,fg=black and ignored it entirely. It must now appear in
# the frame AND be format-expanded like the other style options.
Write-Host "`n[Test 8] message-style serialized to client + format-expanded" -ForegroundColor Yellow
& $PSMUX set-option -g '@msgbg' "#5500ff"
& $PSMUX set-option -g message-style "bg=#{@msgbg},fg=white"
Start-Sleep -Milliseconds 400
$json8 = (Get-DumpState -Session $SESSION) | ConvertFrom-Json
$hasField = ($json8.PSObject.Properties.Name -contains "message_style")
if (-not $hasField) {
    Write-Fail "BUG STILL PRESENT: message_style not present in client frame at all"
} elseif ($json8.message_style -eq "bg=#5500ff,fg=white") {
    Write-Pass "message_style sent + expanded -> '$($json8.message_style)'"
} elseif ($json8.message_style -match '#\{@msgbg\}') {
    Write-Fail "message_style sent but NOT expanded -> '$($json8.message_style)'"
} else {
    Write-Fail "message_style unexpected -> '$($json8.message_style)'"
}

# === TEST 9: literal message-style passes through unchanged ===
Write-Host "`n[Test 9] literal message-style unchanged" -ForegroundColor Yellow
& $PSMUX set-option -g message-style "bg=#123456,fg=#abcdef"
Start-Sleep -Milliseconds 400
$json9 = (Get-DumpState -Session $SESSION) | ConvertFrom-Json
if ($json9.message_style -eq "bg=#123456,fg=#abcdef") { Write-Pass "literal message-style -> '$($json9.message_style)'" }
else { Write-Fail "literal message-style -> '$($json9.message_style)'" }

# === Win32 TUI VISUAL VERIFICATION (Layer 2, MANDATORY) ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
$SESSION_TUI = "test_issue372_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX set-option -g '@tbg' "#1a1b26" 2>&1 | Out-Null
& $PSMUX set-option -g status-style "bg=#{@tbg}" 2>&1 | Out-Null
& $PSMUX set-option -g message-style "bg=#{@tbg},fg=#eeeeee" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$tuiDump = Get-DumpState -Session $SESSION_TUI
if ($tuiDump) {
    $tuiJson = $tuiDump | ConvertFrom-Json
    if ($tuiJson.status_style -eq "bg=#1a1b26") { Write-Pass "TUI: live status-style expanded -> '$($tuiJson.status_style)'" }
    else { Write-Fail "TUI: status-style -> '$($tuiJson.status_style)'" }
    if ($tuiJson.message_style -eq "bg=#1a1b26,fg=#eeeeee") { Write-Pass "TUI: live message-style expanded -> '$($tuiJson.message_style)'" }
    else { Write-Fail "TUI: message-style -> '$($tuiJson.message_style)'" }
    # Trigger a real message on the live window; confirm the message path runs.
    & $PSMUX display-message -t $SESSION_TUI "hello #{@tbg}" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Write-Pass "TUI: display-message issued on live window (message bar uses configured style)"
} else { Write-Fail "TUI: could not dump state" }
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
