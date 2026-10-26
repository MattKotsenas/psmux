# Issue #437: join-pane silently does nothing when the target window cannot be resolved.
#
# Root cause: both the server-side CtrlReq::JoinPane handler (src/server/mod.rs) and the
# client-side join_pane_local (src/commands.rs) guarded the whole operation behind
#   if src_idx < len && raw_target_win < len && src_idx != raw_target_win { ... }
# and did NOTHING (RC=0, no message) when the guard failed. psmux defaults base-index to 0,
# so a tmux user typing `join-pane -t :2` on a 2-window session targets a non-existent
# window and the command appeared completely broken with zero feedback.
#
# Fix: emit a tmux-style status-bar error for each failure mode instead of a silent no-op:
#   - target window out of range  -> "join-pane: can't find window: N"
#   - source window out of range  -> "join-pane: can't find source window: N"
#   - target == source window     -> "join-pane: can't join a pane to its own window"
#
# This test proves: (C) missing target errors, (B) own-window errors, (A) a valid join
# still merges panes (no regression).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Fresh($S){
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
    & $PSMUX new-session -d -s $S
    Start-Sleep -Seconds 3
}

# Read app.status_message out of the server via dump-state JSON.
function Get-StatusMessage($S){
    $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 4000
    $st = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("dump-state`n"); $w.Flush()
    $best = $null
    for ($i = 0; $i -lt 60; $i++) {
        try { $l = $r.ReadLine() } catch { break }
        if ($null -eq $l) { break }
        if ($l -ne "NC" -and $l.Length -gt 80) { $best = $l; break }
    }
    $tcp.Close()
    if ($best) { try { return ($best | ConvertFrom-Json).status_message } catch { return $null } }
    return $null
}

Write-Host "`n=== Issue #437: join-pane missing/invalid target ===" -ForegroundColor Cyan

# --- Test C: target window does not exist (reporter's scenario) ---
Write-Host "`n[Test C] join-pane -t :9 on a 2-window session reports an error" -ForegroundColor Yellow
$S = "i437_C"; Fresh $S
& $PSMUX new-window -t $S; Start-Sleep -Milliseconds 800
& $PSMUX join-pane -t "$S`:9" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$msg = Get-StatusMessage $S
if ($msg -match "can't find window: 9") { Write-Pass "missing target surfaces error: [$msg]" }
else { Write-Fail "expected 'can't find window: 9', got: [$msg]" }
$panes = (& $PSMUX list-windows -t $S -F '#{window_panes}' 2>&1)
if (($panes -join ',') -eq '1,1') { Write-Pass "session unchanged (no corruption)" }
else { Write-Fail "session altered: panes=$($panes -join ',')" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test B: join a pane into its own window ---
Write-Host "`n[Test B] join-pane into the current window reports an error" -ForegroundColor Yellow
$S = "i437_B"; Fresh $S
& $PSMUX new-window -t $S; Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "$S`:1"; Start-Sleep -Milliseconds 400
& $PSMUX join-pane -t "$S`:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$msg = Get-StatusMessage $S
if ($msg -match "own window") { Write-Pass "own-window join surfaces error: [$msg]" }
else { Write-Fail "expected 'own window' error, got: [$msg]" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

# --- Test A: valid join still works (regression guard) ---
Write-Host "`n[Test A] valid join-pane still merges panes" -ForegroundColor Yellow
$S = "i437_A"; Fresh $S
& $PSMUX new-window -t $S; Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "$S`:0"; Start-Sleep -Milliseconds 400
& $PSMUX join-pane -t "$S`:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$firstWinPanes = (& $PSMUX list-windows -t $S -F '#{window_panes}' 2>&1 | Select-Object -First 1)
if ("$firstWinPanes".Trim() -eq "2") { Write-Pass "valid join merged 2 panes into one window" }
else { Write-Fail "valid join broken (panes=$firstWinPanes)" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
