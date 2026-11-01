# Issue #947: status-format as tmux's array option. Each line keeps its own
# index, so `set -g status-format[N]` and `set -gu status-format[N]` work on
# one line and `show` prints the indexes as they are; `-a` takes the lowest
# free index; a value without an index is split on space and `,`; `show -v`
# prints a value a line and `#{status-format}` joins with a space. Only the
# lines below the number of status lines are expanded and sent to the client,
# as tmux's status.c draws them, so a huge index costs nothing.
#
# Every expected show line in part 1 is what tmux 3.8 (`-f /dev/null`, WSL)
# printed for the same commands after `set -g status-format ''`; psmux's
# default is empty, where tmux's is three formats (see src/option_array.rs).
#
# Part 3 reads the status lines off a real attached client with
# tests\conread.cs, since capture-pane cannot see the status bar.
#
# Isolated: USERPROFILE, PSMUX_DATA_DIR and the config point into a fresh temp
# dir, every command uses -L, and only the client this script starts is
# closed, by its PID. PSMUX_EXE picks the binary (defaults to psmux on PATH).

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_sfa_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$env:USERPROFILE = $TMP
$env:PSMUX_DATA_DIR = $TMP
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$CONF = Join-Path $TMP "sf.conf"
"set -g default-shell '$POWERSHELL -NoLogo -NoProfile'" | Set-Content -Path $CONF -Encoding ASCII
$env:PSMUX_CONFIG_FILE = $CONF
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'PSMUX_TARGET*' -or $_.Name -like 'TMUX*' -or $_.Name -in 'PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE' } | ForEach-Object Name)) {
    Remove-Item "Env:$name"
}
$NS = "sfa_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:cpid = $null
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function P { & $PSMUX -L $NS @args 2>&1 }
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Pass "$name = '$got'" } else { Write-Fail "$name expected '$want', got '$got'" }
}
function Show { (P show -g status-format) -join ' | ' }
function Frame {
    $j = (P dump-state) -join "`n"
    if ($j -match '"status_format":(\[[^\]]*\])') { return $Matches[1] }
    return "<none>"
}
function Cleanup {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 800
    if ($script:cpid -and (Get-Process -Id $script:cpid -EA SilentlyContinue)) {
        Stop-Process -Id $script:cpid -Force -EA SilentlyContinue
    }
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# -- 1. set, append, unset and show, against tmux 3.8 --
Write-Host "`n--- 1. the array, step by step ---" -ForegroundColor Yellow
P new-session -d -s s -x 80 -y 10 | Out-Null
for ($i = 0; $i -lt 40; $i++) { P has-session -t s | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 250 }

Check "show on a new server" (Show) "status-format"
P set -g 'status-format[1]' X | Out-Null
Check "show after [1] X" (Show) "status-format[1] X"
Check "show -gv status-format[1]" ((P show -gv 'status-format[1]') -join ' | ') "X"
Check "#{status-format}" ((P display -p '#{status-format}') -join '') "X"
Check "#{status-format[1]}" ((P display -p '#{status-format[1]}') -join '') "X"
P set -g status-format 'a b,c' | Out-Null
Check "show after 'a b,c'" (Show) "status-format[0] a | status-format[1] b | status-format[2] c"
Check "show -gv" ((P show -gv status-format) -join ' | ') "a | b | c"
Check "#{status-format} joins with a space" ((P display -p '#{status-format}') -join '') "a b c"
P set -ga status-format d | Out-Null
Check "show after -ga d" (Show) "status-format[0] a | status-format[1] b | status-format[2] c | status-format[3] d"
P set -ga 'status-format[0]' e | Out-Null
Check "show after -ga [0] e" (Show) "status-format[0] ae | status-format[1] b | status-format[2] c | status-format[3] d"
P set -gu 'status-format[1]' | Out-Null
Check "show after -gu [1]" (Show) "status-format[0] ae | status-format[2] c | status-format[3] d"
P set -ga status-format f | Out-Null
Check "-ga f takes the lowest free index" (Show) "status-format[0] ae | status-format[1] f | status-format[2] c | status-format[3] d"
Check "show status-format[9]" ((P show -g 'status-format[9]') -join ' | ') "status-format[9] ''"
P set -g status-format ' a , b ' | Out-Null
Check "show after ' a , b '" (Show) "status-format[0] a | status-format[1] b"
P set -g 'status-format[2]' ' spaced value ' | Out-Null
Check "show status-format[2] keeps its spaces" ((P show -g 'status-format[2]') -join ' | ') 'status-format[2] " spaced value "'
P set -gu status-format | Out-Null
Check "show after -gu" (Show) "status-format"
# An empty key is refused; a name is a key, as in tmux 3.8 (#957).
$out = P set -g 'status-format[]' Y
if ($LASTEXITCODE -ne 0 -and "$out" -match 'invalid option') { Write-Pass "status-format[] is refused: $out" } else { Write-Fail "status-format[] rc=$LASTEXITCODE '$out'" }

# -- 2. what each frame carries --
Write-Host "`n--- 2. only the shown lines are expanded and sent ---" -ForegroundColor Yellow
Check "frame with nothing set" (Frame) "[]"
P set -g 'status-format[1]' 'L1 #{session_name}' | Out-Null
P set -g 'status-format[7]' 'never' | Out-Null
Check "frame on one status line: [1] is not shown" (Frame) "[]"
P set -g status 2 | Out-Null
Check "frame on two lines: [0] missing, [1] expanded, [7] left out" (Frame) '["","L1 s"]'
$serverPid = [int](((P display -p '#{pid}') -join '').Trim())
$before = (Get-Process -Id $serverPid).WorkingSet64
P set -g 'status-format[4000000000]' Z | Out-Null
Start-Sleep -Milliseconds 1500
$after = (Get-Process -Id $serverPid).WorkingSet64
$growMB = [math]::Round(($after - $before) / 1MB, 1)
if ($growMB -lt 5) { Write-Pass "status-format[4000000000] grew the server by $growMB MB" } else { Write-Fail "status-format[4000000000] grew the server by $growMB MB" }
Check "show [4000000000]" ((P show -g 'status-format[4000000000]') -join '') "status-format[4000000000] Z"
Check "frame still two lines" (Frame) '["","L1 s"]'
P kill-server | Out-Null
Start-Sleep -Milliseconds 800

# -- 3. the lines on a real attached client --
Write-Host "`n--- 3. drawn on an attached client ---" -ForegroundColor Yellow
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
$RD = Join-Path $TMP "conread.exe"
if ($csc -and (Test-Path $csc)) { & $csc /nologo /optimize /out:$RD (Join-Path $PSScriptRoot "conread.cs") 2>&1 | Out-Null }
if (-not (Test-Path $RD)) {
    Write-Fail "could not build tests\conread.cs"
} else {
    $env:PSMUX_RUN_NOPAUSE = "1"
    $client = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "new-session", "-s", "v", "-x", "100", "-y", "20" -PassThru
    $script:cpid = $client.Id
    $up = $false
    for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 250; P has-session -t v | Out-Null; if ($LASTEXITCODE -eq 0) { $up = $true; break } }
    Start-Sleep -Seconds 2
    function Screen {
        $o = Join-Path $TMP "screen.txt"
        Start-Process -FilePath $RD -ArgumentList "$script:cpid" -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
        return @(Get-Content $o)
    }
    function Has($text) { return [bool](@(Screen) | Where-Object { $_.Contains($text) }) }
    function WaitFor($text, [bool]$present) {
        for ($i = 0; $i -lt 12; $i++) { if ((Has $text) -eq $present) { return $true }; Start-Sleep -Milliseconds 250 }
        return $false
    }
    if (-not $up) {
        Write-Fail "the attached client never came up"
    } else {
        P set -g status 3 | Out-Null
        P set -g 'status-format[1]' 'SFONE_#{session_name}' | Out-Null
        P set -g 'status-format[2]' 'SFTWO' | Out-Null
        if (WaitFor "SFONE_v" $true) { Write-Pass "status-format[1] is drawn, expanded" } else { Write-Fail "status-format[1] is not on the client" }
        if (WaitFor "SFTWO" $true) { Write-Pass "status-format[2] is drawn" } else { Write-Fail "status-format[2] is not on the client" }
        P set -gu 'status-format[1]' | Out-Null
        if (WaitFor "SFONE_v" $false) { Write-Pass "-gu status-format[1] removes that line" } else { Write-Fail "-gu status-format[1] left the line drawn" }
        if (Has "SFTWO") { Write-Pass "status-format[2] keeps its line" } else { Write-Fail "status-format[2] went away with [1]" }
        P set -ga status-format 'SFAPP' | Out-Null
        if (WaitFor "SFAPP" $true) { Write-Pass "-ga lands at the lowest free index, [0], and is drawn on line 0" } else { Write-Fail "-ga status-format SFAPP is not on the client" }
        P set -g status-format 'SFX,SFY' | Out-Null
        if ((WaitFor "SFY" $true) -and -not (Has "SFTWO")) { Write-Pass "a value without an index replaces every line" } else { Write-Fail "set status-format 'SFX,SFY' did not replace the lines" }
        P set -gu status-format | Out-Null
        if (WaitFor "SFY" $false) { Write-Pass "-gu status-format empties it" } else { Write-Fail "-gu status-format left SFY drawn" }
    }
}

Cleanup
Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
