# Issue #574: session renaming fails again in 3.3.7
#
# Reported: this loop dies from the third iteration onward on the 3.3.7 release,
# and works on 3.3.6.
#
#     for i in 1..10:
#         psmux new-session -d          # no -s, so the auto-namer picks "0"
#         psmux rename-session -t 0 "test-$i"
#         psmux list-sessions
#
# On the 3.3.7 release binary (05cc5d4) this produces, from iteration 3:
#     psmux: failed to create session '0'
#     psmux: no server running on session '0'
#
# Same root cause as #505: a server holds the Windows named mutex
# Local\psmux-session-<name> for its whole life (the single-server-per-name guard
# from issue #2), keyed on the name it started under. Renaming migrated the
# registry files but not the mutex, so the freed name stayed locked forever and
# the auto-namer's next pick of "0" hit a "duplicate" server that exited without
# writing a port file. b3d55f8 re-keys the guard on rename, but it landed on
# 2026-07-30, ten days AFTER the v3.3.7 tag (2026-07-20), so no released build
# carries it.
#
# What this suite adds over tests\test_issue505_rename_newsession.ps1, which
# already covers a single rename cycle over the TCP path:
#   * the SUSTAINED loop. One rename/recreate cycle passing does not prove the
#     guard survives ten of them, and the report's signature is that iterations
#     1 and 2 pass while 3 onward fail.
#   * the CLI path (main.rs dispatch) rather than the raw TCP server path.
#   * the reporter's config (destroy-unattached on, renumber-windows on) in play.
#
# tmux parity: rename-session is RB_REMOVE + RB_INSERT, so the old name frees
# immediately and can be recreated. Every iteration must succeed.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

# Force the cold spawn path for the whole suite. A warm-claimed server never ran
# the startup guard, so it cannot be refused as a duplicate: with the pool active
# the first few iterations are served by warms and pass even on a broken build,
# and the failure only appears once the pool is drained. That made this suite a
# coin flip against the 3.3.7 release (Tests 1 and 2 passed, 3 and 4 failed).
# The cold path takes the guard on every iteration, which is the thing under test.
$script:PrevNoWarm = $env:PSMUX_NO_WARM
$env:PSMUX_NO_WARM = "1"

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [info] $msg" -ForegroundColor DarkGray }

function Reset-All {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
    Get-ChildItem $psmuxDir -EA SilentlyContinue |
        Where-Object { $_.Extension -in '.port', '.key', '.pid', '.sid', '.spawnlock' } |
        Remove-Item -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Test-SessionExists($name) {
    & $PSMUX has-session -t $name 2>$null
    return ($LASTEXITCODE -eq 0)
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

# One iteration of the reporter's loop over the CLI path. Returns a record of
# what each command actually did, so a failure names the command and its output.
function Invoke-ReporterIteration {
    param([int]$Index)

    $createOut = (& $PSMUX new-session -d 2>&1 | Out-String).Trim()
    $createExit = $LASTEXITCODE
    Start-Sleep -Milliseconds 900

    $renameOut = (& $PSMUX rename-session -t 0 "test-$Index" 2>&1 | Out-String).Trim()
    $renameExit = $LASTEXITCODE
    Start-Sleep -Milliseconds 900

    return [pscustomobject]@{
        Index      = $Index
        CreateExit = $createExit
        CreateOut  = $createOut
        RenameExit = $renameExit
        RenameOut  = $renameOut
    }
}

# Run the reporter's loop and assert on every iteration. $Label distinguishes the
# with-config and without-config runs in the output.
function Invoke-ReporterLoop {
    param([int]$Iterations = 10, [string]$Label)

    $bad = @()
    for ($i = 1; $i -le $Iterations; $i++) {
        $r = Invoke-ReporterIteration -Index $i
        if ($r.CreateExit -ne 0 -or $r.RenameExit -ne 0) {
            $bad += $r
            Write-Info ("iteration {0}: new-session exit={1} '{2}' | rename exit={3} '{4}'" -f `
                $r.Index, $r.CreateExit, $r.CreateOut, $r.RenameExit, $r.RenameOut)
        }
    }

    if ($bad.Count -eq 0) {
        Write-Pass "$Label`: all $Iterations create+rename cycles exited 0"
    } else {
        $first = $bad[0]
        Write-Fail ("$Label`: {0}/{1} iterations failed, first at iteration {2} ('{3}' / '{4}') - issue #574 reproduced" -f `
            $bad.Count, $Iterations, $first.Index, $first.CreateOut, $first.RenameOut)
    }

    # The named sessions must actually be there. Exit 0 alone is not proof.
    $missing = @()
    for ($i = 1; $i -le $Iterations; $i++) {
        if (-not (Test-SessionExists "test-$i")) { $missing += "test-$i" }
    }
    if ($missing.Count -eq 0) {
        Write-Pass "$Label`: all $Iterations renamed sessions exist (test-1 .. test-$Iterations)"
    } else {
        Write-Fail "$Label`: missing renamed sessions: $($missing -join ', ')"
    }

    return $bad.Count
}

Write-Host "`n=== Issue #574: a sustained rename loop must not poison the auto-named session ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray
Write-Host "build: $((& $PSMUX -V 2>&1 | Out-String).Trim())" -ForegroundColor DarkGray

# ---------------------------------------------------------------- Part A ----
# The reporter's exact loop over the CLI path, with no config in play.
Write-Host "`n[Test 1] Reporter's 10-iteration loop over the CLI path" -ForegroundColor Yellow
Reset-All
$null = Invoke-ReporterLoop -Iterations 10 -Label "plain"

# ---------------------------------------------------------------- Part B ----
# The regression signature. On the 3.3.7 release iterations 1 and 2 pass and the
# failure starts at 3, because "0" is only re-picked once an earlier "0" has been
# renamed away and its guard leaked. A suite that stops at one cycle misses this
# entirely, which is why #505 passing did not protect #574.
Write-Host "`n[Test 2] Regression signature: the third cycle is the one that used to die" -ForegroundColor Yellow
Reset-All
$thirdOk = $true
$detail = ""
for ($i = 1; $i -le 3; $i++) {
    $r = Invoke-ReporterIteration -Index $i
    if ($i -eq 3) {
        $thirdOk = ($r.CreateExit -eq 0 -and $r.RenameExit -eq 0)
        $detail = "new-session exit=$($r.CreateExit) '$($r.CreateOut)' | rename exit=$($r.RenameExit) '$($r.RenameOut)'"
    }
}
if ($thirdOk) {
    Write-Pass "third create+rename cycle succeeded"
} else {
    Write-Fail "third cycle failed: $detail"
}
if (Test-SessionExists "test-3") {
    Write-Pass "session test-3 exists after the third cycle"
} else {
    Write-Fail "session test-3 does not exist after the third cycle"
}

# ---------------------------------------------------------------- Part C ----
# Root-cause layer. After each rename the freed name must be unlocked and the new
# name locked. This is what actually broke; the CLI symptoms above are downstream.
Write-Host "`n[Test 3] Root cause: the name guard follows every rename in the loop" -ForegroundColor Yellow
Reset-All
$guardBad = @()
for ($i = 1; $i -le 4; $i++) {
    $null = Invoke-ReporterIteration -Index $i
    Start-Sleep -Milliseconds 400
    $zeroFree = -not (Test-SessionNameHeld "0")
    $newHeld = Test-SessionNameHeld "test-$i"
    if (-not $zeroFree) { $guardBad += "after iteration $i the name '0' was still locked" }
    if (-not $newHeld) { $guardBad += "after iteration $i the name 'test-$i' was not locked" }
}
if ($guardBad.Count -eq 0) {
    Write-Pass "across 4 cycles the guard released '0' and held each new name"
} else {
    foreach ($g in $guardBad) { Write-Info $g }
    Write-Fail "name guard desynchronized in the loop ($($guardBad.Count) problems)"
}

# ---------------------------------------------------------------- Part D ----
# The reporter's actual config. destroy-unattached on is the interesting one:
# every session in this loop is detached and never attached, so if that option
# reaped them the loop would fail for an entirely different reason.
Write-Host "`n[Test 4] The reporter's config file is in play" -ForegroundColor Yellow
$conf = "$env:TEMP\psmux_issue574.conf"
@"
set -g destroy-unattached on
set -g scroll-enter-copy-mode off
set -g mouse on
set -g renumber-windows on
"@ | Set-Content -Path $conf -Encoding UTF8

Reset-All
$env:PSMUX_CONFIG_FILE = $conf
$null = Invoke-ReporterLoop -Iterations 10 -Label "reporter config"
$mouse = (& $PSMUX show-options -g -v mouse -t "test-1" 2>&1 | Out-String).Trim()
if ($mouse -eq "on") {
    Write-Pass "the config was genuinely loaded (mouse reads back 'on')"
} else {
    Write-Fail "config not applied, so this run proves nothing about it (mouse='$mouse')"
}
Remove-Item Env:\PSMUX_CONFIG_FILE -EA SilentlyContinue
Remove-Item $conf -Force -EA SilentlyContinue

# ---------------------------------------------------------------- Part E ----
# Win32 TUI layer: a real attached window, renamed underneath, then the freed
# name recreated. This is the shape the original #505 reporter hit interactively.
Write-Host "`n[Test 5] Win32 TUI: rename a live attached session, then reuse the freed name" -ForegroundColor Yellow
Reset-All
$proc = $null
try {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", "0" -PassThru
    Start-Sleep -Seconds 6

    if (Test-SessionExists "0") {
        Write-Pass "TUI: attached session '0' is up"

        & $PSMUX rename-session -t 0 tui574 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        if ((Test-SessionExists "tui574") -and -not (Test-SessionExists "0")) {
            Write-Pass "TUI: rename 0 -> tui574 took effect on the live session"
        } else {
            Write-Fail "TUI: rename did not take effect"
        }

        & $PSMUX new-session -d 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if (Test-SessionExists "0") {
            Write-Pass "TUI: the freed name '0' was recreated while the renamed session is still live"
        } else {
            Write-Fail "TUI: could not recreate '0' after the rename (issue #574 reproduced)"
        }

        # The renamed session must still be alive and usable, not collateral damage.
        $wins = (& $PSMUX display-message -t tui574 -p '#{session_windows}' 2>&1 | Out-String).Trim()
        if ($wins -match '^\d+$' -and [int]$wins -ge 1) {
            Write-Pass "TUI: the renamed session still answers queries (session_windows=$wins)"
        } else {
            Write-Fail "TUI: the renamed session stopped responding (session_windows='$wins')"
        }
    } else {
        Write-Fail "TUI: setup failed, attached session '0' never came up"
    }
} finally {
    & $PSMUX kill-session -t tui574 2>&1 | Out-Null
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
}

# ------------------------------------------------------------------------- --
Reset-All
if ($null -eq $script:PrevNoWarm) { Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue }
else { $env:PSMUX_NO_WARM = $script:PrevNoWarm }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
