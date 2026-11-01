# Issue #955: a key bound to one quoted argument (`bind r 'set -g @r 1'`,
# `bind x 'a ; b'`) runs that argument as a command string, as tmux's
# bind-key does with the key and exactly one more argument (cmd-bind-key.c:91-92
# at tag 3.8, cmd_parse_from_string). psmux kept the quoted text as one
# command named by all of it, so the key ran nothing.
#
# Every expectation is what tmux 3.8 (WSL, the same lines in its config, a
# client attached under `script`, keys sent with `send-keys -K`) did.
#
# [1] binds each form from the config file, two from the CLI and one typed at
# prefix + : of a real client, and reads list-keys. [2] presses every key on
# that client (tests\injector.cs, WriteConsoleInput) and reads the options and
# the window name back.
#
# Private USERPROFILE, PSMUX_DATA_DIR and config, a -L namespace; cleanup is
# `-L <ns> kill-server` plus the client PID. PSMUX_EXE picks the binary
# (defaults to target\release\psmux.exe).

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'PSMUX_*' -and $_.Name -ne 'PSMUX_EXE' -or $_.Name -like 'TMUX*' } | ForEach-Object Name)) {
    Remove-Item "Env:$name"
}
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Pass "$name = '$got'" } else { Write-Fail "$name expected '$want', got '$got'" }
}

$TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_bqc_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_CONFIG_FILE = Join-Path $TempHome "psmux.conf"
Set-Content -Path $env:PSMUX_CONFIG_FILE -Value @(
    "bind -n F5 'set -g @a 1 ; set -g @b 1'"
    "bind -n F6 'set -g @c 1'"
    "bind r 'set -g @r 1'"
    "bind -n F7 `"set -g @d 1 ; set -g @e 1`""
    "bind -n F11 'rename-window `"x y`"'"
    "bind -n F12 'set -g @k `"v w`"'"
    "bind -n F8 { set -g @f 1 ; set -g @g 1 }"
    "bind -n F3 set -g @z 1"
    "bind t set -g @t 1"
)
$NS = "bqc_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
function P { & $PSMUX -L $NS @args 2>&1 }
function V($name) { ((P show -gqv $name) -join '').Trim() }

Write-Host "`n=== a key bound to a quoted command runs it ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"
Write-Host "  $((& $PSMUX -V) -join ' ')"

$toolDir = Join-Path $TempHome "tools"
New-Item -ItemType Directory -Force $toolDir | Out-Null
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$INJ = Join-Path $toolDir "injector.exe"
& $csc /nologo /optimize "/out:$INJ" (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null

$client = $null
try {
    if (-not (Test-Path $INJ)) { Write-Fail "injector did not compile"; throw "no injector" }
    P new-session -d -s s -x 100 -y 25 | Out-Null
    Start-Sleep -Milliseconds 1500
    P bind -n F9 'set -g @h 1 ; set -g @i 1' | Out-Null
    P bind -n F10 'set -g @j 1' | Out-Null
    $client = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach", "-t", "s" -PassThru
    Start-Sleep -Seconds 4
    & $INJ $client.Id "^b{SLEEP:500}:{SLEEP:600}bind -n F4 'set -g @p 1 ; set -g @q 1'{ENTER}{SLEEP:800}" | Out-Null

    Write-Host "`n[1] list-keys shows the commands, not the quoted text" -ForegroundColor Yellow
    foreach ($case in @(
        @('root', 'F5', 'set -g @a 1 \; set -g @b 1'),
        @('root', 'F6', 'set -g @c 1'),
        @('prefix', 'r', 'set -g @r 1'),
        @('root', 'F7', 'set -g @d 1 \; set -g @e 1'),
        @('root', 'F11', 'rename-window "x y"'),
        @('root', 'F12', 'set -g @k "v w"'),
        @('root', 'F4', 'set -g @p 1 \; set -g @q 1'),
        @('root', 'F8', 'set -g @f 1 \; set -g @g 1'),
        @('root', 'F9', 'set -g @h 1 \; set -g @i 1')
    )) {
        $line = ((P list-keys -T $case[0] $case[1]) -join ' ').Trim()
        $want = "bind-key -T $($case[0]) $($case[1]) $($case[2])"
        Check "list-keys -T $($case[0]) $($case[1])" $line $want
    }

    Write-Host "`n[2] Each key pressed on the attached client" -ForegroundColor Yellow
    & $INJ $client.Id "{F3}{SLEEP:400}^b{SLEEP:400}r{SLEEP:400}^b{SLEEP:400}t{SLEEP:400}{F4}{SLEEP:400}{F5}{SLEEP:400}{F6}{SLEEP:400}{F7}{SLEEP:400}{F8}{SLEEP:400}{F9}{SLEEP:400}{F10}{SLEEP:400}{F11}{SLEEP:400}{F12}{SLEEP:800}" | Out-Null
    Start-Sleep -Milliseconds 800
    Check "config 'set -g @a 1 ; set -g @b 1' (F5)" "$(V '@a') $(V '@b')" "1 1"
    Check "config 'set -g @c 1' (F6)" (V '@c') "1"
    Check "config bind r 'set -g @r 1' (prefix + r)" (V '@r') "1"
    Check "config `"set -g @d 1 ; set -g @e 1`" (F7)" "$(V '@d') $(V '@e')" "1 1"
    Check "config 'rename-window `"x y`"' (F11)" ((P display -p '#{window_name}') -join '') "x y"
    Check "config 'set -g @k `"v w`"' (F12)" (V '@k') "v w"
    Check "prefix + : bind -n F4 'set -g @p 1 ; set -g @q 1' (F4)" "$(V '@p') $(V '@q')" "1 1"
    Check "config { set -g @f 1 ; set -g @g 1 } (F8, as before)" "$(V '@f') $(V '@g')" "1 1"
    Check "config unquoted (F3, prefix + t, as before)" "$(V '@z') $(V '@t')" "1 1"
    Check "CLI bind -n F9 'set -g @h 1 ; set -g @i 1' (F9, as before)" "$(V '@h') $(V '@i')" "1 1"
    Check "CLI bind -n F10 'set -g @j 1' (F10, as before)" (V '@j') "1"
}
catch {
    if ("$_" -ne 'no injector') { Write-Fail "exception: $_" }
}
finally {
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue }
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
