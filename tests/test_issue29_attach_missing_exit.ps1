# Attaching to a session that does not exist must fail, and a nested bare psmux
# must say so, even when stdin is not a terminal.
#
# Two bugs, one shared root cause at src/main.rs. The client had a fallback:
#
#     if !stdin().is_terminal() && !pipe_vt { print_version(); return Ok(()); }
#
# It exists for headless validation pipelines (winget), where a bare `psmux`
# cannot start a TUI and should exit cleanly rather than hang. But it sat AHEAD
# of the work every other invocation still owed:
#
#   1. `attach -t <missing>` resolved the target, never checked it existed, and
#      fell through to that gate. Any scripted attach (output captured, so stdin
#      is a pipe) printed the version and exited 0, reporting success for a
#      session that was never there. tmux prints `can't find session: NAME` and
#      exits 1.
#   2. A nested bare `psmux` hit the same gate BEFORE the nesting guard, so the
#      "sessions should be nested with care" refusal was replaced by a version
#      banner for every non-tty caller.
#
# Both are invisible interactively, which is why they survived: at a real
# terminal stdin IS a tty, the gate never fires, and both paths behave. Only a
# script sees it, and a script is exactly what cannot tell version output from
# success.
#
# The fix validates the attach target before committing, and moves the nesting
# guard ahead of the non-tty fallback. Nesting is a property of the environment,
# not of the terminal.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$MISSING = "no_such_session_i29_xyz"
$SESSION = "i29_real"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [info] $msg" -ForegroundColor DarkGray }

function Reset-All {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Get-Process psmux, tmux, pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 400
    Get-ChildItem $psmuxDir -EA SilentlyContinue |
        Where-Object { $_.Extension -in '.port', '.key', '.pid', '.sid', '.spawnlock' } |
        Remove-Item -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# The non-tty condition is the whole point: it is what made the bug reachable.
# Capturing output only pipes STDOUT; stdin stays whatever the harness gave us
# (a real console under run_all_tests' -NoNewWindow launch, the null device in
# some agent shells). So pipe empty input explicitly: that makes stdin a pipe
# in every harness, and it is what kept this suite hanging for 240s under the
# full runner: with a console stdin, the bare-psmux arms started a REAL TUI on
# the runner's console instead of taking the non-tty fallback.
function Invoke-Attach($form, $target) {
    $out = '' | & $PSMUX $form -t $target 2>&1 | Out-String
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out.Trim() }
}

function Test-MissingSessionRefused($form, $label) {
    $r = Invoke-Attach $form $MISSING
    Write-Info "$label -> exit=$($r.Exit) out=[$($r.Out)]"
    if ($r.Exit -eq 0) {
        Write-Fail "$label exited 0 for a missing session"
        return
    }
    if ($r.Out -match "can't find|no such|no session|not found") {
        Write-Pass "$label failed with a missing-session error (exit $($r.Exit))"
    } else {
        Write-Fail "$label exited $($r.Exit) but said nothing about the missing session: $($r.Out)"
    }
    if ($r.Out -match "^\s*tmux \d+\.\d+") {
        Write-Fail "$label printed the version banner instead of an error"
    } else {
        Write-Pass "$label did not fall through to the version banner"
    }
}

Write-Host "`n=== attach must refuse a missing session; nesting must be reported ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray

# ---------------------------------------------------------------- Part A ----
# No server anywhere. Every alias must refuse.
Write-Host "`n[Test 1] No server running: every attach alias refuses a missing target" -ForegroundColor Yellow
Reset-All
foreach ($f in @("a", "at", "attach", "attach-session")) {
    Test-MissingSessionRefused $f "psmux $f -t <missing>"
}

# ---------------------------------------------------------------- Part B ----
# A server IS running with a real session. A missing target must still be
# refused, and the refusal must not be a side effect of "no server at all".
Write-Host "`n[Test 2] With a live session present, a missing target is still refused" -ForegroundColor Yellow
Reset-All
$env:PSMUX_NO_WARM = "1"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    & $PSMUX has-session -t $SESSION 2>$null
    if ($LASTEXITCODE -eq 0) { $up = $true; break }
}
if (-not $up) {
    Write-Fail "setup: session $SESSION never came up"
} else {
    Write-Pass "setup: live session $SESSION is up"
    Test-MissingSessionRefused "attach" "psmux attach -t <missing> (server live)"

    # The guard must not have become "refuse everything": the real session must
    # still be attachable. Proven without occupying this console by checking
    # that a detached attach client actually registers.
    $p = Start-Process -FilePath $PSMUX -ArgumentList 'attach', '-t', $SESSION -PassThru
    $attached = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $att = ((& $PSMUX display-message -t $SESSION -p '#{session_attached}' 2>&1) -join '').Trim()
        if ($att -match '^\d+$' -and [int]$att -ge 1) { $attached = $true; break }
        Start-Sleep -Milliseconds 400
    }
    if ($attached) {
        Write-Pass "a real session still attaches (the check refuses only what is missing)"
    } else {
        Write-Fail "REGRESSION: a real session no longer attaches"
    }
    try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}
}
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

# ---------------------------------------------------------------- Part C ----
# The nesting guard must survive a non-tty caller.
Write-Host "`n[Test 3] Nested bare psmux (non-tty) reports the nesting refusal" -ForegroundColor Yellow
Reset-All
$portsBefore = (Get-ChildItem "$psmuxDir" -Filter "*.port" -EA SilentlyContinue).Count
$env:PSMUX_ACTIVE = "1"
$env:PSMUX_NO_WARM = "1"
Remove-Item Env:\PSMUX_ALLOW_NESTING -EA SilentlyContinue

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out3 = '' | & $PSMUX 2>&1 | Out-String
$exit3 = $LASTEXITCODE
$sw.Stop()
$portsAfter = (Get-ChildItem "$psmuxDir" -Filter "*.port" -EA SilentlyContinue).Count

Write-Info "bare nested psmux -> exit=$exit3 in $($sw.ElapsedMilliseconds)ms out=[$($out3.Trim())]"
if ($out3 -match "nested with care") {
    Write-Pass "the nesting refusal is reported to a non-tty caller"
} else {
    Write-Fail "expected the nesting refusal, got: $($out3.Trim())"
}
if ($sw.ElapsedMilliseconds -lt 5000) {
    Write-Pass "it exits promptly instead of blocking on a tty ($($sw.ElapsedMilliseconds)ms)"
} else {
    Write-Fail "took $($sw.ElapsedMilliseconds)ms, expected under 5000"
}
if ($portsAfter -le $portsBefore) {
    Write-Pass "no session was spawned by the refused nested invocation"
} else {
    Write-Fail "a nested session was created despite the guard"
}
Remove-Item Env:\PSMUX_ACTIVE -EA SilentlyContinue

# ---------------------------------------------------------------- Part D ----
# The headless fallback itself must survive. This is what the gate is FOR: a
# bare, non-nested, non-tty psmux still reports its version and exits 0, which
# is what the winget validation pipeline depends on.
Write-Host "`n[Test 4] The headless version fallback still works for a bare invocation" -ForegroundColor Yellow
Reset-All
Remove-Item Env:\PSMUX_ACTIVE -EA SilentlyContinue
$out4 = '' | & $PSMUX 2>&1 | Out-String
$exit4 = $LASTEXITCODE
Write-Info "bare psmux (not nested) -> exit=$exit4 out=[$($out4.Trim())]"
if ($exit4 -eq 0 -and $out4 -match "tmux \d+\.\d+") {
    Write-Pass "bare non-tty psmux still prints the version and exits 0"
} else {
    Write-Fail "the headless fallback regressed: exit=$exit4 out=$($out4.Trim())"
}

# ---------------------------------------------------------------- Part E ----
Write-Host "`n[Test 5] Win32 TUI: a live attached window is unaffected" -ForegroundColor Yellow
Reset-All
$proc = $null
try {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", "i29_tui" -PassThru
    Start-Sleep -Seconds 6
    & $PSMUX has-session -t i29_tui 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "TUI: attached session is up"
        $panes = ((& $PSMUX display-message -t i29_tui -p '#{window_panes}' 2>&1) -join '').Trim()
        if ($panes -match '^\d+$' -and [int]$panes -ge 1) {
            Write-Pass "TUI: the session answers queries (window_panes=$panes)"
        } else {
            Write-Fail "TUI: session did not answer (window_panes='$panes')"
        }
        $r = Invoke-Attach "attach" $MISSING
        if ($r.Exit -ne 0) {
            Write-Pass "TUI: a missing target is still refused while a real session runs"
        } else {
            Write-Fail "TUI: missing target exited 0 with a live session present"
        }
    } else {
        Write-Fail "TUI: setup failed, session never came up"
    }
} finally {
    & $PSMUX kill-session -t i29_tui 2>&1 | Out-Null
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
}

Reset-All
Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
