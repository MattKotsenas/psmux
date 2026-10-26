# Regression: one-shot CLI commands must not silently no-op or report a false
# result. Covers the Tier 1–3 command-reliability fixes.
#
# ROOT CAUSE (pre-fix): the client/server loopback IPC could drop a fire-and-
# forget command while the CLI still returned exit 0 (`kill-session` no-op with
# $?=0), and a slow server made `ls`/`list-windows` print `os error 10060` or
# return an empty (wrong) result. Under a burst of window-creates the single
# event loop stalled on synchronous warm-pane spawns, amplifying the timeouts.
#
# WHAT THIS ASSERTS:
#   - new-session -d yields a listable session (ls + list-windows, no 10060)
#   - has-session returns 0 when present, 1 when absent
#   - kill-session returns 0 AND the session is *actually* gone afterwards
#   - kill-session on a real-but-busy session still confirms teardown
#   - a burst of 5 rapid new-windows followed by kill-session tears down cleanly
#   - no command ever emits `os error 10060` / `os error 100xx`
#
# Isolated to a throwaway USERPROFILE so it never touches real sessions.

$ErrorActionPreference = "Stop"
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\release\psmux.exe" }
if (-not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) {
    Write-Host "FATAL: could not resolve psmux executable ($PSMUX)" -ForegroundColor Red
    exit 1
}

$tmpHome = Join-Path $env:TEMP ("psmux_rel_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory $tmpHome -Force | Out-Null
New-Item -ItemType Directory (Join-Path $tmpHome ".psmux") -Force | Out-Null
$env:USERPROFILE = $tmpHome; $env:HOME = $tmpHome
$env:PSMUX_ALLOW_NESTING = "1"   # this test harness itself may run inside psmux

$pass = 0; $fail = 0
function Result($name, $ok, $msg) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $name  ($msg)" -ForegroundColor Red }
}
function Run($cmdArgs) {
    # Returns @{ Out=<combined output string>; Code=<exit code> }
    $out = & $PSMUX @cmdArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}
# A command's output must never surface a raw socket timeout.
function NoTimeout($out) { return ($out -notmatch 'os error 100\d\d' -and $out -notmatch '10060') }

try {
    # --- basic lifecycle -----------------------------------------------------
    $r = Run @('new-session','-d','-s','rel1')
    Result 'new-session -d exits 0' ($r.Code -eq 0) "code=$($r.Code) out=$($r.Out)"
    Start-Sleep -Milliseconds 800

    $r = Run @('ls')
    Result 'ls lists the session'   ($r.Out -match 'rel1:') "out=$($r.Out)"
    Result 'ls has no 10060'        (NoTimeout $r.Out)      "out=$($r.Out)"

    $r = Run @('list-windows','-t','rel1')
    Result 'list-windows returns a window' ($r.Out -match '^\s*0:') "out=$($r.Out)"
    Result 'list-windows has no 10060'     (NoTimeout $r.Out)       "out=$($r.Out)"

    $r = Run @('has-session','-t','rel1')
    Result 'has-session present -> 0' ($r.Code -eq 0) "code=$($r.Code)"
    $r = Run @('has-session','-t','does-not-exist')
    Result 'has-session absent -> 1'  ($r.Code -eq 1) "code=$($r.Code)"

    # --- the core fix: kill actually kills, and reports honestly -------------
    $r = Run @('kill-session','-t','rel1')
    Result 'kill-session exits 0' ($r.Code -eq 0) "code=$($r.Code) out=$($r.Out)"
    Start-Sleep -Milliseconds 500
    $r = Run @('has-session','-t','rel1')
    Result 'session is actually gone after kill' ($r.Code -eq 1) "code=$($r.Code)"

    # --- Tier 3: window-create burst then teardown --------------------------
    $r = Run @('new-session','-d','-s','burst')
    Result 'burst new-session exits 0' ($r.Code -eq 0) "code=$($r.Code)"
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt 5; $i++) { Run @('new-window','-t','burst') | Out-Null }
    Start-Sleep -Milliseconds 800
    $r = Run @('list-windows','-t','burst')
    $winCount = ([regex]::Matches($r.Out, '(?m)^\s*\d+:')).Count
    Result 'burst created ~6 windows' ($winCount -ge 5) "count=$winCount out=$($r.Out)"
    Result 'burst list has no 10060'  (NoTimeout $r.Out) "out=$($r.Out)"

    $r = Run @('kill-session','-t','burst')
    Result 'burst kill-session exits 0' ($r.Code -eq 0) "code=$($r.Code)"
    Start-Sleep -Milliseconds 500
    $r = Run @('has-session','-t','burst')
    Result 'burst session gone after kill' ($r.Code -eq 1) "code=$($r.Code)"
}
finally {
    # Best-effort cleanup: kill any servers this test spawned, then the temp home.
    foreach ($s in @('rel1','burst')) { & $PSMUX kill-session -t $s 2>$null | Out-Null }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "command-reliability: $pass passed, $fail failed" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
