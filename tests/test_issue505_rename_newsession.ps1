# Issue #505: session rename results in failing new session creation
#
# Reported: open psmux, rename the session, then `prefix + :` `new` fails with
# "failed to create session '0'". Renaming the session back to `0` makes it work.
#
# Root cause: the server holds a Windows named mutex `Local\psmux-session-<name>`
# for its whole life (the single-server-per-name guard from issue #2). The key is
# the session name at STARTUP and was never re-keyed on rename, so:
#   1. the OLD name stayed locked forever, and any later server spawned under that
#      name exited silently as a "duplicate" (no port file -> "failed to create
#      session '<old name>'"). The default session name is "0", which is exactly
#      the name plain `new-session` auto-picks, hence the report.
#   2. the NEW name was left completely unguarded, silently disabling the issue #2
#      duplicate-server protection for every renamed session.
#
# tmux parity (verified against real tmux 3.4): rename-session does
# RB_REMOVE + RB_INSERT, so the old name frees immediately and the new name is
# registered. Creating a session under a freed old name succeeds in tmux.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
# Honour PSMUX_DATA_DIR: Reset-All deletes every registry file in this
# directory, so with an isolated data dir it must never touch the real one
# (2026-10-13 a run with a private PSMUX_DATA_DIR wiped ~/.psmux).
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [info] $msg" -ForegroundColor DarkGray }

function Reset-All {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Get-ChildItem $psmuxDir -EA SilentlyContinue |
        Where-Object { $_.Extension -in '.port', '.key', '.pid', '.sid', '.spawnlock' } |
        Remove-Item -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function New-Detached($name) {
    & $PSMUX new-session -d -s $name 2>&1 | Out-Null
    for ($i = 0; $i -lt 75; $i++) {
        if (Test-Path "$psmuxDir\$name.port") { break }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Seconds 2
    return (Test-Path "$psmuxDir\$name.port")
}

# Send one command over a raw TCP socket to a session's server and return the
# first response line. This is the server-side path (server/connection.rs) that
# `prefix + :` and the CLI both funnel a new-session through.
function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $portFile = "$psmuxDir\$Session.port"
    if (-not (Test-Path $portFile)) { return "NO_PORT_FILE" }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    } catch { return "CONNECT_FAILED" }
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $stream.ReadTimeout = 8000
    if ($reader.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 20000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    if ($null -eq $resp) { $resp = "" }
    return $resp
}

# Probe the single-server-per-name mutex from THIS process. A Windows mutex is
# recursive for its owning thread but scoped per process, so an outside probe
# sees the real state: WaitOne(0) false means a live process holds the name.
# The object name carries a data-root tag since #599; the shared helper is the
# one place that knows the layout (it used to be spelled out here, and every
# live session read as unguarded once the tag was inserted).
. "$PSScriptRoot\psmux_session_mutex.ps1"
function Test-SessionNameHeld {
    param([string]$Name)
    return (Test-PsmuxSessionNameHeld $Name)
}

function Test-SessionExists($name) {
    & $PSMUX has-session -t $name 2>$null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "`n=== Issue #505: rename-session must not poison later session creation ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- Part A ----
# The reporter's exact scenario, over the server path used by `prefix + :` `new`.
Write-Host "`n[Test 1] Reporter's scenario: session '0' renamed, then auto-named new-session" -ForegroundColor Yellow
Reset-All
if (New-Detached "0") {
    & $PSMUX rename-session -t 0 work 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    if ((Test-SessionExists "work") -and -not (Test-SessionExists "0")) {
        Write-Pass "rename 0 -> work took effect"
    } else {
        Write-Fail "rename 0 -> work did not take effect"
    }

    $resp = Send-TcpCommand -Session "work" -Command "new-session -d"
    Write-Info "server response: '$resp'"
    if ($resp -eq "OK") {
        Write-Pass "auto-named new-session after rename returned OK"
    } else {
        Write-Fail "auto-named new-session after rename returned '$resp' (issue #505 reproduced)"
    }
    Start-Sleep -Seconds 3
    if (Test-SessionExists "0") {
        Write-Pass "session '0' actually exists after creation"
    } else {
        Write-Fail "session '0' was NOT created"
    }
} else {
    Write-Fail "setup: could not create session '0'"
}

# ---------------------------------------------------------------- Part B ----
# Generalised: any freed old name must be reusable, not just "0".
Write-Host "`n[Test 2] A freed old name is reusable (rename foo -> bar, then create 'foo')" -ForegroundColor Yellow
Reset-All
if (New-Detached "foo") {
    & $PSMUX rename-session -t foo bar 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $resp = Send-TcpCommand -Session "bar" -Command "new-session -d -s foo"
    Write-Info "server response: '$resp'"
    if ($resp -eq "OK") { Write-Pass "creating the freed old name 'foo' returned OK" }
    else { Write-Fail "creating freed old name 'foo' returned '$resp'" }
    Start-Sleep -Seconds 3
    if (Test-SessionExists "foo") { Write-Pass "session 'foo' recreated and live" }
    else { Write-Fail "session 'foo' was NOT recreated" }
    if (Test-SessionExists "bar") { Write-Pass "renamed session 'bar' survived intact" }
    else { Write-Fail "renamed session 'bar' disappeared" }
} else {
    Write-Fail "setup: could not create session 'foo'"
}

# ---------------------------------------------------------------- Part C ----
# Direct proof at the root-cause layer: which name does the process actually lock?
Write-Host "`n[Test 3] Root cause: the name guard follows the rename" -ForegroundColor Yellow
Reset-All
if (New-Detached "alpha") {
    if (Test-SessionNameHeld "alpha") { Write-Pass "pre-rename: 'alpha' is guarded" }
    else { Write-Fail "pre-rename: 'alpha' should be guarded but is free" }

    & $PSMUX rename-session -t alpha omega 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    if (-not (Test-SessionNameHeld "alpha")) {
        Write-Pass "post-rename: old name 'alpha' released"
    } else {
        Write-Fail "post-rename: old name 'alpha' STILL held (this is the #505 root cause)"
    }
    if (Test-SessionNameHeld "omega") {
        Write-Pass "post-rename: new name 'omega' is guarded"
    } else {
        Write-Fail "post-rename: new name 'omega' unguarded (issue #2 protection lost)"
    }
} else {
    Write-Fail "setup: could not create session 'alpha'"
}

# ---------------------------------------------------------------- Part D ----
Write-Host "`n[Test 4] Chained renames free every intermediate name" -ForegroundColor Yellow
Reset-All
if (New-Detached "n1") {
    & $PSMUX rename-session -t n1 n2 2>&1 | Out-Null; Start-Sleep -Seconds 1
    & $PSMUX rename-session -t n2 n3 2>&1 | Out-Null; Start-Sleep -Seconds 1
    & $PSMUX rename-session -t n3 n4 2>&1 | Out-Null; Start-Sleep -Seconds 2

    $stuck = @()
    foreach ($n in @("n1", "n2", "n3")) { if (Test-SessionNameHeld $n) { $stuck += $n } }
    if ($stuck.Count -eq 0) { Write-Pass "all intermediate names (n1, n2, n3) released" }
    else { Write-Fail "intermediate names still held: $($stuck -join ', ')" }

    if (Test-SessionNameHeld "n4") { Write-Pass "final name 'n4' is guarded" }
    else { Write-Fail "final name 'n4' unguarded" }

    $resp = Send-TcpCommand -Session "n4" -Command "new-session -d -s n1"
    if ($resp -eq "OK") { Write-Pass "first-ever name 'n1' is creatable again" }
    else { Write-Fail "recreating 'n1' returned '$resp'" }
} else {
    Write-Fail "setup: could not create session 'n1'"
}

# ---------------------------------------------------------------- Part E ----
Write-Host "`n[Test 5] Renaming back to the original name keeps the guard correct" -ForegroundColor Yellow
Reset-All
if (New-Detached "roundtrip") {
    & $PSMUX rename-session -t roundtrip temp 2>&1 | Out-Null; Start-Sleep -Seconds 2
    & $PSMUX rename-session -t temp roundtrip 2>&1 | Out-Null; Start-Sleep -Seconds 2

    if (Test-SessionExists "roundtrip") { Write-Pass "session survived the round trip" }
    else { Write-Fail "session lost during round-trip rename" }
    if (Test-SessionNameHeld "roundtrip") { Write-Pass "'roundtrip' guarded after returning to it" }
    else { Write-Fail "'roundtrip' unguarded after returning to it" }
    if (-not (Test-SessionNameHeld "temp")) { Write-Pass "intermediate 'temp' released" }
    else { Write-Fail "intermediate 'temp' still held" }
} else {
    Write-Fail "setup: could not create session 'roundtrip'"
}

# ---------------------------------------------------------------- Part F ----
# Edge cases: the guard must not swallow a genuine duplicate, and unrelated
# names must keep working (control that the fix is not just "never guard").
Write-Host "`n[Test 6] Edge cases: genuine duplicate still rejected, unrelated names unaffected" -ForegroundColor Yellow
Reset-All
if (New-Detached "dup") {
    & $PSMUX rename-session -t dup dup2 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $resp = Send-TcpCommand -Session "dup2" -Command "new-session -d -s dup2"
    Write-Info "duplicate-name response: '$resp'"
    if ($resp -match "duplicate session") { Write-Pass "creating the live session's own name is still rejected" }
    else { Write-Fail "expected 'duplicate session' for a live duplicate, got '$resp'" }

    $resp = Send-TcpCommand -Session "dup2" -Command "new-session -d -s unrelated"
    if ($resp -eq "OK") { Write-Pass "unrelated name still creatable after rename" }
    else { Write-Fail "unrelated name failed with '$resp'" }
    Start-Sleep -Seconds 2
    if (Test-SessionExists "unrelated") { Write-Pass "'unrelated' session is live" }
    else { Write-Fail "'unrelated' session missing" }
} else {
    Write-Fail "setup: could not create session 'dup'"
}

# ---------------------------------------------------------------- Part G ----
# A warm-pool session is claimed by being renamed from __warm__ to a real name.
# It skipped the startup guard (the warm pool intentionally runs several), so the
# claimed name must pick the guard up at claim time.
Write-Host "`n[Test 7] Warm-claimed session guards its claimed name" -ForegroundColor Yellow
Reset-All
& $PSMUX warmup 2>&1 | Out-Null
for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path "$psmuxDir\__warm__.port") { break }
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Seconds 3
& $PSMUX new-session -d -s warmclaim 2>&1 | Out-Null
for ($i = 0; $i -lt 75; $i++) {
    if (Test-Path "$psmuxDir\warmclaim.port") { break }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 2
if (Test-SessionExists "warmclaim") {
    if (Test-SessionNameHeld "warmclaim") { Write-Pass "claimed session name 'warmclaim' is guarded" }
    else { Write-Fail "claimed session name 'warmclaim' is unguarded" }
} else {
    Write-Fail "setup: could not create session 'warmclaim'"
}

# ---------------------------------------------------------------- Part H ----
# Win32 TUI: a real visible psmux window, driven the way the reporter drove it.
Write-Host "`n" + ("=" * 62) -ForegroundColor Cyan
Write-Host "Win32 TUI VERIFICATION (real window, reporter's keystroke flow)" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan
Reset-All

$injectorExe = "$env:TEMP\psmux_injector.exe"
$injectorSrc = Join-Path (Split-Path -Parent $PSCommandPath) "injector.cs"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (Test-Path $csc) { & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null }
}

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", "0" -PassThru
Start-Sleep -Seconds 6

if (Test-SessionExists "0") {
    Write-Pass "TUI: attached session '0' is up"

    # Reporter step 1: rename the session from inside the TUI.
    if (Test-Path $injectorExe) {
        & $injectorExe $proc.Id "^b{SLEEP:400}:{SLEEP:600}rename-session mywork{ENTER}" | Out-Null
    } else {
        & $PSMUX rename-session -t 0 mywork 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 3

    if (Test-SessionExists "mywork") { Write-Pass "TUI: rename to 'mywork' applied" }
    else { Write-Fail "TUI: rename to 'mywork' did not apply" }

    # Reporter step 2: prefix + : new
    $before = @(& $PSMUX list-sessions 2>&1).Count
    if (Test-Path $injectorExe) {
        & $injectorExe $proc.Id "^b{SLEEP:400}:{SLEEP:600}new{ENTER}" | Out-Null
    } else {
        Send-TcpCommand -Session "mywork" -Command "new-session -d" | Out-Null
    }
    Start-Sleep -Seconds 5
    $after = @(& $PSMUX list-sessions 2>&1).Count

    if ($after -gt $before) {
        Write-Pass "TUI: prefix + : new created a session after the rename ($before -> $after)"
    } else {
        Write-Fail "TUI: prefix + : new created nothing after the rename ($before -> $after)"
    }
    if (Test-SessionExists "0") { Write-Pass "TUI: the freed default name '0' is what got created" }
    else { Write-Info "TUI: created session is not named '0' (acceptable if another free name was picked)" }

    & $PSMUX kill-session -t mywork 2>&1 | Out-Null
} else {
    Write-Fail "TUI: attached session '0' never came up"
}
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Reset-All

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
