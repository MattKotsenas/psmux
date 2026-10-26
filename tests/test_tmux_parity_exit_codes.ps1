# tmux parity: exit codes and messages for `list-sessions` with nothing running
# and `kill-session -t NAME` on a name that is not a session.
#
# Found while writing docs/tutorials/cross-platform-tmux-scripts.md, where every
# command was run against the shipped binary. Two results did not match tmux:
#
#   psmux ls                      (no server)   printed nothing, exit 0
#   psmux kill-session -t ghost   (no session)  printed nothing, exit 0
#
# tmux (cmd-list-sessions.c / client.c) prints `no server running on <socket>`
# and exits 1 when there is no server to talk to, and cmd-find.c answers
# `can't find session: ghost` at exit 1 for a target that names no session.
# Scripts lean on both: `tmux ls 2>/dev/null || tmux new -d` is the idiom for
# "start it if it is not running", and a kill that reports success for a
# session that never existed hides typos.
#
# Root cause in src/main.rs: the `ls` arm printed whatever it found and returned
# Ok; the `kill-session` arm read "no port file" as "already gone" and returned
# Ok before sending anything.
#
# What must NOT change, and is pinned here too:
#   - `ls -f <filter>` that matches nothing on a LIVE server is an empty
#     listing at exit 0 (tmux: the server is running, the filter just excluded
#     everything), so the "no server" test counts servers before the filter.
#   - kill of a live session exits 0; kill by `$N` id works; has-session on a
#     missing name still exits 1 with no output.
#   - a stale registry (a .port file nobody listens on) is reaped by the kill
#     and reported as `can't find session`, not as a success.
#
# Every command runs under its own -L namespace so other suites' sessions in
# the default namespace cannot make the "nothing running" cases ambiguous.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"

$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$dataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$SOCK = "pxc"
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary:  $PSMUX" -ForegroundColor Cyan
Write-Host "dataDir: $dataDir" -ForegroundColor Cyan

# Run psmux in the test namespace, return @{ out; rc } with stderr merged into out.
function Run {
    param([string[]]$CmdArgs)
    $out = (& $PSMUX -L $SOCK @CmdArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ out = $out.Trim(); rc = $LASTEXITCODE }
}

function Kill-All {
    foreach ($n in @("pxc1", "pxc2")) { & $PSMUX -L $SOCK kill-session -t $n 2>&1 | Out-Null }
    Get-ChildItem -Path $dataDir -Filter "${SOCK}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

function Wait-Gone([string]$name) {
    $end = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $end) {
        if (-not (Test-Path (Join-Path $dataDir "${SOCK}__$name.port"))) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

Kill-All

# ---------------------------------------------------------------------------
Write-Host "`n[A] nothing running in the namespace" -ForegroundColor Yellow

$r = Run @("ls")
if ($r.rc -eq 1) { Write-Pass "ls with no server exits 1 (rc=$($r.rc))" }
else { Write-Fail "ls with no server exited $($r.rc), tmux exits 1; out='$($r.out)'" }
if ($r.out -match "no server running on ") { Write-Pass "ls says 'no server running on <dir>': '$($r.out)'" }
else { Write-Fail "ls did not say 'no server running on': '$($r.out)'" }
if ($r.out -match "\(-L $SOCK\)") { Write-Pass "ls names the -L namespace it looked in" }
else { Write-Fail "ls did not name the -L namespace: '$($r.out)'" }

$r = Run @("list-sessions")
if ($r.rc -eq 1 -and $r.out -match "no server running") { Write-Pass "list-sessions long form behaves the same" }
else { Write-Fail "list-sessions long form rc=$($r.rc) out='$($r.out)'" }

$r = Run @("kill-session", "-t", "ghost")
if ($r.rc -eq 1) { Write-Pass "kill-session -t ghost with no server exits 1" }
else { Write-Fail "kill-session -t ghost with no server exited $($r.rc); out='$($r.out)'" }
if ($r.out -match "can't find session: ghost") { Write-Pass "kill-session message is: can't find session: ghost" }
else { Write-Fail "kill-session message was '$($r.out)'" }

$r = Run @("has-session", "-t", "ghost")
if ($r.rc -eq 1) { Write-Pass "has-session -t ghost still exits 1 (unchanged)" }
else { Write-Fail "has-session -t ghost exited $($r.rc)" }

# ---------------------------------------------------------------------------
Write-Host "`n[B] one live session in the namespace" -ForegroundColor Yellow

& $PSMUX -L $SOCK -f NUL new-session -d -s pxc1 -x 100 -y 30 2>&1 | Out-Null
$end = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $end -and -not (Test-Path (Join-Path $dataDir "${SOCK}__pxc1.port"))) { Start-Sleep -Milliseconds 100 }
Start-Sleep -Milliseconds 500

$r = Run @("ls")
if ($r.rc -eq 0 -and $r.out -match "^pxc1:") { Write-Pass "ls with a live session lists it at exit 0: '$($r.out)'" }
else { Write-Fail "ls with a live session rc=$($r.rc) out='$($r.out)'" }

$r = Run @("ls", "-f", "#{==:#{session_name},nomatch}")
if ($r.rc -eq 0 -and $r.out -eq "") { Write-Pass "ls -f that matches nothing on a live server is empty at exit 0 (tmux parity kept)" }
else { Write-Fail "ls -f nomatch rc=$($r.rc) out='$($r.out)' (expected empty, rc 0)" }

$r = Run @("ls", "-f", "#{==:#{session_name},pxc1}")
if ($r.rc -eq 0 -and $r.out -match "^pxc1:") { Write-Pass "ls -f that matches lists the session" }
else { Write-Fail "ls -f match rc=$($r.rc) out='$($r.out)'" }

$r = Run @("kill-session", "-t", "ghost")
if ($r.rc -eq 1 -and $r.out -match "can't find session: ghost") { Write-Pass "kill-session -t ghost while pxc1 is live: exit 1, can't find session" }
else { Write-Fail "kill-session -t ghost with a live neighbour rc=$($r.rc) out='$($r.out)'" }

$r = Run @("has-session", "-t", "pxc1")
if ($r.rc -eq 0) { Write-Pass "the ghost kill did not touch pxc1 (has-session rc 0)" }
else { Write-Fail "pxc1 is gone after killing ghost (has-session rc=$($r.rc))" }

# ---------------------------------------------------------------------------
Write-Host "`n[C] killing a live session, then the same name again" -ForegroundColor Yellow

$r = Run @("kill-session", "-t", "pxc1")
if ($r.rc -eq 0 -and $r.out -eq "") { Write-Pass "kill-session of a live session exits 0 silently" }
else { Write-Fail "kill-session live rc=$($r.rc) out='$($r.out)'" }
if (Wait-Gone "pxc1") { Write-Pass "pxc1 registry removed after the kill" }
else { Write-Fail "pxc1 .port still present 5s after kill" }

$r = Run @("kill-session", "-t", "pxc1")
if ($r.rc -eq 1 -and $r.out -match "can't find session: pxc1") { Write-Pass "killing pxc1 a second time: exit 1, can't find session: pxc1" }
else { Write-Fail "second kill rc=$($r.rc) out='$($r.out)'" }

$r = Run @("ls")
if ($r.rc -eq 1 -and $r.out -match "no server running") { Write-Pass "ls after the last session died: exit 1, no server running" }
else { Write-Fail "ls after last kill rc=$($r.rc) out='$($r.out)'" }

# ---------------------------------------------------------------------------
Write-Host "`n[D] kill by `$N session id" -ForegroundColor Yellow

& $PSMUX -L $SOCK -f NUL new-session -d -s pxc2 -x 100 -y 30 2>&1 | Out-Null
$end = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $end -and -not (Test-Path (Join-Path $dataDir "${SOCK}__pxc2.port"))) { Start-Sleep -Milliseconds 100 }
Start-Sleep -Milliseconds 500
$id = (Run @("display-message", "-p", "-t", "pxc2", "#{session_id}")).out
if ($id -match '^\$\d+$') {
    # The id resolves to the on disk name, which already carries the -L prefix.
    # Routing used to prefix it again (`pxc__pxc__pxc2`) and every `-t $N`
    # command under -L quietly missed its server.
    $r = Run @("display-message", "-p", "-t", $id, "#{session_name}")
    if ($r.rc -eq 0 -and $r.out -eq "pxc2") { Write-Pass "display-message -t $id under -L routes to pxc2" }
    else { Write-Fail "display-message -t $id under -L rc=$($r.rc) out='$($r.out)'" }
    $r = Run @("kill-session", "-t", $id)
    if ($r.rc -eq 0 -and (Wait-Gone "pxc2")) { Write-Pass "kill-session -t $id killed pxc2 at exit 0" }
    else { Write-Fail "kill-session -t $id rc=$($r.rc) out='$($r.out)'" }
} else {
    Write-Fail "could not read #{session_id} for pxc2: '$id'"
    & $PSMUX -L $SOCK kill-session -t pxc2 2>&1 | Out-Null
}

# ---------------------------------------------------------------------------
Write-Host "`n[E] a stale registry: a .port file nobody listens on" -ForegroundColor Yellow

# Take a free loopback port and release it so nothing is bound there.
$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$l.Start(); $freePort = $l.LocalEndpoint.Port; $l.Stop()
$stalePort = Join-Path $dataDir "${SOCK}__stale.port"
[IO.File]::WriteAllText($stalePort, "$freePort")
$r = Run @("kill-session", "-t", "stale")
if ($r.rc -eq 1 -and $r.out -match "can't find session: stale") { Write-Pass "kill-session on a stale registry: exit 1, can't find session: stale" }
else { Write-Fail "stale kill rc=$($r.rc) out='$($r.out)'" }
if (-not (Test-Path $stalePort)) { Write-Pass "the stale .port was reaped by the kill" }
else { Write-Fail "the stale .port survived the kill"; Remove-Item $stalePort -Force -EA SilentlyContinue }

$r = Run @("ls")
if ($r.rc -eq 1 -and $r.out -match "no server running") { Write-Pass "ls after the stale reap: exit 1, no server running" }
else { Write-Fail "ls after stale reap rc=$($r.rc) out='$($r.out)'" }

Kill-All

Write-Host "`n=== tmux parity exit codes: $script:Pass passed, $script:Fail failed ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
