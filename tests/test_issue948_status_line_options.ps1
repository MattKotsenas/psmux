# Issue #948: status-bg and status-fg are colour options of their own, set
# the same way from a config file and at runtime, shown as tmux shows them,
# taken off by -u, and laid over status-style when the status line is drawn,
# so a later status-style does not replace them; a bad colour is refused.
# status-justify and status-position take their tmux choices only, and
# status-left-length and status-right-length stop at 32767.
#
# Every expected show line and error below is what tmux 3.8 (`-f /dev/null`,
# WSL) printed for the same commands. What the status line is drawn with is
# read from dump-state, the frame the server sends the client: its
# status_style is the base style the client paints the line with, a later
# bg= or fg= over an earlier one. tmux 3.8 drew the config of [2] with
# ESC[37m ESC[41m (white on red), the one of [3] with ESC[41m (red), and
# that one without its status-bg line with ESC[44m (blue).
#
# Isolated: USERPROFILE, PSMUX_DATA_DIR and PSMUX_CONFIG_FILE point into a
# fresh temp dir and every command uses -L. PSMUX_EXE picks the binary
# (defaults to psmux on PATH).

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$TempHome = Join-Path $env:TEMP ("psmux_sl_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
$EmptyConf = Join-Path $TempHome "empty.conf"
Set-Content -Path $EmptyConf -Value ""
$env:PSMUX_CONFIG_FILE = $EmptyConf
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'PSMUX_TARGET*' -or $_.Name -like 'TMUX*' } | ForEach-Object Name)) {
    Remove-Item "Env:$name"
}
$env:PSMUX_NO_WARM = "1"
$script:NS = ""
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function P { & $PSMUX -L $script:NS @args 2>&1 }
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Pass "$name = '$got'" } else { Write-Fail "$name expected '$want', got '$got'" }
}
# A command that must fail: its exit code and its message.
function Refused($name, $want, [string[]]$cmd) {
    $out = ((P @cmd) -join ' ') -replace '\x1b\[[0-9;]*m', '' -replace '^psmux: (set-option: )?', ''
    if ($LASTEXITCODE -ne 0 -and $out -eq $want) { Write-Pass "$name refused: '$out'" }
    else { Write-Fail "$name expected '$want' and a failing exit, got rc=$LASTEXITCODE '$out'" }
}

# A new server on its own namespace, with `$Conf` as its config file.
function Start-Server([string]$Conf = '') {
    if ($script:NS) { P kill-server | Out-Null; Start-Sleep -Milliseconds 500 }
    $script:NS = "sl_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
    if ($Conf) {
        $file = Join-Path $TempHome "$($script:NS).conf"
        Set-Content -Path $file -Value $Conf
        $env:PSMUX_CONFIG_FILE = $file
    } else {
        $env:PSMUX_CONFIG_FILE = $EmptyConf
    }
    P new-session -d -s s -x 80 -y 10 | Out-Null
    Start-Sleep -Seconds 2
}

# The status_style of the frame the server sends for session `s`.
function Frame {
    $port = Get-ChildItem -Path $TempHome -Recurse -File -Filter "$($script:NS)__s.port" -EA SilentlyContinue | Select-Object -First 1
    if (-not $port) { return "(no port file)" }
    $key = Join-Path $port.DirectoryName "$($script:NS)__s.key"
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int](Get-Content $port.FullName -Raw).Trim())
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 8000
        $writer = [System.IO.StreamWriter]::new($stream); $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $((Get-Content $key -Raw).Trim())`n")
        $null = $reader.ReadLine()
        $writer.Write("dump-state`n")
        $json = $reader.ReadLine()
        $tcp.Close()
        return ($json | ConvertFrom-Json).status_style
    } catch { return "(error: $_)" }
}
function ShowG($name) { (P show -g $name) -join ' | ' }

Write-Host "`n=== Issue #948: status line options ===" -ForegroundColor Cyan
Write-Host "  exe: $(& $PSMUX -V | Select-Object -Last 1)"

Write-Host "`n[1] A new server" -ForegroundColor Yellow
Start-Server
Check "show -g status-bg" (ShowG status-bg) "status-bg default"
Check "show -g status-fg" (ShowG status-fg) "status-fg default"
Check "drawn with" (Frame) "bg=green,fg=black"

Write-Host "`n[2] From a config file" -ForegroundColor Yellow
Start-Server "set -g status-bg red`nset -g status-fg white"
Check "show -g status-bg" (ShowG status-bg) "status-bg red"
Check "show -g status-fg" (ShowG status-fg) "status-fg white"
Check "status-style is left as it is" (ShowG status-style) "status-style bg=green,fg=black"
Check "drawn with (white on red)" (Frame) "bg=green,fg=black,fg=white,bg=red"

Write-Host "`n[3] A later status-style does not replace status-bg" -ForegroundColor Yellow
Start-Server "set -g status-bg red`nset -g status-style bg=blue"
Check "drawn with (red)" (Frame) "bg=blue,bg=red"
Start-Server "set -g status-style bg=blue"
Check "without status-bg (blue)" (Frame) "bg=blue"

Write-Host "`n[4] At runtime" -ForegroundColor Yellow
Start-Server
P set -g status-bg red | Out-Null
Check "show -g status-bg" (ShowG status-bg) "status-bg red"
Check "status-style is left as it is" (ShowG status-style) "status-style bg=green,fg=black"
Check "#{status-bg}" ((P display -p '#{status-bg}') -join '') "red"
Start-Sleep -Milliseconds 300
Check "drawn with" (Frame) "bg=green,fg=black,bg=red"
P set -ga status-bg blue | Out-Null
Check "-a sets the colour given" (ShowG status-bg) "status-bg blue"
P set -gu status-bg | Out-Null
Check "after -u" (ShowG status-bg) "status-bg default"
Start-Sleep -Milliseconds 300
Check "drawn with after -u" (Frame) "bg=green,fg=black"

Write-Host "`n[5] Colours as tmux shows them" -ForegroundColor Yellow
foreach ($pair in @(@('1', 'red'), @('RED', 'red'), @('#FF0000', '#ff0000'), @('color5', 'colour5'), @('91', 'brightred'), @('terminal', 'terminal'))) {
    P set -g status-fg $pair[0] | Out-Null
    Check "status-fg $($pair[0])" (ShowG status-fg) "status-fg $($pair[1])"
}
Start-Sleep -Milliseconds 300
Check "terminal lays nothing over status-style" (Frame) "bg=green,fg=black"
P set -gu status-fg | Out-Null

Write-Host "`n[6] A bad colour" -ForegroundColor Yellow
Refused "status-bg nosuchcolour" "bad colour: nosuchcolour" @('set', '-g', 'status-bg', 'nosuchcolour')
Refused "status-fg colour300" "bad colour: colour300" @('set', '-g', 'status-fg', 'colour300')
Check "nothing set" (ShowG status-bg) "status-bg default"
Check "status-style untouched" (ShowG status-style) "status-style bg=green,fg=black"

Write-Host "`n[7] A bare show -g lists both" -ForegroundColor Yellow
P set -g status-bg red | Out-Null
Check "listed" ((@(P show -g) | Where-Object { $_ -like 'status-bg *' -or $_ -like 'status-fg *' }) -join ' | ') "status-bg red | status-fg default"

Write-Host "`n[8] The session's own value over the global one" -ForegroundColor Yellow
P set status-bg blue | Out-Null
Check "show status-bg" ((P show status-bg) -join '') "status-bg blue"
Check "show -g status-bg" (ShowG status-bg) "status-bg red"
Start-Sleep -Milliseconds 300
Check "drawn with the session's" (Frame) "bg=green,fg=black,bg=blue"

Write-Host "`n[9] status-justify and status-position" -ForegroundColor Yellow
Refused "status-justify middle" "unknown value: middle" @('set', '-g', 'status-justify', 'middle')
Refused "status-justify center" "unknown value: center" @('set', '-g', 'status-justify', 'center')
Refused "status-position middle" "unknown value: middle" @('set', '-g', 'status-position', 'middle')
Check "status-justify unchanged" (ShowG status-justify) "status-justify left"
Check "status-position unchanged" (ShowG status-position) "status-position bottom"
P set -g status-justify absolute-centre | Out-Null
Check "absolute-centre" (ShowG status-justify) "status-justify absolute-centre"

Write-Host "`n[10] The status lengths" -ForegroundColor Yellow
Refused "status-left-length 99999" "value is too large: 99999" @('set', '-g', 'status-left-length', '99999')
Refused "status-right-length 32768" "value is too large: 32768" @('set', '-g', 'status-right-length', '32768')
P set -g status-right-length 32767 | Out-Null
Check "status-right-length 32767" (ShowG status-right-length) "status-right-length 32767"
Check "status-left-length unchanged" (ShowG status-left-length) "status-left-length 10"

P kill-server | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item Env:PSMUX_CONFIG_FILE, Env:PSMUX_DATA_DIR, Env:PSMUX_NO_WARM -EA SilentlyContinue
Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
