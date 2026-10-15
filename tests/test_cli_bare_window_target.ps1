# The CLI routed a bare `-t` of a window or pane command as a SESSION name:
# `psmux rename-window -t w2 x` and `psmux kill-window -t 2` died with "no
# server running on session '<ns>__w2'". tmux reads a target without a colon
# or period as the window (or pane) part in the current session before it
# tries it as a session (cmd-find.c:1093 to :1110, cmd_find_get_window and
# cmd_find_get_pane). `-t @id`, `-t :name` and `-t sess:name` already worked.
#
# Every command runs against a fresh session with windows w0 (current), w1,
# w2, w3 in a private -L namespace; cleanup with `psmux -L <ns> kill-server`.

$ErrorActionPreference = 'Continue'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "psmux: $PSMUX ($(& $PSMUX -V))"
$ns = 'clibw_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
function P { & $PSMUX -L $ns @args 2>&1 }
function Fresh {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 300
    P new-session -d -s s -n w0 | Out-Null
    P set -g automatic-rename off | Out-Null
    P set -g base-index 0 | Out-Null
    foreach ($n in 'w1', 'w2', 'w3') { P new-window -d -n $n | Out-Null }
    Start-Sleep -Milliseconds 800
}
function State { return ((P list-windows -F '#{window_name}#{?window_active,*,}') -join ' ') }
function Run([string]$label, [string[]]$a, [string]$expectState, [string]$expectOut = $null) {
    Fresh
    $o = ((P @a) | ForEach-Object { "$_" }) -join ' / '
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 500
    $st = State
    $ok = ($rc -eq 0) -and ($st -eq $expectState) -and ($null -eq $expectOut -or $o -eq $expectOut)
    if ($ok) { Write-Pass "$label -> $st" } else { Write-Fail "$label -> rc=$rc out='$o' state='$st' (want '$expectState'$(if ($expectOut) { ", out '$expectOut'" }))" }
}

try {
    Write-Host "`n[1] bare window names and indexes" -ForegroundColor Yellow
    foreach ($t in 'w2', '2') {
        Run "rename-window -t $t" @('rename-window', '-t', $t, 'RN') 'w0* w1 RN w3'
        Run "select-window -t $t" @('select-window', '-t', $t) 'w0 w1 w2* w3'
        Run "kill-window -t $t" @('kill-window', '-t', $t) 'w0* w1 w3'
        Run "unlink-window -k -t $t" @('unlink-window', '-k', '-t', $t) 'w0* w1 w3'
        Run "swap-window -s :w1 -t $t" @('swap-window', '-s', ':w1', '-t', $t) 'w0* w2 w1 w3'
        Run "display-message -t $t" @('display-message', '-t', $t, '-p', '#{window_name}') 'w0* w1 w2 w3' 'w2'
        Run "kill-pane -t $t" @('kill-pane', '-t', $t) 'w0* w1 w3'
    }
    Run "respawn-window -k -t w2" @('respawn-window', '-k', '-t', 'w2') 'w0* w1 w2 w3'
    Run "rotate-window -t w2" @('rotate-window', '-t', 'w2') 'w0* w1 w2 w3'

    Write-Host "`n[2] the forms that already worked still do" -ForegroundColor Yellow
    foreach ($t in '@3', ':w2', 's:w2') {
        Run "rename-window -t $t" @('rename-window', '-t', $t, 'RN') 'w0* w1 RN w3'
        Run "kill-window -t $t" @('kill-window', '-t', $t) 'w0* w1 w3'
    }

    Write-Host "`n[3] a name naming nothing is an error and changes nothing" -ForegroundColor Yellow
    foreach ($c in @(@('rename-window', '-t', 'nosuch', 'RN'), @('kill-window', '-t', 'nosuch'), @('kill-pane', '-t', 'nosuch'))) {
        Fresh
        $o = ((P @c) | ForEach-Object { "$_" }) -join ' / '
        $rc = $LASTEXITCODE
        Start-Sleep -Milliseconds 400
        $st = State
        if ($rc -ne 0 -and $o -match "can't find (window|pane): nosuch" -and $st -eq 'w0* w1 w2 w3') { Write-Pass "$($c -join ' ') -> rc=$rc '$o'" }
        else { Write-Fail "$($c -join ' ') -> rc=$rc '$o' state '$st'" }
    }

    Write-Host "`n[4] a bare session name still names that session" -ForegroundColor Yellow
    Fresh
    P new-session -d -s other -n o0 | Out-Null
    Start-Sleep -Milliseconds 800
    $o = ((P display-message -t other -p '#{session_name}:#{window_name}') -join '').Trim()
    if ($o -eq 'other:o0') { Write-Pass "display-message -t other -> $o" } else { Write-Fail "display-message -t other -> '$o'" }
} catch {
    Write-Fail "exception: $_"
} finally {
    P kill-server | Out-Null
}

Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
