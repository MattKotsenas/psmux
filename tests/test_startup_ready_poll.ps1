# test_startup_ready_poll.ps1 — the `new-session` readiness contract.
#
# `psmux new-session` returns only once the session is genuinely usable, and it
# discovers that by polling. The poll interval used to be a flat 20ms; it now
# ramps 1ms -> 20ms (see next_ready_poll_step_ms in src/main.rs and the unit
# tests in tests-rs/test_ready_poll_backoff.rs) so a warm claim is noticed
# promptly instead of sleeping through most of the remaining wait.
#
# Polling FASTER is only safe if the predicate is unchanged, so what this suite
# pins is the contract, not a stopwatch: when `new-session -d` exits 0, the
# session must ALREADY be fully usable with no settling delay whatsoever — a
# window listed, a pane capturable, the server answering commands. It checks
# that on the warm-claim path and on the cold path, and it checks that a failed
# creation is still reported rather than raced past.
#
#   pwsh -NoProfile -File tests\test_startup_ready_poll.ps1

param([string]$Psmux = "", [int]$Iterations = 6)
$ErrorActionPreference = "Continue"
$script:Passed = 0
$script:Failed = 0
function Ok   { param($m) Write-Host "[PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Bad  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red;   $script:Failed++ }
function Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }

if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
if (-not (Test-Path $Psmux)) { Write-Host "psmux release binary not found; run cargo build --release" -ForegroundColor Red; exit 1 }
$Psmux = (Resolve-Path $Psmux).Path
# session.rs gates the server image name; a differently named copy silently
# loses the warm-claim fast path and this suite would be testing the rename.
$imgName = [IO.Path]::GetFileNameWithoutExtension($Psmux).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) { Write-Host "REFUSING: '$imgName' is not a recognised server image name" -ForegroundColor Red; exit 1 }

$NS = "rdypoll$PID"
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $NS kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 250
    Get-ChildItem "$DataDir\$($NS)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("=" * 72)
Write-Host "  NEW-SESSION READINESS CONTRACT (ramped poll)"
Write-Host ("=" * 72)
Info "binary: $Psmux"
Info "namespace: $NS"

# ---------------------------------------------------------------------------
# 1 + 2: when new-session -d returns 0, the session is usable RIGHT NOW.
# No Start-Sleep anywhere after the call: any settling the CLI still owed would
# show up immediately as an empty window list or an unusable pane.
# ---------------------------------------------------------------------------
foreach ($mode in @("warm", "cold")) {
    Cleanup
    if ($mode -eq "warm") {
        # prime the namespace's warm spare the way a real machine has it primed
        & $Psmux -L $NS new-session -d -s primer 2>&1 | Out-Null
        & $Psmux -L $NS kill-session -t primer 2>&1 | Out-Null
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.ElapsedMilliseconds -lt 10000 -and -not (Test-Path "$DataDir\$($NS)____warm__.port")) { Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 800
        $env:PSMUX_NO_WARM = $null
    } else {
        $env:PSMUX_NO_WARM = "1"
    }

    $usable = 0; $created = 0; $badRc = 0
    for ($i = 0; $i -lt $Iterations; $i++) {
        $sess = "rp$i"
        & $Psmux -L $NS new-session -d -s $sess 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $badRc++; continue }
        $created++
        # NO sleep here on purpose.
        $wins = & $Psmux -L $NS list-windows -t $sess 2>&1
        $rcW = $LASTEXITCODE
        $cap = & $Psmux -L $NS capture-pane -p -t "$($sess):0.0" 2>&1
        $rcC = $LASTEXITCODE
        if ($rcW -eq 0 -and $rcC -eq 0 -and "$wins".Trim() -and "$wins" -notmatch '^ERROR') { $usable++ }
        else { Write-Host "       iter $i unusable: list rc=$rcW cap rc=$rcC wins='$("$wins".Trim())'" -ForegroundColor DarkYellow }
        & $Psmux -L $NS kill-session -t $sess 2>&1 | Out-Null
    }
    $env:PSMUX_NO_WARM = $null

    Write-Host ""
    Write-Host "[TEST] ${mode} path: new-session -d exits 0 only when the session is already usable"
    if ($badRc -gt 0) { Bad "${mode}: $badRc/$Iterations new-session calls exited non-zero" }
    else { Ok "${mode}: all $Iterations new-session calls exited 0" }
    if ($usable -eq $created -and $created -eq $Iterations) {
        Ok "${mode}: all $created sessions listed a window and captured a pane with no settling delay"
    } else {
        Bad "${mode}: only $usable/$created sessions were usable the instant new-session returned"
    }
}

# ---------------------------------------------------------------------------
# 3: a faster poll must not turn a genuine failure into a false success. A
# session name that already exists must still be refused, not raced past.
# ---------------------------------------------------------------------------
Cleanup
& $Psmux -L $NS new-session -d -s dup 2>&1 | Out-Null
$firstRc = $LASTEXITCODE
$out = & $Psmux -L $NS new-session -d -s dup 2>&1
$dupRc = $LASTEXITCODE
Write-Host ""
Write-Host "[TEST] duplicate session name is still refused"
if ($firstRc -eq 0 -and $dupRc -ne 0) { Ok "second new-session -s dup exited $dupRc (refused)" }
else { Bad "first rc=$firstRc second rc=$dupRc out='$("$out".Trim())'" }

# ---------------------------------------------------------------------------
# 4: the readiness wait still bounds a server that never becomes usable, and a
# genuine spawn failure is reported rather than raced past.
#
# The unspawnable condition is a `default-shell` that does not exist. That is
# the one case where the SERVER's own CreateProcessW fails: it records the
# reason in server-startup.log and exits, the .port file vanishes, and the
# client's readiness wait turns that into rc 1 plus the reason (issue #370).
#
# It is NOT a bogus path given as the pane command. A string pane command is
# handed to the default shell (`pwsh -Command "<cmd>"`), exactly as tmux hands
# it to `sh -c`, so the spawn SUCCEEDS, the window exists when new-session
# returns, and it is the shell that then reports the missing executable and
# exits. tmux returns 0 there and so does psmux; the original version of this
# arm asserted rc 1 for that case and was wrong from the day it was written
# (2026-09-09 sweep, "exited 0 for a shell that cannot exist"). Both cases are
# now pinned separately.
# ---------------------------------------------------------------------------
Cleanup
$badConf = Join-Path ([IO.Path]::GetTempPath()) "psmux_rdypoll_badshell_$PID.conf"
'set -g default-shell "C:\definitely\not\a\real\shell.exe"' | Set-Content -Path $badConf -Encoding ASCII
$sw = [Diagnostics.Stopwatch]::StartNew()
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_CONFIG_FILE = $badConf
$deadOut = & $Psmux -L $NS new-session -d -s deadshell 2>&1 | Out-String
$deadRc = $LASTEXITCODE
$env:PSMUX_CONFIG_FILE = $null
$sw.Stop()
$env:PSMUX_NO_WARM = $null
Remove-Item $badConf -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "[TEST] an unspawnable default-shell still fails, names the reason, and is still bounded"
if ($deadRc -ne 0) { Ok "exited $deadRc after $([math]::Round($sw.Elapsed.TotalSeconds,1))s" }
else { Bad "exited 0 for a default-shell that cannot exist (after $([math]::Round($sw.Elapsed.TotalSeconds,1))s)" }
if ($deadOut -match "failed to create session" -and $deadOut -match "spawn shell error|cannot find the path") { Ok "the spawn failure and its reason were surfaced to the caller (#370)" }
else { Bad "expected the spawn failure reason on stderr, got: '$($deadOut.Trim())'" }
if ($sw.Elapsed.TotalSeconds -lt 20) { Ok "bounded: returned in $([math]::Round($sw.Elapsed.TotalSeconds,1))s, under the 15s readiness deadline plus slack" }
else { Bad "took $([math]::Round($sw.Elapsed.TotalSeconds,1))s, past the readiness deadline" }
$deadLs = & $Psmux -L $NS list-sessions 2>&1 | Out-String
if ($deadLs -notmatch "deadshell") { Ok "no half-created deadshell session was left behind" }
else { Bad "a deadshell session survived a failed spawn: '$($deadLs.Trim())'" }

# The tmux parity half: a bogus PANE COMMAND goes through the shell, so the
# session is created and new-session exits 0, the same as `tmux new -d nosuch`.
Cleanup
$env:PSMUX_NO_WARM = "1"
& $Psmux -L $NS new-session -d -s bogus "C:\definitely\not\a\real\shell_$PID.exe" 2>&1 | Out-Null
$bogusRc = $LASTEXITCODE
$env:PSMUX_NO_WARM = $null
Write-Host ""
Write-Host "[TEST] a bogus pane COMMAND is the shell's problem, not a creation failure (tmux parity)"
if ($bogusRc -eq 0) { Ok "new-session -d with a bogus pane command exited 0, like tmux" }
else { Bad "new-session -d with a bogus pane command exited $bogusRc, tmux exits 0" }

Cleanup
Write-Host ""
Write-Host ("=" * 72)
Write-Host ("  PASSED: {0}   FAILED: {1}" -f $script:Passed, $script:Failed)
Write-Host ("=" * 72)
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
