# Issue #681: copy mode page motions move a page, not a fixed number of lines.
#
# `C-b` and `C-f` scrolled a constant 10 lines whatever the pane height was,
# `send-keys -X page-up` and `page-down` scrolled a constant 20, and
# `copy-mode -u` scrolled a whole screen. tmux computes every one of them from
# the pane height in a single place, window_copy_pageup1 and its
# window_copy_pagedown1 twin (window-copy.c:767-773 and :825-831 at tag 3.7c,
# :723-729 and :781-787 at 3.6a):
#
#     n = 1;
#     if (screen_size_y(s) > 2) {
#             if (half_page)
#                     n = screen_size_y(s) / 2;
#             else
#                     n = screen_size_y(s) - 2;
#     }
#
# A full page is the height minus two lines, a half page is half the height,
# and a pane of two rows or fewer moves a single line. The cursor keeps its
# screen row unless the history end clamps the scroll (window-copy.c:775-782
# going up, :833-840 going down).
#
# Two layers, because the amount lives on two surfaces:
#   Layer 1 (CLI + TCP dump-state) drives the server command path with
#           `send-keys -t s C-b`, `send-keys -X page-up` and `copy-mode -u`.
#   Layer 2 (attached Win32 TUI) injects real WriteConsoleInput KEY_EVENT
#           records, which is the only way to prove what a user pressing the
#           key actually gets.
#
# Measured against tmux 3.7c for every number asserted here.

param([string]$PsmuxPath = "")

$ErrorActionPreference = "Continue"
$env:PSMUX_NO_WARM = "1"

# -PsmuxPath names the build to measure, which is how the before and after
# numbers in the PR were taken. Without it, the checkout's own build comes
# first and an installed psmux is the last resort.
function Resolve-Psmux([string]$Explicit) {
    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        Write-Host "[FAIL] psmux not found at $Explicit"
        exit 1
    }
    foreach ($c in @(
        "$PSScriptRoot\..\target\release\psmux.exe",
        "$PSScriptRoot\..\target\debug\psmux.exe",
        "$env:USERPROFILE\.cargo\bin\psmux.exe"
    )) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    $onPath = Get-Command psmux -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    Write-Host "[FAIL] no psmux found: build the checkout (cargo build --release) or pass -PsmuxPath"
    exit 1
}

$PSMUX = Resolve-Psmux $PsmuxPath
Write-Host "      psmux:   $PSMUX" -ForegroundColor DarkGray
Write-Host "      version: $(& $PSMUX -V 2>&1 | Select-Object -Last 1)" -ForegroundColor DarkGray

$SOCK = "i681"
$psmuxDir = "$env:USERPROFILE\.psmux"
$pass = 0
$fail = 0
$skip = 0

function Write-Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function Write-Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Write-Skip($m) { Write-Host "[SKIP] $m" -ForegroundColor Yellow; $script:skip++ }

function Get-Leaf([string]$Session) {
    $portFile = "$psmuxDir\${SOCK}__$Session.port"
    $keyFile = "$psmuxDir\${SOCK}__$Session.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    } catch { return $null }
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("dump-state`n"); $writer.Flush()
    try { $resp = $reader.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    if (-not $resp -or $resp.Length -lt 50) { return $null }
    return ($resp | ConvertFrom-Json).layout
}

function Fill-Pane([string]$Session) {
    & $PSMUX -L $SOCK send-keys -t $Session "1..400 | % { `"line-`$_`" }" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

# Enter copy mode at the live end with a known starting offset.
function Start-CopyMode([string]$Session) {
    & $PSMUX -L $SOCK copy-mode -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $SOCK send-keys -t $Session -X history-bottom 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    return Get-Leaf $Session
}

# One motion, then report how far the view moved.
function Step([string]$Session, [scriptblock]$Send) {
    $b = Get-Leaf $Session
    & $Send
    Start-Sleep -Milliseconds 400
    $a = Get-Leaf $Session
    return @{ Before = $b; After = $a; Delta = ($a.scroll_offset - $b.scroll_offset) }
}

function Check([string]$Name, [int]$Want, $Step) {
    if ($Step.Delta -eq $Want) {
        Write-Pass "$Name moved $Want lines (offset $($Step.Before.scroll_offset) -> $($Step.After.scroll_offset))"
    } else {
        Write-Fail "$Name expected $Want lines, moved $($Step.Delta) (offset $($Step.Before.scroll_offset) -> $($Step.After.scroll_offset))"
    }
}

Write-Host "`n=== copy mode page scroll: a page is pane_height - 2, a half page is pane_height / 2 ===" -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════════════
# Layer 1: CLI + TCP dump-state (server command dispatch path)
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n--- Layer 1: CLI send-keys + dump-state ---" -ForegroundColor Cyan

# Measure against a config of our own, not the user's ~/.tmux.conf: a smaller
# history-limit or a different mode-keys would change what these numbers mean.
$cliConf = "$env:TEMP\psmux_681_cli.conf"
"set -g mode-keys vi`n" | Set-Content -Path $cliConf -Encoding ASCII

# 24 and 10 rows prove the amount tracks the pane, 3 rows covers the small pane
# branch (a page of 1 line, because screen_size_y(s) > 2 is false at 2 and the
# formula would otherwise give 1 anyway).
foreach ($rows in @(24, 10, 3)) {
    $S = "i681cli$rows"
    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $SOCK -f "$cliConf" new-session -d -s $S -x 80 -y $rows 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    & $PSMUX -L $SOCK set-option -t $S -g mode-keys vi 2>&1 | Out-Null
    Fill-Pane $S

    $l = Start-CopyMode $S
    if (-not $l -or -not $l.copy_mode) {
        Write-Skip "${rows} rows: could not enter copy mode over the CLI, nothing proven"
        & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
        continue
    }

    $h = [int]$l.rows
    $page = if ($h -gt 2) { $h - 2 } else { 1 }
    $half = if ($h -gt 2) { [math]::Floor($h / 2) } else { 1 }
    Write-Host ("      pane height $h : page=$page half=$half") -ForegroundColor DarkGray

    Check "${rows}r C-b"                 $page (Step $S { & $PSMUX -L $SOCK send-keys -t $S C-b 2>&1 | Out-Null })
    Check "${rows}r C-f"     (-1 * $page) (Step $S { & $PSMUX -L $SOCK send-keys -t $S C-f 2>&1 | Out-Null })
    Check "${rows}r PageUp"              $page (Step $S { & $PSMUX -L $SOCK send-keys -t $S PageUp 2>&1 | Out-Null })
    Check "${rows}r PageDown" (-1 * $page) (Step $S { & $PSMUX -L $SOCK send-keys -t $S PageDown 2>&1 | Out-Null })
    Check "${rows}r C-u"                 $half (Step $S { & $PSMUX -L $SOCK send-keys -t $S C-u 2>&1 | Out-Null })
    Check "${rows}r C-d"     (-1 * $half) (Step $S { & $PSMUX -L $SOCK send-keys -t $S C-d 2>&1 | Out-Null })
    Check "${rows}r -X page-up"          $page (Step $S { & $PSMUX -L $SOCK send-keys -t $S -X page-up 2>&1 | Out-Null })
    Check "${rows}r -X page-down" (-1 * $page) (Step $S { & $PSMUX -L $SOCK send-keys -t $S -X page-down 2>&1 | Out-Null })
    Check "${rows}r -X halfpage-up"      $half (Step $S { & $PSMUX -L $SOCK send-keys -t $S -X halfpage-up 2>&1 | Out-Null })
    Check "${rows}r -X halfpage-down" (-1 * $half) (Step $S { & $PSMUX -L $SOCK send-keys -t $S -X halfpage-down 2>&1 | Out-Null })

    # The cursor keeps its screen row while the view moves (window-copy.c:775-782
    # only touches data->cy when the history end clamps the scroll).
    $b = Get-Leaf $S
    & $PSMUX -L $SOCK send-keys -t $S C-b 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
    $a = Get-Leaf $S
    if ($a.copy_cursor_row -eq $b.copy_cursor_row) {
        Write-Pass "${rows}r C-b left the cursor on row $($a.copy_cursor_row)"
    } else {
        Write-Fail "${rows}r C-b moved the cursor $($b.copy_cursor_row) -> $($a.copy_cursor_row) away from the history end"
    }

    # copy-mode -u enters scrolled one page up, not one screen
    # (cmd-copy-mode.c:99-100 calls window_copy_pageup(wp, 0)).
    & $PSMUX -L $SOCK send-keys -t $S q 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $SOCK copy-mode -u -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $a = Get-Leaf $S
    if ($a.copy_mode -and $a.scroll_offset -eq $page) {
        Write-Pass "${rows}r copy-mode -u entered scrolled $page lines up"
    } else {
        Write-Fail "${rows}r copy-mode -u expected offset $page, got $($a.scroll_offset) (copy_mode=$($a.copy_mode))"
    }

    # At the top of the history the view stops and the cursor is pulled along,
    # so repeated page-ups can reach the first retained line.
    & $PSMUX -L $SOCK send-keys -t $S -X history-top 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $top = Get-Leaf $S
    for ($i = 0; $i -lt [math]::Ceiling($h / [math]::Max($page, 1)) + 2; $i++) {
        & $PSMUX -L $SOCK send-keys -t $S C-b 2>&1 | Out-Null
        Start-Sleep -Milliseconds 200
    }
    $a = Get-Leaf $S
    if ($a.scroll_offset -eq $top.scroll_offset -and $a.copy_cursor_row -eq 0) {
        Write-Pass "${rows}r page up at the history top stops at offset $($a.scroll_offset) and lands the cursor on row 0"
    } else {
        Write-Fail "${rows}r page up at the history top expected offset $($top.scroll_offset) / row 0, got offset $($a.scroll_offset) / row $($a.copy_cursor_row)"
    }

    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

# ══════════════════════════════════════════════════════════════════════════
# Layer 2: attached Win32 TUI, real WriteConsoleInput keystrokes
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n--- Layer 2: attached TUI + WriteConsoleInput injection ---" -ForegroundColor Cyan

$injector = "$env:TEMP\psmux_injector_681.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

if (-not (Test-Path $injector)) {
    Write-Skip "could not compile injector.cs, the attached TUI layer proves nothing"
} else {
    # The suite itself may run inside a psmux pane. An attached client refuses to
    # start there, so launch through a .cmd that scrubs the nesting variables.
    #
    # -f names a config of our own. Without it the client reads the user's
    # ~/.tmux.conf, and a config that moves the prefix makes the injected prefix
    # arrive in the pane as a literal control character instead of opening copy
    # mode, which reads as "the keys never landed".
    #
    # The prefix is C-a here precisely because it must not be C-b: the prefix
    # key is claimed before the copy-mode table is consulted, so with the
    # default prefix a C-b press in copy mode arms the prefix rather than
    # paging up. tmux behaves the same way, which is why its own vi users move
    # the prefix off C-b.
    $S = "i681tui"
    $tuiConf = "$env:TEMP\psmux_681_tui.conf"
    "set -g prefix C-a`nbind-key C-a send-prefix`nset -g mode-keys vi`n" |
        Set-Content -Path $tuiConf -Encoding ASCII
    $launchCmd = "$env:TEMP\psmux_681_launch.cmd"
    @"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set PSMUX_NO_WARM=1
"$PSMUX" -L $SOCK -f "$tuiConf" new-session -s $S -x 80 -y 24
"@ | Set-Content -Path $launchCmd -Encoding ASCII

    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $null = Start-Process -FilePath $launchCmd -PassThru
    Start-Sleep -Seconds 7

    $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
        Where-Object { $_.CommandLine -match "-L $SOCK" -and $_.CommandLine -match "new-session -s $S" }

    if (-not $cli) {
        Write-Skip "no attached client came up, injection layer proves nothing"
    } else {
        $clientPid = $cli.ProcessId
        Write-Host "      attached client pid=$clientPid"
        & $PSMUX -L $SOCK set-option -t $S -g mode-keys vi 2>&1 | Out-Null
        Fill-Pane $S

        # prefix (C-a here, see the config above) then '[' enters copy mode,
        # exactly as a user does it.
        & $injector $clientPid "^a" | Out-Null
        Start-Sleep -Milliseconds 400
        & $injector $clientPid "[" | Out-Null
        Start-Sleep -Milliseconds 900

        $l = Get-Leaf $S
        if (-not $l -or -not $l.copy_mode) {
            Write-Skip "prefix+[ did not reach the client, no keys were delivered, nothing proven"
        } else {
            $h = [int]$l.rows
            $page = if ($h -gt 2) { $h - 2 } else { 1 }
            $half = if ($h -gt 2) { [math]::Floor($h / 2) } else { 1 }
            Write-Pass "injected prefix+[ entered copy mode (pane height $h, page=$page half=$half)"

            Check "TUI Ctrl+B"              $page (Step $S { & $injector $clientPid "^b" | Out-Null })
            Check "TUI Ctrl+F"  (-1 * $page) (Step $S { & $injector $clientPid "^f" | Out-Null })
            Check "TUI Ctrl+U"              $half (Step $S { & $injector $clientPid "^u" | Out-Null })
            Check "TUI Ctrl+D"  (-1 * $half) (Step $S { & $injector $clientPid "^d" | Out-Null })
            Check "TUI PageUp"             $page (Step $S { & $injector $clientPid "{PGUP}" | Out-Null })
            Check "TUI PageDown" (-1 * $page) (Step $S { & $injector $clientPid "{PGDN}" | Out-Null })

            # Repeat to rule out a one shot fluke: three page ups then three page
            # downs land back where they started.
            $b = Get-Leaf $S
            for ($i = 0; $i -lt 3; $i++) { & $injector $clientPid "^b" | Out-Null; Start-Sleep -Milliseconds 350 }
            $mid = Get-Leaf $S
            for ($i = 0; $i -lt 3; $i++) { & $injector $clientPid "^f" | Out-Null; Start-Sleep -Milliseconds 350 }
            $a = Get-Leaf $S
            if ($mid.scroll_offset -eq ($b.scroll_offset + 3 * $page) -and $a.scroll_offset -eq $b.scroll_offset) {
                Write-Pass "TUI three Ctrl+B then three Ctrl+F moved $((3 * $page)) lines and came back"
            } else {
                Write-Fail "TUI repeat rounds: expected $($b.scroll_offset + 3 * $page) then $($b.scroll_offset), got $($mid.scroll_offset) then $($a.scroll_offset)"
            }
        }

        & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        Stop-Process -Id $clientPid -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== RESULT: $pass passed, $fail failed, $skip skipped ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
exit 0
