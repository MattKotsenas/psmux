#!/usr/bin/env pwsh
# Test: where does a new window open? tmux's cwd is DISPATCH-MODE dependent:
# `-c` wins; else a command-line / detached client uses the CALLER's cwd (the
# issuing client is not attached); else (attached) the session start dir. These
# are tmux's three cwd cases, visible in its own source.
#
# This test drives the COMMAND-LINE (detached) path — every psmux/tmux call is a
# separate, unattached client — so the tmux-faithful expectations are:
#   - initial window (new-session -c SDIR)   -> SDIR
#   - detached new-window (no -c) from dir X  -> X      (caller cwd)
#   - detached split-window (no -c) from dir X -> X     (caller cwd)
#   - new-window -c DIR2 (from anywhere)      -> DIR2
# The attached/interactive path (prefix+c -> session start dir) needs a pty or
# control-mode client and is NOT covered here.
#
# Runs with warm panes BOTH disabled and enabled: where a window opens must not
# depend on the warm-pane optimisation — a warm pane pre-spawned in the server's
# cwd must NOT override the caller's cwd for a detached new-window.
#
# Well-behaved on a shared server: uses a unique session name and cleans up
# with kill-session (never kill-server), so it does not disturb other sessions.

$ErrorActionPreference = "Continue"
$results = @()

function Add-Result($name, $pass, $detail = "") {
    $script:results += [PSCustomObject]@{
        Test   = $name
        Result = if ($pass) { "PASS" } else { "FAIL" }
        Detail = $detail
    }
}

# Binary discovery: honour $env:PSMUX_EXE first (CI convention), then the local
# build outputs (debug preferred — usually the build under test).
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = Join-Path $PSScriptRoot "..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) { $PSMUX = Join-Path $PSScriptRoot "..\target\release\psmux.exe" }
if (-not (Test-Path $PSMUX)) {
    Write-Host "psmux binary not found; build the project first." -ForegroundColor Red
    exit 1
}

# Launch every pane as `pwsh -NoProfile` so the pane shell NEVER changes its own
# cwd during startup. A profile `Set-Location` would otherwise make
# #{pane_current_path} drift away from the spawn dir and this test would assert
# against a shell-dependent value; with -NoProfile explicit, psmux also skips its
# manual profile sourcing. Base-index is left at the default, no warm/option
# overrides.
$cfgFile = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_ssd_" + [guid]::NewGuid().ToString("N") + ".conf")
Set-Content -LiteralPath $cfgFile -Value 'set -g default-command "pwsh -NoProfile"'
$env:PSMUX_CONFIG_FILE = $cfgFile

# Canonicalise a path for comparison: resolve via the filesystem (collapses 8.3
# short names to long form), forward slashes to backslashes, drop trailing
# slash, lower-case. Sidesteps C:\ vs C:/, casing, and short-vs-long-name
# differences in #{pane_current_path}.
function Normalize-Path($p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    try { $p = (Get-Item -LiteralPath $p -ErrorAction Stop).FullName } catch { }
    ($p -replace '/', '\').TrimEnd('\').ToLower()
}
function Get-PanePath($target) {
    (& $PSMUX display-message -p -t $target '#{pane_current_path}' 2>&1 | Out-String).Trim()
}

# Poll until the server has created the session (the client may return before the
# server is ready). Mirrors the suite's has-session readiness idiom.
function Wait-ForSession($name, $timeoutSec = 10) {
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Poll #{pane_current_path} until it converges to $expectNorm (already
# normalised), then return the raw value. The pane runs -NoProfile so it never
# changes its own cwd: any readable value IS the spawn dir, and we only wait out
# the latency between spawning the pane process and it reporting its cwd. A wrong
# cwd never converges, so this can't mask a regression — it fails by timeout and
# returns the last value seen for a meaningful diff.
function Wait-PanePath($target, $expectNorm, $timeoutSec = 10) {
    $last = ""
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        $last = Get-PanePath $target
        if ((Normalize-Path $last) -eq $expectNorm) { return $last }
        Start-Sleep -Milliseconds 200
    }
    return $last
}

# Poll a window's panes until one converges to $expectNorm; return that raw path
# (or the panes seen, on timeout). Scans all panes in the window so we don't
# depend on a pane index / pane-base-index — we just look for the expected cwd.
function Wait-PaneInWindow($winTarget, $expectNorm, $timeoutSec = 10) {
    $last = @()
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        $last = & $PSMUX list-panes -t $winTarget -F '#{pane_current_path}' 2>&1 |
            ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }
        foreach ($p in $last) { if ((Normalize-Path $p) -eq $expectNorm) { return $p } }
        Start-Sleep -Milliseconds 200
    }
    return ($last -join ' | ')
}

# Target dirs live under the build dir (target\): no user name in the path, no
# special permissions, gitignored.
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\target\cwd_start_dir_test"))

function Test-Mode {
    param([string]$Mode, [bool]$WarmOff)

    if ($WarmOff) { $env:PSMUX_NO_WARM = "1" } else { Remove-Item Env:\PSMUX_NO_WARM -ErrorAction SilentlyContinue }

    $sess     = "ssdtest_${Mode}_"             + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $startDir = Join-Path $testRoot ("start_${Mode}_"    + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $cliDir   = Join-Path $testRoot ("cli_${Mode}_"      + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $winDir   = Join-Path $testRoot ("explicit_${Mode}_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $startDir, $cliDir, $winDir -Force | Out-Null

    try {
        # Create the session FROM the tests directory (the launch dir) but with
        # -c $startDir, to prove -c wins over the launch directory.
        Push-Location $PSScriptRoot
        & $PSMUX new-session -d -s $sess -c $startDir
        Pop-Location
        if (-not (Wait-ForSession $sess)) {
            Add-Result "[$Mode] session ready" $false "new-session never became ready"
            return
        }

        # Initial window was created WITH -c: it must open in the session start dir.
        $expectStart = Normalize-Path $startDir
        $raw0 = Wait-PanePath "${sess}:0" $expectStart
        Add-Result "[$Mode] initial window (-c) opens in start dir" `
            ((Normalize-Path $raw0) -eq $expectStart) "got '$raw0' expected '$startDir'"

        # Command-line (detached) new-window WITHOUT -c. tmux resolves this to the
        # CALLER's cwd (the issuing client is not attached), NOT the session start
        # dir. Invoke it from a distinct CLI dir and require the new window to open
        # THERE. (psmux currently opens it in the session dir because it never
        # propagates the client cwd — the RED.)
        Push-Location $cliDir
        & $PSMUX new-window -t $sess
        Pop-Location
        $expectCli = Normalize-Path $cliDir
        $raw1 = Wait-PanePath "${sess}:1" $expectCli
        Add-Result "[$Mode] detached new-window (no -c) opens in caller cwd" `
            ((Normalize-Path $raw1) -eq $expectCli) "got '$raw1' expected '$cliDir'"

        # Explicit per-window -c always wins, even over the caller cwd: invoke from
        # the CLI dir but pass -c $winDir, and require the window to open in $winDir.
        Push-Location $cliDir
        & $PSMUX new-window -t $sess -c $winDir
        Pop-Location
        $expectWin = Normalize-Path $winDir
        $raw2 = Wait-PanePath "${sess}:2" $expectWin
        Add-Result "[$Mode] new-window -c DIR2 opens in DIR2" `
            ((Normalize-Path $raw2) -eq $expectWin) "got '$raw2' expected '$winDir'"

        # Detached split-window WITHOUT -c: same rule as new-window — the new pane
        # opens in the CALLER's cwd, not the session dir. Split window 0
        # (whose initial pane is in $startDir) from the CLI dir and require one of
        # its panes to land in $cliDir.
        Push-Location $cliDir
        & $PSMUX split-window -d -t "${sess}:0" *> $null
        Pop-Location
        $rawS = Wait-PaneInWindow "${sess}:0" $expectCli
        Add-Result "[$Mode] detached split-window (no -c) opens in caller cwd" `
            ((Normalize-Path $rawS) -eq $expectCli) "got '$rawS' expected '$cliDir'"

    } finally {
        & $PSMUX kill-session -t $sess 2>$null
        Remove-Item $startDir, $cliDir, $winDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Mode -Mode "warm-off" -WarmOff $true
Test-Mode -Mode "warm-on"  -WarmOff $false

Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue

Write-Host "`n=== new-session -c / session start directory (warm on + off) ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = ($results | Where-Object { $_.Result -eq "FAIL" }).Count
$total = $results.Count
$passed = $total - $failed
Write-Host "Total: $total | Passed: $passed | Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
if ($failed -gt 0) { exit 1 }
