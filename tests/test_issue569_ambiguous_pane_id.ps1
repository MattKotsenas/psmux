# Issue #569: psmux runs one server per session and each allocates %N from its
# own counter starting at 1, so %1 exists in EVERY session simultaneously. An
# unqualified `-t %1` could therefore be resolved by a most-recently-used
# fallback into a session the caller never meant, silently and at exit 0.
#
# The refusal is deliberately NARROW, and this file exists to pin both edges:
#
#   * When the session the command is ROUTED to owns the id, that is the answer.
#     Refusing there would break the ordinary "read a %id from this session and
#     use it" idiom. The first version of this fix refused unconditionally and
#     regressed test_named_session_parity, which is exactly this case.
#
#   * Only when the routed session does NOT own the id, and several others do,
#     is the target genuinely unanswerable. That is the case #569 reported, and
#     the only one that errors.
#
# Routing is pinned with $env:TMUX (what every pane inside a session sets), so
# these tests control which session is "current" rather than depending on the
# most-recently-used fallback.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$L = 't569'
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function PortOf($sess) { (Get-Content "$psmuxDir\${L}__$sess.port" -Raw -EA SilentlyContinue).Trim() }

# Run psmux with routing pinned at $RouteTo, capturing stdout/stderr separately.
function Probe {
    param([string]$RouteTo, [string[]]$PsmuxArgs)
    $o = [System.IO.Path]::GetTempFileName(); $e = [System.IO.Path]::GetTempFileName()
    $port = PortOf $RouteTo
    $env:TMUX = "x,$port,0"
    $p = Start-Process -FilePath $PSMUX -ArgumentList $PsmuxArgs -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $env:TMUX = $null
    $r = @{ rc=$p.ExitCode
            stdout=((Get-Content $o -Raw -EA SilentlyContinue) ?? '').Trim()
            stderr=((Get-Content $e -Raw -EA SilentlyContinue) ?? '').Trim() }
    Remove-Item $o,$e -Force -EA SilentlyContinue
    return $r
}

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

Write-Host "=== Issue #569: unqualified %N pane targets ===" -ForegroundColor Cyan

# alpha: ONE pane  -> owns %1 only
# beta, gamma: TWO panes each -> both own %1 AND %2
& $PSMUX -L $L new-session -d -s alpha 2>&1 | Out-Null
& $PSMUX -L $L new-session -d -s beta  2>&1 | Out-Null
& $PSMUX -L $L new-session -d -s gamma 2>&1 | Out-Null
Start-Sleep -Seconds 5
& $PSMUX -L $L split-window -t beta  2>&1 | Out-Null
& $PSMUX -L $L split-window -t gamma 2>&1 | Out-Null
Start-Sleep -Seconds 4

# Prove the precondition instead of assuming it.
$panes = & $PSMUX -L $L list-panes -a -F '#{session_name} #{pane_id}' 2>&1 | Out-String
$alphaHas2 = $panes -match 'alpha\s+%2'
$betaHas2  = $panes -match 'beta\s+%2'
$gammaHas2 = $panes -match 'gamma\s+%2'
if (-not $alphaHas2 -and $betaHas2 -and $gammaHas2) {
    Pass "precondition: %2 exists in beta+gamma but NOT alpha"
} else {
    Fail "precondition not met: alpha%2=$alphaHas2 beta%2=$betaHas2 gamma%2=$gammaHas2`n$panes"
}

# --- EDGE 1: routed session OWNS the id -> must RESOLVE (regression guard for
# test_named_session_parity, which the first version of this fix broke).
$r = Probe -RouteTo beta -PsmuxArgs @('-L', $L, 'display-message', '-p', '-t', '%1', '#{session_name}')
if ($r.rc -eq 0 -and $r.stdout -eq 'beta') { Pass "routed session owns %1 -> resolves to 'beta' (rc=0)" }
else { Fail "routed-owner case broke: rc=$($r.rc) out=[$($r.stdout)] err=[$($r.stderr)]" }

$r2 = Probe -RouteTo beta -PsmuxArgs @('-L', $L, 'display-message', '-p', '-t', '%2', '#{session_name}')
if ($r2.rc -eq 0 -and $r2.stdout -eq 'beta') { Pass "routed session owns %2 -> resolves to 'beta' (rc=0)" }
else { Fail "routed-owner case broke for %2: rc=$($r2.rc) out=[$($r2.stdout)] err=[$($r2.stderr)]" }

# --- EDGE 2: routed session does NOT own the id, several others do -> REFUSE.
# This is the #569 case: without the check, resolution falls back to picking a
# session by recency and acts on a pane the caller never named.
$a = Probe -RouteTo alpha -PsmuxArgs @('-L', $L, 'display-message', '-p', '-t', '%2', '#{session_name}')
if ($a.rc -ne 0) { Pass "routed session lacks %2, two others have it -> refused (rc=$($a.rc))" }
else { Fail "ambiguous %2 resolved anyway to [$($a.stdout)] instead of erroring" }
if ($a.stderr -match 'ambiguous pane id') { Pass "diagnostic names the ambiguity" }
else { Fail "no ambiguity diagnostic: [$($a.stderr)]" }
if ($a.stderr -match 'beta' -and $a.stderr -match 'gamma' -and $a.stderr -notmatch "${L}__") {
    Pass "diagnostic lists the owning sessions by their short names"
} else { Fail "session names wrong in: [$($a.stderr)]" }
if ([string]::IsNullOrWhiteSpace($a.stdout)) { Pass "stdout stayed clean" }
else { Fail "diagnostic leaked to stdout: [$($a.stdout)]" }

# --- CONTROL: fully qualified targets are never affected.
foreach ($s in @('beta','gamma')) {
    $q = Probe -RouteTo alpha -PsmuxArgs @('-L', $L, 'display-message', '-p', '-t', "${s}:0.0", '#{session_name}')
    if ($q.rc -eq 0 -and $q.stdout -eq $s) { Pass "qualified -t ${s}:0.0 resolves even when routed elsewhere" }
    else { Fail "qualified -t ${s}:0.0 broke: rc=$($q.rc) out=[$($q.stdout)] err=[$($q.stderr)]" }
}

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
