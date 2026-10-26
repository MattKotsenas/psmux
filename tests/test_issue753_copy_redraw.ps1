# Issue #753: a copy-mode command that changes only how the mode is drawn did
# not ask for the frame that would show it, so the change waited for an
# unrelated one.
#
# The condition is PRESSING ONE KEY AND PRESSING NOTHING ELSE. Every check here
# injects a single key and then reads the console, because the next key is what
# hides the bug: it moves the cursor, which changes the data version, which
# rebuilds the frame and carries the pending change along with it.
#
# That is also why the existing parity suite passes with the bug in place:
# tests\test_disc694_copy_mode_vi_parity.ps1 presses `X` and then `kkk` before
# it reads the colours.
#
# `display-message` is a command request and marks the state dirty on its own,
# so it would push the very frame being waited for. Nothing here asks psmux
# anything between the key and the read.
#
# GROUND TRUTH: the colour attributes of the attached client's console, read
# with tests\conread.cs -a, which is what the user sees. Keys go in through
# tests\injector.cs.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null
# NO_COLOR makes the client draw without colour, and then no highlight can be
# seen in the console attributes at all.
Remove-Item Env:NO_COLOR -EA SilentlyContinue

$NS   = "cr-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "cr"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cr_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }
function D($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
foreach ($tool in "conread", "injector") {
    $exe = Join-Path $TMP "$tool.exe"
    if ($csc -and (Test-Path $csc)) {
        & $csc /nologo /optimize /out:$exe (Join-Path $PSScriptRoot "$tool.cs") 2>&1 | Out-Null
    }
    if (-not (Test-Path $exe)) {
        Write-Fail "could not build tests\$tool.cs (csc.exe unavailable)"
        Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
        exit 1
    }
}
$RD  = Join-Path $TMP "conread.exe"
$INJ = Join-Path $TMP "injector.exe"

function Stop-Opened {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
}

function Kill-Rig {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Stop-Opened
    Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

$CONF = Join-Path $TMP "cr.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi",
    "set -g history-limit 2000",
    "set -g status-left ''"
) | Set-Content -Path $CONF -Encoding ASCII

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX `
        -ArgumentList "-f",$CONF,"-L",$NS,"new-session","-s",$SESS,"-x","100","-y","30" -PassThru
    $script:Opened += $p.Id
    $portFile = Join-Path $psmuxDir "${NS}__${SESS}.port"
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw).Trim()
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close()
                Start-Sleep -Milliseconds 2500
                return $p
            } catch {}
        }
    }
    return $null
}

function Inj($keys) { & $INJ $script:cpid $keys | Out-Null; Start-Sleep -Milliseconds 450 }

function Screen([switch]$Attr) {
    $o = Join-Path $TMP "screen.txt"
    $a = @("$script:cpid"); if ($Attr) { $a += "-a" }
    Start-Process -FilePath $RD -ArgumentList $a -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The attribute runs of the first screen row whose text matches $pattern.
function Row-Attr($pattern) {
    foreach ($l in Screen -Attr) {
        if ($l -match '^\[attr ([^\]]+)\] (.*)$') {
            $runs = $Matches[1]; $text = $Matches[2]
            if ($text -match $pattern) { return $runs }
        }
    }
    return ""
}

# How many rows carry the search match colour right now.
function Match-Rows {
    $n = 0
    foreach ($l in Screen -Attr) {
        if ($l -match '^\[attr ([^\]]+)\]' -and $Matches[1] -match '(^|,)(48|16432)x') { $n++ }
    }
    return $n
}

function Enter-Copy { P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 700 }
function Leave-Copy { P send-keys -t $SESS -X cancel | Out-Null; Start-Sleep -Milliseconds 400 }

# ── Rig ──

Kill-Rig
$proc = Start-Attached
if (-not $proc) {
    Write-Fail "the attached client never came up"
    Kill-Rig
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
$script:cpid = $proc.Id
for ($try = 0; $try -lt 4; $try++) {
    P send-keys -t $SESS 'cls; 1..80 | % { "row $_ alpha beta gamma" }' Enter | Out-Null
    Start-Sleep -Seconds 2
    if ([int]("0" + (D '#{history_size}')) -ge 40) { break }
    Write-Info "the pane is still empty after attempt $($try + 1); sending the range again"
}
Write-Info "history_size = $(D '#{history_size}')"

# ── 1. X alone colours the marked row ──

Write-Head "1. X alone colours the marked row"
Enter-Copy
Inj "kkk"
# Read the row text BEFORE the key: asking psmux anything afterwards would
# push the frame this check is waiting for.
$markLine = D '#{copy_cursor_line}'
Write-Info "the mark will go on [$markLine]"
Inj "X"
$a = Row-Attr ("^" + [regex]::Escape($markLine))
Check ($a -match '(^|,)64x') "the marked row is bg=red with no other key pressed [$a]" `
                             "the marked row still reads [$a] until another key is pressed"

# ── 2. the same mark through -X, the control ──

Write-Head "2. the -X route colours it, with the bug in place as well"
# A command request marks the state dirty on its own, so this passes before the
# fix too: it is here to show that only the key route was broken.
Inj "{ESC}"
Inj "jj"
$markLine2 = D '#{copy_cursor_line}'
P send-keys -t $SESS -X set-mark | Out-Null
Start-Sleep -Milliseconds 450
$b = Row-Attr ("^" + [regex]::Escape($markLine2))
Check ($b -match '(^|,)64x') "send-keys -X set-mark colours it [$b]" `
                             "even the -X route did not colour it [$b]"
Leave-Copy

# ── 3. Escape alone takes the search colours off ──

Write-Head "3. Escape alone takes the search highlights off"
Enter-Copy
Inj "?alpha"
Inj "{ENTER}"
$lit = Match-Rows
Write-Info "rows carrying the match colour after the search: $lit"
if ($lit -lt 1) {
    Write-Fail "the search coloured nothing, so this check cannot measure anything"
} else {
    Inj "{ESC}"
    $left = Match-Rows
    Check ($left -eq 0) "no row keeps the match colour after Escape" `
                        "$left row(s) still carry the match colour after Escape"
}
Leave-Copy

# ── 4. v alone takes them off too ──

Write-Head "4. v alone takes the search highlights off"
Enter-Copy
Inj "?beta"
Inj "{ENTER}"
$lit2 = Match-Rows
Write-Info "rows carrying the match colour after the search: $lit2"
if ($lit2 -lt 1) {
    Write-Fail "the search coloured nothing, so this check cannot measure anything"
} else {
    Inj "v"
    $left2 = Match-Rows
    Check ($left2 -eq 0) "no row keeps the match colour after v" `
                         "$left2 row(s) still carry the match colour after v"
}
Leave-Copy

# ── Cleanup ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
