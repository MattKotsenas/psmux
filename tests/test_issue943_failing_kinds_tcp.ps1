# Issue #943 over raw TCP: every kind of failing command, sent on a
# PERSISTENT connection (the one an attached client types prefix + : over),
# must leave that connection reading its next line, and must not leave the
# server spinning, before or after the connection closes.
#
# On master 14 of these hung the connection and 11 of them spun the server at
# one to two cores, still spinning after the client went away: the four arms
# fixed for #943 (show-options of an unknown name, of an unset user option,
# show-options -p, display-message with a flag it lacks) reached with any
# flags, and through a line if-shell feeds back.
#
# Each command runs on a server of its own so a spin cannot be counted
# against the next one. Private USERPROFILE, PSMUX_DATA_DIR and empty
# config, a -L namespace per command; cleanup is `-L <ns> kill-server`,
# then the server's own PID if it is still there. PSMUX_EXE picks the
# binary (defaults to target\release\psmux.exe).

$ErrorActionPreference = "Continue"
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

$TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_fkt_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
$env:PSMUX_CONFIG_FILE = Join-Path $TempHome "empty.conf"
Set-Content -Path $env:PSMUX_CONFIG_FILE -Value ""

$commands = @(
    # The four arms, and the same arms with other flags.
    'show-options codepoint-width'
    'show-options @nope'
    'display-message -x hi'
    'show-options -p'
    'show-options -w @nope'
    'show-options -s @nope'
    'show-options -g nosuch'
    'show-window-options nosuch'
    'show-options -gv nosuch'
    'show-options -A nosuch'
    'display-message -Z'
    'if-shell -F 1 "show-options @nope"'
    # Every other kind of failure, which already read the next line.
    'show-options -t nosuch'
    'show-hooks nosuch'
    'display-message -t nosuch hi'
    'nosuchcommand a b'
    'set-option nosuch x'
    'set-option -g @x'
    'set-hook nosuch x'
    'select-window -t 99'
    'select-pane -t %999'
    'split-window -t nosuch'
    'source-file C:/nope/x.conf'
    'unbind-key -T nosuch x'
    'list-keys -T nosuch'
    'send-keys -t nosuch x'
    'capture-pane -t nosuch'
    'show-buffer -b nosuch'
    'switch-client -t nosuch'
    'kill-session -t nosuch'
    'show-options codepoint-width ; set -g @chain 1'
    'set -g @a 1 ; show-options @nope ; set -g @b 1'
)

function Server-Cpu($proc, $seconds) {
    $proc.Refresh(); $t0 = $proc.TotalProcessorTime
    Start-Sleep -Seconds $seconds
    $proc.Refresh()
    return [math]::Round(($proc.TotalProcessorTime - $t0).TotalSeconds, 2)
}

Write-Host "`n=== a failing command on a persistent connection leaves it reading ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"
$started = @()
try {
    $k = 0
    foreach ($cmd in $commands) {
        $k++
        $ns = "fkt_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
        & $PSMUX -L $ns new-session -d -s s -x 100 -y 30 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $serverPid = [int]((& $PSMUX -L $ns display -p -t s '#{pid}') | Select-Object -Last 1)
        $proc = Get-Process -Id $serverPid -EA SilentlyContinue
        if (-not $proc) { Write-Fail "[$k] $cmd : server did not start"; continue }
        $started += $serverPid
        $port = [int](Get-Content (Join-Path $TempHome "${ns}__s.port") -Raw).Trim()
        $key = (Get-Content (Join-Path $TempHome "${ns}__s.key") -Raw).Trim()
        $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $port)
        $stream = $client.GetStream(); $stream.ReadTimeout = 3000
        $w = New-Object System.IO.StreamWriter($stream); $w.NewLine = "`n"; $w.AutoFlush = $true
        $r = New-Object System.IO.StreamReader($stream)
        $w.WriteLine("AUTH $key"); [void]$r.ReadLine()
        $w.WriteLine("PERSISTENT")
        $w.WriteLine($cmd)
        Start-Sleep -Milliseconds 500
        $cpu = Server-Cpu $proc 2
        try { $w.WriteLine("set-option -g @alive $k") } catch {}
        Start-Sleep -Milliseconds 800
        $alive = (& $PSMUX -L $ns show -gv '@alive' 2>&1) -join ''
        $client.Close()
        Start-Sleep -Milliseconds 1500
        $cpuAfter = Server-Cpu $proc 2
        $ok = ($alive -eq "$k") -and $cpu -lt 0.5 -and $cpuAfter -lt 0.5
        $detail = "(next line ran: $($alive -eq "$k"), cpu $cpu s in 2 s, after close $cpuAfter s in 2 s)"
        if ($ok) { Write-Pass "[$k] $cmd $detail" } else { Write-Fail "[$k] $cmd $detail" }
        & $PSMUX -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
}
finally {
    foreach ($id in $started) {
        $p = Get-Process -Id $id -EA SilentlyContinue
        if ($p -and $p.Path -eq (Get-Item $PSMUX).FullName) { Stop-Process -Id $id -Force -EA SilentlyContinue }
    }
    Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
