# Issue #399: Claude Code Agent Teams teammates spawn in psmux panes but stay idle.
#
# ROOT CAUSE (proven by capturing every tmux call Claude Code makes): the lead
# spawns a teammate pane and then delivers the teammate's `claude` launch command
# with `respawn-pane -k -t %N -- "<launch command>"`. psmux's respawn-pane parsed
# only -c/-k and IGNORED the trailing `-- <command>`, so the pane was respawned
# with the DEFAULT SHELL. The teammate agent never launched -> its mailbox was
# never polled -> task assignments stayed "read": false and teammates sat idle.
#
# FIX: respawn-pane now honors `-- <command>` (like split-window already did),
# running that command in the pane instead of the default shell.
#
# This test is DETERMINISTIC (no Claude Code / no credits): it exercises the exact
# psmux mechanism Claude relies on and proves the `-- command` actually runs.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue399"
$psmuxDir = "$env:USERPROFILE\.psmux"
$marker = "$env:TEMP\psmux_issue399_marker.txt"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400; Remove-Item "$psmuxDir\$SESSION.*",$marker -Force -EA SilentlyContinue }

Cleanup
& $PSMUX new-session -d -s $SESSION -x 200 -y 50
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #399: respawn-pane honors -- <command> ===" -ForegroundColor Cyan

# Create a target pane (Claude uses: split-window -d ... -- cat as a placeholder)
$id = (& $PSMUX split-window -P -F '#{pane_id}' -t $SESSION -- cat 2>&1 | Out-String).Trim()
if ($id -match '^%\d+$') { Write-Pass "split-window -P returned a pane id ($id)" }
else { Write-Fail "split-window -P did not return a pane id (got '$id')"; Cleanup; exit 1 }
Start-Sleep -Seconds 2

# TEST 1: respawn-pane -k -t <id> -- <shell command> must RUN the command.
# Mirrors Claude Code: respawn-pane -k -t %N -- "cd '...' && ... <launch> ..."
Write-Host "`n[Test 1] respawn-pane -k -t $id -- <command> runs the command" -ForegroundColor Yellow
$shellCmd = "cd '$env:TEMP' && cmd /c echo TEAMMATE_LAUNCHED > psmux_issue399_marker.txt"
& $PSMUX respawn-pane -k -t $id -- $shellCmd 2>&1 | Out-Null
$ran = $false
for ($i=0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path $marker) { $ran = $true; break } }
if ($ran) { Write-Pass "respawn-pane executed the -- command (teammate launch would run)" }
else {
    Write-Fail "respawn-pane IGNORED the -- command (regression: teammate would never launch)"
    $cap = & $PSMUX capture-pane -t $id -p 2>&1 | Out-String
    ($cap -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
}

# TEST 2: respawn-pane WITHOUT a command still respawns the default shell (no regression).
#
# NOTE (#545/#554 rewrite): Test 1's `-- cmd /c echo > file` COMPLETES, and with
# remain-on-exit off (tmux default) its pane closes when the process exits, so
# $id no longer exists here. The old version of this test kept targeting the
# gone $id and "passed" only because unresolvable -t targets silently operated
# on the ACTIVE pane at rc 0 — the exact misroute #545 fixed. tmux errors with
# "can't find pane" for the gone id, and so does psmux now. Exercise the
# intended behavior (no-command respawn gives the default shell) on a pane
# that is still alive: a fresh long-lived `cat` pane.
Write-Host "`n[Test 2] respawn-pane with no -- command still respawns the default shell" -ForegroundColor Yellow
# The marker file appears when `cmd /c echo` has RUN, but the pane only closes
# once that process has EXITED and the server has reaped it, which is a few
# hundred ms later. Targeting $id in that window finds a still-live pane, and
# `respawn-pane -k` on a live pane legitimately succeeds at rc 0, which is not
# the case this arm pins. Wait for the id to actually leave the pane list
# (2026-09-09 sweep: 3P/1F under load, 4P/0F standalone, i.e. a race, not a
# product change).
$gone = $false
for ($i = 0; $i -lt 50; $i++) {
    $ids = & $PSMUX list-panes -s -t $SESSION -F '#{pane_id}' 2>&1 | Out-String
    if ($ids -notmatch [regex]::Escape($id)) { $gone = $true; break }
    Start-Sleep -Milliseconds 100
}
if (-not $gone) { Write-Host "     (pane $id still listed after 5s; the gone-pane check below reflects that)" -ForegroundColor DarkGray }
$out = & $PSMUX respawn-pane -k -t $id 2>&1
if ($LASTEXITCODE -ne 0 -and "$out" -match "can't find pane") {
    Write-Pass "gone pane $id correctly rejected (rc=$LASTEXITCODE, tmux parity)"
} else {
    Write-Fail "respawn-pane -t $id (gone pane) rc=$LASTEXITCODE out='$out' (expected can't find pane)"
}

$id2 = (& $PSMUX split-window -P -F '#{pane_id}' -t $SESSION -- cat 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 2
& $PSMUX respawn-pane -k -t $id2 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $id2 "echo SHELL_ALIVE_MARKER" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap2 = & $PSMUX capture-pane -t $id2 -p 2>&1 | Out-String
if ($cap2 -match "SHELL_ALIVE_MARKER") { Write-Pass "default-shell respawn still works (no regression)" }
else { Write-Fail "default-shell respawn broke" }

Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed