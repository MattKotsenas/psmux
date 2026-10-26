# Issue #702: the copy mode position indicator printed the scroll offset on
# both sides of the slash, and drew nothing at the live bottom.
#
# The indicator is drawn by the attached CLIENT around the pane, so
# capture-pane cannot see it. This suite launches a real attached client and
# reads its console screen with tests\conread.cs.
#
# Measured on 2c5ee95 with a 100x30 client and `1..200` in the pane, 3 runs:
#
#                      #{scroll_position}/#{history_size}   on screen
#   entered copy mode  0/173                                 (nothing)
#   scrolled up 97     97/173                                [97/97]
#
# tmux draws `[#{copy_position}/#{copy_position_limit}]` on every copy mode
# frame (tmux tree, window-copy.c window_copy_write_line, py == 0, no lower
# bound) from window_copy_formats:
#
#   copy-mode-line-numbers off/default   oy / hsize
#   absolute/relative/hybrid             hsize - oy + 1 / hsize + pane height
#
# WSL tmux 3.4 with `seq 1 200` in a 30 row pane shows [0/174] then [97/174].
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

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$NS   = "i702-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "pos"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i702_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$RD = Join-Path $TMP "conread.exe"
if ($csc -and (Test-Path $csc)) {
    & $csc /nologo /optimize /out:$RD (Join-Path $PSScriptRoot "conread.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $RD)) {
    Write-Fail "could not build tests\conread.cs (csc.exe unavailable); the screen cannot be read"
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}

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

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$SESS,"-x","100","-y","30" -PassThru
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

function Get-ClientScreen($procId) {
    $o = Join-Path $TMP "screen.txt"; $e = Join-Path $TMP "screen_err.txt"
    Start-Process -FilePath $RD -ArgumentList "$procId" -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The indicator sits at the right edge of the pane's top rows. Return every
# `[N/M]` token found on the first three screen rows.
function Get-Indicator($procId) {
    $rows = Get-ClientScreen $procId | Select-Object -First 3
    $hits = @()
    foreach ($r in $rows) {
        foreach ($m in [regex]::Matches($r, '\[(\d+)/(\d+)\]')) { $hits += $m.Value }
    }
    return ,$hits
}

# Poll until the screen shows the expected token; the client repaints on its
# own schedule after a server side change.
function Wait-Indicator($procId, $want) {
    $last = @()
    for ($i = 0; $i -lt 20; $i++) {
        $last = Get-Indicator $procId
        if ($last -contains $want) { return $last }
        Start-Sleep -Milliseconds 250
    }
    return $last
}

function Show-Top($procId) {
    Get-ClientScreen $procId | Select-Object -First 3 | ForEach-Object { Write-Info ("screen: " + $_.TrimEnd()) }
}

function Fill-And-Enter {
    P send-keys -t $SESS '1..200' Enter | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $h = [int]((P display-message -t $SESS -p '#{history_size}') -join '')
        if ($h -ge 150) { break }
    }
    Start-Sleep -Milliseconds 500
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 800
}

function Scroll-Up($n) {
    P send-keys -t $SESS -X -N $n scroll-up | Out-Null
    $sp = (P display-message -t $SESS -p '#{scroll_position}') -join ''
    if ([int]$sp -ne $n) {
        # Fall back to single steps if -N is not honoured.
        for ($k = [int]$sp; $k -lt $n; $k++) { P send-keys -t $SESS -X scroll-up | Out-Null }
    }
    Start-Sleep -Milliseconds 600
}

try {
    # -----------------------------------------------------------------------
    Write-Head "copy-mode-line-numbers off: [scroll_position/history_size]"
    # -----------------------------------------------------------------------
    $p = Start-Attached
    if (-not $p) { Write-Fail "attached client never came up"; throw "no client" }
    Fill-And-Enter

    $fmt = (P display-message -t $SESS -p '#{pane_in_mode} #{scroll_position} #{history_size}') -join ''
    Write-Info "formats at bottom: $fmt"
    $parts = $fmt.Split(' ')
    if ($parts[0] -ne '1') { Write-Fail "pane is not in copy mode ($fmt)" }
    $hs = [int]$parts[2]
    $want = "[0/$hs]"
    $got = Wait-Indicator $p.Id $want
    if ($got -contains $want) { Write-Pass "live bottom shows $want" }
    else { Write-Fail "live bottom: expected $want, screen had '$($got -join ',')'"; Show-Top $p.Id }

    Scroll-Up 97
    $fmt = (P display-message -t $SESS -p '#{scroll_position}/#{history_size}') -join ''
    Write-Info "formats after scroll: $fmt"
    $want = "[$fmt]"
    $got = Wait-Indicator $p.Id $want
    if ($got -contains $want) { Write-Pass "scrolled view shows $want, matching the formats" }
    else { Write-Fail "scrolled: expected $want, screen had '$($got -join ',')'"; Show-Top $p.Id }
    if ($got -contains "[97/97]") { Write-Fail "the offset is printed on both sides of the slash" }
    else { Write-Pass "the old [97/97] reading is gone" }
    if (@($got).Count -eq 1) { Write-Pass "exactly one indicator on the top rows" }
    else { Write-Fail "expected one indicator, found '$($got -join ',')'" }

    # Scrolling further moves the position, never the limit.
    Scroll-Up 120
    $fmt = (P display-message -t $SESS -p '#{scroll_position}/#{history_size}') -join ''
    $want = "[$fmt]"
    $got = Wait-Indicator $p.Id $want
    if ($got -contains $want) { Write-Pass "further scroll shows $want" }
    else { Write-Fail "further scroll: expected $want, screen had '$($got -join ',')'" }

    # Leaving copy mode removes it.
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 800
    $got = Get-Indicator $p.Id
    if (@($got).Count -eq 0) { Write-Pass "no indicator after leaving copy mode" }
    else { Write-Fail "indicator still drawn after cancel: '$($got -join ',')'" }

    # -----------------------------------------------------------------------
    Write-Head "copy-mode-line-numbers absolute: [top line/total lines]"
    # -----------------------------------------------------------------------
    P set-option -g copy-mode-line-numbers absolute | Out-Null
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 800
    Scroll-Up 68
    $fmt = (P display-message -t $SESS -p '#{scroll_position} #{history_size} #{pane_height}') -join ''
    Write-Info "formats: $fmt"
    $a = $fmt.Split(' ') | ForEach-Object { [int]$_ }
    $want = "[$($a[1] - $a[0] + 1)/$($a[1] + $a[2])]"
    $got = Wait-Indicator $p.Id $want
    if ($got -contains $want) { Write-Pass "absolute reading shows $want" }
    else { Write-Fail "absolute: expected $want, screen had '$($got -join ',')'"; Show-Top $p.Id }
    # The gutter's top number is the same line the indicator names.
    $top = (Get-ClientScreen $p.Id | Select-Object -First 1)
    $n = ([regex]::Match($top, '^\s*(\d+)\s')).Groups[1].Value
    if ($n -eq "$($a[1] - $a[0] + 1)") { Write-Pass "gutter top row $n agrees with the indicator" }
    else { Write-Fail "gutter top row '$n' does not match $want (row: '$($top.TrimEnd())')" }
    P set-option -g copy-mode-line-numbers off | Out-Null
    P send-keys -t $SESS -X cancel | Out-Null
}
finally {
    Kill-Rig
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== #702 results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit [int]($script:TestsFailed -gt 0)
