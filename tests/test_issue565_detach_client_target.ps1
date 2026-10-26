# Issue #565: detach-client's client-spec -t was deleted by the generic stripper.
# Case A: `-t <tty>` without -s was misrouted as a session name ("no session").
# Case B: `-t <tty>` with -s was promoted to detach-all, destroying a session
# with destroy-unattached on. The fix exempts detach-client's -t from the routing
# pre-pass and from the post-subcommand stripper so the handler sees the target.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = 'test565det'
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

Write-Host "=== Issue #565: detach-client -t client spec ===" -ForegroundColor Cyan

# Case A: -t <tty> without -s must NOT be reported as a missing session.
& $PSMUX kill-session -t $S 2>&1 | Out-Null
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 2
$aout = (& $PSMUX detach-client -t /dev/pts/3 2>&1) -join ' '
& $PSMUX has-session -t $S 2>$null
$aliveA = ($LASTEXITCODE -eq 0)
if ($aout -notmatch "no session '/dev/pts/3'") { Pass "case A: tty not misrouted as a session name" }
else { Fail "case A: tty routed as a session name: [$aout]" }
if ($aliveA) { Pass "case A: session survived" } else { Fail "case A: session vanished" }

# Case B: -t <tty> with -s and destroy-unattached on must NOT destroy the session.
& $PSMUX kill-session -t $S 2>&1 | Out-Null
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 2
& $PSMUX -t $S set-option -g destroy-unattached on | Out-Null
& $PSMUX detach-client -t /dev/pts/3 -s $S 2>&1 | Out-Null
& $PSMUX has-session -t $S 2>$null
$aliveB = ($LASTEXITCODE -eq 0)
if ($aliveB) { Pass "case B: targeted detach did NOT widen to detach-all" }
else { Fail "case B: session destroyed (promoted to detach-all)" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
