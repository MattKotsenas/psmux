# Issue #485: display-message reports the LAST created/attached session instead
# of the session the calling pane is attached to.
#
# Root cause: a warm-pool pane shell inherits PSMUX_TARGET_SESSION=__warm__ from
# the warm server's environment. When a psmux CLI command runs inside that pane
# with no explicit `-t`, main() saw PSMUX_TARGET_SESSION already set and skipped
# the $TMUX-based resolution, routing the query to the most-recent session.
#
# Fix: with no explicit `-t <session>`, $TMUX (which correctly names the live
# server for the pane) is authoritative and overrides any stale inherited
# PSMUX_TARGET_SESSION.
#
# This test PROVES the fix by running `display-message -p '#S'` INSIDE each
# session's own pane (the exact path the reporter used) while a different,
# newer session is the last-created one.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

$SESSIONS = @("iss485_repro", "iss485_other", "iss485_third")

function Cleanup {
    foreach ($s in $SESSIONS) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    foreach ($s in $SESSIONS) {
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
}

# Run a display-message query INSIDE a session's own pane and return what #S
# (and optionally more) resolves to. This is the reporter's exact code path:
# the CLI runs inside the pane, inheriting the pane's environment.
$script:QueryN = 0
function Query-InPane {
    # NOTE: do NOT name a parameter $Args -- it collides with PowerShell's
    # automatic $args variable and silently fails to bind.
    param([string]$Session, [string]$Format = '#S', [string]$ExtraArgs = '')
    # Unique per-call token so a stale line from an earlier query in the same
    # pane can never be mistaken for this call's output.
    $script:QueryN++
    $marker = "ISS485MARK$($script:QueryN)"
    $cmd = "clear; tmux display-message $ExtraArgs -p `"$marker=[$Format]`""
    & $PSMUX send-keys -t $Session $cmd Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t $Session -p 2>&1 | Out-String
    # Take the LAST match of this call's unique marker (freshest render).
    $m = [regex]::Matches($cap, "$marker=\[(.*?)\]")
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
    return "<no-output>"
}

Cleanup
Write-Host "`n=== Issue #485: active-session resolution inside a pane ===" -ForegroundColor Cyan

# Create three sessions in order; the LAST one created (iss485_third) is the
# stale "most recent" that the bug used to leak into every query.
& $PSMUX new-session -d -s "iss485_repro";  Start-Sleep -Seconds 3
& $PSMUX new-session -d -s "iss485_other";  Start-Sleep -Seconds 3
& $PSMUX new-session -d -s "iss485_third";  Start-Sleep -Seconds 3

foreach ($s in $SESSIONS) {
    & $PSMUX has-session -t $s 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Fail "setup: $s not created"; Cleanup; exit 1 }
}
Write-Host "  Sessions created (iss485_third is the last-created)" -ForegroundColor DarkGray

# === TEST 1: #S inside iss485_repro must be iss485_repro (not iss485_third) ===
Write-Host "`n[Test 1] '#S' inside iss485_repro's own pane" -ForegroundColor Yellow
$r = Query-InPane -Session "iss485_repro" -Format '#S'
if ($r -eq "iss485_repro") { Write-Pass "reports iss485_repro (was iss485_third before fix)" }
else { Write-Fail "expected iss485_repro, got '$r'" }

# === TEST 2: #S inside iss485_other must be iss485_other ===
Write-Host "`n[Test 2] '#S' inside iss485_other's own pane" -ForegroundColor Yellow
$r = Query-InPane -Session "iss485_other" -Format '#S'
if ($r -eq "iss485_other") { Write-Pass "reports iss485_other" }
else { Write-Fail "expected iss485_other, got '$r'" }

# === TEST 3: #S inside iss485_third (the last-created) must be itself ===
Write-Host "`n[Test 3] '#S' inside iss485_third's own pane" -ForegroundColor Yellow
$r = Query-InPane -Session "iss485_third" -Format '#S'
if ($r -eq "iss485_third") { Write-Pass "reports iss485_third" }
else { Write-Fail "expected iss485_third, got '$r'" }

# === TEST 4: other identifying vars resolve to the calling session too ===
Write-Host "`n[Test 4] session_name / session_id target the calling pane" -ForegroundColor Yellow
$r = Query-InPane -Session "iss485_repro" -Format '#{session_name}:#{window_index}.#{pane_index}'
if ($r -eq "iss485_repro:0.0") { Write-Pass "full target #{session_name}:#{window_index}.#{pane_index} = $r" }
else { Write-Fail "expected iss485_repro:0.0, got '$r'" }

# === TEST 5: explicit -t still wins (no over-correction) ===
Write-Host "`n[Test 5] explicit -t from inside a pane is still honored" -ForegroundColor Yellow
$r = Query-InPane -Session "iss485_repro" -Format '#S' -ExtraArgs '-t iss485_other'
if ($r -eq "iss485_other") { Write-Pass "explicit -t iss485_other honored from iss485_repro's pane" }
else { Write-Fail "expected iss485_other, got '$r'" }

# === TEST 6: raw env inside the pane no longer misroutes the CLI ===
# The pane may still carry PSMUX_TARGET_SESSION=__warm__ (frozen warm env), but
# the CLI must ignore it. Prove #S is correct even while that var is present.
Write-Host "`n[Test 6] stale PSMUX_TARGET_SESSION in pane env does not misroute" -ForegroundColor Yellow
& $PSMUX send-keys -t "iss485_repro" 'clear; tmux display-message -p "ENVCHK=[#S]|PTS=[$($env:PSMUX_TARGET_SESSION)]"' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t "iss485_repro" -p 2>&1 | Out-String
if ($cap -match "ENVCHK=\[(.*?)\]\|PTS=\[(.*?)\]") {
    $sVal = $Matches[1]; $pts = $Matches[2]
    Write-Host "    (#S=$sVal, inherited PSMUX_TARGET_SESSION='$pts')" -ForegroundColor DarkGray
    if ($sVal -eq "iss485_repro") { Write-Pass "#S correct regardless of inherited PSMUX_TARGET_SESSION" }
    else { Write-Fail "#S wrong ($sVal) despite fix; inherited PTS='$pts'" }
} else { Write-Fail "could not read env-check output" }

# === Win32 TUI VISUAL VERIFICATION (real visible window) ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$TUI = "iss485_tui"
$DECOY = "iss485_tui_decoy"
& $PSMUX kill-session -t $TUI 2>&1 | Out-Null
& $PSMUX kill-session -t $DECOY 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Launch a REAL visible attached psmux window.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$TUI -PassThru
Start-Sleep -Seconds 5
# Create a NEWER decoy session (the last-created one the bug used to leak).
& $PSMUX new-session -d -s $DECOY
Start-Sleep -Seconds 3

Write-Host "`n[TUI 1] '#S' inside the visible window's pane must be $TUI (not the newer decoy)" -ForegroundColor Yellow
& $PSMUX send-keys -t $TUI 'clear; tmux display-message -p "TUIMARK=[#S]"' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $TUI -p 2>&1 | Out-String
if ($cap -match "TUIMARK=\[(.*?)\]") {
    if ($Matches[1] -eq $TUI) { Write-Pass "TUI: visible window reports its own session ($TUI)" }
    else { Write-Fail "TUI: expected $TUI, got '$($Matches[1])'" }
} else { Write-Fail "TUI: no TUIMARK output captured" }

Write-Host "`n[TUI 2] session stays functional (split-window via CLI)" -ForegroundColor Yellow
& $PSMUX split-window -v -t $TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

& $PSMUX kill-session -t $TUI 2>&1 | Out-Null
& $PSMUX kill-session -t $DECOY 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$TUI.*","$psmuxDir\$DECOY.*" -Force -EA SilentlyContinue

Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
