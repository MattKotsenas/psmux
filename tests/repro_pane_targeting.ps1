# Reproduction for the pane targeting / MRU focus cluster.
#
# Five suites fail with what look like five different bugs, and this script
# exists to find out whether they are actually one:
#
#   test_issue43_prefix_o_l      select-pane -t :.+ does not move; -l picks wrong pane
#   test_pane_navigation         "Only 3/4 panes reachable. Missing: %2"
#   test_kill_pane_by_id         "Killed pane %2 still exists"
#   test_issue71_kill_pane_focus focus after kill ignores MRU
#   test_issue140_kill_pane...   focus after kill lands on the wrong pane
#
# Everything here is observed the way a user would observe it: create real panes,
# issue a real command, then ask psmux what the state IS. No mocks, no asserts on
# internal structures. Each check prints what it did and what came back so the
# output alone is enough to judge the claim.
#
# Deliberately NOT named test_*.ps1: the runner globs that pattern and this is a
# diagnostic, not a regression test. It is promoted to a test only once it pins a
# proven bug.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$L = 'reprotgt'
$S = 'tgt'

function Hdr($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Note($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Good($m) { Write-Host "  [OK]      $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [PROBLEM] $m" -ForegroundColor Red }

function P { param([string[]]$A) (& $PSMUX -L $L @A 2>&1 | Out-String).Trim() }
function Active { P @('display-message','-t',$S,'-p','#{pane_id}') }
function PaneIds { (P @('list-panes','-t',$S,'-F','#{pane_id}')) -split "\r?\n" | Where-Object { $_ } }

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

Hdr "Setup: one window, four panes"
& $PSMUX -L $L new-session -d -s $S 2>&1 | Out-Null
Start-Sleep -Seconds 4
for ($i = 0; $i -lt 3; $i++) {
    & $PSMUX -L $L split-window -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
}
$ids = @(PaneIds)
Note "panes present: $($ids -join ', ')"
Note "active pane:   $(Active)"
if ($ids.Count -eq 4) { Good "four panes exist" } else { Bad "expected 4 panes, got $($ids.Count)" }

Hdr "Claim 1: every pane is selectable by its own %id"
foreach ($id in $ids) {
    $out = P @('select-pane','-t',$id)
    $now = Active
    if ($now -eq $id) { Good "select-pane -t $id  -> active is $now" }
    else { Bad "select-pane -t $id  -> active is $now (rc output: '$out')" }
}

Hdr "Claim 2: -t :.+ cycles through ALL panes, not a subset"
& $PSMUX -L $L select-pane -t $ids[0] 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$visited = New-Object System.Collections.Generic.List[string]
$visited.Add((Active))
for ($i = 0; $i -lt 6; $i++) {
    $out = P @('select-pane','-t',':.+')
    Start-Sleep -Milliseconds 300
    $now = Active
    Note "after -t :.+ (step $($i+1)) active=$now"
    if ($out) { Note "   command said: $out" }
    if (-not $visited.Contains($now)) { $visited.Add($now) }
}
if ($visited.Count -eq $ids.Count) { Good "-t :.+ reached all $($ids.Count) panes: $($visited -join ' -> ')" }
else { Bad "-t :.+ reached only $($visited.Count) of $($ids.Count): $($visited -join ' -> ')" }

Hdr "Claim 3: -t :.- walks the other way"
$back = New-Object System.Collections.Generic.List[string]
$back.Add((Active))
for ($i = 0; $i -lt 3; $i++) {
    P @('select-pane','-t',':.-') | Out-Null
    Start-Sleep -Milliseconds 300
    $now = Active
    if (-not $back.Contains($now)) { $back.Add($now) }
}
if ($back.Count -gt 1) { Good "-t :.- moved through: $($back -join ' -> ')" }
else { Bad "-t :.- never moved (stuck on $($back[0]))" }

Hdr "Claim 4: select-pane -l returns to the PREVIOUS pane"
$first = $ids[0]; $second = $ids[1]
P @('select-pane','-t',$first) | Out-Null; Start-Sleep -Milliseconds 300
P @('select-pane','-t',$second) | Out-Null; Start-Sleep -Milliseconds 300
Note "sequence: selected $first, then $second (active=$(Active))"
P @('select-pane','-l') | Out-Null; Start-Sleep -Milliseconds 400
$afterLast = Active
if ($afterLast -eq $first) { Good "select-pane -l returned to $first" }
else { Bad "select-pane -l went to $afterLast, expected $first" }

Hdr "Claim 5: kill-pane -t %id actually removes THAT pane"
$before = @(PaneIds)
$victim = $before[-1]
Note "killing $victim (panes before: $($before -join ', '))"
$out = P @('kill-pane','-t',$victim)
Start-Sleep -Seconds 2
$after = @(PaneIds)
Note "panes after:  $($after -join ', ')"
if ($out) { Note "command said: $out" }
if ($after -notcontains $victim) { Good "$victim is gone" } else { Bad "$victim STILL EXISTS after kill-pane" }
if ($after.Count -eq $before.Count - 1) { Good "pane count dropped $($before.Count) -> $($after.Count)" }
else { Bad "pane count went $($before.Count) -> $($after.Count), expected $($before.Count - 1)" }

Hdr "Claim 6: focus after killing the ACTIVE pane follows most-recently-used"
$ids2 = @(PaneIds)
if ($ids2.Count -ge 3) {
    $a = $ids2[0]; $b = $ids2[1]; $c = $ids2[2]
    P @('select-pane','-t',$a) | Out-Null; Start-Sleep -Milliseconds 300
    P @('select-pane','-t',$b) | Out-Null; Start-Sleep -Milliseconds 300
    P @('select-pane','-t',$c) | Out-Null; Start-Sleep -Milliseconds 400
    Note "MRU order built: $a, then $b, then $c (active=$(Active))"
    P @('kill-pane','-t',$c) | Out-Null
    Start-Sleep -Seconds 2
    $focus = Active
    Note "after killing active pane $c, focus=$focus"
    if ($focus -eq $b) { Good "focus fell back to the most recently used pane ($b)" }
    else { Bad "focus went to $focus, most-recently-used was $b" }
} else {
    Bad "not enough panes left to test MRU fallback"
}

Hdr "Cleanup"
& $PSMUX -L $L kill-server 2>&1 | Out-Null
Write-Host "  done`n"
