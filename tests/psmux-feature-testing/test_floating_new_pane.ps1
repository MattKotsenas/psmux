# Feature: floating panes (tmux new-pane) - creation E2E.
#
# Drives a real psmux server: `new-pane` with an explicit position/size/border
# creates a floating pane over the active window. We assert the float appears
# in the live state JSON (dump-state) at the requested geometry. The actual
# glyph rendering is proven deterministically by tests-rs/test_floating_render.rs.
#
# Exit 0 = new-pane creates a float with the requested geometry.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_new_pane"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2

# No float yet.
$before = (& $PSMUX dump-state 2>&1) -join ""
Check "baseline" (-not ($before -match '"floats"\s*:\s*\[\s*\{')) "no float before new-pane"

# tmux flags: -X/-Y = position, -x/-y = size, -B = border, -T = title, -P = print id.
$pid1 = (& $PSMUX new-pane -X 8 -Y 4 -x 30 -y 10 -B double -T FLTTITLE -P 2>&1 | ForEach-Object { ($_ -replace "\x1b\[[0-9;]*m","").Trim() }) -join ""
Start-Sleep -Milliseconds 800
Check "print-id" ($pid1 -match '^%\d+$') "new-pane -P returned pane id '$pid1'"

$after = (& $PSMUX dump-state 2>&1) -join ""
Check "float-present" ($after -match '"floats"\s*:\s*\[\s*\{') "floats array present in state"
Check "float-x(pos)" ($after -match '"x"\s*:\s*8') "float x-position=8 (from -X)"
Check "float-y(pos)" ($after -match '"y"\s*:\s*4') "float y-position=4 (from -Y)"
Check "float-w(size)" ($after -match '"w"\s*:\s*30') "float width=30 (from -x)"
Check "float-h(size)" ($after -match '"h"\s*:\s*10') "float height=10 (from -y)"
Check "float-border" ($after -match '"border"\s*:\s*"double"') "border=double in state"
Check "float-title" ($after -match 'FLTTITLE') "title shipped in state"

# Numeric position: -X 80 anchors the top-right corner (100-wide window, 20-wide float).
& $PSMUX new-pane -X 80 -Y 0 -x 20 -y 6 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$after2 = (& $PSMUX dump-state 2>&1) -join ""
Check "position-numeric" ($after2 -match '"x"\s*:\s*80') "float anchored to x=80 via -X"

Stop-All

Write-Host ""
if ($failures -eq 0) { Write-Host "FLOATING new-pane CREATION PROVEN (geometry + border + title + -P)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
