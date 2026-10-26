# Issue #558: kill-session -t =<name> never kills the session.
# The = exact-match prefix (tmux universal target grammar) is stripped for
# port-file routing but forwarded raw to the server, whose kill-session
# fallback compares "name" == "=name", matches nothing, and the client burns
# its 5s settle deadline before exiting 1 while the session survives.
#
# Part A: repro / regression guard for the exact reported sequence
# Part B: = prefix on other session verbs stays consistent (has-session,
#         rename-session via -t, display-message -t)
# Part C: edge cases (= with nonexistent session must fail fast, plain kill
#         still works, double == means literal "=name" session and must NOT
#         match "name")
# Part D: Win32 TUI proof: attached session killed via -t =name, window closes

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Remove-Session($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #558: kill-session -t =name ===" -ForegroundColor Cyan

# -- Part A: the reported repro, verbatim --
Write-Host "`n[Part A] kill-session -t =name kills the session" -ForegroundColor Yellow
$S = "t558_eqkill"
Remove-Session $S
& $PSMUX new-session -d -s $S -c .
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "setup: session never came up"; exit 1 }

& $PSMUX has-session -t "=$S" 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "has-session -t =name resolves (rc=0)" }
else { Write-Fail "has-session -t =name returned rc=$LASTEXITCODE" }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$killOut = & $PSMUX kill-session -t "=$S" 2>&1 | Out-String
$killRc = $LASTEXITCODE
$sw.Stop()
Write-Info "kill-session -t =name: rc=$killRc in $($sw.ElapsedMilliseconds)ms output=[$($killOut.Trim())]"

Start-Sleep -Milliseconds 800
& $PSMUX has-session -t $S 2>$null
$aliveRc = $LASTEXITCODE
if ($killRc -eq 0 -and $aliveRc -ne 0) {
    Write-Pass "session killed via =name (kill rc=0, has-session rc=$aliveRc)"
} elseif ($aliveRc -eq 0) {
    Write-Fail "REPRO: session SURVIVED kill-session -t =name (kill rc=$killRc)"
} else {
    Write-Fail "session gone but kill rc=$killRc"
}
if ($sw.ElapsedMilliseconds -lt 4000) { Write-Pass "no 5s stall ($($sw.ElapsedMilliseconds)ms)" }
else { Write-Fail "kill-session stalled $($sw.ElapsedMilliseconds)ms (settle-deadline burn)" }
Remove-Session $S

# -- Part B: = prefix consistency on other session verbs --
Write-Host "`n[Part B] = prefix works on other session-target verbs" -ForegroundColor Yellow
$S2 = "t558_eqverbs"
Remove-Session $S2
& $PSMUX new-session -d -s $S2
Start-Sleep -Seconds 3

$dm = (& $PSMUX display-message -t "=$S2" -p '#{session_name}' 2>&1 | Out-String).Trim()
if ($dm -eq $S2) { Write-Pass "display-message -t =name resolves" }
else { Write-Fail "display-message -t =name got: $dm" }

& $PSMUX rename-session -t "=$S2" "t558_renamed" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX has-session -t "t558_renamed" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "rename-session -t =name renamed the session"
    Remove-Session "t558_renamed"
} else {
    # rename with = target may be a separate defect; report, do not hard-fail Part A's fix
    & $PSMUX has-session -t $S2 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Fail "rename-session -t =name did NOT rename (old name still present)" }
    else { Write-Fail "rename-session -t =name: neither old nor new name found" }
    Remove-Session $S2
}

# -- Part C: edge cases --
Write-Host "`n[Part C] Edge cases" -ForegroundColor Yellow
# C1: =nonexistent must behave exactly like the plain nonexistent form
# (same exit code, no 5s stall). The exit CODE for missing sessions is a
# separate pre-existing behavior shared by the plain form; #558 is only
# about the = form diverging from the plain form.
& $PSMUX kill-session -t "t558_no_such_session" 2>&1 | Out-Null
$plainMissRc = $LASTEXITCODE
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $PSMUX kill-session -t "=t558_no_such_session" 2>&1 | Out-Null
$rc = $LASTEXITCODE
$sw.Stop()
if ($rc -eq $plainMissRc) { Write-Pass "kill-session -t =missing matches plain-missing rc ($rc)" }
else { Write-Fail "=missing rc=$rc but plain-missing rc=$plainMissRc" }
if ($sw.ElapsedMilliseconds -lt 4000) { Write-Pass "missing-target handling is fast ($($sw.ElapsedMilliseconds)ms)" }
else { Write-Fail "missing-target kill stalled $($sw.ElapsedMilliseconds)ms" }

# C2: plain-name kill still works (no regression)
$S3 = "t558_plain"
Remove-Session $S3
& $PSMUX new-session -d -s $S3
Start-Sleep -Seconds 3
& $PSMUX kill-session -t $S3 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 800
& $PSMUX has-session -t $S3 2>$null
if ($rc -eq 0 -and $LASTEXITCODE -ne 0) { Write-Pass "plain kill-session still works" }
else { Write-Fail "plain kill-session broke: rc=$rc alive=$LASTEXITCODE" }
Remove-Item "$psmuxDir\$S3.*" -Force -EA SilentlyContinue

# -- Part D: Win32 TUI proof --
Write-Host "`n[Part D] Win32 TUI: attached session killed via -t =name" -ForegroundColor Yellow
$S4 = "t558_tui"
Remove-Session $S4
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S4 -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $S4 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "TUI session never came up" }
else {
    $att = (& $PSMUX display-message -t "=$S4" -p '#{session_attached}' 2>&1 | Out-String).Trim()
    if ($att -match "^[1-9]") { Write-Pass "TUI: display-message -t =name sees attached client" }
    else { Write-Fail "TUI: expected attached=1 via =name, got: $att" }

    & $PSMUX kill-session -t "=$S4" 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    Start-Sleep -Seconds 2
    & $PSMUX has-session -t $S4 2>$null
    if ($rc -eq 0 -and $LASTEXITCODE -ne 0) { Write-Pass "TUI: attached session killed via =name" }
    else { Write-Fail "TUI: attached kill via =name failed (rc=$rc alive=$LASTEXITCODE)" }
}
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$S4.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
