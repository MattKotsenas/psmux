# Feature: floating panes phase 5 - split-window inside a float creates a float.
#
# tmux: when the focused pane is a floating pane, split-window creates ANOTHER
# floating pane instead of splitting the tiled layout. Proven by counting the
# floats array in dump-state (1 -> 2) and confirming the tiled layout still has
# a single pane.
#
# Exit 0 = split-from-float creates a second float without touching the layout.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_split"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}
function DS { (& $PSMUX dump-state 2>&1) -join "" }
function FloatCount([string]$json) {
    $m = [regex]::Match($json, '"floats"\s*:\s*\[(.*)$')
    if (-not $m.Success) { return 0 }
    return ([regex]::Matches($m.Groups[1].Value, '"border"\s*:')).Count
}

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2

# One tiled pane baseline.
$panes0 = (& $PSMUX list-panes -t $S 2>&1 | Measure-Object -Line).Lines

# Create a focused float (tmux flags: -X/-Y position, -x/-y size).
& $PSMUX new-pane -X 10 -Y 5 -x 30 -y 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$c1 = FloatCount (DS)
Check "one-float" ($c1 -eq 1) "float count = $c1"

# Split while the float is focused -> should create a SECOND float.
& $PSMUX split-window -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$c2 = FloatCount (DS)
Check "split-makes-float" ($c2 -eq 2) "float count after split = $c2 (expected 2)"

# The tiled layout must be untouched (still a single tiled pane).
$panes1 = (& $PSMUX list-panes -t $S 2>&1 | Measure-Object -Line).Lines
Check "layout-untouched" ($panes1 -eq $panes0) "tiled pane count unchanged ($panes0 -> $panes1)"

Stop-All
Write-Host ""
if ($failures -eq 0) { Write-Host "SPLIT-FROM-FLOAT PROVEN (creates a float, layout untouched)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
