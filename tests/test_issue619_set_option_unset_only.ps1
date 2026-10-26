# Issue #619 item 2: `set-option -o` after `set-option -u` was silently
# ignored for every option except the two that PR #617 repaired.
#
# psmux tracks "the user set this explicitly" in AppState::user_set_options,
# and `-o` (only set if not already set) consults that set. The unset branch
# erased the entry only for window-style and window-active-style, so for every
# other non `@` option the key survived `-u` and `-o` still read the option as
# set. The sequence
#
#     set-option -g  escape-time 5
#     set-option -gu escape-time
#     set-option -go escape-time 77
#
# left escape-time at its 500 ms default and dropped the 77 on the floor, at
# exit code 0, on the CLI route, the TCP route and the config-file route alike.
#
# tmux (cmd-set-option.c) skips the -o guard when -u is present, and otherwise
# judges -o by `already = (o != NULL)` where o = options_get_only(oo, name).
# `-u` calls options_remove_or_default first, which clears the option at that
# scope, so a following `-o` finds nothing set and applies.
#
# A @user option carries no options-table entry, so options.c
# options_remove_or_default takes its options_remove branch and deletes the key
# outright. psmux now does the same, because `-o` tests user options by key
# presence and an entry left holding "" would read as set for ever.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue619_set_option_unset_only.ps1

$ErrorActionPreference = "Continue"

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$SESSION   = "test_issue619"
$TUISESS   = "test_issue619tui"
$CFGSESS   = "test_issue619cfg"
$PSMUX_DIR = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

# Run psmux with an exact argv (no shell re-tokenizing) and capture rc/out/err.
function Invoke-Psmux([string[]]$ArgList) {
    $so = Join-Path $env:TEMP "t619_out.txt"
    $se = Join-Path $env:TEMP "t619_err.txt"
    $proc = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $so -RedirectStandardError $se
    [pscustomobject]@{
        rc  = $proc.ExitCode
        out = "$(Get-Content $so -Raw -ErrorAction SilentlyContinue)".Trim()
        err = "$(Get-Content $se -Raw -ErrorAction SilentlyContinue)".Trim()
    }
}
function Read-Opt($sess, $name) { (Invoke-Psmux @('show-options','-qv','-t',$sess,$name)).out }

# Raw TCP straight to the server, bypassing the CLI guard entirely, so the
# server-side request handler is measured on its own.
function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $port = (Get-Content "$PSMUX_DIR\$Session.port" -Raw).Trim()
        $key  = (Get-Content "$PSMUX_DIR\$Session.key" -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $ns = $tcp.GetStream()
        $ns.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($ns); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($ns)
        $wr.WriteLine("AUTH $key")
        $auth = $rd.ReadLine()
        if ($auth -ne "OK") { $tcp.Close(); return @{ ok=$false; err="AUTH_FAIL" } }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $tcp.Close()
        return @{ ok=$true; resp=($lines -join "`n"); lines=$lines }
    } catch { return @{ ok=$false; err=$_.Exception.Message } }
}

function Wait-SessionReady([string]$Name, [int]$TimeoutMs = 20000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $PSMUX has-session -t $Name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# set / unset / only-if-unset, then read the value back. Returns the value the
# option holds after the -o, which must be $Second for every option class.
function Test-UnsetThenOnlyIfUnset {
    param(
        [string]$Label,
        [string]$Verb,        # set-option, setw, set-window-option
        [string]$SetFlag,     # -g, -s, or empty for session scope
        [string]$Option,
        [string]$First,
        [string]$Second
    )
    $setArgs   = @($Verb)
    $unsetArgs = @($Verb)
    $onlyArgs  = @($Verb)
    if ($SetFlag) {
        $setArgs   += $SetFlag
        $unsetArgs += ($SetFlag + 'u')
        $onlyArgs  += ($SetFlag + 'o')
    } else {
        $unsetArgs += '-u'
        $onlyArgs  += '-o'
    }
    $setArgs   += @('-t', $SESSION, $Option, $First)
    $unsetArgs += @('-t', $SESSION, $Option)
    $onlyArgs  += @('-t', $SESSION, $Option, $Second)

    $r1 = Invoke-Psmux $setArgs
    $v1 = Read-Opt $SESSION $Option
    $r2 = Invoke-Psmux $unsetArgs
    $v2 = Read-Opt $SESSION $Option
    $r3 = Invoke-Psmux $onlyArgs
    $v3 = Read-Opt $SESSION $Option

    Write-Info "$Label : set=[$v1] after-u=[$v2] after-o=[$v3] rc=$($r1.rc)/$($r2.rc)/$($r3.rc)"
    if ($v3 -eq $Second) {
        Write-Pass "$Label : -o after -u applied ($Second)"
    } else {
        Write-Fail "$Label : -o after -u was swallowed, value stayed [$v3], expected [$Second]"
    }
}

$env:PSMUX_NO_WARM = "1"
$env:PSMUX_SESSION_NAME = $null

Write-Host "`n=== Issue #619: set-option -o after set-option -u ===" -ForegroundColor Cyan
Write-Info "Binary: $PSMUX"

foreach ($s in @($SESSION, $TUISESS, $CFGSESS)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800

& $PSMUX new-session -d -s $SESSION
if (-not (Wait-SessionReady $SESSION)) { Write-Fail "session creation failed"; exit 1 }

# ---------------------------------------------------------------------------
# Arm 1: the reported sequence, one representative option per value type.
# ---------------------------------------------------------------------------
Write-Host "[Arm 1] CLI: one option per value type" -ForegroundColor Yellow

Test-UnsetThenOnlyIfUnset -Label "int escape-time"     -Verb 'set-option' -SetFlag '-g' -Option 'escape-time'   -First '5'      -Second '77'
Test-UnsetThenOnlyIfUnset -Label "int history-limit"   -Verb 'set-option' -SetFlag '-g' -Option 'history-limit' -First '1234'   -Second '4321'
Test-UnsetThenOnlyIfUnset -Label "string status-left"  -Verb 'set-option' -SetFlag '-g' -Option 'status-left'   -First 'AAA'    -Second 'ZZZ'
Test-UnsetThenOnlyIfUnset -Label "style status-style"  -Verb 'set-option' -SetFlag '-g' -Option 'status-style'  -First 'fg=red' -Second 'fg=blue'
# mouse defaults to on, so `-go off` staying on was the visible symptom.
Test-UnsetThenOnlyIfUnset -Label "bool mouse"          -Verb 'set-option' -SetFlag '-g' -Option 'mouse'         -First 'on'     -Second 'off'
Test-UnsetThenOnlyIfUnset -Label "@user option"        -Verb 'set-option' -SetFlag '-g' -Option '@i619u'        -First 'one'    -Second 'two'

# ---------------------------------------------------------------------------
# Arm 2: every scope spelling.
# ---------------------------------------------------------------------------
Write-Host "[Arm 2] scope spellings: session, setw, set-window-option, -s" -ForegroundColor Yellow

Test-UnsetThenOnlyIfUnset -Label "session scope, no -g" -Verb 'set-option'        -SetFlag ''   -Option 'escape-time'             -First '5'  -Second '66'
Test-UnsetThenOnlyIfUnset -Label "setw window option"   -Verb 'setw'              -SetFlag '-g' -Option 'window-status-separator' -First 'XX' -Second 'YY'
Test-UnsetThenOnlyIfUnset -Label "set-window-option"    -Verb 'set-window-option' -SetFlag '-g' -Option 'window-status-separator' -First 'PP' -Second 'QQ'
# -s is the server scope #618 added; it resolves to the same single store as -g.
Test-UnsetThenOnlyIfUnset -Label "server scope -s"      -Verb 'set-option'        -SetFlag '-s' -Option 'default-terminal'        -First 'xterm-256color' -Second 'screen-256color'
Test-UnsetThenOnlyIfUnset -Label "server scope @option" -Verb 'set-option'        -SetFlag '-s' -Option '@i619s'                  -First 'sone' -Second 'stwo'

# ---------------------------------------------------------------------------
# Arm 3: the #617 pair must keep working, the generic erase subsumes it.
# ---------------------------------------------------------------------------
Write-Host "[Arm 3] window-style and window-active-style (#617 must not regress)" -ForegroundColor Yellow

Test-UnsetThenOnlyIfUnset -Label "window-style"        -Verb 'set-option' -SetFlag '-g' -Option 'window-style'        -First 'bg=black' -Second 'bg=colour235'
Test-UnsetThenOnlyIfUnset -Label "window-active-style" -Verb 'set-option' -SetFlag '-g' -Option 'window-active-style' -First 'bg=black' -Second 'bg=colour236'

# ---------------------------------------------------------------------------
# Arm 4: the -o guard is still armed. -o on a SET option is a no-op, and -u
# present in the same token wins over -o (tmux skips the guard when -u is set).
# ---------------------------------------------------------------------------
Write-Host "[Arm 4] the guard is still armed" -ForegroundColor Yellow

Invoke-Psmux @('set-option','-g','-t',$SESSION,'escape-time','11') | Out-Null
$r = Invoke-Psmux @('set-option','-go','-t',$SESSION,'escape-time','22')
$v = Read-Opt $SESSION 'escape-time'
if ($v -eq '11') { Write-Pass "-o on an already-set option is still a no-op (value stayed 11)" }
else { Write-Fail "-o overwrote a set option: escape-time=[$v], expected 11" }

$r = Invoke-Psmux @('set-option','-goq','-t',$SESSION,'escape-time','33')
$v = Read-Opt $SESSION 'escape-time'
if ($r.rc -eq 0 -and $v -eq '11') { Write-Pass "-o with -q is a quiet no-op at rc 0" }
else { Write-Fail "-goq: rc=$($r.rc) escape-time=[$v]" }

Invoke-Psmux @('set-option','-g','-t',$SESSION,'status-left','PRE') | Out-Null
$r = Invoke-Psmux @('set-option','-guo','-t',$SESSION,'status-left','NEVER')
$v = Read-Opt $SESSION 'status-left'
if ($v -ne 'NEVER') { Write-Pass "-u in the same token wins over -o, so nothing was set (tmux parity)" }
else { Write-Fail "-guo set the value; tmux skips the -o guard when -u is present" }

$r = Invoke-Psmux @('set-option','-go','-t',$SESSION,'@i619fresh','freshvalue')
$v = Read-Opt $SESSION '@i619fresh'
if ($r.rc -eq 0 -and $v -eq 'freshvalue') { Write-Pass "-o on a never-set option still applies" }
else { Write-Fail "-o on a fresh option: rc=$($r.rc) value=[$v]" }

# ---------------------------------------------------------------------------
# Arm 5: raw TCP, straight at the server request handler.
# ---------------------------------------------------------------------------
Write-Host "[Arm 5] raw TCP to the server" -ForegroundColor Yellow

$r = Send-TcpCommand $SESSION 'set-option -g @i619tcp one'
if (-not $r.ok) {
    Write-Fail "TCP connect failed: $($r.err)"
} else {
    Send-TcpCommand $SESSION 'set-option -gu @i619tcp' | Out-Null
    Send-TcpCommand $SESSION 'set-option -go @i619tcp two' | Out-Null
    Start-Sleep -Milliseconds 400
    $v = "$((Send-TcpCommand $SESSION 'show-options -qv @i619tcp').resp)".Trim()
    if ($v -eq 'two') { Write-Pass "TCP: -go after -gu applied on a @user option" }
    else { Write-Fail "TCP @user option: read back [$v], expected two" }

    Send-TcpCommand $SESSION 'set-option -g escape-time 7'  | Out-Null
    Send-TcpCommand $SESSION 'set-option -gu escape-time'   | Out-Null
    Send-TcpCommand $SESSION 'set-option -go escape-time 99' | Out-Null
    Start-Sleep -Milliseconds 400
    $v = "$((Send-TcpCommand $SESSION 'show-options -qv escape-time').resp)".Trim()
    if ($v -eq '99') { Write-Pass "TCP: -go after -gu applied on escape-time" }
    else { Write-Fail "TCP escape-time: read back [$v], expected 99" }
}

# ---------------------------------------------------------------------------
# Arm 6: the config-file route, which is a separate parser
# (src/config.rs parse_set_option).
# ---------------------------------------------------------------------------
Write-Host "[Arm 6] config file route" -ForegroundColor Yellow

$conf = Join-Path $env:TEMP "psmux_619.conf"
@"
set -g escape-time 5
set -gu escape-time
set -go escape-time 77
set -g status-left AAA
set -gu status-left
set -go status-left ZZZ
set -g @i619c one
set -gu @i619c
set -go @i619c two
setw -g window-status-separator XX
setw -gu window-status-separator
setw -go window-status-separator YY
set -s default-terminal xterm-256color
set -su default-terminal
set -so default-terminal screen-256color
"@ | Set-Content -Path $conf -Encoding ASCII

$env:PSMUX_CONFIG_FILE = $conf
& $PSMUX new-session -d -s $CFGSESS
$ready = Wait-SessionReady $CFGSESS
Remove-Item env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue

if (-not $ready) {
    Write-Fail "config-file session did not start"
} else {
    Start-Sleep -Milliseconds 800
    $checks = @(
        @{ opt = 'escape-time';             want = '77' },
        @{ opt = 'status-left';             want = 'ZZZ' },
        @{ opt = '@i619c';                  want = 'two' },
        @{ opt = 'window-status-separator'; want = 'YY' },
        @{ opt = 'default-terminal';        want = 'screen-256color' }
    )
    foreach ($c in $checks) {
        $v = Read-Opt $CFGSESS $c.opt
        if ($v -eq $c.want) { Write-Pass "config: -go after -gu applied to $($c.opt) = $v" }
        else { Write-Fail "config: $($c.opt) = [$v], expected [$($c.want)]" }
    }
}
& $PSMUX kill-session -t $CFGSESS 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# Arm 7 (Layer 2, Win32 TUI): the same sequence against a REAL attached client
# in its own console window, read back through display-message so the value is
# proven live in the server that client is talking to, not just in a one-shot
# CLI round trip.
# ---------------------------------------------------------------------------
Write-Host "[Arm 7] attached client (Win32 TUI visual verification)" -ForegroundColor Yellow

# A .cmd wrapper, because the agent shell exports PSMUX_SESSION_NAME and the
# launched client would otherwise route into the wrong session.
$launcher = Join-Path $env:TEMP "psmux_619_launch.cmd"
@"
@echo off
set PSMUX_SESSION_NAME=
set PSMUX_NO_WARM=1
"$PSMUX" new-session -s %1 -x 120 -y 30
"@ | Set-Content -Path $launcher -Encoding ASCII

$client = Start-Process -FilePath $launcher -ArgumentList @($TUISESS) -PassThru
if (-not (Wait-SessionReady $TUISESS 25000)) {
    Write-Fail "attached client never came up"
} else {
    Start-Sleep -Seconds 3

    # A @user option, read back through the format engine on the live client.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'@i619tui','one')  | Out-Null
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'@i619tui')       | Out-Null
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'@i619tui','two')
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{@i619tui}')
    if ($r.rc -eq 0 -and $dm.out -eq 'two') {
        Write-Pass "attached client: -go after -gu applied, display-message reports $($dm.out)"
    } else { Write-Fail "TUI @user option: rc=$($r.rc) display-message=[$($dm.out)]" }

    # A built-in option, read back the same way.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'status-left','AAA') | Out-Null
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'status-left')      | Out-Null
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'status-left','LIVE')
    Start-Sleep -Milliseconds 700
    $v = Read-Opt $TUISESS 'status-left'
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{status-left}')
    if ($r.rc -eq 0 -and $v -eq 'LIVE') {
        Write-Pass "attached client: status-left is live at LIVE after -gu then -go (display-message: [$($dm.out)])"
    } else { Write-Fail "TUI status-left: rc=$($r.rc) show=[$v] display-message=[$($dm.out)]" }

    # window-style, the #617 pair, against the live renderer.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'window-style','bg=black') | Out-Null
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'window-style')           | Out-Null
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'window-style','bg=colour235')
    Start-Sleep -Milliseconds 700
    $v = Read-Opt $TUISESS 'window-style'
    if ($r.rc -eq 0 -and $v -eq 'bg=colour235') {
        Write-Pass "attached client: window-style still settable after -u (#617 intact)"
    } else { Write-Fail "TUI window-style: rc=$($r.rc) value=[$v]" }
}

& $PSMUX kill-session -t $TUISESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
# Stop only the client we launched, by PID. Never a blanket kill by name.
if ($client -and -not $client.HasExited) {
    try { Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue } catch {}
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
