# paste-buffer is byte-verbatim: quotes, tabs, control bytes and newlines that
# went into a buffer come back out of it unchanged.
#
# tmux's paste is a byte copy. psmux's was not: `load-buffer` shipped the file
# to the server as bare words on the control line, so before any handler saw it
# the wire tokenizer had stripped quote grouping, collapsed tabs and runs of
# spaces to one space, split the line at `;`, and left the client's `\n` escape
# as two literal characters. `paste-buffer` then pasted that faithfully, which
# for a buffer pasted at a shell prompt is not cosmetic damage but a DIFFERENT
# command: `printf '%s' 'QUOTED ARG'` arrived as `printf %s QUOTED ARG`.
#
# Buffer content now travels hex-encoded (`set-buffer -H`), the same byte-exact
# wire shape `send -H` already uses for keystrokes.
#
# Isolation (AGENTS.md): New-PsmuxTestEnv (throwaway USERPROFILE/HOME, scrubbed
# PSMUX_*/TMUX vars) plus a dedicated -L namespace.

$ErrorActionPreference = "Continue"

$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_paste_buffer_verbatim: starts a real server." -ForegroundColor Yellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 in a disposable environment to run it." -ForegroundColor Yellow
    Write-Host "       Server-free coverage: cargo test --bin psmux hex_buffer_wire" -ForegroundColor Yellow
    exit 0
}

. "$PSScriptRoot\psmux_test_helpers.ps1"

$ctx = New-PsmuxTestEnv -Tag 'pbverbatim'
$PSMUX = $ctx.PsmuxExe
$ns = Register-PsmuxNamespace -Ctx $ctx -Namespace "pbverbatim"
$S = "pbverbatim"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "`n=== paste-buffer verbatim bytes ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX  namespace: $ns" -ForegroundColor DarkGray

try {
    & $PSMUX -L $ns new-session -d -s $S
    Start-Sleep -Seconds 3

    # -----------------------------------------------------------------------
    # TEST 1: load-buffer -> show-buffer round-trips every hostile byte
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 1] load-buffer round-trip keeps quotes, tab, ESC, ';', newlines" -ForegroundColor Yellow
    $f = Join-Path $ctx.Home "verbatim.txt"
    # Single quotes, double quotes, a TAB, a semicolon (the wire's command
    # separator), an ESC control byte, a run of spaces, and two lines.
    $content = "printf '%s' 'QUOTED ARG'`tTAB;NOTACOMMAND`nsecond `"dq`"  two-spaces`e[0m"
    [System.IO.File]::WriteAllText($f, $content, [System.Text.UTF8Encoding]::new($false))
    & $PSMUX -L $ns load-buffer -b pb $f
    Start-Sleep -Milliseconds 500
    # show-buffer appends a trailing newline of its own (protocol framing).
    $shown = (& $PSMUX -L $ns show-buffer -b pb 2>&1 | Out-String) -replace "`r`n", "`n"
    $expected = ($content -replace "`r`n", "`n")
    if ($shown.TrimEnd("`n") -ceq $expected.TrimEnd("`n")) {
        Write-Pass "buffer content is byte-identical to the file"
    } else {
        Write-Fail "buffer content differs"
        Write-Host ("    expected: " + ($expected | ConvertTo-Json)) -ForegroundColor DarkGray
        Write-Host ("    actual  : " + ($shown | ConvertTo-Json)) -ForegroundColor DarkGray
    }

    # -----------------------------------------------------------------------
    # TEST 2: set-buffer content survives the same wire
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 2] set-buffer keeps quoting and repeated spaces" -ForegroundColor Yellow
    & $PSMUX -L $ns set-buffer -b sb "echo 'A  B'"
    Start-Sleep -Milliseconds 300
    $sb = (& $PSMUX -L $ns show-buffer -b sb 2>&1 | Out-String).TrimEnd("`r", "`n")
    if ($sb -ceq "echo 'A  B'") { Write-Pass "set-buffer stored the literal text" }
    else { Write-Fail "set-buffer stored '$sb'" }

    # -----------------------------------------------------------------------
    # TEST 3: what the pane RUNS is the command that was in the buffer.
    # The single quotes are load-bearing, not decoration: with them the shell
    # prints the literal text, without them it expands $novar_END to nothing.
    # That is the whole point — a paste that drops quotes is a DIFFERENT
    # command, and a buffer pasted at a prompt is program control, not display.
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 3] pasted text executes as the original command" -ForegroundColor Yellow
    $quoted = "Write-Output 'PBV_`$novar_END'"
    & $PSMUX -L $ns set-buffer -b run $quoted
    Start-Sleep -Milliseconds 300
    & $PSMUX -L $ns paste-buffer -b run -t $S
    Start-Sleep -Milliseconds 700
    & $PSMUX -L $ns send-keys -t $S Enter
    Start-Sleep -Seconds 2
    $cap = & $PSMUX -L $ns capture-pane -p -t $S 2>&1 | Out-String
    # Match the OUTPUT line, not the echoed input: the prompt line contains the
    # marker either way, so only a line that is exactly the marker proves the
    # shell received the quotes.
    $lines = ($cap -split "`r?`n") | ForEach-Object { $_.Trim() }
    if ($lines -contains 'PBV_$novar_END') { Write-Pass "quoted argument reached the shell intact" }
    elseif ($lines -contains 'PBV_') { Write-Fail "quoting was lost: the shell ran a different command" }
    else { Write-Fail "pasted command produced no recognizable output" }
} finally {
    Remove-PsmuxTestEnv -Ctx $ctx
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
