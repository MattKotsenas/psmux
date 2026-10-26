# Issue #603: a bare CLI command (no -t, no $TMUX) must route to the session
# tmux would pick, which is the one with the newest ACTIVITY.
#
# tmux decides this in cmd-find.c `cmd_find_best_session`. Its comparator
# `cmd_find_session_better` is handed no CMD_FIND_PREFER_UNATTACHED for an
# ordinary command, so it collapses to one `timercmp` on `activity_time`, and
# activity_time is restamped on client attach and on every key a real client
# sends (server-client.c). psmux answered instead from a single data-dir-global
# `last_session` file, written once per attach and never again: a session that
# was attached at some point and has since been detached kept winning over the
# session the user is actually sitting in and typing into.
#
# Measured against tmux 3.4 in WSL with the identical script of moves, so the
# expectations below are tmux's answers, not a guess.
#
# This test runs against its own PSMUX_DATA_DIR: `last_session` and the `.port`
# registry it ranks are data-dir-global, so a shared registry would let any
# other session on the machine decide the answer.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source

# Private registry, created before anything reads PSMUX_DATA_DIR.
$psmuxDir = Join-Path $env:TEMP "psmux_603_registry"
Remove-Item $psmuxDir -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Force -Path $psmuxDir | Out-Null
$env:PSMUX_DATA_DIR = $psmuxDir

# An external shell: no nesting variables, so routing must use the fallback.
foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
# No warm pool: a standby server would outlive the throwaway registry this test
# deletes on the way out. It is never a routing candidate either way.
$env:PSMUX_NO_WARM = "1"

$SESS_A = "i603_a"
$SESS_B = "i603_b"
$SESS_SOLO = "i603_solo"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

# WriteConsoleInput injector: the ONLY way to produce activity that counts.
# `send-keys` is a command from another client and tmux does not restamp
# activity for it (verified against tmux 3.4), so it cannot stand in here.
$injector = "$env:TEMP\psmux_603_injector.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

# Launcher that scrubs the nesting variables and pins the private registry, so
# the attached client is a genuine outside-in attach even when the suite itself
# is running inside a psmux pane.
$launchCmd = "$env:TEMP\psmux_603_launch.cmd"
@"
@echo off
set PSMUX_SESSION=
set PSMUX_SESSION_NAME=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set PSMUX_DATA_DIR=$psmuxDir
set PSMUX_NO_WARM=1
"$PSMUX" attach-session -t %1
"@ | Set-Content -Path $launchCmd -Encoding ASCII

function Get-ClientPid($name) {
    $c = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
        Where-Object { $_.CommandLine -match "attach-session -t\s+$name\b" } |
        Select-Object -First 1
    if ($c) { return $c.ProcessId } else { return $null }
}
function Attach-Client($name) {
    $null = Start-Process -FilePath $launchCmd -ArgumentList $name -PassThru
    Start-Sleep -Seconds 6
    return (Get-ClientPid $name)
}
function Bare-Session { (& $PSMUX display-message -p '#S' 2>&1 | Out-String).Trim() }
function Bare-Windows { (& $PSMUX list-windows -F '#{session_name}' 2>&1 | Out-String).Trim() -split "`r?`n" | Select-Object -First 1 }
function Last-SessionFile {
    $f = Join-Path $psmuxDir "last_session"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Is-Attached($name) {
    $row = (& $PSMUX list-sessions 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -match "^$name\:" }
    return [bool]($row -match '\(attached\)')
}
function Reset-Registry {
    foreach ($n in @($SESS_A, $SESS_B, $SESS_SOLO)) { & $PSMUX kill-session -t $n 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 1500
    Get-ChildItem $psmuxDir -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
}

Write-Host "`n=== Issue #603 Tests: bare CLI routing follows activity, not a stale last_session ===" -ForegroundColor Cyan

# === TEST 1: one session exists, so everything bare must land on it ===
Write-Host "`n[Test 1] a lone session is the only routing target" -ForegroundColor Yellow
Reset-Registry
& $PSMUX new-session -d -s $SESS_SOLO | Out-Null
Start-Sleep -Seconds 3
$got = Bare-Session
if ($got -eq $SESS_SOLO) { Write-Pass "display-message -p '#S' -> $got" } else { Write-Fail "display-message -p '#S' -> '$got', expected '$SESS_SOLO'" }
$gotW = Bare-Windows
if ($gotW -eq $SESS_SOLO) { Write-Pass "list-windows -> $gotW" } else { Write-Fail "list-windows -> '$gotW', expected '$SESS_SOLO'" }

# === TEST 2: two detached sessions, the newer one wins (tmux: creation seeds activity) ===
Write-Host "`n[Test 2] newest of two detached sessions wins" -ForegroundColor Yellow
Reset-Registry
& $PSMUX new-session -d -s $SESS_A | Out-Null
Start-Sleep -Seconds 3
& $PSMUX new-session -d -s $SESS_B | Out-Null
Start-Sleep -Seconds 3
$got = Bare-Session
# tmux 3.4 with the same moves picks p_beta, the later-created session.
if ($got -eq $SESS_B) { Write-Pass "later-created session wins: $got" } else { Write-Fail "routed to '$got', expected '$SESS_B'" }

# === TEST 3: THE ISSUE. A stale last_session must not beat the session being typed in ===
Write-Host "`n[Test 3] stale last_session loses to the session with real recent input" -ForegroundColor Yellow
if (-not (Test-Path $injector)) {
    Write-Skip "could not compile injector.cs, so real client input cannot be produced"
} else {
    # B is attached first, then A. A's attach is what writes last_session=A.
    $pidB = Attach-Client $SESS_B
    $pidA = Attach-Client $SESS_A
    if (-not $pidB -or -not $pidA) {
        Write-Skip "attached clients did not start (B=$pidB A=$pidA)"
    } else {
        & $PSMUX detach-client -s $SESS_A 2>&1 | Out-Null
        Start-Sleep -Seconds 3

        # Preconditions: prove the exact state the issue describes, so a drift in
        # the setup cannot make the assertions below pass vacuously.
        $stale = Last-SessionFile
        if ($stale -eq $SESS_A) { Write-Pass "precondition: last_session names the detached '$SESS_A'" }
        else { Write-Fail "precondition: last_session is '$stale', expected '$SESS_A'" }
        if (-not (Is-Attached $SESS_A)) { Write-Pass "precondition: '$SESS_A' is detached" }
        else { Write-Fail "precondition: '$SESS_A' is still attached" }
        if (Is-Attached $SESS_B) { Write-Pass "precondition: '$SESS_B' is the only attached session" }
        else { Write-Fail "precondition: '$SESS_B' is not attached" }

        # Real keystrokes into B's console: this is the activity tmux counts.
        & $injector $pidB "echo I603_TYPED{ENTER}" | Out-Null
        Start-Sleep -Seconds 4
        $capB = (& $PSMUX capture-pane -p -t $SESS_B 2>&1 | Out-String)
        if ($capB -match 'I603_TYPED') {
            Write-Pass "precondition: real keystrokes reached '$SESS_B'"

            # tmux 3.4 with these moves routes to p_beta (== B).
            $got = Bare-Session
            if ($got -eq $SESS_B) { Write-Pass "display-message -p '#S' -> $got" }
            else { Write-Fail "display-message -p '#S' -> '$got', expected '$SESS_B' (stale last_session won)" }

            $gotW = Bare-Windows
            if ($gotW -eq $SESS_B) { Write-Pass "list-windows -> $gotW" }
            else { Write-Fail "list-windows -> '$gotW', expected '$SESS_B'" }

            # A side-effecting command must not land in the wrong session.
            & $PSMUX new-window -n i603probe 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $winA = (& $PSMUX list-windows -t $SESS_A -F '#{window_name}' 2>&1 | Out-String)
            $winB = (& $PSMUX list-windows -t $SESS_B -F '#{window_name}' 2>&1 | Out-String)
            if ($winB -match 'i603probe' -and $winA -notmatch 'i603probe') { Write-Pass "bare new-window landed in '$SESS_B'" }
            else { Write-Fail "bare new-window landed wrong (A='$($winA.Trim())' B='$($winB.Trim())')" }

            # The stale hint is overruled, not rewritten: nothing re-attached A.
            $stillStale = Last-SessionFile
            if ($stillStale -eq $SESS_A) { Write-Pass "last_session still names '$SESS_A': overruled by activity, not overwritten" }
            else { Write-Fail "last_session changed to '$stillStale'; the test no longer proves the stale case" }
        } else {
            Write-Skip "keystrokes never reached '$SESS_B' console, cannot judge activity routing"
        }
    }
    foreach ($n in @($SESS_A, $SESS_B)) { & $PSMUX kill-session -t $n 2>&1 | Out-Null }
    Start-Sleep -Seconds 2
}

# === TEST 4: last_session naming a session that no longer exists ===
Write-Host "`n[Test 4] a last_session pointing at a dead session falls through to a live one" -ForegroundColor Yellow
Reset-Registry
& $PSMUX new-session -d -s $SESS_A | Out-Null
Start-Sleep -Seconds 3
& $PSMUX new-session -d -s $SESS_B | Out-Null
Start-Sleep -Seconds 3
"i603_ghost" | Set-Content -Path (Join-Path $psmuxDir "last_session") -Encoding ASCII -NoNewline
$got = Bare-Session
if ($got -eq $SESS_B) { Write-Pass "dead hint ignored, routed to $got" }
elseif ($got -eq $SESS_A) { Write-Fail "routed to '$SESS_A'; expected the newer '$SESS_B'" }
else { Write-Fail "routed to '$got', expected '$SESS_B'" }

# === TEST 5: no last_session file at all ===
Write-Host "`n[Test 5] absent last_session still resolves by activity" -ForegroundColor Yellow
Remove-Item (Join-Path $psmuxDir "last_session") -Force -EA SilentlyContinue
$got = Bare-Session
if ($got -eq $SESS_B) { Write-Pass "routed to $got with no hint file" } else { Write-Fail "routed to '$got', expected '$SESS_B'" }

# === CLEANUP ===
Reset-Registry
Remove-Item $psmuxDir -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Issue #603 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
