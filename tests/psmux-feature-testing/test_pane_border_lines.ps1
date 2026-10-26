# Feature: pane-border-lines  (tmux `set -g pane-border-lines <style>`)
#
# E2E TCP layer: drives a REAL psmux server over the socket and proves the
# option round-trips through set-option -> server store -> show-options.
# The actual glyph rendering is proven deterministically by the headless
# ratatui render tests in tests-rs/test_pane_border_lines_render.rs (single /
# double / heavy / simple / none + junctions).
#
# Exit 0 = every style round-trips; non-zero = a style failed.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_border_lines"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}

function Get-BorderLines {
    # strip ANSI colour so string matching is reliable
    $out = (& $PSMUX show-options -g 2>&1) | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", "" }
    foreach ($line in $out) {
        if ($line -match '^\s*pane-border-lines\s+"?([a-z]+)"?\s*$') { return $Matches[1] }
    }
    return "<absent>"
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 24 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX split-window -h -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

foreach ($style in @("single","double","heavy","simple","number","spaces","none")) {
    & $PSMUX set-option -g pane-border-lines $style 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    $got = Get-BorderLines
    Check $style ($got -eq $style) "set -> show-options returned '$got'"
}

Stop-All

Write-Host ""
if ($failures -eq 0) { Write-Host "PANE-BORDER-LINES E2E ROUND-TRIP PROVEN (all 7 styles)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures style(s) FAILED" -ForegroundColor Red; exit 1 }
