#!/usr/bin/env pwsh
###############################################################################
# test_copy_drag_autoscroll.ps1
#
# Integration test for drag-selection auto-scroll through scrollback:
#   - In copy mode, dragging on/past the pane's first row scrolls the view
#     up so the selection keeps growing into history (tmux parity #62), and
#     releasing yanks the selection and cancels copy mode
#     (copy-pipe-and-cancel).
#   - With scroll-enter-copy-mode off (#193), the wheel scrolls the pane
#     directly WITHOUT entering copy mode; a drag selection over that view
#     hands off to copy mode at the bottom edge (copy-drag-begin), keeps
#     the direct-scrolled offset, and auto-scrolls back toward the live
#     output.
#
# Drives the server through the CLI's raw event forwarding
# (pane-scroll / pane-mouse / copy-drag-begin) and asserts observable
# state via display-message formats (pane_in_mode, selection_present,
# scroll_position) and show-buffer.
###############################################################################
$ErrorActionPreference = "Continue"

$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Passed = 0
$script:Failed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;  $script:Failed++ }

$SESSION = "cdrag_autoscroll"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Port {
    param([string]$SessionName, [int]$MaxSeconds = 12)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "$psmuxDir\$SessionName.port") { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Get-DisplayFormat {
    param([string]$Format)
    $val = (& $PSMUX display-message -t $SESSION -p $Format 2>&1 | Out-String).Trim()
    return $val
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " Drag auto-scroll: edge scrolling + direct-scroll handoff (#193)" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

Cleanup

& $PSMUX new-session -d -s $SESSION -x 120 -y 30 2>&1 | Out-Null
if (-not (Wait-Port $SESSION)) {
    Write-Fail "Session $SESSION did not start"
    exit 1
}
Start-Sleep -Seconds 1

# Fill the scrollback with numbered content so edge scrolling has history
# to move through and yanks have real text to grab.
& $PSMUX send-keys -t $SESSION '1..100 | % { "CDRAG-$_" }' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

$paneId = (Get-DisplayFormat '#{pane_id}') -replace '%', ''
$paneH  = [int](Get-DisplayFormat '#{pane_height}')
$bottom = $paneH - 1
if ($paneId -match '^\d+$' -and $paneH -gt 2) {
    Write-Pass "setup: pane id=$paneId height=$paneH"
} else {
    Write-Fail "setup: bad pane id '$paneId' / height '$paneH'"
    Cleanup
    exit 1
}

###############################################################################
# TEST 1: copy-mode drag at the top row auto-scrolls; release yanks + cancels
###############################################################################
Write-Host "`n--- TEST 1: copy-mode top-edge drag auto-scroll ---" -ForegroundColor Yellow

# Pin the option explicitly — the session loads the local user config,
# which may carry scroll-enter-copy-mode off (#193).
& $PSMUX set-option -t $SESSION scroll-enter-copy-mode on 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# Wheel up: enters copy mode, 3 lines.
& $PSMUX -t $SESSION pane-scroll $paneId up 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$inMode = Get-DisplayFormat '#{pane_in_mode}'
$scroll = Get-DisplayFormat '#{scroll_position}'
if ($inMode -eq "1" -and $scroll -eq "3") {
    Write-Pass "wheel up: pane_in_mode=1, scroll_position=3"
} else {
    Write-Fail "wheel up: expected mode=1 scroll=3, got mode='$inMode' scroll='$scroll'"
}

# Press at row 2, then drag onto the top row three times (the client's
# 50ms dwell repeat re-sends the same drag): each one scrolls the view.
& $PSMUX -t $SESSION pane-mouse $paneId 0 5 2 M 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
1..3 | ForEach-Object {
    & $PSMUX -t $SESSION pane-mouse $paneId 32 5 0 M 2>&1 | Out-Null
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Milliseconds 300

$scrollAfterDrag = [int](Get-DisplayFormat '#{scroll_position}')
$selDuring = Get-DisplayFormat '#{selection_present}'
if ($scrollAfterDrag -gt 3) {
    Write-Pass "top-edge drags: view scrolled deeper into history (scroll_position=$scrollAfterDrag)"
} else {
    Write-Fail "top-edge drags: expected scroll_position>3, got $scrollAfterDrag"
}
if ($selDuring -eq "1") {
    Write-Pass "top-edge drags: selection_present=1 (drag is selecting)"
} else {
    Write-Fail "top-edge drags: selection_present='$selDuring' (no selection during drag)"
}

# Release: yanks the multi-line selection and cancels copy mode.
& $PSMUX -t $SESSION pane-mouse $paneId 0 5 0 m 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$inModeUp = Get-DisplayFormat '#{pane_in_mode}'
$scrollUp = Get-DisplayFormat '#{scroll_position}'
if ($inModeUp -eq "0" -and $scrollUp -eq "0") {
    Write-Pass "release: copy mode cancelled, back at live view (tmux copy-pipe-and-cancel)"
} else {
    Write-Fail "release: expected mode=0 scroll=0, got mode='$inModeUp' scroll='$scrollUp'"
}

$buf = (& $PSMUX show-buffer -t $SESSION 2>&1 | Out-String)
if ($buf.Trim().Length -gt 0 -and ($buf.Trim() -split "`n").Count -ge 2) {
    Write-Pass "release: yanked buffer is multi-line (selection spanned the scroll)"
} else {
    Write-Fail "release: expected a multi-line yank, got '$($buf.Trim())'"
}

###############################################################################
# TEST 2: scroll-enter-copy-mode off — bottom-edge handoff from direct scroll
###############################################################################
Write-Host "`n--- TEST 2: direct-scroll bottom-edge handoff (#193) ---" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION scroll-enter-copy-mode off 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# Two wheel reports: the pane scrolls back 6 lines WITHOUT entering copy mode.
& $PSMUX -t $SESSION pane-scroll $paneId up 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
& $PSMUX -t $SESSION pane-scroll $paneId up 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$inModeDirect = Get-DisplayFormat '#{pane_in_mode}'
if ($inModeDirect -eq "0") {
    Write-Pass "direct scroll: pane_in_mode=0 (wheel did not enter copy mode)"
} else {
    Write-Fail "direct scroll: pane_in_mode='$inModeDirect' (option did not take effect)"
}

# A drag selection over the scrolled view reached the bottom row: the
# client hands off to server-side copy mode.  The direct-scrolled offset
# (6) must be preserved, minus the one line the bottom edge scrolls.
& $PSMUX -t $SESSION copy-drag-begin $paneId 5 3 5 $bottom 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$inModeHand = Get-DisplayFormat '#{pane_in_mode}'
$selHand    = Get-DisplayFormat '#{selection_present}'
$scrollHand = Get-DisplayFormat '#{scroll_position}'
if ($inModeHand -eq "1" -and $selHand -eq "1") {
    Write-Pass "handoff: copy mode entered with the selection anchored"
} else {
    Write-Fail "handoff: expected mode=1 sel=1, got mode='$inModeHand' sel='$selHand'"
}
if ($scrollHand -eq "5") {
    Write-Pass "handoff: scroll_position=5 (direct-scroll offset 6 preserved, one bottom-edge scroll)"
} else {
    Write-Fail "handoff: expected scroll_position=5, got '$scrollHand'"
}

# Dwell drags on the bottom row keep scrolling toward the live view and
# clamp there instead of wrapping.
1..5 | ForEach-Object {
    & $PSMUX -t $SESSION pane-mouse $paneId 32 5 $bottom M 2>&1 | Out-Null
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Milliseconds 300

$scrollDwell = Get-DisplayFormat '#{scroll_position}'
if ($scrollDwell -eq "0") {
    Write-Pass "bottom-edge dwell: scrolled back to the live view and clamped (scroll_position=0)"
} else {
    Write-Fail "bottom-edge dwell: expected scroll_position=0, got '$scrollDwell'"
}

# Release: yanks everything the drag swept and cancels copy mode.
& $PSMUX -t $SESSION pane-mouse $paneId 0 5 $bottom m 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$inModeEnd = Get-DisplayFormat '#{pane_in_mode}'
$scrollEnd = Get-DisplayFormat '#{scroll_position}'
if ($inModeEnd -eq "0" -and $scrollEnd -eq "0") {
    Write-Pass "release: copy mode cancelled, back at live view"
} else {
    Write-Fail "release: expected mode=0 scroll=0, got mode='$inModeEnd' scroll='$scrollEnd'"
}

$buf2 = (& $PSMUX show-buffer -t $SESSION 2>&1 | Out-String)
if ($buf2.Trim().Length -gt 0 -and $buf2 -match "CDRAG-") {
    Write-Pass "release: yanked buffer holds the swept scrollback content"
} else {
    Write-Fail "release: expected CDRAG content in the buffer, got '$($buf2.Trim())'"
}

& $PSMUX set-option -t $SESSION scroll-enter-copy-mode on 2>&1 | Out-Null

###############################################################################
# CLEANUP
###############################################################################
Cleanup

###############################################################################
# SUMMARY
###############################################################################
Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " Results: $($script:Passed) passed, $($script:Failed) failed" -ForegroundColor $(if ($script:Failed -eq 0) { "Green" } else { "Red" })
Write-Host "================================================================`n" -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }
exit 0
