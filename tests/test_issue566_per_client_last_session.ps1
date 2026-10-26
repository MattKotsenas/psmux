# Issue #566 claims 1 and 3: `switch-client -l` resolved through a single
# data-dir-global `last_session` file that EVERY client attach overwrites with
# the session being ENTERED. Its "not the current session" filter then
# guaranteed that the only value able to survive was one written by a DIFFERENT
# client, so -l relocated this client into a session it had never visited,
# chosen by whoever attached most recently anywhere on the machine. And
# `#{client_last_session}` was aliased to the CURRENT session, so it could
# neither predict what -l would do nor verify what it did.
#
# The fix records the session a client came FROM on that client's own registry
# entry, reported on the attach handshake (only the client process spans both
# sides of a switch, since psmux runs one server per session).
#
# EVERYTHING runs in ONE script invocation on purpose: an attached client
# launched with Start-Process is killed when the tool call that spawned it ends,
# which would otherwise produce a misleading "no server running".
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$A = 'c566_alpha'; $B = 'c566_beta'
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# A REAL client is one row of `list-clients -t <session>`; a session with no
# client lists nothing. A bare list-clients lists the clients of EVERY session,
# as tmux does (issue #724), so the session is named explicitly.
function RealClients($sess) {
    $port = (Get-Content "$psmuxDir\$sess.port" -Raw -EA SilentlyContinue)
    if (-not $port) { return 0 }
    $out = & $PSMUX list-clients -t $sess -F '#{client_name}' 2>&1 | Out-String
    return ([regex]::Matches($out, '/dev/pts/\d+')).Count
}
function Fmt($sess, $fmt) {
    $port = (Get-Content "$psmuxDir\$sess.port" -Raw -EA SilentlyContinue)
    if (-not $port) { return '' }
    $env:TMUX = "x,$($port.Trim()),0"
    $out = (& $PSMUX display-message -p $fmt 2>&1 | Out-String).Trim()
    $env:TMUX = $null
    return $out
}
function SwitchL($sess) {
    $port = (Get-Content "$psmuxDir\$sess.port" -Raw -EA SilentlyContinue)
    $env:TMUX = "x,$($port.Trim()),0"
    $o = & $PSMUX switch-client -l 2>&1 | Out-String
    $rc = $LASTEXITCODE
    $env:TMUX = $null
    return @{ rc=$rc; out=$o.Trim() }
}

foreach ($s in @($A,$B)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800
& $PSMUX new-session -d -s $A 2>&1 | Out-Null
& $PSMUX new-session -d -s $B 2>&1 | Out-Null
Start-Sleep -Seconds 4

Write-Host "=== Issue #566 claims 1 and 3: per-client last session ===" -ForegroundColor Cyan

# Client 1 attaches to alpha and has never been anywhere else.
$c1 = Start-Process $PSMUX -ArgumentList "attach","-t",$A -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 6

# CLAIM 3: a client that has not switched must report an EMPTY last session,
# not an echo of the session it is sitting in.
$cls = Fmt $A '#{client_last_session}'
$cs  = Fmt $A '#{client_session}'
if ([string]::IsNullOrWhiteSpace($cls)) { Pass "client_last_session empty before any switch (was echoing '$cs')" }
else { Fail "client_last_session should be empty, got '$cls'" }

# CLAIM 1: an UNRELATED client attaching to beta writes the global file. That
# must no longer be able to drag client 1 out of alpha.
$c2 = Start-Process $PSMUX -ArgumentList "attach","-t",$B -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 6
$globalFile = (Get-Content "$psmuxDir\last_session" -Raw -EA SilentlyContinue)
Write-Host "  (global last_session file now reads '$(($globalFile ?? '').Trim())')"

$before = RealClients $A
$r = SwitchL $A
Start-Sleep -Seconds 4
$after = RealClients $A
$betaNow = RealClients $B

if ($after -ge $before -and $after -gt 0) {
    Pass "client 1 stayed in alpha despite the global file naming beta (clients before=$before after=$after)"
} else {
    Fail "client 1 was RELOCATED out of alpha (before=$before after=$after, beta now=$betaNow)"
}
if ($r.rc -ne 0) { Pass "-l with no per-client history exits non-zero (rc=$($r.rc))" }
else { Fail "-l exited 0 despite having no last session to go to" }

foreach ($p in @($c1,$c2)) { try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {} }
Start-Sleep -Seconds 2
foreach ($s in @($A,$B)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Seconds 2

# ── POSITIVE CONTROL ──────────────────────────────────────────────────────────
# Everything above is satisfied by an implementation that simply always refuses,
# so it proves nothing on its own. A client that has GENUINELY switched must be
# able to go back, and must report where it came from. This is the half that
# caught a real defect during development: the value was originally sent on the
# attach handshake, which arrives BEFORE the client is registered, so it was
# silently dropped and -l refused every time.
& $PSMUX new-session -d -s $A 2>&1 | Out-Null
& $PSMUX new-session -d -s $B 2>&1 | Out-Null
Start-Sleep -Seconds 4
$c3 = Start-Process $PSMUX -ArgumentList "attach","-t",$A -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 6

# A real switch, driven the way a user would.
$portA = (Get-Content "$psmuxDir\$A.port" -Raw).Trim()
$env:TMUX = "x,$portA,0"; & $PSMUX switch-client -t $B 2>&1 | Out-Null; $env:TMUX = $null
Start-Sleep -Seconds 6

$cls2 = Fmt $B '#{client_last_session}'
if ($cls2 -eq $A) { Pass "after a real switch, client_last_session names the origin ('$cls2')" }
else { Fail "client_last_session should be '$A', got '$cls2'" }

$back = SwitchL $B
Start-Sleep -Seconds 6
$aEnd = RealClients $A; $bEnd = RealClients $B
if ($back.rc -eq 0 -and $aEnd -gt 0 -and $bEnd -eq 0) {
    Pass "-l returned the client to its real previous session (alpha=$aEnd beta=$bEnd)"
} else {
    Fail "-l did not return the client: rc=$($back.rc) alpha=$aEnd beta=$bEnd out=[$($back.out)]"
}

try { Stop-Process -Id $c3.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Seconds 2
foreach ($s in @($A,$B)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }

Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
