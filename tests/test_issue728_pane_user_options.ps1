# Issue #728: pane scoped user options.
#
# THE REPORT
#
#     psmux set-option -p -t %1 @omx_team_pane_owner_id 1
#     psmux: pane-scoped option '@omx_team_pane_owner_id' is not supported
#            (supported: remain-on-exit, @mouse-force)                 exit 1
#
# tmux keeps an options table on every pane and puts any `@name` there. Codex
# `omx team` and the Claude Code teammate backend tag their panes this way and
# read the tag back with `show-options -qv -p -t %N @name` and `#{@name}` in
# list-panes -F.
#
# THE ORACLE (tmux 3.4 under WSL, `tmux -L t728ref -f /dev/null`)
#
#     set -p -t %0 @omx_team_pane_owner_id 1   rc 0
#     show -p -t %0                            "@omx_team_pane_owner_id 1"
#     show -qv -p -t %0 @omx...                "1"
#     show -v -p -t %1 @omx...                 "invalid option: @omx..." rc 1
#     show -qv -p -t %1 @omx...                "" rc 0
#     list-panes -F '#{pane_id} [#{@omx...}]'  "%0 [1]" / "%1 []"
#     display -p -t %0 '#{@omx...}'            "1"
#     set -g @omx... G                         "%0 [1]" / "%1 [G]"
#     show -pvA -t %1 @omx...                  "G" (inherited)
#     set -pu -t %0 @omx...                    "%0 [G]"
#     set -p @a x; set -pa @a y                "xy"
#     set -po @a z                             "already set: @a" rc 1
#     set -p bogus-opt 1                       rc 1
#     set -p -t %999 @x 1                      "no such pane: %999" rc 1
#     move-pane / break-pane / swap-pane       the value travels with the pane
#
# Usage: pwsh -NoProfile -File tests\test_issue728_pane_user_options.ps1
#        pwsh -NoProfile -File tests\test_issue728_pane_user_options.ps1 -Binary <path>

param([string]$Binary = "")

$ErrorActionPreference = "Continue"

$PSMUX = ""
if ($Binary) { $PSMUX = (Resolve-Path $Binary -EA SilentlyContinue).Path }
if (-not $PSMUX -and $env:PSMUX_TEST_BIN) { $PSMUX = (Resolve-Path $env:PSMUX_TEST_BIN -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$NS   = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i728$PID" }
$SESS = "t728"

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i728_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

# Run a binary with an exact argv and capture rc/out/err. The call operator,
# not Start-Process -Wait: PowerShell 7 waits for the whole process tree there,
# and new-session leaves a server running.
function Invoke-Bin([string]$Exe, [string[]]$ArgList) {
    $se = Join-Path $root "err.txt"
    $out = & $Exe @ArgList 2>$se
    $rc = $LASTEXITCODE
    [pscustomobject]@{
        rc  = $rc
        out = (@($out) -join "`n").TrimEnd("`r", "`n")
        err = "$(Get-Content $se -Raw -EA SilentlyContinue)".Trim()
    }
}
function Px([string[]]$ArgList) { Invoke-Bin $PSMUX (@('-L', $NS) + $ArgList) }
function Lines($r) { @($r.out -split "`r?`n" | Where-Object { $_ -ne '' }) }

# Raw TCP straight at the server, bypassing the CLI, so the server side parser
# and the persistent connection route are measured on their own.
function Send-Tcp([string]$Command, [switch]$Persistent) {
    try {
        $port = (Get-Content (Join-Path $env:PSMUX_DATA_DIR "${NS}__$SESS.port") -Raw).Trim()
        $key  = (Get-Content (Join-Path $env:PSMUX_DATA_DIR "${NS}__$SESS.key") -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 3000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $key")
        if ($rd.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAIL" }
        $wr.WriteLine($Command)
        # A one-shot reply is one send followed by the server's FIN, so read to
        # EOF. A DataAvailable check would stop after the first line, since the
        # whole reply is already in the StreamReader buffer. ReadTimeout bounds it.
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
            }
        } catch {}
        $tcp.Close()
        return ($lines -join "`n")
    } catch { return "TCP_ERROR: $($_.Exception.Message)" }
}

function Check($name, $cond, $detail) { if ($cond) { Write-Pass $name } else { Write-Fail "$name :: $detail" } }

Write-Host "`n=== Issue #728: pane scoped user options ===" -ForegroundColor Cyan
Write-Info ("psmux: {0}  ({1})  ns={2}" -f $PSMUX, ((& $PSMUX -V) -join ' '), $NS)

try {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    & $PSMUX -L $NS new-session -d -s $SESS -x 160 -y 40 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "new-session failed"; throw "setup" }
    & $PSMUX -L $NS split-window -t $SESS 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $panes = Lines (Px @('list-panes', '-t', $SESS, '-F', '#{pane_id}'))
    if ($panes.Count -ne 2) { Write-Fail "expected 2 panes, got '$($panes -join ',')'"; throw "setup" }
    $P1 = $panes[0]; $P2 = $panes[1]
    Write-Info "panes $P1 $P2"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 1] CLI: the reporter's exact commands" -ForegroundColor Yellow
    $r = Px @('set-option', '-p', '-t', $P1, '@omx_team_pane_owner_id', '1')
    Check "set-option -p -t $P1 @omx_team_pane_owner_id 1 is rc 0 with no stderr" ($r.rc -eq 0 -and $r.err -eq '') "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('show-options', '-p', '-t', $P1)
    Check "show-options -p lists the pane's user option" ((Lines $r) -contains '@omx_team_pane_owner_id 1') "out='$($r.out)'"
    $r = Px @('show-option', '-qv', '-p', '-t', $P1, '@omx_team_pane_owner_id')
    Check "show-option -qv -p reads the value back" ($r.rc -eq 0 -and $r.out -eq '1') "rc=$($r.rc) out='$($r.out)'"
    $r = Px @('show-option', '-v', '-p', '-t', $P2, '@omx_team_pane_owner_id')
    Check "show-option -v -p on a pane without it is 'invalid option' rc 1 (tmux 3.4)" ($r.rc -eq 1 -and $r.err -match 'invalid option: @omx_team_pane_owner_id') "rc=$($r.rc) err='$($r.err)' out='$($r.out)'"
    $r = Px @('show-option', '-qv', '-p', '-t', $P2, '@omx_team_pane_owner_id')
    Check "show-option -qv -p on a pane without it is empty rc 0" ($r.rc -eq 0 -and $r.out -eq '') "rc=$($r.rc) out='$($r.out)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 2] two panes, two values, format expansion" -ForegroundColor Yellow
    Px @('set-option', '-p', '-t', $P1, '@owner', 'lead') | Out-Null
    Px @('set-option', '-p', '-t', $P2, '@owner', 'worker two') | Out-Null
    $r = Px @('list-panes', '-t', $SESS, '-F', '#{pane_id} [#{@owner}] [#{@omx_team_pane_owner_id}]')
    $want = @("$P1 [lead] [1]", "$P2 [worker two] []")
    Check "list-panes -F expands each pane's own value" (((Lines $r) -join '|') -eq ($want -join '|')) "got '$((Lines $r) -join '|')' want '$($want -join '|')'"
    $r = Px @('display-message', '-p', '-t', $P2, '#{@owner}')
    Check "display-message -p -t $P2 expands that pane's value" ($r.out -eq 'worker two') "out='$($r.out)'"
    $r = Px @('display-message', '-p', '-t', $P1, '#{?#{==:#{@owner},lead},LEAD,other}')
    Check "a conditional over the pane value resolves for the target pane" ($r.out -eq 'LEAD') "out='$($r.out)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 3] inheritance: pane, then the session/global store" -ForegroundColor Yellow
    Px @('set-option', '-g', '@inh', 'G') | Out-Null
    Px @('set-option', '-p', '-t', $P1, '@inh', 'P') | Out-Null
    $r = Px @('list-panes', '-t', $SESS, '-F', '#{@inh}')
    Check "pane value wins, the other pane inherits the global" (((Lines $r) -join '|') -eq 'P|G') "got '$((Lines $r) -join '|')'"
    $r = Px @('show-option', '-pvA', '-t', $P2, '@inh')
    Check "show-option -pvA on the inheriting pane prints the parent value" ($r.out -eq 'G') "out='$($r.out)' err='$($r.err)'"
    $r = Px @('set-option', '-pu', '-t', $P1, '@inh')
    Check "set-option -pu is rc 0" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('list-panes', '-t', $SESS, '-F', '#{@inh}')
    Check "after -pu the pane falls back to the global value" (((Lines $r) -join '|') -eq 'G|G') "got '$((Lines $r) -join '|')'"
    $r = Px @('show-option', '-qv', '-p', '-t', $P1, '@inh')
    Check "after -pu the pane's own store is empty" ($r.out -eq '') "out='$($r.out)'"
    $r = Px @('show-option', '-gv', '@inh')
    Check "the global value was never touched by the pane writes" ($r.out -eq 'G') "out='$($r.out)'"
    $r = Px @('set-option', '-pu', '-t', $P1, '@never_set')
    Check "-pu of an option the pane never had is rc 0 (tmux 3.4)" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 4] -a / -o / -q" -ForegroundColor Yellow
    Px @('set-option', '-p', '-t', $P1, '@a', 'x') | Out-Null
    Px @('set-option', '-pa', '-t', $P1, '@a', 'y') | Out-Null
    $r = Px @('show-option', '-pv', '-t', $P1, '@a')
    Check "set -pa appends: xy" ($r.out -eq 'xy') "out='$($r.out)'"
    $r = Px @('set-option', '-po', '-t', $P1, '@a', 'z')
    Check "set -po on an owned option is 'already set' rc 1" ($r.rc -eq 1 -and $r.err -match 'already set: @a') "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('set-option', '-poq', '-t', $P1, '@a', 'z')
    Check "set -poq is silent rc 0" ($r.rc -eq 0 -and $r.err -eq '') "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('show-option', '-pv', '-t', $P1, '@a')
    Check "-o never overwrote the value" ($r.out -eq 'xy') "out='$($r.out)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 5] existing pane options and refusals unchanged" -ForegroundColor Yellow
    $r = Px @('set-option', '-p', '-t', $P1, 'bogus-opt', '1')
    Check "a non @ name psmux does not keep per pane is still refused rc 1" ($r.rc -eq 1 -and $r.err -match "bogus-opt") "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('set-option', '-p', '-t', $P1, 'remain-on-exit', 'on')
    Check "remain-on-exit still accepted" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('show-option', '-pv', '-t', $P1, 'remain-on-exit')
    Check "remain-on-exit reads back on" ($r.out -eq 'on') "out='$($r.out)'"
    Px @('set-option', '-pu', '-t', $P1, 'remain-on-exit') | Out-Null
    $r = Px @('set-option', '-p', '-t', $P1, '@mouse-force', 'loud')
    Check "@mouse-force keeps its on/off validation" ($r.rc -eq 1 -and $r.err -match 'bad value') "rc=$($r.rc) err='$($r.err)'"
    $r = Px @('set-option', '-p', '-t', $P1, '@mouse-force', 'on')
    Check "@mouse-force on accepted" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    Px @('set-option', '-pu', '-t', $P1, '@mouse-force') | Out-Null
    $r = Px @('set-option', '-p', '-t', '%999', '@x', '1')
    Check "a missing pane is rc 1" ($r.rc -eq 1 -and $r.err -match '999') "rc=$($r.rc) err='$($r.err)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 6] raw TCP route" -ForegroundColor Yellow
    $t = Send-Tcp "set-option -p -t $P2 @tcp tcpval"
    Check "TCP set-option -p @tcp answers with no error" ($t -notmatch 'ERROR|TCP_ERROR|AUTH_FAIL') "reply='$t'"
    $t = Send-Tcp "show-options -p -v -t $P2 @tcp"
    Check "TCP show-options -p -v reads it back" ($t.Trim() -eq 'tcpval') "reply='$t'"
    $t = Send-Tcp "set-option -pa -t $P2 @tcp 2"
    $t = Send-Tcp "show-options -p -v -t $P2 @tcp"
    Check "TCP set-option -pa appends" ($t.Trim() -eq 'tcpval2') "reply='$t'"
    $t = Send-Tcp "list-panes -t $SESS -F '#{pane_id}=#{@tcp}'"
    Check "TCP list-panes -F sees it on that pane only" ($t -match [regex]::Escape("$P1=") -and $t -match [regex]::Escape("$P2=tcpval2")) "reply='$t'"
    $t = Send-Tcp "show-options -p -v -t $P1 @tcp"
    Check "TCP show-options -p -v on a pane without it reports invalid option" ($t -match 'invalid option: @tcp') "reply='$t'"
    $t = Send-Tcp "set-option -pu -t $P2 @tcp"
    $t = Send-Tcp "show-options -p -q -v -t $P2 @tcp"
    Check "TCP set-option -pu removes it" ($t.Trim() -eq '') "reply='$t'"
    $t = Send-Tcp "set-option -p -t $P1 bogus-opt 1"
    Check "TCP refusal for a non @ name still says ERROR" ($t -match 'ERROR') "reply='$t'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 7] the option follows the pane between windows" -ForegroundColor Yellow
    & $PSMUX -L $NS new-window -d -t "${SESS}:" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Px @('set-option', '-p', '-t', $P2, '@mv', 'moved') | Out-Null
    # `-t :1`, not `-t t728:1`: under -L the CLI compares the bare session
    # name with the namespaced one and takes the cross session path, a
    # separate defect that has nothing to do with pane options.
    $r = Px @('move-pane', '-s', $P2, '-t', ':1')
    Check "move-pane -s $P2 -t :1 is rc 0" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    Start-Sleep -Milliseconds 400
    $r = Px @('list-panes', '-s', '-t', $SESS, '-F', '#{window_index} #{pane_id} [#{@mv}]')
    $line = (Lines $r) | Where-Object { $_ -match [regex]::Escape(" $P2 ") }
    Check "after move-pane the pane is in window 1 and keeps @mv" ($line -eq "1 $P2 [moved]") "lines='$((Lines $r) -join '|')'"
    $others = (Lines $r) | Where-Object { $_ -notmatch [regex]::Escape(" $P2 ") -and $_ -match 'moved' }
    Check "no other pane picked the value up" (@($others).Count -eq 0) "lines='$((Lines $r) -join '|')'"
    $r = Px @('break-pane', '-d', '-s', $P2)
    Check "break-pane -d -s $P2 is rc 0" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    Start-Sleep -Milliseconds 400
    $r = Px @('list-panes', '-s', '-t', $SESS, '-F', '#{window_index} #{pane_id} [#{@mv}]')
    $line = (Lines $r) | Where-Object { $_ -match [regex]::Escape(" $P2 ") }
    Check "after break-pane the pane is alone in a new window and keeps @mv" ($line -match "^\d+ $([regex]::Escape($P2)) \[moved\]$" -and $line -notmatch '^[01] ') "lines='$((Lines $r) -join '|')'"
    $r = Px @('swap-pane', '-s', $P1, '-t', $P2)
    Check "swap-pane -s $P1 -t $P2 is rc 0" ($r.rc -eq 0) "rc=$($r.rc) err='$($r.err)'"
    Start-Sleep -Milliseconds 400
    $r = Px @('list-panes', '-s', '-t', $SESS, '-F', '#{window_index} #{pane_id} [#{@mv}]')
    $l2 = (Lines $r) | Where-Object { $_ -match [regex]::Escape(" $P2 ") }
    $l1 = (Lines $r) | Where-Object { $_ -match [regex]::Escape(" $P1 ") }
    Check "after swap-pane $P2 sits in window 0 and still carries @mv" ($l2 -eq "0 $P2 [moved]") "lines='$((Lines $r) -join '|')'"
    Check "and $P1 did not take it" ($l1 -match "\[\]$") "lines='$((Lines $r) -join '|')'"
    $r = Px @('show-option', '-qv', '-p', '-t', $P2, '@mv')
    Check "show-option -qv -p follows the moved pane" ($r.out -eq 'moved') "out='$($r.out)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 8] a killed pane takes its options with it" -ForegroundColor Yellow
    Px @('set-option', '-p', '-t', $P1, '@gone', 'yes') | Out-Null
    Px @('kill-pane', '-t', $P1) | Out-Null
    Start-Sleep -Milliseconds 400
    $r = Px @('show-option', '-qv', '-p', '-t', $P1, '@gone')
    Check "show-option -p on the killed pane is a can't find pane error" ($r.rc -eq 1) "rc=$($r.rc) out='$($r.out)' err='$($r.err)'"
    $r = Px @('list-panes', '-s', '-t', $SESS, '-F', '[#{@gone}]')
    Check "no surviving pane expands the killed pane's value" (-not ($r.out -match 'yes')) "out='$($r.out)'"

    # -----------------------------------------------------------------------
    Write-Host "[Arm 9] the tmux alias binary" -ForegroundColor Yellow
    $tmuxExe = Join-Path (Split-Path $PSMUX) "tmux.exe"
    if (-not (Test-Path $tmuxExe)) {
        Write-Skip "tmux.exe not next to $PSMUX"
    } else {
        $r = Invoke-Bin $tmuxExe @('-L', $NS, 'set-option', '-p', '-t', $P2, '@via_tmux', 'T1')
        Check "tmux.exe set-option -p @via_tmux is rc 0" ($r.rc -eq 0 -and $r.err -eq '') "rc=$($r.rc) err='$($r.err)'"
        $r = Invoke-Bin $tmuxExe @('-L', $NS, 'show-options', '-qv', '-p', '-t', $P2, '@via_tmux')
        Check "tmux.exe show-options -qv -p reads it back" ($r.out -eq 'T1') "out='$($r.out)'"
        $r = Invoke-Bin $tmuxExe @('-L', $NS, 'display-message', '-p', '-t', $P2, '#{@via_tmux}')
        Check "tmux.exe display-message expands it" ($r.out -eq 'T1') "out='$($r.out)'"
    }
} catch {
    if ("$_" -ne 'setup') { Write-Fail "unexpected: $_" }
} finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
