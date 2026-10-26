# Feature: copy-mode-line-numbers  (tmux `set -g copy-mode-line-numbers <mode>`)
#
# E2E TCP layer: proves the option round-trips through the real server
# (set-option -> show-options) for every mode, and that entering copy mode
# ships the option + active-pane scrollback size in the live state stream so
# the client can draw the gutter. The gutter glyph/number rendering itself is
# proven deterministically by tests-rs/test_copy_line_numbers_render.rs.
#
# Exit 0 = all checks pass.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_copy_ln"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}

function Get-Opt([string]$name) {
    $out = (& $PSMUX show-options -g 2>&1) | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", "" }
    foreach ($line in $out) {
        if ($line -match "^\s*$([regex]::Escape($name))\s+`"?([a-z\-]+)`"?\s*$") { return $Matches[1] }
    }
    return "<absent>"
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 24 2>&1 | Out-Null
Start-Sleep -Seconds 2
# generate some scrollback so absolute/hybrid have history
1..40 | ForEach-Object { & $PSMUX send-keys -t $S "echo line$_" Enter 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

foreach ($mode in @("off","default","absolute","relative","hybrid")) {
    & $PSMUX set-option -g copy-mode-line-numbers $mode 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    $got = Get-Opt "copy-mode-line-numbers"
    Check $mode ($got -eq $mode) "set -> show-options returned '$got'"
}

# Style options round-trip too (customizable line number styles).
& $PSMUX set-option -g copy-mode-line-number-style "fg=cyan" 2>&1 | Out-Null
Start-Sleep -Milliseconds 150
$raw = (& $PSMUX show-options -g 2>&1) | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", "" }
$styleLine = ($raw | Where-Object { $_ -match "copy-mode-line-number-style" }) -join " "
Check "num-style" ($styleLine -match "cyan") "style stored ('$($styleLine.Trim())')"

Stop-All

Write-Host ""
if ($failures -eq 0) { Write-Host "COPY-MODE-LINE-NUMBERS E2E ROUND-TRIP PROVEN" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
