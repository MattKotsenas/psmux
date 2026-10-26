# A one shot `psmux confirm-before -t A kill-pane` with no client attached
# left a server side prompt. Scripts rely on that (they answer it with
# send-keys or confirm-respond), but the next client to attach was greeted by
# it and answered it no with the first key it pressed, so its own
# `prefix : confirm-before kill-pane`, `y` killed nothing (3 panes stayed 3).
# The prompt now stays for scripts while nobody is attached and is dropped
# when the first client attaches. tmux refuses such a confirm-before with
# `no current client` (cmd-find.c:1298); psmux keeps the detached ability.
#
# Parts, each in default and shared server mode:
#  A  no client: the CLI exits 0, and a script's send-keys y answers the prompt
#  B  after a detached CLI prompt, an attached client's prompt + y kills a pane
#  C  a client attached: the CLI's prompt shows on it and its y kills a pane
#  D  a prompt open when its only client goes away does not greet the next one
#  E  a prompt left by its client stays answerable by a script's send-keys y
#  F  an invalid -c still fails at exit 1
#
# Isolation: a unique -L namespace per case, a private PSMUX_DATA_DIR, cleanup
# only with `-L <ns> kill-server`; client windows are stopped by PID.
param([string]$Exe = $(if ($env:PSMUX_TEST_EXE) { $env:PSMUX_TEST_EXE } else { (Get-Command psmux -EA Stop).Source }))
$ErrorActionPreference = 'Continue'
$script:Passed = 0; $script:Failed = 0
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }

$injector = Join-Path $env:TEMP 'psmux_injector.exe'
if (-not (Test-Path $injector)) {
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /optimize "/out:$injector" (Join-Path $PSScriptRoot 'injector.cs') | Out-Null
}
if (-not (Test-Path $injector)) { Write-Host 'injector not built'; exit 1 }

$savedData = $env:PSMUX_DATA_DIR; $savedMode = $env:PSMUX_SERVER_MODE
Remove-Item env:PSMUX_DATA_DIR, env:PSMUX_SERVER_MODE -EA SilentlyContinue
$defaultBefore = (& $Exe ls 2>&1 | Out-String).Trim()
$work = Join-Path $env:TEMP "stale_confirm_$(Get-Random)"
New-Item -ItemType Directory $work -Force | Out-Null
$conf = Join-Path $work 'empty.conf'; Set-Content $conf '' -Encoding ascii
$env:PSMUX_CONFIG_FILE = $conf
$prompt = '^b{SLEEP:400}:{SLEEP:500}confirm-before kill-pane{ENTER}{SLEEP:900}y'

function New-Case([string]$Mode) {
    $ns = "stc$(Get-Random -Max 999999)"
    $env:PSMUX_DATA_DIR = Join-Path $work $ns
    New-Item -ItemType Directory $env:PSMUX_DATA_DIR -Force | Out-Null
    if ($Mode -eq 'shared') { $env:PSMUX_SERVER_MODE = 'shared' } else { Remove-Item env:PSMUX_SERVER_MODE -EA SilentlyContinue }
    & $Exe -L $ns new -d -s A | Out-Null
    Start-Sleep 2
    & $Exe -L $ns split-window -t A | Out-Null
    & $Exe -L $ns split-window -t A | Out-Null
    Start-Sleep 1
    $ns
}
function Panes([string]$ns) { (& $Exe -L $ns display -p -t A '#{window_panes}' 2>&1 | Out-String).Trim() }
function Attach([string]$ns) {
    $p = Start-Process -FilePath $Exe -ArgumentList '-L', $ns, 'attach', '-t', 'A' -PassThru
    Start-Sleep 4
    $p
}
function End-Case([string]$ns, $procs) {
    & $Exe -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    foreach ($p in $procs) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } }
}

try {
    foreach ($mode in 'default', 'shared') {
        Write-Host "`n=== $mode server ===" -ForegroundColor Cyan

        # A
        # The guarded command sets an option: a kill-pane answered by
        # send-keys does not kill on any build (a separate, older bug), while
        # an option set is what test_issue828 checks on this same path.
        $ns = New-Case $mode
        $out = (& $Exe -L $ns confirm-before -t A set -g '@stc' ran 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        if ($rc -eq 0 -and $out -eq '') { Pass "[$mode A] no client: the CLI exits 0 with no output" }
        else { Fail "[$mode A] no client: expected rc 0 and no output, got rc=$rc '$out'" }
        $v = (& $Exe -L $ns show -gv '@stc' 2>&1 | Out-String).Trim()
        if ($v -ne 'ran') { Pass "[$mode A] nothing ran before the answer" } else { Fail "[$mode A] @stc=ran before the answer" }
        & $Exe -L $ns send-keys -t A y 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        $v = (& $Exe -L $ns show -gv '@stc' 2>&1 | Out-String).Trim()
        if ($v -eq 'ran') { Pass "[$mode A] a script's send-keys y answered the detached prompt" }
        else { Fail "[$mode A] @stc='$v' after send-keys y, expected ran" }
        End-Case $ns @()

        # B: the original repro
        $ns = New-Case $mode
        & $Exe -L $ns confirm-before -t A kill-pane 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $c = Attach $ns
        & $injector $c.Id $prompt | Out-Null
        Start-Sleep -Milliseconds 1500
        $p = Panes $ns
        if ($p -eq '2') { Pass "[$mode B] attached prompt + y after a detached CLI prompt killed a pane (3 to 2)" }
        else { Fail "[$mode B] attached prompt + y left panes=$p, expected 2 (the detached prompt ate the keys)" }
        End-Case $ns @($c)

        # C
        $ns = New-Case $mode
        $c = Attach $ns
        $out = (& $Exe -L $ns confirm-before -t A kill-pane 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        if ($rc -eq 0 -and $out -eq '') { Pass "[$mode C] client attached: CLI accepted, rc=0" }
        else { Fail "[$mode C] client attached: expected rc 0 and no output, got rc=$rc '$out'" }
        Start-Sleep -Milliseconds 800
        & $injector $c.Id 'y' | Out-Null
        Start-Sleep -Milliseconds 1200
        $p = Panes $ns
        if ($p -eq '2') { Pass "[$mode C] the CLI's prompt showed on the client and its y killed a pane" }
        else { Fail "[$mode C] panes=$p after y, expected 2" }
        End-Case $ns @($c)

        # D
        $ns = New-Case $mode
        $c1 = Attach $ns
        & $Exe -L $ns confirm-before -t A kill-pane 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        Stop-Process -Id $c1.Id -Force -EA SilentlyContinue
        Start-Sleep 2
        $c2 = Attach $ns
        & $injector $c2.Id $prompt | Out-Null
        Start-Sleep -Milliseconds 1500
        $p = Panes $ns
        if ($p -eq '2') { Pass "[$mode D] a prompt whose client went away did not greet the next client" }
        else { Fail "[$mode D] panes=$p, expected 2 (the old prompt survived into the next client)" }
        End-Case $ns @($c1, $c2)

        # E
        $ns = New-Case $mode
        $c1 = Attach $ns
        & $Exe -L $ns confirm-before -t A set -g '@stc' ran 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        Stop-Process -Id $c1.Id -Force -EA SilentlyContinue
        Start-Sleep 2
        & $Exe -L $ns send-keys -t A y 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        $v = (& $Exe -L $ns show -gv '@stc' 2>&1 | Out-String).Trim()
        if ($v -eq 'ran') { Pass "[$mode E] a prompt left by its client is still answered by a script's send-keys y" }
        else { Fail "[$mode E] @stc='$v' after send-keys y, expected ran" }
        End-Case $ns @($c1)

        # F
        $ns = New-Case $mode
        $out = (& $Exe -L $ns confirm-before -c ab -t A kill-pane 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        if ($rc -eq 1 -and $out -match 'invalid confirm key') { Pass "[$mode F] invalid -c: rc=1 '$out'" }
        else { Fail "[$mode F] invalid -c: expected rc 1 and 'invalid confirm key', got rc=$rc '$out'" }
        End-Case $ns @()
    }
} finally {
    Remove-Item env:PSMUX_DATA_DIR, env:PSMUX_SERVER_MODE, env:PSMUX_CONFIG_FILE -EA SilentlyContinue
    $defaultAfter = (& $Exe ls 2>&1 | Out-String).Trim()
    if ($defaultAfter -ne $defaultBefore) { Fail "the default namespace changed: '$defaultBefore' -> '$defaultAfter'" }
    if ($null -ne $savedData) { $env:PSMUX_DATA_DIR = $savedData }
    if ($null -ne $savedMode) { $env:PSMUX_SERVER_MODE = $savedMode }
    Remove-Item -Recurse -Force $work -EA SilentlyContinue
}
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed"
Write-Host "  Failed: $script:Failed"
exit $script:Failed
