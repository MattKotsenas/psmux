# Feature: -T pane title at creation for new-window and split-window
# (tmux `new-window -T`, `split-window -T`).
#
# E2E TCP layer: create a window / split a pane WITH -T and prove the new
# pane's title is set at creation time (previously -T was only honoured by
# select-pane on an existing pane). Title is read back with
# display-message -p '#{pane_title}'.
#
# Exit 0 = both new-window -T and split-window -T set the title.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_pane_title"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}

function Clean([string[]]$lines) { $lines | ForEach-Object { ($_ -replace "\x1b\[[0-9;]*m","").Trim() } }

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 24 2>&1 | Out-Null
Start-Sleep -Seconds 2

# 1) new-window -T sets the new window's pane title at creation.
& $PSMUX new-window -t $S -n W2 -T "NWTITLE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$got = (Clean (& $PSMUX display-message -p -t "${S}:W2" '#{pane_title}' 2>&1)) -join ""
Check "new-window -T" ($got -match "NWTITLE") "pane_title = '$got'"

# 2) split-window -T sets the new pane's title at creation. Use -P to learn the
#    new pane's id, then read its title.
$paneId = (Clean (& $PSMUX split-window -t "${S}:W2" -h -P -F '#{pane_id}' -T "SPTITLE" 2>&1)) -join ""
Start-Sleep -Milliseconds 500
$got2 = (Clean (& $PSMUX display-message -p -t $paneId '#{pane_title}' 2>&1)) -join ""
Check "split-window -T" ($got2 -match "SPTITLE") "pane_id=$paneId pane_title = '$got2'"

Stop-All

Write-Host ""
if ($failures -eq 0) { Write-Host "PANE TITLE AT CREATION (-T) PROVEN for new-window and split-window" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
