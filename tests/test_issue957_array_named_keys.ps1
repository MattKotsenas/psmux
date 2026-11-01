# Issue #957: an array element keyed by a name, as tmux 3.8 keys it
# (20ef19b4; options.c:41-98 and :759-784 at tag 3.8). A key of digits only
# is a number, any other key is a name; the numbered elements are listed
# first, then the named ones by strcmp; a value without a key takes the
# lowest free number. psmux refused every key that was no number, as tmux
# 3.7c does.
#
# Every expectation is what tmux 3.8 (`-f /dev/null`, WSL) printed for the
# same commands, on command-alias, terminal-overrides, codepoint-widths and
# status-format. The config file sets one named alias, so the config route is
# covered too.
#
# Private USERPROFILE, PSMUX_DATA_DIR and config, a -L namespace; cleanup is
# `-L <ns> kill-server`. PSMUX_EXE picks the binary (defaults to
# target\release\psmux.exe).

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

$TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_ank_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_CONFIG_FILE = Join-Path $TempHome "psmux.conf"
Set-Content -Path $env:PSMUX_CONFIG_FILE -Value "set -s command-alias[cfg] 'cf=display -p FROMCONFIG'"
$NS = "ank_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
function P { & $PSMUX -L $NS @args 2>&1 | ForEach-Object { "$_" } }
# Every output line, joined; the exit code goes in $script:rc.
function Out { $o = (P @args) -join ' | '; $script:rc = $LASTEXITCODE; $o }
$defaults = 'command-alias[0] split-pane=split-window | command-alias[1] splitp=split-window | command-alias[2] "server-info=show-messages -JT" | command-alias[3] "info=show-messages -JT" | command-alias[4] "choose-window=choose-tree -w" | command-alias[5] "choose-session=choose-tree -s"'

Write-Host "`n=== array elements keyed by a name ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"
Write-Host "  $((& $PSMUX -V) -join ' ')"

try {
    P new-session -d -s s -x 100 -y 20 | Out-Null
    Start-Sleep -Milliseconds 1500

    Write-Host "`n[1] command-alias[NAME] is an alias" -ForegroundColor Yellow
    Check "alias from the config file, cf" (Out cf) "FROMCONFIG"
    P set -su 'command-alias[cfg]' | Out-Null
    $o = Out set -s 'command-alias[foo]' 'zz=display -p ZZALIAS'
    Check "set -s command-alias[foo] (exit, output)" "$script:rc $o".Trim() "0"
    Check "zz" (Out zz) "ZZALIAS"
    P set -s 'command-alias[10]' 'ten=display -p TEN' | Out-Null
    P set -s 'command-alias[Bar]' 'bb=display -p BB' | Out-Null
    P set -s 'command-alias[a b]' 'ab=display -p AB' | Out-Null
    Check "show -s command-alias: numbers first, then names by strcmp" (Out show -s command-alias) "$defaults | command-alias[10] `"ten=display -p TEN`" | command-alias[Bar] `"bb=display -p BB`" | command-alias[a b] `"ab=display -p AB`" | command-alias[foo] `"zz=display -p ZZALIAS`""
    # One element of command-alias is shown by its own code, unquoted and
    # with no '' for a missing one, numbered or named alike; that is not
    # part of this change, so one element's line is checked on
    # terminal-overrides in [3].
    Check "show -sv command-alias[foo]" (Out show -sv 'command-alias[foo]') 'zz=display -p ZZALIAS'
    Check "#{command-alias[foo]}" (Out display -p '#{command-alias[foo]}') 'zz=display -p ZZALIAS'

    Write-Host "`n[2] -a, -u and a value without a key" -ForegroundColor Yellow
    P set -sa 'command-alias[foo]' 'X' | Out-Null
    Check "-a on command-alias[foo] appends" (Out show -sv 'command-alias[foo]') 'zz=display -p ZZALIASX'
    P set -sa command-alias 'na=display -p NA' | Out-Null
    Check "-a without a key takes the lowest free number, [6]" (Out show -sv 'command-alias[6]') 'na=display -p NA'
    $o = Out set -su 'command-alias[foo]'
    Check "set -su command-alias[foo] (exit)" $script:rc "0"
    Check "zz after -u" ((Out zz) -match 'unknown command') "True"
    $o = Out set -su 'command-alias[nosuch]'
    Check "set -su of a name that is not there (exit)" $script:rc "0"

    Write-Host "`n[3] Which keys are numbers, names, or no key" -ForegroundColor Yellow
    foreach ($case in @(
        @('terminal-overrides[01]', 'one', 0),
        @('terminal-overrides[007]', 'seven', 0),
        @('terminal-overrides[-1]', 'minus', 0),
        @('terminal-overrides[b[c]', 'brk', 0),
        @('terminal-overrides[#]', 'hash', 0),
        @('terminal-overrides[4294967295]', 'max', 0),
        @('terminal-overrides[]', 'empty', 1),
        @('terminal-overrides[x]y', 'tail', 1),
        @('terminal-overrides[a]]', 'dbl', 1),
        @('terminal-overrides[4294967296]', 'over', 1)
    )) {
        $o = Out set -s $case[0] $case[1]
        $failed = [int]($script:rc -ne 0)
        Check "set -s $($case[0]) is refused (1) or taken (0)" $failed $case[2]
    }
    Check "show -s terminal-overrides" (Out show -s terminal-overrides) 'terminal-overrides[0] linux*:AX@ | terminal-overrides[1] one | terminal-overrides[7] seven | terminal-overrides[4294967295] max | terminal-overrides[#] hash | terminal-overrides[-1] minus | terminal-overrides[b[c] brk'
    Check "show -s terminal-overrides[b[c]" (Out show -s 'terminal-overrides[b[c]') 'terminal-overrides[b[c] brk'
    P set -s 'terminal-overrides[mine]' 'xterm*:Tc:RGB' | Out-Null
    Check "show -s terminal-overrides[mine]" (Out show -s 'terminal-overrides[mine]') 'terminal-overrides[mine] xterm*:Tc:RGB'
    Check "show -s terminal-overrides[nosuch]" (Out show -s 'terminal-overrides[nosuch]') "terminal-overrides[nosuch] ''"
    Check "#{terminal-overrides[mine]}" (Out display -p '#{terminal-overrides[mine]}') 'xterm*:Tc:RGB'
    P set -su 'terminal-overrides[mine]' | Out-Null
    P set -s terminal-overrides 'p,q' | Out-Null
    Check "a value without a key replaces named elements too" (Out show -s terminal-overrides) 'terminal-overrides[0] p | terminal-overrides[1] q'

    Write-Host "`n[4] The other arrays" -ForegroundColor Yellow
    P set -s 'codepoint-widths[x]' 'U+2603=2' | Out-Null
    Check "show -s codepoint-widths" (Out show -s codepoint-widths) 'codepoint-widths[x] U+2603=2'
    P set -g 'status-format[x]' 'NAMED' | Out-Null
    # tmux lists its three default formats before it; psmux's default is
    # empty (#947).
    Check "show -g status-format" (Out show -g status-format) 'status-format[x] NAMED'
}
finally {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
