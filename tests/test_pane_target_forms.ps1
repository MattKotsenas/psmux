# Pane target forms: "%id" in the pane slot, and relative pane specifiers.
#
# Two bugs found by the full suite, both proved against real tmux 3.4 in WSL
# before anything was changed:
#
# 1. DESTRUCTIVE. A %id in the pane slot of "session:window.pane" was parsed with
#    a bare integer parse, which fails on the '%'. The pane component came back
#    empty and the command fell through to the ACTIVE pane. Measured:
#
#      panes 0:%1 0:%2 1:%3 1:%4, active %2, current window 0
#      psmux kill-pane -t wt:.%4   ->  exit 0, and %2 died instead of %4
#
#    A user asking to close one pane silently lost a different one, in a
#    different window, with a success exit code. tmux kills %4.
#
# 2. Relative pane targets never reached the server. "-t :.+" was split as a
#    WINDOW literally named ".+", so the client refused with "can't find window:
#    .+" and exited 1 without sending anything. The server implements +/- fine:
#    driving the same command over the control socket moved the pane correctly.
#
# The parity oracle for every claim below is tmux 3.4:
#   tmux select-pane -t :.+      rc 0, cycles %0 -> %1 -> %2 -> %0
#   tmux kill-pane   -t cw:.%3   rc 0, kills %3 even from another window
#   tmux kill-pane   -t sp:%1    rc 1, "can't find window: %1"  (pane id in the
#                                 WINDOW slot is an error in tmux too)
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$L = 'ptf'
$S = 'ptf1'
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Px { param([string[]]$A) (& $PSMUX -L $L @A 2>&1 | Out-String).Trim() }
function AllPanes { @(& $PSMUX -L $L list-panes -a -F '#{window_index}:#{pane_id}' 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function ActivePane { (Px @('display-message','-t',$S,'-p','#{pane_id}')) }

function Reset-Layout {
    # window 0: two panes, window 1: two panes, window 0 focused.
    & $PSMUX -L $L kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    & $PSMUX -L $L new-session -d -s $S 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    & $PSMUX -L $L split-window -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX -L $L new-window -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX -L $L split-window -t $S 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX -L $L select-window -t "${S}:0" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}

Write-Host "`n=== Pane target forms ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
Write-Host "`n[Test 1] session:.%id kills THAT pane, not the active one" -ForegroundColor Yellow
Reset-Layout
$before = AllPanes
$active = ActivePane
$victim = (@(& $PSMUX -L $L list-panes -t "${S}:1" -F '#{pane_id}')[-1]).Trim()
Write-Host "  layout: $($before -join ' ')  active=$active  victim=$victim (window 1)"
if ($before.Count -eq 4 -and $victim -ne $active) {
    Write-Pass "precondition: 4 panes, victim ($victim) is NOT the active pane ($active)"
} else {
    Write-Fail "precondition failed: panes=$($before.Count) victim=$victim active=$active"
}
& $PSMUX -L $L kill-pane -t "${S}:.$victim" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$after = AllPanes
$died = @($before | Where-Object { $after -notcontains $_ })
Write-Host "  after:  $($after -join ' ')   died: $($died -join ' ')"
if ($died.Count -eq 1 -and $died[0] -like "*$victim") {
    Write-Pass "the targeted pane $victim died"
} else {
    Write-Fail "wrong pane died: $($died -join ', ') (expected $victim)"
}
if ($after -contains "0:$active") {
    Write-Pass "the active pane $active survived (it was never the target)"
} else {
    Write-Fail "DESTRUCTIVE: active pane $active was killed instead of $victim"
}

# ---------------------------------------------------------------------------
Write-Host "`n[Test 2] a %id in the WINDOW slot is refused, as tmux does" -ForegroundColor Yellow
Reset-Layout
$panes = AllPanes
$target = (@(& $PSMUX -L $L list-panes -t "${S}:0" -F '#{pane_id}')[-1]).Trim()
$out = Px @('kill-pane','-t',"${S}:$target")
$rc = $LASTEXITCODE
$still = AllPanes
if ($rc -ne 0) { Write-Pass "session:%id refused with rc=$rc (tmux: rc 1)" }
else { Write-Fail "session:%id was accepted (rc=0); tmux rejects it" }
if ($out -match "can't find window") { Write-Pass "diagnostic matches tmux: $out" }
else { Write-Fail "unexpected diagnostic: [$out]" }
if ($still.Count -eq $panes.Count) { Write-Pass "nothing was killed by the rejected target" }
else { Write-Fail "a pane died despite the target being refused: $($panes.Count) -> $($still.Count)" }

# ---------------------------------------------------------------------------
Write-Host "`n[Test 3] -t :.+ and :.- cycle through every pane" -ForegroundColor Yellow
Reset-Layout
$w0 = @(& $PSMUX -L $L list-panes -t "${S}:0" -F '#{pane_id}' | ForEach-Object { $_.Trim() })
& $PSMUX -L $L select-pane -t $w0[0] 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$visited = New-Object System.Collections.Generic.List[string]
$visited.Add((ActivePane))
$err = ''
for ($i = 0; $i -lt $w0.Count; $i++) {
    $o = Px @('select-pane','-t',':.+')
    if ($o) { $err = $o }
    Start-Sleep -Milliseconds 350
    $now = ActivePane
    if (-not $visited.Contains($now)) { $visited.Add($now) }
}
if ($err) { Write-Fail "-t :.+ reported an error: $err" }
else { Write-Pass "-t :.+ was accepted (no client-side refusal)" }
if ($visited.Count -eq $w0.Count) {
    Write-Pass "-t :.+ reached all $($w0.Count) panes: $($visited -join ' -> ')"
} else {
    Write-Fail "-t :.+ reached only $($visited.Count)/$($w0.Count): $($visited -join ' -> ')"
}
$beforeBack = ActivePane
Px @('select-pane','-t',':.-') | Out-Null
Start-Sleep -Milliseconds 400
if ((ActivePane) -ne $beforeBack) { Write-Pass "-t :.- moved in the other direction" }
else { Write-Fail "-t :.- did not move (stuck on $beforeBack)" }

# ---------------------------------------------------------------------------
Write-Host "`n[Test 4] bare %id and session:window.%id both resolve" -ForegroundColor Yellow
Reset-Layout
$victim = (@(& $PSMUX -L $L list-panes -t "${S}:1" -F '#{pane_id}')[-1]).Trim()
$n0 = (AllPanes).Count
& $PSMUX -L $L kill-pane -t $victim 2>&1 | Out-Null
Start-Sleep -Seconds 2
if ((AllPanes) -notcontains "1:$victim") { Write-Pass "bare $victim killed the right pane" }
else { Write-Fail "bare $victim did not kill it" }

Reset-Layout
$victim2 = (@(& $PSMUX -L $L list-panes -t "${S}:1" -F '#{pane_id}')[-1]).Trim()
& $PSMUX -L $L kill-pane -t "${S}:1.$victim2" 2>&1 | Out-Null
Start-Sleep -Seconds 2
if ((AllPanes) -notcontains "1:$victim2") { Write-Pass "session:1.$victim2 killed the right pane" }
else { Write-Fail "session:1.$victim2 did not kill it" }

# ---------------------------------------------------------------------------
# Win32 TUI check: the same target form driven against a REAL visible window.
Write-Host "`n[Test 5] Win32 TUI: relative select-pane on a live window" -ForegroundColor Yellow
& $PSMUX -L $L kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$tuiS = 'ptf_tui'
$proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$L,"new-session","-s",$tuiS -PassThru
Start-Sleep -Seconds 5
& $PSMUX -L $L split-window -t $tuiS 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panesT = @(& $PSMUX -L $L list-panes -t $tuiS -F '#{pane_id}' | ForEach-Object { $_.Trim() })
if ($panesT.Count -eq 2) { Write-Pass "TUI: split produced 2 panes" } else { Write-Fail "TUI: expected 2 panes, got $($panesT.Count)" }
$b = (& $PSMUX -L $L display-message -t $tuiS -p '#{pane_id}' 2>&1).Trim()
& $PSMUX -L $L select-pane -t ':.+' 2>&1 | Out-Null
Start-Sleep -Seconds 1
$a = (& $PSMUX -L $L display-message -t $tuiS -p '#{pane_id}' 2>&1).Trim()
if ($a -ne $b) { Write-Pass "TUI: -t :.+ moved the active pane on a live window ($b -> $a)" }
else { Write-Fail "TUI: -t :.+ did not move the active pane (stuck on $b)" }
& $PSMUX -L $L kill-session -t $tuiS 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

& $PSMUX -L $L kill-server 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
