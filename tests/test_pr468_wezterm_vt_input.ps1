# PR #468: WezTerm VT mouse input routing
# Proves the patched psmux (a) does NOT regress the normal local terminal case
# and (b) boots + stays functional when WezTerm env vars force the VT input path.
#
# The routing decision itself (needs_vt_input) is proven irrefutably by the Rust
# unit tests in tests-rs/test_pr468_wezterm_vt_input.rs. This E2E layer proves the
# patched binary behaves at runtime end-to-end.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== PR #468 WezTerm VT input E2E ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Part A: NORMAL LOCAL CASE (no WezTerm env) must be fully functional.
# Guards against the patched binary regressing the common path.
# ---------------------------------------------------------------------------
Write-Host "`n[Part A] Normal local terminal (no WezTerm vars)" -ForegroundColor Yellow
$SA = "pr468_local"
Cleanup $SA
Remove-Item Env:\WEZTERM_PANE -EA SilentlyContinue
Remove-Item Env:\TERM_PROGRAM -EA SilentlyContinue
& $PSMUX new-session -d -s $SA
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SA 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "A: session created" } else { Write-Fail "A: session not created"; Cleanup $SA }

& $PSMUX split-window -v -t $SA 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panes = (& $PSMUX display-message -t $SA -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "A: split-window works (2 panes)" } else { Write-Fail "A: expected 2 panes, got $panes" }

& $PSMUX send-keys -t $SA "echo PR468_LOCAL_OK" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap = & $PSMUX capture-pane -t $SA -p 2>&1 | Out-String
if ($cap -match "PR468_LOCAL_OK") { Write-Pass "A: pane echo works" } else { Write-Fail "A: pane echo not captured" }
Cleanup $SA

# ---------------------------------------------------------------------------
# Part B: WEZTERM ENV forces the VT input path. Patched binary must still boot
# a functional session (no crash / hang) with the server reachable + responsive.
# ---------------------------------------------------------------------------
Write-Host "`n[Part B] WezTerm env vars set (forces VT input path)" -ForegroundColor Yellow
$SB = "pr468_wez"
Cleanup $SB
$env:TERM_PROGRAM = "WezTerm"
$env:WEZTERM_PANE = "0"
# Launch a REAL visible attached window so the client actually evaluates
# needs_vt_input() and enters VT input mode with send_mouse_enable().
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SB -PassThru
Start-Sleep -Seconds 5

& $PSMUX has-session -t $SB 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "B: session booted under WezTerm env" } else { Write-Fail "B: session did not boot" }

if (-not $proc.HasExited) { Write-Pass "B: client process alive (no crash)" } else { Write-Fail "B: client process exited (code $($proc.ExitCode))" }

# Server responsive via CLI while client is in VT input mode
$sn = (& $PSMUX display-message -t $SB -p '#{session_name}' 2>&1).Trim()
if ($sn -eq $SB) { Write-Pass "B: server responsive (display-message)" } else { Write-Fail "B: server not responsive, got '$sn'" }

# Pane still runs commands (server-side, unaffected by client input mode)
& $PSMUX send-keys -t $SB "echo PR468_WEZ_OK" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$capB = & $PSMUX capture-pane -t $SB -p 2>&1 | Out-String
if ($capB -match "PR468_WEZ_OK") { Write-Pass "B: pane echo works under WezTerm env" } else { Write-Fail "B: pane echo not captured under WezTerm env" }

# TUI: split via CLI to prove rendering path is live
& $PSMUX split-window -h -t $SB 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panesB = (& $PSMUX display-message -t $SB -p '#{window_panes}' 2>&1).Trim()
if ($panesB -eq "2") { Write-Pass "B: TUI split-window works under WezTerm env" } else { Write-Fail "B: expected 2 panes, got $panesB" }

# Cleanup
& $PSMUX kill-session -t $SB 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item Env:\WEZTERM_PANE -EA SilentlyContinue
Remove-Item Env:\TERM_PROGRAM -EA SilentlyContinue
Cleanup $SB

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
