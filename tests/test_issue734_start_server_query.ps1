# Issue #734: `start-server ; set-option -g exit-empty off` returned 0 and
# started a live standby, but the server it started could not be queried
# (`display-message -p '#{socket_path} #{pid}'` said "no server running"
# until a session existed), and the queued `set-option` never ran, so
# `exit-empty` was still `on` afterwards. oh-my-claudecode's detached team
# start holds an empty private server this way, captures its identity, then
# creates its session under a guard (`if-shell <guard> "new-session -d -P
# -F ..."`) and requires the session to be in that same server.
#
# tmux 3.4, measured in WSL (`tmux -L t734 ...`):
#   start-server \; set-option -g exit-empty off   rc 0
#   display-message -p '#{socket_path} #{pid}'      /tmp/tmux-1000/t734 428, rc 0
#   show-options -g exit-empty                      exit-empty off
#   list-sessions                                   (nothing), rc 0
#   new-session -d -s a ; display -p '#{pid}'       428 (same server)
#   plain start-server (exit-empty on)              server exits, display rc 1
#   kill-server of the empty server                 rc 0
# Sources: cmd-kill-server.c (start-server is CMD_STARTSERVER), client.c
# (CLIENT_STARTSERVER when any queued command has it, then the whole list is
# sent), server.c server_loop (exit-empty off keeps an empty server alive).
#
# Everything runs under a private PSMUX_DATA_DIR. The user's real default
# namespace is snapshotted before and after and must not change.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue734_start_server_query.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_SOCKET_PATH','PSMUX_TARGET_SESSION','PSMUX_TARGET_FULL','PSMUX_ROUTE_WARM') { Remove-Item "Env:\$v" -EA SilentlyContinue }

$realBefore = (& $PSMUX list-sessions -F '#{session_name}' 2>&1) -join "`n"

$savedDataDir = $env:PSMUX_DATA_DIR
$root = Join-Path $env:TEMP "psmux_i734_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$dataDir = $env:PSMUX_DATA_DIR

$TMUXBIN = Join-Path (Split-Path $PSMUX) "tmux.exe"
$sock = Join-Path $root "private.sock"
$sockT = Join-Path $root "tmuxexe.sock"
$sockG = Join-Path $root "guarded.sock"
$NS = "i734ns$PID"
$NSOFF = "i734on$PID"
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function Run([string]$exe, [string[]]$a) {
    $out = (& $exe @a 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ Out = $out; Rc = $LASTEXITCODE }
}

# The reporter's exact sequence, for one binary and one socket selector.
function Test-KeepaliveFlow([string]$exe, [string[]]$sel, [string]$label, [string]$expectPath) {
    Write-Host "`n=== $label ===" -ForegroundColor Yellow
    $r = Run $exe ($sel + @('-f','NUL','start-server',';','set-option','-g','exit-empty','off'))
    if ($r.Rc -eq 0 -and $r.Out -eq '') { Write-Pass "$label start-server ; set-option exits 0 with no output" }
    else { Write-Fail "$label start-server rc=$($r.Rc) out='$($r.Out)'" }

    $q = Run $exe ($sel + @('display-message','-p',"#{socket_path}`t#{pid}"))
    $fields = $q.Out -split "`t"
    $pid0 = if ($fields.Count -eq 2) { $fields[1] } else { '' }
    if ($q.Rc -eq 0 -and $fields.Count -eq 2 -and $pid0 -match '^\d+$') { Write-Pass "$label the empty server answers display-message ($($q.Out -replace "`t",' | '))" }
    else { Write-Fail "$label display-message before any session rc=$($q.Rc) '$($q.Out)'" }
    if ($fields[0] -eq $expectPath) { Write-Pass "$label #{socket_path} is the selected socket" }
    else { Write-Fail "$label #{socket_path} '$($fields[0])', expected '$expectPath'" }
    if ($pid0 -match '^\d+$' -and (Get-Process -Id ([int]$pid0) -EA SilentlyContinue)) { Write-Pass "$label #{pid} is a live process" }
    else { Write-Fail "$label #{pid} '$pid0' is not a live process" }

    $o = Run $exe ($sel + @('show-options','-g','exit-empty'))
    if ($o.Rc -eq 0 -and $o.Out -eq 'exit-empty off') { Write-Pass "$label the queued set-option ran (exit-empty off)" }
    else { Write-Fail "$label show-options -g exit-empty rc=$($o.Rc) '$($o.Out)'" }

    $ls = Run $exe ($sel + @('list-sessions'))
    if ($ls.Rc -eq 0 -and $ls.Out -eq '') { Write-Pass "$label list-sessions on the empty server: nothing, rc 0 (tmux parity)" }
    else { Write-Fail "$label list-sessions on the empty server rc=$($ls.Rc) '$($ls.Out)'" }

    Start-Sleep -Milliseconds 1500
    $again = Run $exe ($sel + @('display-message','-p','#{pid}'))
    if ($again.Rc -eq 0 -and $again.Out -eq $pid0) { Write-Pass "$label the empty server stays alive with exit-empty off" }
    else { Write-Fail "$label empty server after 1.5 s rc=$($again.Rc) '$($again.Out)'" }

    $n = Run $exe ($sel + @('-f','NUL','new-session','-d','-s','probe'))
    if ($n.Rc -eq 0) { Write-Pass "$label new-session after start-server exits 0" }
    else { Write-Fail "$label new-session rc=$($n.Rc) '$($n.Out)'" }
    $after = Run $exe ($sel + @('display-message','-t','probe','-p',"#{socket_path}`t#{pid}"))
    if ($after.Out -eq $q.Out) { Write-Pass "$label the session is in the same server (identity unchanged: pid $pid0)" }
    else { Write-Fail "$label identity changed: before '$($q.Out)' after '$($after.Out)'" }
    $o2 = Run $exe ($sel + @('show-options','-g','exit-empty'))
    if ($o2.Out -eq 'exit-empty off') { Write-Pass "$label exit-empty is still off after new-session" }
    else { Write-Fail "$label exit-empty after new-session '$($o2.Out)'" }

    $k = Run $exe ($sel + @('kill-server'))
    Start-Sleep -Milliseconds 500
    $gone = Run $exe ($sel + @('display-message','-p','#{pid}'))
    if ($k.Rc -eq 0 -and $gone.Rc -ne 0 -and -not (Get-Process -Id ([int]$pid0) -EA SilentlyContinue)) { Write-Pass "$label kill-server on that socket ends the server" }
    else { Write-Fail "$label kill-server rc=$($k.Rc), afterwards rc=$($gone.Rc) '$($gone.Out)'" }
}

try {
    Test-KeepaliveFlow $PSMUX @('-S',$sock) "psmux.exe -S" $sock
    if (Test-Path $TMUXBIN) { Test-KeepaliveFlow $TMUXBIN @('-S',$sockT) "tmux.exe -S" $sockT }
    else { Write-Fail "tmux.exe alias binary not found next to $PSMUX" }
    Test-KeepaliveFlow $PSMUX @('-L',$NS) "psmux.exe -L" ("{0}/{1}" -f $dataDir, $NS)

    Write-Host "`n=== OMC guarded creation: if-shell new-session -P in the held server ===" -ForegroundColor Yellow
    & $PSMUX -S $sockG start-server ';' set-option -g exit-empty off 2>&1 | Out-Null
    $id = (& $PSMUX -S $sockG display-message -p "#{socket_path}`t#{pid}" 2>&1) -join "`n"
    $gpid = ($id -split "`t")[-1]
    $fmt = "'#S:#{window_index}`t#{pane_id}`t#{socket_path}`t#{pid}'"
    $created = (& $PSMUX -S $sockG if-shell 'exit 0' "new-session -d -P -F $fmt -s omcteam -c '$root' 'pwsh -NoLogo -NoProfile'" 'display-message -p GUARD_FAIL' 2>&1) -join "`n"
    $rec = $created -split "`t"
    if ($rec.Count -eq 4 -and $rec[0] -eq 'omcteam:0' -and $rec[1] -match '^%\d+$' -and $rec[2] -eq $sockG -and $rec[3] -eq $gpid) {
        Write-Pass "the guarded new-session lands in the held server and reports it ($($created -replace "`t",' | '))"
    } else { Write-Fail "guarded new-session printed '$created' (held identity '$id')" }
    $restore = Run $PSMUX @('-S',$sockG,'set-option','-g','exit-empty','on')
    $still = Run $PSMUX @('-S',$sockG,'display-message','-t','omcteam','-p','#{pid}')
    if ($restore.Rc -eq 0 -and $gpid -match '^\d+$' -and $still.Out -eq $gpid) { Write-Pass "exit-empty restored to on, the session's server is the same process" }
    else { Write-Fail "after restoring exit-empty: rc=$($restore.Rc) pid '$($still.Out)'" }
    $defLs = Run $PSMUX @('list-sessions','-F','#{session_name}')
    if ($defLs.Out -notmatch '(?m)^omcteam$') { Write-Pass "the guarded session did not leak into the default namespace" }
    else { Write-Fail "omcteam appeared in the default namespace: $($defLs.Out)" }
    & $PSMUX -S $sockG kill-server 2>&1 | Out-Null

    Write-Host "`n=== a queued new-session runs in the started server ===" -ForegroundColor Yellow
    $q = Run $PSMUX @('-L',"$NS-q",'start-server',';','set','-g','exit-empty','off',';','new-session','-d','-s','z',';','display-message','-p','tail #{session_name}')
    if ($q.Rc -eq 0 -and $q.Out -eq 'tail z') { Write-Pass "start-server ; set ; new-session ; display runs the whole queue in order" }
    else { Write-Fail "queued commands rc=$($q.Rc) '$($q.Out)'" }
    & $PSMUX -L "$NS-q" kill-server 2>&1 | Out-Null

    Write-Host "`n=== exit-empty on: the empty server is not a server (tmux exits) ===" -ForegroundColor Yellow
    $p = Run $PSMUX @('-L',$NSOFF,'start-server')
    Start-Sleep -Milliseconds 1500
    $d = Run $PSMUX @('-L',$NSOFF,'display-message','-p','#{pid}')
    if ($p.Rc -eq 0 -and $d.Rc -ne 0) { Write-Pass "plain start-server leaves nothing to query, like tmux (rc=$($d.Rc))" }
    else { Write-Fail "plain start-server then display rc=$($d.Rc) '$($d.Out)'" }
    & $PSMUX -L $NSOFF start-server ';' set -g exit-empty off 2>&1 | Out-Null
    $d2 = Run $PSMUX @('-L',$NSOFF,'display-message','-p','#{pid}')
    & $PSMUX -L $NSOFF set -g exit-empty on 2>&1 | Out-Null
    $d3 = Run $PSMUX @('-L',$NSOFF,'display-message','-p','#{pid}')
    if ($d2.Rc -eq 0 -and $d3.Rc -ne 0) { Write-Pass "set -g exit-empty on withdraws the empty server (held $($d2.Out), then rc=$($d3.Rc))" }
    else { Write-Fail "exit-empty on: held rc=$($d2.Rc) '$($d2.Out)', after on rc=$($d3.Rc) '$($d3.Out)'" }
    & $PSMUX -L $NSOFF kill-server 2>&1 | Out-Null
} finally {
    foreach ($a in @(@('-S',$sock), @('-S',$sockT), @('-S',$sockG), @('-L',$NS), @('-L',"$NS-q"), @('-L',$NSOFF))) {
        & $PSMUX @a kill-server 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    # Anything still registered in the scratch data dir was started by this
    # test: stop exactly those pids, never anything by name.
    Get-ChildItem $dataDir -Filter *.pid -EA SilentlyContinue | ForEach-Object {
        $first = (Get-Content $_.FullName -EA SilentlyContinue | Select-Object -First 1)
        $p = 0
        if ($first -and [int]::TryParse(($first -split ':')[0], [ref]$p) -and $p -gt 0) {
            $proc = Get-Process -Id $p -EA SilentlyContinue
            if ($proc -and $proc.Path -and ((Split-Path $proc.Path -Leaf) -in @('psmux.exe','tmux.exe','pmux.exe'))) {
                Write-Info "stopping leftover scratch server $p ($($_.Name))"
                Stop-Process -Id $p -Force -EA SilentlyContinue
            }
        }
    }
    $env:PSMUX_DATA_DIR = $savedDataDir
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

$realAfter = (& $PSMUX list-sessions -F '#{session_name}' 2>&1) -join "`n"
if ($realAfter -eq $realBefore) { Write-Pass "the real default namespace is unchanged" }
else { Write-Fail "the real default namespace changed: before '$realBefore' after '$realAfter'" }

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
