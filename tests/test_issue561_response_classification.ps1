# Issue #561: send_control_with_response classified nothing, so three non-reply
# outcomes were reported as a successful command at rc 0:
#   A) a server refusal was returned as reply DATA and printed to STDOUT
#   B) a post-ack stall returned Ok("")      (looks like an empty result set)
#   C) a post-ack truncation returned Ok(partial) (looks like a complete result)
# The fix classifies at the chokepoint: the two exact auth refusal strings become
# a PermissionDenied error, and any read timeout becomes a TimedOut error (the
# old guard also required buf.is_empty(), which the OK ack made permanently
# false on every authenticated connection).
#
# This file covers case A, which is deterministic: hold the session .key open
# with FileShare.None (what an on-access scanner does) so the client cannot read
# it, sends an empty key, and the server refuses the connection.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = 'test561auth'
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# Run a psmux verb capturing stdout and stderr to SEPARATE files so the two
# streams can never be conflated (the whole point of this issue).
function Probe {
    param([string[]]$PsmuxArgs)
    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $PSMUX -ArgumentList $PsmuxArgs -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $res = @{
        rc     = $p.ExitCode
        stdout = (Get-Content $o -Raw -EA SilentlyContinue)
        stderr = (Get-Content $e -Raw -EA SilentlyContinue)
    }
    Remove-Item $o,$e -Force -EA SilentlyContinue
    return $res
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "SETUP FAILED: no session"; exit 1 }

Write-Host "=== Issue #561: refusal must not be reported as reply data ===" -ForegroundColor Cyan

# CONTROL (lock absent): the same verb must return real data at rc 0.
$ctrl = Probe @('-t', $S, 'list-windows')
if ($ctrl.rc -eq 0 -and $ctrl.stdout -match 'panes') { Pass "control: list-windows returns real data at rc 0" }
else { Fail "control invalid: rc=$($ctrl.rc) stdout=[$($ctrl.stdout)]" }

# PROBE: hold the key file open so the client cannot read it.
$key = "$psmuxDir\$S.key"
$fs = [System.IO.File]::Open($key, 'Open', 'Read', 'None')
try {
    foreach ($verb in @(@('list-windows'), @('list-panes'), @('display-message','-p','#{window_index}'))) {
        $r = Probe (@('-t', $S) + $verb)
        $name = ($verb -join ' ')
        if ($r.stdout -match 'ERROR: Authentication required') {
            Fail "$name leaked the refusal to STDOUT (rc=$($r.rc))"
        } elseif ($r.rc -ne 0) {
            Pass "$name refused with rc=$($r.rc) and clean stdout"
        } else {
            Fail "$name exited 0 on a refused connection (stdout=[$($r.stdout)])"
        }
    }
} finally {
    $fs.Close()
}

# CONTROL AGAIN (lock released): proves the probe measured the lock, not a dead session.
$ctrl2 = Probe @('-t', $S, 'list-windows')
if ($ctrl2.rc -eq 0 -and $ctrl2.stdout -match 'panes') { Pass "control after unlock: back to real data at rc 0" }
else { Fail "control-after invalid: rc=$($ctrl2.rc) stdout=[$($ctrl2.stdout)]" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
