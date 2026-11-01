# Issue #951: a command that fails at the command prompt shows its error on
# the status line, as tmux's cmdq_error does for a command whose client has a
# session (cmd-queue.c:880-882 at tag 3.8): its first letter in upper case,
# and a command line that does not parse worded `command NAME: ...` first
# (cmd.c:534). It used to open a popup, be written to the connection where
# the client dropped it, or not be reported at all.
#
# Every expected message below is what tmux 3.8 (`-f /dev/null`, WSL)
# showed for the same command typed at the prompt of an attached client
# (command-prompt -b, then send-keys -K, read back with show-messages).
#
# [1] sends each command as prefix + : sends it, on a PERSISTENT connection
# after client-attach, and reads what the client is told from dump-state:
# status_message and popup_active. [2] checks that a command that works
# still opens its popup. [3] types three of them at prefix + : of a real
# client (tests\injector.cs, WriteConsoleInput) and reads its screen
# (tests\conread.cs). [4] is the CLI.
#
# display-time is 20000 in the config, so a message is still up when it is
# read. Private USERPROFILE, PSMUX_DATA_DIR and config, a -L namespace per
# server; cleanup is `-L <ns> kill-server` plus the client PID. PSMUX_EXE
# picks the binary (defaults to target\release\psmux.exe).

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

$TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_pel_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_CONFIG_FILE = Join-Path $TempHome "psmux.conf"
Set-Content -Path $env:PSMUX_CONFIG_FILE -Value "set -g display-time 20000"
$script:NS = ""
function P { & $PSMUX -L $script:NS @args 2>&1 }
function New-Server {
    $script:NS = "pel_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
    P new-session -d -s s -x 120 -y 30 | Out-Null
    Start-Sleep -Milliseconds 1500
}
function Open-Connection {
    $port = [int](Get-Content (Join-Path $TempHome "$($script:NS)__s.port") -Raw).Trim()
    $key = (Get-Content (Join-Path $TempHome "$($script:NS)__s.key") -Raw).Trim()
    $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
    $s = $c.GetStream(); $s.ReadTimeout = 500
    $w = [System.IO.StreamWriter]::new($s); $w.NewLine = "`n"; $w.AutoFlush = $true
    $r = [System.IO.StreamReader]::new($s)
    $w.WriteLine("AUTH $key"); [void]$r.ReadLine()
    return @($c, $w, $r)
}
function Dump-State {
    $c, $w, $r = Open-Connection
    $c.GetStream().ReadTimeout = 3000
    $w.WriteLine("dump-state")
    $json = $null; try { $json = $r.ReadLine() | ConvertFrom-Json } catch {}
    $c.Close()
    return $json
}
# Runs $command as the prompt sends it. Returns the status message, whether
# a popup opened, and the lines written back that are no frame.
function At-Prompt($command) {
    New-Server
    $c, $w, $r = Open-Connection
    $w.WriteLine("PERSISTENT"); $w.WriteLine("client-attach features=0x0")
    Start-Sleep -Milliseconds 300
    try { while ($true) { [void]$r.ReadLine() } } catch {}
    $w.WriteLine($command)
    $back = @()
    $until = (Get-Date).AddMilliseconds(900)
    while ((Get-Date) -lt $until) {
        try { $l = $r.ReadLine(); if ($null -eq $l) { break }; if ($l.Trim() -and $l -notmatch '^\s*\{' -and $l.Trim() -ne 'NC') { $back += $l.Trim() } } catch {}
    }
    $json = Dump-State
    $c.Close()
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 300
    return @{
        Message = if ($json -and $json.status_message) { $json.status_message } else { '' }
        Popup = [bool]($json -and $json.popup_active)
        Back = $back -join ' / '
    }
}

Write-Host "`n=== a failing command at the prompt shows its error on the status line ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"
Write-Host "  $((& $PSMUX -V) -join ' ')"

$cases = @(
    # A popup before.
    @('show-options @nope', 'Invalid option: @nope'),
    @('show-options -w @nope', 'Invalid option: @nope'),
    @('show-options -s @nope', 'Invalid option: @nope'),
    @('show-options -g nosuch', 'Invalid option: nosuch'),
    @('show-options -gv nosuch', 'Invalid option: nosuch'),
    @('show-options -A nosuch', 'Invalid option: nosuch'),
    @('show-window-options nosuch', 'Invalid option: nosuch'),
    @('if-shell -F 1 "show-options @nope"', 'Invalid option: @nope'),
    @('show-hooks nosuch', 'Invalid option: nosuch'),
    @('list-keys -T nosuch', "Table nosuch doesn't exist"),
    @('show-buffer -b nosuch', 'No buffer nosuch'),
    @('set -g @a 1 ; show-options @nope ; set -g @b 1', 'Invalid option: @nope'),
    # Written to the connection and dropped before.
    @('display-message -x hi', 'Command display-message: unknown flag -x'),
    @('display-message -Z', 'Command display-message: unknown flag -Z'),
    @('set-option nosuch x', 'Invalid option: nosuch'),
    # Not reported at all before.
    @('nosuchcommand a b', 'Unknown command: nosuchcommand'),
    @('set-hook nosuch x', 'Invalid option: nosuch'),
    @('select-pane -t %999', "Can't find pane: %999"),
    @('unbind-key -T nosuch x', "Table nosuch doesn't exist"),
    @('kill-session -t nosuch', "Can't find session: nosuch"),
    # Shown before, in lower case or with a prefix of psmux's own.
    @('select-window -t 99', "Can't find window: 99"),
    @('split-window -t nosuch', "Can't find pane: nosuch"),
    @('send-keys -t nosuch x', "Can't find pane: nosuch"),
    @('capture-pane -t nosuch', "Can't find pane: nosuch"),
    @('switch-client -t nosuch', "Can't find session: nosuch")
)
Write-Host "`n[1] At the prompt" -ForegroundColor Yellow
foreach ($case in $cases) {
    $got = At-Prompt $case[0]
    $detail = "(popup: $($got.Popup), written back: '$($got.Back)')"
    if ($got.Message -eq $case[1] -and -not $got.Popup -and -not $got.Back) {
        Write-Pass "$($case[0]) => '$($got.Message)'"
    } else {
        Write-Fail "$($case[0]) expected '$($case[1])', got '$($got.Message)' $detail"
    }
}

Write-Host "`n[2] A command that works still opens its popup" -ForegroundColor Yellow
$got = At-Prompt 'show-options -g status'
if ($got.Popup -and -not $got.Message) { Write-Pass "show-options -g status opens a popup, no message" }
else { Write-Fail "show-options -g status: popup $($got.Popup), message '$($got.Message)'" }

Write-Host "`n[3] Typed at prefix + : of a real client" -ForegroundColor Yellow
$toolDir = Join-Path $TempHome "tools"
New-Item -ItemType Directory -Force $toolDir | Out-Null
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$INJ = Join-Path $toolDir "injector.exe"
$READ = Join-Path $toolDir "conread.exe"
& $csc /nologo /optimize /out:$INJ  (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
& $csc /nologo /optimize /out:$READ (Join-Path $PSScriptRoot "conread.cs") 2>&1 | Out-Null
$script:clients = @()
try {
    if (-not ((Test-Path $INJ) -and (Test-Path $READ))) {
        Write-Fail "harness tools did not compile"
    } else {
        foreach ($case in @(
            @('display-message -x hi', 'Command display-message: unknown flag -x'),
            @('show-options @nope', 'Invalid option: @nope'),
            @('nosuchcommand a b', 'Unknown command: nosuchcommand')
        )) {
            New-Server
            $p = Start-Process -FilePath $PSMUX -ArgumentList "-L", $script:NS, "attach", "-t", "s" -PassThru
            $script:clients += $p
            Start-Sleep -Seconds 4
            & $INJ $p.Id "^b{SLEEP:500}:{SLEEP:600}$($case[0]){ENTER}{SLEEP:1500}" | Out-Null
            Start-Sleep -Milliseconds 900
            $screen = ([string[]](& $READ $p.Id))
            $lastRow = ($screen | Where-Object { $_.Trim() } | Select-Object -Last 1)
            $json = Dump-State
            if ($lastRow -and $lastRow.Contains($case[1]) -and -not $json.popup_active) {
                Write-Pass "$($case[0]): the status line reads '$($case[1])'"
            } else {
                Write-Fail "$($case[0]): expected '$($case[1])' on the status line, last row '$lastRow', popup $($json.popup_active)"
            }
            try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 700
            P kill-server | Out-Null
            Start-Sleep -Milliseconds 300
        }
    }

    Write-Host "`n[4] From the CLI" -ForegroundColor Yellow
    New-Server
    foreach ($case in @(
        @(@('set-hook', 'nosuch', 'x'), 1, 'psmux: invalid option: nosuch'),
        @(@('show-hooks', 'nosuch'), 1, 'psmux: invalid option: nosuch'),
        @(@('unbind-key', '-T', 'nosuch', 'x'), 1, "psmux: table nosuch doesn't exist"),
        @(@('list-keys', '-T', 'nosuch'), 1, "psmux: table nosuch doesn't exist"),
        @(@('unbind-key', '-T', 'copy-mode-vi', 'v'), 0, ''),
        @(@('set-hook', '-g', 'after-new-window', 'display hi'), 0, '')
    )) {
        $out = ((P @($case[0])) -join ' ') -replace '\x1b\[[0-9;]*m', ''
        Check "psmux $($case[0] -join ' ') (exit $LASTEXITCODE)" "$LASTEXITCODE $out".Trim() "$($case[1]) $($case[2])".Trim()
    }
    P kill-server | Out-Null
}
finally {
    foreach ($p in $script:clients) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } }
    if ($script:NS) { P kill-server | Out-Null }
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
