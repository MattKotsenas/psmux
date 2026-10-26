# `#{pane_current_command}` reports the pane's FOREGROUND program, not its shell.
#
# tmux answers that format with the program in front of the tty. psmux answered
# it from a one-level walk (plus one extra level for a known wrapper name), so
# any real Windows chain deeper than that froze at the shell: git bash alone is
# `bash.exe -> bash.exe`, which spends the wrapper step before the user's
# command is even reached. Control tools that key off this format then
# mis-detect nesting and never see a command finish.
#
# The format now resolves the deepest non-system descendant on demand.
#
# Isolation (AGENTS.md): New-PsmuxTestEnv (throwaway USERPROFILE/HOME, scrubbed
# PSMUX_*/TMUX vars) plus a dedicated -L namespace.

$ErrorActionPreference = "Continue"

$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_pane_current_command_foreground: starts a real server." -ForegroundColor Yellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 in a disposable environment to run it." -ForegroundColor Yellow
    exit 0
}

. "$PSScriptRoot\psmux_test_helpers.ps1"

$ctx = New-PsmuxTestEnv -Tag 'pcurcmd'
$PSMUX = $ctx.PsmuxExe
$ns = Register-PsmuxNamespace -Ctx $ctx -Namespace "pcurcmd"
$S = "pcurcmd"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Get-CurrentCommand {
    (& $PSMUX -L $ns display-message -p -t $S '#{pane_current_command}' 2>&1 | Out-String).Trim()
}

Write-Host "`n=== pane_current_command follows the foreground process ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX  namespace: $ns" -ForegroundColor DarkGray

try {
    & $PSMUX -L $ns new-session -d -s $S
    Start-Sleep -Seconds 3

    # -----------------------------------------------------------------------
    # TEST 1: an idle pane reports its own shell
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 1] idle pane reports the shell" -ForegroundColor Yellow
    $idle = Get-CurrentCommand
    if ($idle -match '^(pwsh|powershell|cmd|bash)$') { Write-Pass "idle pane reports '$idle'" }
    else { Write-Fail "idle pane reported '$idle'" }

    # -----------------------------------------------------------------------
    # TEST 2: a command nested three levels down is reported, not the shell.
    # `cmd /c "cmd /c ping"` is pwsh -> cmd -> cmd -> PING.EXE; the old walk
    # stopped at the first wrapper's child and answered "cmd".
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 2] deeply nested foreground command (pwsh -> cmd -> cmd -> ping)" -ForegroundColor Yellow
    & $PSMUX -L $ns send-keys -t $S 'cmd /c "cmd /c ping -n 30 127.0.0.1"' Enter
    Start-Sleep -Seconds 4
    $running = Get-CurrentCommand
    if ($running -ieq "PING") { Write-Pass "reports the foreground command ('$running')" }
    elseif ($running -ieq "cmd" -or $running -ieq "pwsh") { Write-Fail "stopped short at '$running' instead of the ping" }
    else { Write-Fail "reported '$running'" }

    # -----------------------------------------------------------------------
    # TEST 3: it goes back to the shell when the command ends
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 3] returns to the shell after the command exits" -ForegroundColor Yellow
    # send-keys C-c cannot stop a detached ConPTY child (known limitation), so
    # end the chain by pid: killing the ping lets both cmd wrappers run to
    # completion and the shell take the tty back.
    Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" |
        Where-Object { $_.CommandLine -match '-n 30 127\.0\.0\.1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Start-Sleep -Seconds 3
    $back = Get-CurrentCommand
    if ($back -ieq $idle) { Write-Pass "back to '$back'" }
    else { Write-Fail "expected '$idle', got '$back'" }

    # -----------------------------------------------------------------------
    # TEST 4: the reported repro shape — a command under a bash shell.
    # Git bash is `bash.exe -> bash.exe -> <command>`, the chain that made the
    # old walk answer "bash" for everything the user ran.
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 4] command running under bash" -ForegroundColor Yellow
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (-not (Test-Path $gitBash)) {
        Write-Host "  [SKIP] Git for Windows bash not installed at $gitBash" -ForegroundColor Yellow
    } else {
        & $PSMUX -L $ns send-keys -t $S ('& "' + $gitBash + '" -c "sleep 60"') Enter
        Start-Sleep -Seconds 5
        $under = Get-CurrentCommand
        if ($under -ieq "sleep") { Write-Pass "reports 'sleep', not the bash wrapping it" }
        elseif ($under -ieq "bash") { Write-Fail "reported the shell ('bash') while sleep was in front" }
        else { Write-Fail "reported '$under'" }
        # Same ConPTY limitation as Test 3: end the bash chain by pid.
        Get-CimInstance Win32_Process -Filter "Name='sleep.exe'" |
            Where-Object { $_.CommandLine -match 'sleep 60' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
        Start-Sleep -Seconds 3
    }

    # -----------------------------------------------------------------------
    # TEST 5: process enumeration failure must not be fatal — a pane whose
    # child is gone still answers (the format never errors out).
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 5] answer is always a non-empty name" -ForegroundColor Yellow
    $final = Get-CurrentCommand
    if ($final) { Write-Pass "still answers ('$final')" }
    else { Write-Fail "empty answer" }
} finally {
    Remove-PsmuxTestEnv -Ctx $ctx
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
