# Issue #566, claim 2: `switch-client -l` returned rc 0 with empty stdout and
# stderr whatever happened, so a caller could not tell "switched", "did nothing"
# and "switched somewhere unintended" apart. The -l/-n/-p arms were dispatched
# fire-and-forget and their only failure report was a TUI status line that a
# one-shot CLI caller never sees. They now carry the same reply channel the -t
# arm already had, so a failure exits non-zero with the reason on stderr,
# matching tmux ("can't find last session", rc 1).
#
# NOTE: this covers the EXIT CODE half of #566 only. The relocation half (a
# client being moved into a session it has never visited, because last_session
# is a single data-dir-global file) needs per-client history and is NOT fixed here.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$L = 'i566sock'
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# Run a psmux verb capturing stdout and stderr separately, so the two streams
# can never be conflated.
function Probe {
    param([string[]]$PsmuxArgs)
    $o = [System.IO.Path]::GetTempFileName(); $e = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $PSMUX -ArgumentList $PsmuxArgs -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $r = @{ rc=$p.ExitCode
            stdout=(Get-Content $o -Raw -EA SilentlyContinue)
            stderr=(Get-Content $e -Raw -EA SilentlyContinue) }
    Remove-Item $o,$e -Force -EA SilentlyContinue
    return $r
}

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX -L $L new-session -d -s solo
Start-Sleep -Seconds 4

Write-Host "=== Issue #566: switch-client -l must report failure ===" -ForegroundColor Cyan

# Point last_session at a session that does not exist, so -l CANNOT resolve.
# tmux answers "can't find last session" with rc 1; psmux used to answer rc 0.
$lastPath = "$psmuxDir\last_session"
$saved = if (Test-Path $lastPath) { Get-Content $lastPath -Raw } else { $null }
Set-Content -Path $lastPath -Value "i566_ghost_never_existed" -NoNewline

$port = (Get-Content "$psmuxDir\${L}__solo.port" -Raw).Trim()
$env:TMUX = "x,$port,0"
$r = Probe @('-L', $L, 'switch-client', '-l')
$env:TMUX = $null

Write-Host "  rc=$($r.rc) stdout=[$(($r.stdout ?? '').Trim())] stderr=[$(($r.stderr ?? '').Trim())]"
if ($r.rc -ne 0) { Pass "unresolvable -l exits non-zero (rc=$($r.rc))" }
else { Fail "unresolvable -l still exits 0 (silent no-op)" }
if (($r.stderr ?? '') -match 'last session') { Pass "reason reported on stderr" }
else { Fail "no reason on stderr" }
if ([string]::IsNullOrWhiteSpace($r.stdout)) { Pass "stdout stayed clean" }
else { Fail "diagnostic leaked to stdout: [$($r.stdout)]" }

# Restore whatever the file held before, so this test leaves no trace.
if ($null -ne $saved) { Set-Content -Path $lastPath -Value $saved -NoNewline }
else { Remove-Item $lastPath -Force -EA SilentlyContinue }

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
