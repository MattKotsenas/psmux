# Feature: floating panes - mouse-drag move + resize (tmux's native float move).
#
# tmux moves/resizes floating panes by dragging them with the mouse. This proves,
# via dump-state, that:
#  - dragging the float BODY moves it (x/y follow the cursor by the grab offset)
#  - dragging the float bottom-right EDGE resizes it (w/h grow)
# driven through the mouse-down/mouse-drag/mouse-up control commands.
#
# Exit 0 = both pass.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_drag"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}
function DS { (& $PSMUX dump-state 2>&1) -join "" }
function FloatField([string]$json, [string]$field) {
    $m = [regex]::Match($json, '"floats"\s*:\s*\[\s*\{[^}]*?"' + [regex]::Escape($field) + '"\s*:\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value } else { return -1 }
}

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX set-option -g mouse on 2>&1 | Out-Null

# Float at position (10,5), size 30x10. Body spans x 10..39, y 5..14.
& $PSMUX new-pane -X 10 -Y 5 -x 30 -y 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$x0 = FloatField (DS) "x"; $y0 = FloatField (DS) "y"
Check "create" ($x0 -eq 10 -and $y0 -eq 5) "float at ($x0,$y0)"

# MOVE: grab the body at (15,7) [offset (5,2) from top-left] and drag to (30,15).
# New top-left = (30-5, 15-2) = (25,13).
& $PSMUX mouse-down 15 7 2>&1 | Out-Null
Start-Sleep -Milliseconds 150
& $PSMUX mouse-drag 30 15 2>&1 | Out-Null
Start-Sleep -Milliseconds 250
& $PSMUX mouse-up 30 15 2>&1 | Out-Null
Start-Sleep -Milliseconds 250
$x1 = FloatField (DS) "x"; $y1 = FloatField (DS) "y"
Check "drag-move" ($x1 -eq 25 -and $y1 -eq 13) "float moved to ($x1,$y1), expected (25,13)"

# RESIZE: float is now at (25,13) size 30x10 -> right/bottom edge at x=54,y=22.
# Grab the bottom-right corner (54,22) and drag to (64,25):
# new w = 64-25+1 = 40, new h = 25-13+1 = 13.
& $PSMUX mouse-down 54 22 2>&1 | Out-Null
Start-Sleep -Milliseconds 150
& $PSMUX mouse-drag 64 25 2>&1 | Out-Null
Start-Sleep -Milliseconds 250
& $PSMUX mouse-up 64 25 2>&1 | Out-Null
Start-Sleep -Milliseconds 250
$w1 = FloatField (DS) "w"; $h1 = FloatField (DS) "h"
Check "drag-resize" ($w1 -eq 40 -and $h1 -eq 13) "float resized to ${w1}x${h1}, expected 40x13"

Stop-All
Write-Host ""
if ($failures -eq 0) { Write-Host "FLOAT MOUSE-DRAG move + resize PROVEN" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
