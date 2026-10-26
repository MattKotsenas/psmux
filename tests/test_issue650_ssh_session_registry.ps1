# Issue #650: a desktop psmux command must not reap the registry of a live
# server it is simply not allowed to open.
#
# pid_anchor_verdict decided liveness from get_process_name, which needs
# OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION). That handle is refused, with
# GetLastError 5 (ERROR_ACCESS_DENIED), when the target lives in another
# terminal services session AND the caller is not elevated. A server started
# from an OpenSSH logon lives in session 0 under the elevated token sshd mints
# for an administrator; an ordinary desktop shell lives in session 1 under the
# UAC filtered Medium token, so the desktop side could see the server in the
# process table but not open it. The refusal was read as "the server has
# exited" and the startup registry sweep, which runs on every invocation
# including psmux -V, deleted the live session's .port / .key / .pid / .sid.
#
# Expected: liveness survives an unopenable PID. The Toolhelp32 snapshot needs
# no handle and answers for exactly those PIDs, so the registry is kept and
# list-sessions still reports the session. A PID that is genuinely gone is
# absent from the snapshot too, so the fast reap from issue #448 still fires.
#
# Three legs:
#   1. always runs   - a live server of our own integrity survives psmux -V
#   2. always runs   - a server that really died is still reaped by psmux -V
#   3. conditional   - the cross token case that actually reproduced the bug:
#                      a High integrity server plus a Medium integrity client,
#                      either over ssh localhost or, when key auth is not set
#                      up, locally by dropping to the interactive shell token
#
# Nothing here reconfigures sshd or touches the user's ~/.ssh.

$ErrorActionPreference = "Continue"

$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$NS = "ns650"
$S = "t650remote"
$BASE = "${NS}__${S}"
$LOCAL = "t650local"

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  $m" -ForegroundColor DarkGray }

$scratch = Join-Path $env:TEMP ("psmux_issue650_" + $PID)
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

# Registry file set for one session base, as a sorted display string.
function Registry-Files([string]$base) {
    $f = Get-ChildItem -Path $psmuxDir -Filter "$base.*" -EA SilentlyContinue |
         Sort-Object Name | ForEach-Object { $_.Name }
    if ($f) { return ($f -join ", ") }
    return "NONE"
}

# Server PID recorded in a session's .pid anchor (body is pid or pid:creation).
function Server-Pid([string]$base) {
    $p = Join-Path $psmuxDir "$base.pid"
    if (-not (Test-Path $p)) { return $null }
    $raw = (Get-Content $p -Raw -EA SilentlyContinue)
    if (-not $raw) { return $null }
    $n = ($raw.Trim() -split ':')[0]
    $out = 0
    if ([int]::TryParse($n, [ref]$out)) { return $out }
    return $null
}

# Kill a psmux server by PID, but only when its image really is the binary
# under test. Never kills by name.
function Kill-OurServer([int]$serverPid) {
    if (-not $serverPid) { return }
    $p = Get-Process -Id $serverPid -EA SilentlyContinue
    if (-not $p) { return }
    if ($p.Path -and $p.Path -ne $PSMUX) {
        Write-Info "not ours, leaving pid $serverPid ($($p.Path))"
        return
    }
    Stop-Process -Id $serverPid -Force -EA SilentlyContinue
}

function Cleanup-Namespace() {
    # Ask the namespace's servers to exit over their own channel first. The ssh
    # leg's server runs under the ssh logon's token, which is elevated for an
    # admin account, so an unelevated suite's Stop-Process is refused and the
    # server (with its pane shells and warm pool) outlived the suite by hours,
    # loading every suite after it (sweeps 2026-10-08, ~100 refused kills each).
    # kill-server is scoped to this unique namespace (#649).
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    foreach ($f in Get-ChildItem -Path $psmuxDir -Filter "$NS*.pid" -EA SilentlyContinue) {
        $raw = (Get-Content $f.FullName -Raw -EA SilentlyContinue)
        if ($raw) { Kill-OurServer ([int](($raw.Trim() -split ':')[0])) }
    }
    Start-Sleep -Milliseconds 400
    Remove-Item (Join-Path $psmuxDir "$NS*") -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #650: cross session registry reap ===" -ForegroundColor Cyan
Write-Info "exe:      $PSMUX"
Write-Info "data dir: $psmuxDir"
$myIntegrity = (whoami /groups | Select-String "Mandatory Label").Line
Write-Info "this process integrity: $($myIntegrity -replace '\s+', ' ')"

# ---------------------------------------------------------------------------
# Leg 1 (always): a live server survives psmux -V from the desktop.
# ---------------------------------------------------------------------------
Write-Host "`n--- Leg 1: a live server survives psmux -V ---" -ForegroundColor Cyan

& $PSMUX kill-session -t $LOCAL 2>&1 | Out-Null
Remove-Item (Join-Path $psmuxDir "$LOCAL.*") -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 400

& $PSMUX new-session -d -s $LOCAL -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX has-session -t $LOCAL 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "setup: could not create local session $LOCAL"
} else {
    $localPid = Server-Pid $LOCAL
    Write-Info "before: $(Registry-Files $LOCAL)"
    & $PSMUX -V 2>&1 | Out-Null
    $filesAfter = Registry-Files $LOCAL
    Write-Info "after psmux -V: $filesAfter"
    if ($filesAfter -ne "NONE") { Write-Pass "registry files survive psmux -V for a live server" }
    else { Write-Fail "BUG: psmux -V reaped a live server's registry files" }

    & $PSMUX has-session -t $LOCAL 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Pass "has-session still rc=0 after psmux -V" }
    else { Write-Fail "BUG: has-session rc=$LASTEXITCODE after psmux -V" }

    Kill-OurServer $localPid
    Start-Sleep -Milliseconds 400
    Remove-Item (Join-Path $psmuxDir "$LOCAL.*") -Force -EA SilentlyContinue
}

# ---------------------------------------------------------------------------
# Leg 2 (always): the fast reap from issue #448 still fires for a dead server.
# The snapshot fallback must not turn "dead" into "alive".
# ---------------------------------------------------------------------------
Write-Host "`n--- Leg 2: a dead server is still reaped ---" -ForegroundColor Cyan

Cleanup-Namespace
& $PSMUX -L $NS new-session -d -s $S -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$deadPid = Server-Pid $BASE
if (-not $deadPid) {
    Write-Fail "setup: no .pid anchor for $BASE"
} else {
    Kill-OurServer $deadPid
    Start-Sleep -Seconds 2
    if (Get-Process -Id $deadPid -EA SilentlyContinue) {
        Write-Fail "setup: server pid $deadPid did not exit"
    } else {
        Write-Info "server pid $deadPid killed; registry now: $(Registry-Files $BASE)"
        & $PSMUX -V 2>&1 | Out-Null
        $afterDead = Registry-Files $BASE
        Write-Info "after psmux -V: $afterDead"
        if ($afterDead -eq "NONE") { Write-Pass "dead server's registry is still reaped by psmux -V (#448 fast reap intact)" }
        else { Write-Fail "BUG: dead server's registry survived psmux -V ($afterDead)" }
    }
}
Cleanup-Namespace

# ---------------------------------------------------------------------------
# Leg 3 (conditional): the cross session case that actually reproduces #650.
#
# Measured on Windows 11 10.0.26200, same user in every row:
#
#   caller                      target                   OpenProcess(QLI)
#   session 1, Medium token     session 0 (sshd spawned) FAILS, GetLastError 5
#   session 1, elevated token   session 0 (sshd spawned) succeeds
#   session 1, Medium token     session 1, elevated      succeeds
#
# So the refusal needs BOTH halves: a server in another terminal services
# session AND a caller that is not elevated. PROCESS_QUERY_LIMITED_INFORMATION
# is exempt from the mandatory integrity check within one session, which is why
# a purely local high versus medium pair does not reproduce this.
#
# That means this leg needs a real ssh logon for the server side. Without non
# interactive key auth it SKIPS; this test never sets key auth up.
# ---------------------------------------------------------------------------
Write-Host "`n--- Leg 3: server in another terminal services session ---" -ForegroundColor Cyan

$sshExe = (Get-Command ssh -EA SilentlyContinue).Source
$sshUsable = $false
if (-not $sshExe) {
    Write-Skip "no ssh client on PATH, so there is no way to put a server in another terminal services session; skipping the cross session leg"
} else {
    $probe = & $sshExe -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 localhost hostname 2>&1
    if ($LASTEXITCODE -eq 0 -and $probe) { $sshUsable = $true }
    else { Write-Skip "ssh localhost key auth is not set up (rc=$LASTEXITCODE), skipping the cross session leg" }
}

# The desktop side must run UNELEVATED, or OpenProcess is never refused and the
# leg proves nothing. When this process is already unelevated we run psmux
# directly; when it is elevated we borrow the interactive shell's own Medium
# token by having explorer.exe launch the command.
$amElevated = ([System.Security.Principal.WindowsPrincipal] `
    [System.Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$myShell = Get-Process -Id $PID
$explorer = Get-Process -Name explorer -EA SilentlyContinue |
            Where-Object { $_.SessionId -eq $myShell.SessionId } | Select-Object -First 1

$desktopMode = $null
if (-not $amElevated) { $desktopMode = "direct" }
elseif ($explorer) { $desktopMode = "explorer" }

# Run psmux with a plain desktop (unelevated) token. Returns the combined
# output, or $null when the launch produced nothing.
function Invoke-Desktop([string]$argLine, [int]$TimeoutSec = 30) {
    if ($desktopMode -eq "direct") {
        $out = & $PSMUX @($argLine -split ' ' | Where-Object { $_ }) 2>&1
        return (($out | Out-String).Trim())
    }
    $outFile = Join-Path $scratch ("desktop_" + [guid]::NewGuid().ToString("N") + ".txt")
    $doneFile = "$outFile.done"
    $cmdFile = Join-Path $scratch ("desktop_" + [guid]::NewGuid().ToString("N") + ".cmd")
    Set-Content -Path $cmdFile -Encoding ASCII -Value @(
        '@echo off',
        "`"$PSMUX`" $argLine > `"$outFile`" 2>&1",
        "echo %ERRORLEVEL% > `"$doneFile`""
    )
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$cmdFile`"" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $doneFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    Remove-Item $cmdFile -Force -EA SilentlyContinue
    if (-not (Test-Path $doneFile)) { return $null }
    if (Test-Path $outFile) { return ((Get-Content $outFile -Raw).Trim()) }
    return ""
}

if ($sshUsable -and -not $desktopMode) {
    Write-Skip "this process is elevated and there is no interactive explorer.exe to borrow an unelevated token from; skipping the cross session leg"
}

if ($sshUsable -and $desktopMode) {
    Write-Info "desktop side runs $desktopMode (elevated=$amElevated)"
    Cleanup-Namespace
    $remoteScript = Join-Path $scratch "start_over_ssh.ps1"
    Set-Content -Path $remoteScript -Encoding UTF8 -Value @(
        'param([string]$Exe, [string]$Ns, [string]$Sess, [string]$DataDir)',
        'if ($DataDir) { $env:PSMUX_DATA_DIR = $DataDir }',
        '$env:PSMUX_SESSION_NAME = $null',
        '$me = Get-Process -Id $PID',
        'Write-Output ("ssh_side_session=" + $me.SessionId)',
        '& $Exe -L $Ns new-session -d -s $Sess 2>&1 | Out-Null',
        'Write-Output ("ssh_side_rc=" + $LASTEXITCODE)'
    )
    $dataArg = ""
    if ($env:PSMUX_DATA_DIR) { $dataArg = " -DataDir `"$env:PSMUX_DATA_DIR`"" }
    $remoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$remoteScript`" -Exe `"$PSMUX`" -Ns $NS -Sess $S$dataArg"
    (& $sshExe -o BatchMode=yes localhost $remoteCmd 2>&1) | ForEach-Object { Write-Info "ssh: $_" }
    Start-Sleep -Seconds 2

    $remotePid = Server-Pid $BASE
    $rp = if ($remotePid) { Get-Process -Id $remotePid -EA SilentlyContinue } else { $null }
    if (-not $rp) {
        Write-Fail "cross session leg: the ssh started server is not running (pid=$remotePid)"
    } elseif ($rp.SessionId -eq $myShell.SessionId) {
        Write-Skip "the ssh logon landed in our own terminal services session ($($rp.SessionId)), so OpenProcess is never refused here; nothing to prove"
    } else {
        Write-Info "ssh server pid $remotePid in terminal services session $($rp.SessionId), we are in $($myShell.SessionId)"
        Write-Info "before: $(Registry-Files $BASE)"

        $vOut = Invoke-Desktop "-V"
        if ($null -eq $vOut) {
            Write-Skip "the unelevated desktop client never ran, cannot judge the cross session leg"
        } else {
            Write-Info "desktop psmux -V said: $($vOut -replace "`r?`n", ' | ')"
            $afterV = Registry-Files $BASE
            Write-Info "after psmux -V: $afterV"
            if ($afterV -ne "NONE") {
                Write-Pass "ssh started server's registry survives an unelevated desktop psmux -V"
            } else {
                Write-Fail "BUG(#650): an unelevated desktop psmux -V reaped the live ssh started server's registry"
            }

            $lsOut = Invoke-Desktop "-L $NS list-sessions"
            Write-Info "desktop list-sessions said: $($lsOut -replace "`r?`n", ' | ')"
            if ($lsOut -and $lsOut -match [regex]::Escape($S)) {
                Write-Pass "desktop list-sessions still reports $S"
            } else {
                Write-Fail "BUG(#650): desktop list-sessions lost $S"
            }

            if (Get-Process -Id $remotePid -EA SilentlyContinue) {
                Write-Pass "ssh started server pid $remotePid still running"
            } else {
                Write-Fail "BUG(#650): ssh started server pid $remotePid was terminated"
            }
        }
    }
    Cleanup-Namespace
}

Remove-Item $scratch -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) Skipped=$($script:Skip) ===" -ForegroundColor Cyan
exit $script:Fail
