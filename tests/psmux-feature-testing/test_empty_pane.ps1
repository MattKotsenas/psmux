# Feature: empty panes (tmux -E) - a pane with NO command/process, blank until
# respawn-pane gives it one.
#
# Proves, via dump-state, that `new-pane -E` creates a floating pane that:
#  - exists and is retained (not reaped, since it has no child that exits)
#  - renders BLANK (no visible/non-space content)
# and the server stays healthy (a childless ConPTY must not crash/hang it).
#
# Exit 0 = all pass.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "empty_pane"

function Stop-All { & $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 300 }
function DS { (& $PSMUX dump-state 2>&1) -join "" }

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Create an empty floating pane (no command).
& $PSMUX new-pane -E -X 10 -Y 5 -x 30 -y 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$ds = DS
Check "server-alive" ($ds.Length -gt 200) "server healthy after -E (state len $($ds.Length))"
Check "float-present" ($ds -match '"floats"\s*:\s*\[\s*\{') "empty float present"

# The float's rows must contain no visible (non-space) glyph.
$m = [regex]::Match($ds, '"rows"\s*:\s*\[(.*)$')
$rowsBlob = if ($m.Success) { $m.Groups[1].Value } else { "" }
$hasVisible = $rowsBlob -match '"text"\s*:\s*"[^ "\\]'
Check "blank" (-not $hasVisible) "empty pane renders blank (no visible content)"

# It must persist (not be reaped) since it has no child that exits.
Start-Sleep -Seconds 2
$ds2 = DS
Check "retained" ($ds2 -match '"floats"\s*:\s*\[\s*\{') "empty pane retained (not reaped)"

# new-window -E: a new window whose tiled pane is empty (blank).
& $PSMUX new-window -E -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$capNW = (& $PSMUX capture-pane -p -t $S 2>&1) -join ""
Check "new-window-E-blank" (($capNW.Trim()).Length -eq 0) "new-window -E pane is blank ('$($capNW.Trim())')"

# respawn-pane -E: a running pane, once respawned empty, goes blank.
& $PSMUX new-window -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX send-keys -t $S "echo RESPAWNME" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1000
$capBefore = (& $PSMUX capture-pane -p -t $S 2>&1) -join "`n"
Check "respawn-before" ($capBefore -match "RESPAWNME") "pane shows output before respawn"
& $PSMUX respawn-pane -E -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$capAfter = (& $PSMUX capture-pane -p -t $S 2>&1) -join "`n"
Check "respawn-pane-E-blank" (-not ($capAfter -match "RESPAWNME")) "respawn-pane -E cleared the pane to empty"

Stop-All
Write-Host ""
if ($failures -eq 0) { Write-Host "EMPTY PANE (-E) PROVEN: blank, childless, retained, server healthy" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
