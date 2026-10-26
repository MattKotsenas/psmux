# Issue #742: on the console input route every character outside the Basic
# Multilingual Plane is dropped on the way in, in a pane and in psmux's own
# command prompt.
#
# The console hands a non BMP character over as one key down AND one key up
# record per UTF-16 code unit, all with vk=0. For U+1F60A:
#     down D83D, up D83D, down DE0A, up DE0A
# crossterm 0.29's Windows parser pairs consecutive surrogates without looking
# at bKeyDown, so it pairs (high, high) and (low, low), both fail to decode and
# all four halves vanish.
#
# This suite writes exactly those records into a real attached client's console
# with WriteConsoleInputW (injector {UTF16:...}, one call, the shape a paste or
# an IME commit produces), then measures what arrived:
#   1. in a pane: Read-Host reports the UTF-16 length it received
#   2. the same with the two halves in separate writes ({U:...})
#   3. two emoji back to back, and U+20B9F (a JIS 2004 kanji)
#   4. a BMP kanji still arrives as 1 unit (control)
#   5. psmux's command prompt: rename-window A<emoji>B
#
# Before the fix: the BMP control passes and every non BMP case fails.
# After the fix: all pass.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "i742_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "nb"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function P { & $PSMUX -L $NS @args 2>&1 }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ("version: " + (& $PSMUX -V)) -ForegroundColor Cyan

# Compile the injector.
$injectorExe = Join-Path $env:TEMP "psmux_injector_742.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
& $csc /nologo /optimize /out:$injectorExe (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { Write-Host "FATAL: injector did not compile" -ForegroundColor Red; exit 1 }
$injLog = Join-Path $env:TEMP "psmux_inject.log"

function Inject($keys) {
    & $injectorExe $script:client.Id $keys
    $l = Get-Content $injLog -Raw -EA SilentlyContinue
    if ($l -match 'FAILED') { Write-Info "injector: $l" }
}

$env:PSMUX_NO_WARM = "1"
P new-session -d -s $SESS -x 100 -y 30 | Out-Null
$up = $false
for ($i = 0; $i -lt 80; $i++) {
    if ((P list-sessions | Out-String) -match $SESS) { $up = $true; break }
    Start-Sleep -Milliseconds 250
}
if (-not $up) { Write-Host "FATAL: no session" -ForegroundColor Red; exit 1 }

$script:client = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach", "-t", $SESS -PassThru
Write-Info "attached client pid $($script:client.Id)"
Start-Sleep -Seconds 3
if ($script:client.HasExited) { Write-Host "FATAL: client exited" -ForegroundColor Red; P kill-server | Out-Null; exit 1 }

function Wait-Prompt($tag) {
    for ($i = 0; $i -lt 40; $i++) {
        $cap = (P capture-pane -t $SESS -p | Out-String)
        if ($cap -match "$tag here") { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Runs Read-Host in the pane, injects $keys into the client's console, presses
# Enter, and returns the UTF-16 length and code units the shell received.
function Measure-PaneInput($tag, $keys) {
    P send-keys -t $SESS -l ('$s = Read-Host "' + $tag + ' here"; "' + $tag + ' got $($s.Length) units [" + (($s.ToCharArray() | % { ''{0:X4}'' -f [int]$_ }) -join '','') + "]"') | Out-Null
    P send-keys -t $SESS Enter | Out-Null
    if (-not (Wait-Prompt $tag)) { return $null }
    Start-Sleep -Milliseconds 300
    Inject $keys
    Start-Sleep -Milliseconds 400
    Inject '{ENTER}'
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $cap = (P capture-pane -t $SESS -p | Out-String)
        $m = [regex]::Match($cap, "$tag got (\d+) units \[([0-9A-F,]*)\]")
        if ($m.Success) { return [pscustomobject]@{ Units = [int]$m.Groups[1].Value; Hex = $m.Groups[2].Value; Line = $m.Value } }
    }
    return $null
}

function Check($name, $tag, $keys, $wantUnits, $wantHex) {
    $r = Measure-PaneInput $tag $keys
    if ($null -eq $r) { Write-Fail "$name : no result line in the pane"; return }
    Write-Info "$name : $($r.Line)"
    if ($r.Units -eq $wantUnits -and $r.Hex -eq $wantHex) {
        Write-Pass "$name : $wantUnits units [$wantHex]"
    } else {
        Write-Fail "$name : got $($r.Units) units [$($r.Hex)], wanted $wantUnits units [$wantHex]"
    }
}

try {
    # wait for the pane shell to be ready
    for ($i = 0; $i -lt 40; $i++) {
        if ((P capture-pane -t $SESS -p | Out-String) -match 'PS ') { break }
        Start-Sleep -Milliseconds 250
    }
    P send-keys -t $SESS -l 'clear' | Out-Null
    P send-keys -t $SESS Enter | Out-Null
    Start-Sleep -Milliseconds 500

    Write-Host "`n=== pane input ===" -ForegroundColor Cyan
    Check "BMP kanji U+5F45 (control)" "ka" '{UTF16:5F45}' 1 '5F45'
    Check "emoji U+1F60A, one write" "em" '{UTF16:D83D,DE0A}' 2 'D83D,DE0A'
    Check "emoji U+1F60A, halves in two writes" "sp" '{U:D83D,DE0A}' 2 'D83D,DE0A'
    Check "two emoji back to back" "tw" '{UTF16:D83D,DE0A,D83D,DE00}' 4 'D83D,DE0A,D83D,DE00'
    Check "JIS 2004 kanji U+20B9F between ASCII" "jk" 'a{UTF16:D842,DF9F}b' 4 '0061,D842,DF9F,0062'

    Write-Host "`n=== command prompt ===" -ForegroundColor Cyan
    Inject '^b{SLEEP:300}:{SLEEP:400}rename-window A{UTF16:D83D,DE0A}B{SLEEP:300}{ENTER}'
    Start-Sleep -Milliseconds 800
    $wn = (P display-message -t $SESS -p '#{window_name}' | Out-String).Trim()
    $wnHex = (($wn.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ',')
    Write-Info "window_name after the prompt: '$wn' [$wnHex]"
    if ($wnHex -eq '0041,D83D,DE0A,0042') { Write-Pass "command prompt keeps the emoji" }
    else { Write-Fail "command prompt: window_name [$wnHex], wanted [0041,D83D,DE0A,0042]" }

    # The same parser drops a control character delivered with vk=0, so such a
    # prefix never armed. No terminal measured types Ctrl+B in this shape (a
    # ConPTY host such as mintty, winpty, sshd or a byte writing terminal gets
    # vk=B, see console_tap.rs); it comes from WM_CHAR posted to a console
    # window, a win32-input-mode report with Vk=0, or WriteConsoleInput.
    # 0x02 then c must open a window like a real Ctrl+B.
    Write-Host "`n=== vk=0 control character as the prefix ===" -ForegroundColor Cyan
    $before = (P list-windows -t $SESS | Measure-Object).Count
    Inject '{UTF16:0002}{SLEEP:300}c'
    $after = $before
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 200
        $after = (P list-windows -t $SESS | Measure-Object).Count
        if ($after -gt $before) { break }
    }
    if ($after -eq $before + 1) { Write-Pass "vk=0 0x02 arms the prefix ($before to $after windows)" }
    else { Write-Fail "vk=0 0x02 did not arm the prefix ($before to $after windows)" }
}
finally {
    if ($script:client -and -not $script:client.HasExited) { Stop-Process -Id $script:client.Id -Force -EA SilentlyContinue }
    P kill-server | Out-Null
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
