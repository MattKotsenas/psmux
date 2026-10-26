# Issue #755: an abandoned `prefix $` leaves the next `prefix ,` renaming the
# session instead of the window.
#
# The client keeps one rename overlay and a `session_renaming` flag that says
# which of the two it is. `$` sets the flag, `,` does not clear it, and the
# Escape that closes any overlay (`src/client.rs:4318` to `:4336`) clears
# `renaming` without clearing `session_renaming`. The per key arm that would
# have cleared both (`:5528`) never runs, because the earlier branch has
# already taken the key. So the flag survives the cancelled rename and the
# next window rename acts on the session.
#
# Reported by the user who hit it: open `$`, press Escape, press `,`, type a
# name, press Enter, and the session is renamed.
#
# GROUND TRUTH: what psmux calls the session and the window afterwards, read
# with `display-message -p`. Keys go in through tests\injector.cs, into a real
# attached client.
#
# Each rename here clears the field with C-u before typing, because the overlay
# opens holding the current name (#757). Without that the typed name is appended
# to the one already there and every check reads a name nobody asked for.
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

$NS   = "rn-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "rn"
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

# What the server holds right now, asked for by neither name: the socket has
# exactly one session here, so list it rather than guess what it is called.
function Session-Name { ((& $PSMUX -L $NS list-sessions -F '#{session_name}') -join '').Trim() }
function Window-Name { ((& $PSMUX -L $NS list-windows -a -F '#{window_name}') -join '').Trim() }

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
Start-Sleep -Milliseconds 800
Write-Info "start: session [$(Session-Name)] window [$(Window-Name)]"

# ── 1. the control: a window rename on its own ──

Write-Head "1. prefix , renames the window"
Inj "^b{SLEEP:300},"
Inj "^u"
Inj "winA{ENTER}"
$s = Session-Name; $w = Window-Name
Check (($w -eq "winA") -and ($s -eq $SESS)) `
    "the window is winA and the session is still $SESS" `
    "session [$s] window [$w]"

# ── 2. a session rename, carried out ──

Write-Head "2. prefix `$ renames the session"
Inj "^b{SLEEP:300}`$"
Inj "^u"
Inj "sessB{ENTER}"
Start-Sleep -Milliseconds 400
$s = Session-Name
Check ($s -eq "sessB") "the session is sessB" "the session reads [$s]"

# ── 3. the bug: an abandoned session rename, then a window rename ──

Write-Head "3. prefix `$ abandoned with Escape, then prefix ,"
Inj "^b{SLEEP:300}`$"
Inj "{ESC}"
$s = Session-Name; $w = Window-Name
Write-Info "after Escape: session [$s] window [$w]"
Check (($s -eq "sessB") -and ($w -eq "winA")) `
    "Escape changed nothing" `
    "Escape already changed something: session [$s] window [$w]"

Inj "^b{SLEEP:300},"
Inj "^u"
Inj "winC{ENTER}"
Start-Sleep -Milliseconds 400
$s = Session-Name; $w = Window-Name
Write-Info "after the window rename: session [$s] window [$w]"
Check ($w -eq "winC") "the window is winC" "the window reads [$w]"
Check ($s -eq "sessB") "the session is untouched" "the SESSION was renamed to [$s] instead"

# ── 4. the same again, to show it is not a one off ──

Write-Head "4. the flag does not come back"
$before = Session-Name
Inj "^b{SLEEP:300}`$"
Inj "{ESC}"
Inj "^b{SLEEP:300},"
Inj "^u"
Inj "winD{ENTER}"
Start-Sleep -Milliseconds 400
$s2 = Session-Name; $w2 = Window-Name
Write-Info "session [$s2] window [$w2]"
Check ($w2 -eq "winD") "the window is winD" "the window reads [$w2]"
Check ($s2 -eq $before) "the session is still $before" "the session reads [$s2]"

# ── Cleanup ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
