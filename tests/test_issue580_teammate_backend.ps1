# Issue #580: Claude Code teammate backend gaps.
#
# B2 (bare %id targets outside the active window) and B3 (silent respawn /
# select-pane no-ops) were fixed by intervening work; arms 1-2 lock them in.
# This change adds the remaining two:
#   B1: `set-option -p` / `show-options -p` pane scope. `-p` is a bare scope
#       flag (it never consumes an argument); `remain-on-exit` is wired with
#       tmux semantics (on / off / failed - keep the dead pane only when the
#       process exited nonzero), unwired pane options are refused loudly at
#       exit 1, and `show-options -p` lists the pane's stored options.
#   B4: a placeholder pane command of bare `cat` (the tmux blocker idiom the
#       teammate backend uses) is substituted with a stdin-draining blocker
#       instead of hitting PowerShell's Get-Content alias and wedging the
#       pane at a `Path[0]:` parameter prompt.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t580e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #580: teammate backend gaps ===" -ForegroundColor Cyan

# The teammate shape: a second window holding a cat-placeholder pane,
# addressed by bare %id while window 0 stays active.
$paneId = (& $PSMUX new-window -t $SESSION -n teammate -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 3
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# --- Arm 1 (B4): the cat placeholder blocks silently ---
Write-Host "[Arm 1] cat placeholder is a silent blocker" -ForegroundColor Yellow
$cap = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap -match 'Path\[0\]|Get-Content') {
    Write-Fail "placeholder pane wedged at the Get-Content parameter prompt"
} elseif ($cap.Trim().Length -le 2) {
    Write-Pass "placeholder pane is blank and blocking (no alias prompt)"
} else {
    Write-Fail "placeholder pane shows unexpected content: [$($cap.Trim().Substring(0,[Math]::Min(60,$cap.Trim().Length)))]"
}
$dead = (& $PSMUX display-message -t $paneId -p '#{pane_dead}' 2>&1 | Out-String).Trim()
if ($dead -eq "0") { Write-Pass "placeholder process is alive (blocking, not exited)" }
else { Write-Fail "placeholder process is dead (dead=$dead)" }

# --- Arm 2 (B2/B3 lock-in): bare %id respawn from a non-active window ---
Write-Host "[Arm 2] respawn-pane by bare %id from another window" -ForegroundColor Yellow
& $PSMUX respawn-pane -k -t $paneId -- "pwsh -NoProfile -Command Write-Output RESPAWN580; Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap -match 'RESPAWN580') { Write-Pass "respawn-pane replaced the placeholder" }
else { Write-Fail "respawned command output not found" }
# A respawned pane must re-register its child pid: respawn_active_pane used
# to null child_pid, blanking #{pane_pid} and sending
# #{pane_current_command} to the foreground-window fallback forever.
$rpid = (& $PSMUX display-message -t $paneId -p '#{pane_pid}' 2>&1 | Out-String).Trim()
if ($rpid -match '^\d+$') { Write-Pass "respawned pane reports a fresh pane_pid ($rpid)" }
else { Write-Fail "respawned pane lost its pane_pid (got [$rpid])" }

# --- Arm 3 (B1): pane-scope option round trip ---
Write-Host "[Arm 3] set-option -p / show-options -p round trip" -ForegroundColor Yellow
& $PSMUX set-option -p -t $paneId remain-on-exit failed 2>&1 | Out-Null
$ec1 = $LASTEXITCODE
$shown = (& $PSMUX show-options -p -t $paneId 2>&1 | Out-String).Trim()
if ($ec1 -eq 0 -and $shown -match 'remain-on-exit failed') {
    Write-Pass "remain-on-exit failed set and listed via -p"
} else {
    Write-Fail "round trip failed (set exit=$ec1, show=[$shown])"
}

# unsupported pane option: loud refusal, nonzero exit
$err = & $PSMUX set-option -p -t $paneId pane-border-style fg=red 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -and $err -match 'not supported') {
    Write-Pass "unwired pane option refused loudly (exit 1)"
} else {
    Write-Fail "unwired pane option: exit=$LASTEXITCODE out=[$($err.Trim())]"
}

# bad target: nonzero exit, no phantom success
$err = & $PSMUX set-option -p -t '%9999' remain-on-exit on 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Pass "missing pane target refused (exit 1)" }
else { Write-Fail "missing pane target accepted at exit 0" }

# --- Arm 4 (B1 semantics): remain-on-exit failed keeps a CRASHED pane ---
Write-Host "[Arm 4] remain-on-exit failed keeps a crashed pane" -ForegroundColor Yellow
& $PSMUX respawn-pane -k -t $paneId -- "pwsh -NoProfile -Command Start-Sleep 2; exit 7" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX set-option -p -t $paneId remain-on-exit failed 2>&1 | Out-Null
Start-Sleep -Seconds 5
$panes1 = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_panes}' 2>&1 | Out-String).Trim()
$dead = (& $PSMUX display-message -t $paneId -p '#{pane_dead}' 2>&1 | Out-String).Trim()
if ($dead -eq "1") { Write-Pass "crashed pane (exit 7) kept dead-but-visible" }
else { Write-Fail "crashed pane not kept (pane_dead=$dead, window panes=$panes1)" }

# --- Arm 5 (B1 semantics): remain-on-exit failed CLOSES a clean exit ---
Write-Host "[Arm 5] remain-on-exit failed closes a clean exit" -ForegroundColor Yellow
$paneId2 = (& $PSMUX split-window -d -t "${SESSION}:0" -h -P -F '#{pane_id}' 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 2
& $PSMUX set-option -p -t $paneId2 remain-on-exit failed 2>&1 | Out-Null
& $PSMUX respawn-pane -k -t $paneId2 -- "pwsh -NoProfile -Command Start-Sleep 2; exit 0" 2>&1 | Out-Null
Start-Sleep -Seconds 6
$panes0 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes0 -eq "1") { Write-Pass "cleanly-exited pane closed (window back to 1 pane)" }
else { Write-Fail "cleanly-exited pane not closed (window panes=$panes0)" }

# --- Arm 6 (B4): new-session with cat as the root command ---
Write-Host "[Arm 6] new-session root command cat" -ForegroundColor Yellow
& $PSMUX new-session -d -s "${SESSION}cat" cat 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t "${SESSION}cat" 2>$null
$alive = ($LASTEXITCODE -eq 0)
$cap = & $PSMUX capture-pane -t "${SESSION}cat" -p 2>&1 | Out-String
if ($alive -and $cap -notmatch 'Path\[0\]|Get-Content') {
    Write-Pass "cat-rooted session up with a silent blocker"
} else {
    Write-Fail "cat-rooted session: alive=$alive content=[$($cap.Trim().Substring(0,[Math]::Min(60,($cap.Trim().Length))))]"
}
& $PSMUX kill-session -t "${SESSION}cat" 2>&1 | Out-Null

# --- Arm 7 (B4): new-session with `-- cat` (the exact Claude Code teammate
# form). The `--` args take the direct-exec path (build_raw_command), which
# handed the literal `cat` to CreateProcessW and failed the whole
# new-session at exit 1 before the blocker substitution was routed here.
Write-Host "[Arm 7] new-session -- cat (direct-exec path)" -ForegroundColor Yellow
& $PSMUX new-session -d -s "${SESSION}cat2" -- cat 2>&1 | Out-Null
$ec = $LASTEXITCODE
Start-Sleep -Seconds 3
& $PSMUX has-session -t "${SESSION}cat2" 2>$null
$alive = ($LASTEXITCODE -eq 0)
$dead = (& $PSMUX display-message -t "${SESSION}cat2" -p '#{pane_dead}' 2>&1 | Out-String).Trim()
$cap = & $PSMUX capture-pane -t "${SESSION}cat2" -p 2>&1 | Out-String
if ($ec -eq 0 -and $alive -and $dead -eq "0" -and $cap -notmatch 'Path\[0\]|Get-Content') {
    Write-Pass "new-session -- cat up with a live silent blocker (exit 0)"
} else {
    Write-Fail "new-session -- cat: exit=$ec alive=$alive dead=$dead content=[$($cap.Trim())]"
}
& $PSMUX kill-session -t "${SESSION}cat2" 2>&1 | Out-Null

# `cat -` spells the same blocker idiom.
& $PSMUX new-session -d -s "${SESSION}cat3" -- cat - 2>&1 | Out-Null
$ec = $LASTEXITCODE
Start-Sleep -Seconds 3
& $PSMUX has-session -t "${SESSION}cat3" 2>$null
if ($ec -eq 0 -and $LASTEXITCODE -eq 0) {
    Write-Pass "new-session -- cat - accepted (exit 0, session up)"
} else {
    Write-Fail "new-session -- cat - failed (exit=$ec)"
}
& $PSMUX kill-session -t "${SESSION}cat3" 2>&1 | Out-Null

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
