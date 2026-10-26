# `psmux command-prompt` from the command line, or from a hook, opens its
# prompt on an attached client, with the same parse and editor a prefix
# binding's prompt has (#789 follow up). And C-b at a prompt the server has open
# (a copy mode prompt) goes to that prompt instead of arming the prefix.
#
# The command line kept only -I and opened a prompt in the server that no
# client drew; the template, -p, -k, -1, -N, -T, -F and -b never arrived.
# Measured in tmux 3.4 from a plain shell against a session with one attached
# client (cmd-command-prompt.c is the same in 3.7c):
#   -b -p name 'rename-window %%', TEST Enter          window TEST
#   -b, typed rename-window BARE, Enter                window BARE
#   -I init -p name 'rename-window %%', Enter          window init
#   -p a,b 'rename-window %1-%2', x Enter y Enter      window x-y
#   -k Left / -1 z / -N then 1 2 a                     Left / Oz / N12
#   -F "set -g @k '#{session_name}-%%'", q Enter       <session>-q
#   -T search, HIST Enter, then -T search Up           HIST in the prompt
#   no -b: the command returns when the prompt is answered, rc 0, and rc 0
#     after Escape too
#   a second prompt while one is open                  the first is kept
#   -t <client>                                        that client
#   -t /nonexistent                                    rc 1
#   no client attached                                 "no current client", rc 1
# and at a copy mode prompt C-b is cursor left (status.c:1487), at a -k prompt
# the answer C-b; the prefix still works once the prompt is gone.
#
# GROUND TRUTH: window names and options read back with display-message and
# show-options, prompt labels read off the attached client's console with
# tests\conread.cs, keys sent with tests\injector.cs (WriteConsoleInput) into a
# client this suite starts and tracks by PID. Private PSMUX_DATA_DIR and a
# unique -L namespace; cleanup is `-L <ns> kill-server` plus the client PID.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0; $script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Set-Item "env:$v" $null -EA SilentlyContinue }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_clicp_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$DATA = Join-Path $TMP "data"
New-Item -ItemType Directory -Force $DATA | Out-Null
$env:PSMUX_DATA_DIR = $DATA
$NS   = "clicp-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "cp"

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
foreach ($tool in "conread", "injector") {
    $exe = Join-Path $TMP "$tool.exe"
    if ($csc -and (Test-Path $csc)) { & $csc /nologo /optimize /out:$exe (Join-Path $PSScriptRoot "$tool.cs") 2>&1 | Out-Null }
    if (-not (Test-Path $exe)) {
        Write-Fail "could not build tests\$tool.cs (csc.exe unavailable)"
        Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
        exit 1
    }
}
$RD  = Join-Path $TMP "conread.exe"
$INJ = Join-Path $TMP "injector.exe"

$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$CONF = Join-Path $TMP "cp.conf"
@(
    "set -g default-shell '$POWERSHELL -NoLogo -NoProfile'",
    "set -g mode-keys vi",
    "set -g status-keys emacs",
    "set -g automatic-rename off",
    "bind M command-prompt -p a,b `"rename-window %1-%2`"",
    "bind N command-prompt -N -p num `"set -g @k 'N%%'`"",
    "bind S command-prompt -T search -p s `"set -g @k '%%'`"",
    "bind B command-prompt -p br { rename-window `"%%`" }",
    "bind -T copy-mode-vi K command-prompt -k -p key `"set -g @k '%%'`"",
    "bind -T copy-mode-vi Z command-prompt -p z `"set -g @k '%%'`""
) | Set-Content -Path $CONF -Encoding ASCII

$client = Start-Process -FilePath $PSMUX -ArgumentList "-f",$CONF,"-L",$NS,"new-session","-s",$SESS,"-x","100","-y","30" -PassThru
$script:cpid = $client.Id
$up = $false
for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 250
    P has-session -t $SESS | Out-Null
    if ($LASTEXITCODE -eq 0) { $up = $true; break }
}
function Cleanup {
    Get-Job | Where-Object { $_.Name -like "clicp-*" } | Remove-Job -Force -EA SilentlyContinue
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    if (Get-Process -Id $script:cpid -EA SilentlyContinue) { Stop-Process -Id $script:cpid -Force -EA SilentlyContinue }
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}
if (-not $up) { Write-Fail "the attached client never came up"; Cleanup; exit 1 }
Start-Sleep -Seconds 3

function Inj($keys) { & $INJ $script:cpid $keys | Out-Null; Start-Sleep -Milliseconds 400 }
function Win { ((P display-message -t $SESS -p '#{window_name}') -join '').Trim() }
function Opt { ((P show -gv '@k') -join '').Trim() }
function In-Mode { ((P display-message -t $SESS -p '#{pane_in_mode}') -join '').Trim() }
function OnScreen($text) {
    $o = Join-Path $TMP "screen.txt"
    Start-Process -FilePath $RD -ArgumentList "$script:cpid" -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
    return [bool](@(Get-Content $o) | Where-Object { $_.Contains($text) })
}
# A command line `command-prompt`, run as a job so one that waits does not
# block the suite. Returns the job; Done collects "rc=N ms=M err=[...]".
$script:jobN = 0
function CmdPrompt([string[]]$a) {
    $script:jobN++
    $argv = @("-L", $NS, "command-prompt") + $a
    Start-Job -Name "clicp-$script:jobN" -ScriptBlock {
        param($b, $argv, $d)
        $env:PSMUX_DATA_DIR = $d
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & $b @argv 2>&1
        "rc=$LASTEXITCODE ms=$($sw.ElapsedMilliseconds) err=[$(($out | ForEach-Object { "$_" }) -join ' ')]"
    } -ArgumentList $PSMUX, $argv, $DATA
}
function Done($job, $sec = 5) {
    if (Wait-Job $job -Timeout $sec) { $r = Receive-Job $job; Remove-Job $job -Force; return [string]$r }
    Stop-Job $job; Remove-Job $job -Force; return "STILL RUNNING"
}

# -- 1. the prompt opens on the client and runs --

Write-Head "1. psmux command-prompt opens on the attached client"
P rename-window -t $SESS START | Out-Null
$j = CmdPrompt @("-b", "-p", "name", "rename-window %%"); Start-Sleep -Milliseconds 800
Check (OnScreen "name") "-p name is drawn on the client" "the prompt labelled name is not on the client"
Inj "TEST{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win; $r = Done $j
Check ($w -ceq "TEST") "TEST Enter renamed the window: [$w]" "window [$w], wanted TEST"
Check ($r -like "rc=0*") "-b returned rc 0: $r" "-b: $r"

$j = CmdPrompt @("-b", "rename-window %%"); Start-Sleep -Milliseconds 800
Check (OnScreen "(rename-window)") "no -p: labelled (rename-window)" "no -p: (rename-window) not drawn"
Inj "{ESC}"; $null = Done $j

$j = CmdPrompt @("-b"); Start-Sleep -Milliseconds 800
Inj "rename-window BARE{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win; $null = Done $j
Check ($w -ceq "BARE") "bare: the typed line runs: [$w]" "bare: window [$w], wanted BARE"

$j = CmdPrompt @("-b", "-I", "init", "-p", "name", "rename-window %%"); Start-Sleep -Milliseconds 800
Inj "{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win; $null = Done $j
Check ($w -ceq "init") "-I init, Enter: [$w]" "-I: window [$w], wanted init"

$j = CmdPrompt @("-b", "-p", "a,b", "rename-window %1-%2"); Start-Sleep -Milliseconds 800
Inj "x{ENTER}"; Inj "y{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win; $null = Done $j
Check ($w -ceq "x-y") "-p a,b, x Enter y Enter: [$w]" "-p a,b: window [$w], wanted x-y"

# -- 2. -k, -1, -N, -F, -T --

Write-Head "2. -k, -1, -N, -F and -T search"
P set -g '@k' UNSET | Out-Null
$j = CmdPrompt @("-b", "-k", "-p", "key", "set -g @k '%%'"); Start-Sleep -Milliseconds 800
Inj "{LEFT}"; Start-Sleep -Milliseconds 300
$v = Opt; $null = Done $j
Check ($v -ceq "Left") "-k Left: [$v]" "-k Left: [$v], wanted Left"
if ($v -ne "Left") { Inj "{ESC}" }

P set -g '@k' UNSET | Out-Null
$j = CmdPrompt @("-b", "-1", "-p", "one", "set -g @k 'O%%'"); Start-Sleep -Milliseconds 800
Inj "z"; Start-Sleep -Milliseconds 300
$v = Opt; $null = Done $j
Check ($v -ceq "Oz") "-1 z: [$v]" "-1 z: [$v], wanted Oz"
if ($v -ne "Oz") { Inj "{ESC}" }

P set -g '@k' UNSET | Out-Null
$j = CmdPrompt @("-b", "-N", "-p", "num", "set -g @k 'N%%'"); Start-Sleep -Milliseconds 800
Inj "12a"; Start-Sleep -Milliseconds 300
$v = Opt; $null = Done $j
Check ($v -ceq "N12") "-N 1 2 a: [$v]" "-N: [$v], wanted N12"
if ($v -ne "N12") { Inj "{ESC}" }
Inj "{MOD:08:0008:0000}"   # the a went to the shell, as in tmux

P set -g '@k' UNSET | Out-Null
$j = CmdPrompt @("-b", "-F", "-p", "fmt", "set -g @k '#{session_name}-%%'"); Start-Sleep -Milliseconds 800
Inj "q{ENTER}"; Start-Sleep -Milliseconds 300
$v = Opt; $null = Done $j
Check ($v -ceq "$SESS-q") "-F: [$v]" "-F: [$v], wanted $SESS-q"

$j = CmdPrompt @("-b", "-T", "search", "-p", "s1", "set -g @k '%%'"); Start-Sleep -Milliseconds 800
Inj "HIST{ENTER}"; Start-Sleep -Milliseconds 300; $null = Done $j
$j = CmdPrompt @("-b", "-T", "search", "-p", "s2", "set -g @k '%%'"); Start-Sleep -Milliseconds 800
Inj "{UP}"; Start-Sleep -Milliseconds 300
Check (OnScreen ": HIST") "-T search recalls HIST" "-T search: HIST not recalled"
Inj "{ESC}"; $null = Done $j
$r = Done (CmdPrompt @("-b", "-T", "nope", "x %%"))
Check ($r -like "rc=1*unknown type: nope*") "-T nope is refused: $r" "-T nope: $r"

# -- 3. waiting, a second prompt, -t, no client --

Write-Head "3. waiting without -b, a second prompt, -t"
P rename-window -t $SESS START | Out-Null
$j = CmdPrompt @("-p", "w", "rename-window %%"); Start-Sleep -Milliseconds 1500
Check ($j.State -eq "Running") "no -b: still waiting before the answer" "no -b: [$($j.State)] before the answer"
Inj "WAITED{ENTER}"; Start-Sleep -Milliseconds 500
$r = Done $j; $w = Win
Check (($r -like "rc=0*") -and $w -ceq "WAITED") "no -b: returned rc 0 after the command ran: $r, [$w]" "no -b: $r, window [$w]"
$j = CmdPrompt @("-p", "w", "rename-window %%"); Start-Sleep -Milliseconds 1200
Inj "{ESC}"; Start-Sleep -Milliseconds 500
$r = Done $j
Check ($r -like "rc=0*") "no -b, Escape: rc 0: $r" "no -b, Escape: $r"

P rename-window -t $SESS START | Out-Null
$j1 = CmdPrompt @("-b", "-p", "first", "rename-window F%%"); Start-Sleep -Milliseconds 700
$j2 = CmdPrompt @("-b", "-p", "second", "rename-window S%%"); Start-Sleep -Milliseconds 700
Inj "x{ENTER}"; Start-Sleep -Milliseconds 400
$w = Win; $null = Done $j1; $null = Done $j2
Check ($w -ceq "Fx") "a second prompt is dropped while the first is open: [$w]" "second prompt: window [$w], wanted Fx"

$cl = ((P list-clients -F '#{client_name}') | Select-Object -First 1)
P rename-window -t $SESS START | Out-Null
$j = CmdPrompt @("-b", "-t", "$cl", "-p", "tc", "rename-window %%"); Start-Sleep -Milliseconds 800
Inj "TC{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win; $null = Done $j
Check ($w -ceq "TC") "-t ${cl}: [$w]" "-t ${cl}: window [$w]"
$r = Done (CmdPrompt @("-b", "-t", "/nonexistent", "-p", "x", "rename-window %%"))
Check ($r -like "rc=1*can't find client*") "-t /nonexistent: $r" "-t /nonexistent: $r"

# -- 4. a hook --

Write-Head "4. a command-prompt a hook runs opens on the client"
P set-hook -g after-new-window "command-prompt -p hk 'rename-window %%'" | Out-Null
P new-window -t $SESS | Out-Null; Start-Sleep -Milliseconds 1200
Inj "HK{ENTER}"; Start-Sleep -Milliseconds 500
$w = Win
Check ($w -ceq "HK") "after-new-window prompt renamed the new window: [$w]" "hook prompt: window [$w], wanted HK"
P set-hook -gu after-new-window | Out-Null

# -- 5. prefix bindings get the same --

Write-Head "5. a prefix binding's prompt: -p a,b, -N, -T search"
P rename-window -t $SESS START | Out-Null
Inj "^b"; Inj "M"; Inj "p{ENTER}"; Inj "q{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win
Check ($w -ceq "p-q") "prefix M (-p a,b): [$w]" "prefix M: window [$w], wanted p-q"
P set -g '@k' UNSET | Out-Null
Inj "^b"; Inj "N"; Inj "7{ENTER}"; Start-Sleep -Milliseconds 300
$v = Opt
Check ($v -ceq "N7") "prefix N (-N), 7 Enter: [$v]" "prefix N: [$v], wanted N7"
Inj "^b"; Inj "S"; Inj "{UP}"; Start-Sleep -Milliseconds 300
Check (OnScreen ": HIST") "prefix S (-T search) recalls the search history" "prefix S: HIST not recalled"
Inj "{ESC}"
P rename-window -t $SESS START | Out-Null
Inj "^b"; Inj "B"; Inj "a b{ENTER}"; Start-Sleep -Milliseconds 300
$w = Win
Check ($w -ceq "a b") "prefix B ({ rename-window `"%%`" } block), a b: [$w]" "prefix B block: window [$w], wanted a b"

# -- 6. C-b at a prompt the server has open --

Write-Head "6. C-b at a copy mode prompt goes to the prompt"
P set -g '@k' UNSET | Out-Null
P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 500
Inj "K"; Start-Sleep -Milliseconds 1200
Inj "^b"; Start-Sleep -Milliseconds 400
$v = Opt
Check ($v -ceq "C-b") "-k prompt, C-b: [$v]" "-k prompt, C-b: [$v], wanted C-b"
if ($v -ne "C-b") { Inj "{ESC}" }
if ((In-Mode) -ne "1") { P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 500 }
P set -g '@k' UNSET | Out-Null
Inj "Z"; Inj "abc"; Inj "^b"; Inj "X{ENTER}"; Start-Sleep -Milliseconds 400
$v = Opt
Check ($v -ceq "abXc") "text prompt, abc C-b X: [$v]" "text prompt: [$v], wanted abXc"
Inj "q"; Start-Sleep -Milliseconds 300
if ((In-Mode) -eq "1") { P send-keys -t $SESS -X cancel | Out-Null }
$before = ((P display-message -t $SESS -p '#{session_windows}') -join '').Trim()
Inj "^b"; Inj "c"; Start-Sleep -Milliseconds 1500
$after = ((P display-message -t $SESS -p '#{session_windows}') -join '').Trim()
Check ([int]$after -eq [int]$before + 1) "the prefix still works outside a prompt ($before -> $after windows)" "prefix c: $before -> $after windows"

# -- 7. no client --

Write-Head "7. no attached client"
Stop-Process -Id $script:cpid -Force -EA SilentlyContinue; Start-Sleep -Milliseconds 1500
$r = Done (CmdPrompt @("-b", "-p", "x", "rename-window %%"))
Check ($r -like "rc=1*no current client*") "no client: $r" "no client: $r"

Cleanup
Write-Host ""
Write-Host "passed: $script:TestsPassed  failed: $script:TestsFailed" -ForegroundColor Cyan
if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
