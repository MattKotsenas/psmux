# Issue #730: `-S <socket-path>` was silently ignored, so every `-S` command
# reached the DEFAULT server (kill-server included), and `#{socket_path}` was
# always `<psmux_dir>/default`, even under `-L`.
#
# tmux semantics (tmux.c main, make_label; format.c socket_path):
#   -S path   selects the server at exactly that path, and wins over -L
#   -L label  selects <socket dir>/<label>
#   #{socket_path} is the path of the server that answered, and the first
#   field of $TMUX in its panes is that same path.
#
# Everything runs under a private PSMUX_DATA_DIR, so the "default server" this
# test creates (and the one the bug reached) is a scratch one; the user's real
# default namespace is snapshotted before and after and must not change.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue730_socket_path.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i730ns$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_SOCKET_PATH','PSMUX_TARGET_SESSION') { Remove-Item "Env:\$v" -EA SilentlyContinue }

# The user's real default namespace, before anything happens.
$realBefore = (& $PSMUX list-sessions -F '#{session_name}' 2>&1) -join "`n"

$savedDataDir = $env:PSMUX_DATA_DIR
$root = Join-Path $env:TEMP "psmux_i730_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$dataDir = $env:PSMUX_DATA_DIR

$TMUXBIN = Join-Path (Split-Path $PSMUX) "tmux.exe"
$sockA = Join-Path $root "a.sock"
$sockB = Join-Path $root "b.sock"
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function Q([string[]]$a) { ((& $PSMUX @a 2>&1) | ForEach-Object { "$_" }) -join "`n" }
function Wait-Pane([string[]]$sel, [string]$sess, [string]$pattern) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $cap = (& $PSMUX @sel capture-pane -p -t $sess 2>&1) -join "`n"
        if ($cap -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

try {
    Write-Host "`n=== -S creates its own server, not the default one ===" -ForegroundColor Yellow
    & $PSMUX new-session -d -s base730 2>&1 | Out-Null
    $defPid = Q @('display-message','-t','base730','-p','#{pid}')
    & $PSMUX -S $sockA new-session -d -s probe 2>&1 | Out-Null
    $aPid = Q @('-S',$sockA,'display-message','-p','#{pid}')
    Write-Info "default pid=$defPid  -S pid=$aPid"
    if ($aPid -match '^\d+$' -and $aPid -ne $defPid) { Write-Pass "-S server is a different server from the default one" }
    else { Write-Fail "-S answered from the default server (default=$defPid, -S=$aPid)" }
    $defLs = Q @('list-sessions','-F','#{session_name}')
    if ($defLs -notmatch '(?m)^probe$') { Write-Pass "the -S session is not listed in the default namespace" }
    else { Write-Fail "the -S session shows up in the default namespace: $defLs" }
    $aLs = Q @('-S',$sockA,'list-sessions','-F','#{session_name}')
    if ($aLs -match '(?m)^probe$' -and $aLs -notmatch 'base730') { Write-Pass "-S list-sessions shows only its own session" }
    else { Write-Fail "-S list-sessions: $aLs" }
    $has = & $PSMUX -S $sockA has-session -t probe 2>&1; $hasRc = $LASTEXITCODE
    $hasBase = & $PSMUX -S $sockA has-session -t base730 2>&1; $hasBaseRc = $LASTEXITCODE
    if ($hasRc -eq 0 -and $hasBaseRc -ne 0) { Write-Pass "-S has-session sees its own session and not the default one" }
    else { Write-Fail "-S has-session probe rc=$hasRc base730 rc=$hasBaseRc" }

    Write-Host "`n=== the same path reaches the same server ===" -ForegroundColor Yellow
    $alt = $sockA.Replace([string][char]92, '/').ToUpper()
    $altPid = Q @('-S',$alt,'display-message','-p','#{pid}')
    if ($altPid -eq $aPid) { Write-Pass "another spelling of the path reaches the same server ($altPid)" }
    else { Write-Fail "'$alt' answered $altPid, expected $aPid" }
    & $PSMUX -S $sockA new-session -d -s probe2 2>&1 | Out-Null
    $two = Q @('-S',$sockA,'list-sessions','-F','#{session_name}')
    if ($two -match '(?m)^probe$' -and $two -match '(?m)^probe2$') { Write-Pass "a second -S new-session joins the same namespace" }
    else { Write-Fail "second -S session missing: $two" }
    $p2Path = Q @('-S',$sockA,'display-message','-t','probe2','-p','#{socket_path}')
    if ($p2Path -eq $sockA) { Write-Pass "the second -S session (warm claim or cold) reports the -S path" }
    else { Write-Fail "second -S session socket_path '$p2Path'" }
    $bPid = Q @('-S',$sockB,'display-message','-p','#{pid}')
    $bRc = $LASTEXITCODE
    if ($bRc -ne 0 -and $bPid -match [regex]::Escape($sockB)) { Write-Pass "an unused -S path has no server (rc=${bRc}, $bPid)" }
    else { Write-Fail "an unused -S path answered: $bPid" }

    Write-Host "`n=== #{socket_path} names the server that answered ===" -ForegroundColor Yellow
    $sp = Q @('-S',$sockA,'display-message','-p','#{socket_path}')
    if ($sp -eq $sockA) { Write-Pass "-S: #{socket_path} is the given path" }
    else { Write-Fail "-S: #{socket_path} '$sp', expected '$sockA'" }
    $dp = Q @('display-message','-t','base730','-p','#{socket_path}')
    if ($dp -eq "$dataDir/default") { Write-Pass "default: #{socket_path} is <psmux_dir>/default" }
    else { Write-Fail "default: #{socket_path} '$dp'" }
    & $PSMUX -L $NS new-session -d -s lsess 2>&1 | Out-Null
    $lp = Q @('-L',$NS,'display-message','-p','#{socket_path}')
    if ($lp -eq "$dataDir/$NS") { Write-Pass "-L: #{socket_path} is <psmux_dir>/<label>" }
    else { Write-Fail "-L: #{socket_path} '$lp', expected '$dataDir/$NS'" }
    $lpid = Q @('-L',$NS,'display-message','-p','#{pid}')
    $lpViaS = Q @('-S',$lp,'display-message','-p','#{pid}')
    if ($lpViaS -eq $lpid) { Write-Pass "-S with the -L server's #{socket_path} reaches the -L server" }
    else { Write-Fail "-S '$lp' answered $lpViaS, -L answered $lpid" }
    $dpViaS = Q @('-S',$dp,'display-message','-p','#{pid}')
    if ($dpViaS -eq $defPid) { Write-Pass "-S with the default server's #{socket_path} reaches the default server" }
    else { Write-Fail "-S '$dp' answered $dpViaS, default is $defPid" }
    $both = Q @('-L',$NS,'-S',$sockA,'display-message','-t','probe','-p','#{pid}')
    if ($both -eq $aPid) { Write-Pass "-S wins over -L, as in tmux" }
    else { Write-Fail "-L $NS -S a answered $both, expected $aPid" }

    Write-Host "`n=== `$TMUX inside a -S pane ===" -ForegroundColor Yellow
    $out = Join-Path $root "inpane.txt"
    $cmd = "`$f='$out'; `"TMUX=`$env:TMUX`" | Out-File `$f; `"SPATH=[`$env:PSMUX_SOCKET_PATH]`" | Out-File -Append `$f; & '$PSMUX' -S (`$env:TMUX -split ',')[0] display-message -t probe -p 'VIAS=#{pid}' | Out-File -Append `$f; & '$PSMUX' display-message -p 'BARE=#{pid}' | Out-File -Append `$f; 'DONE' | Out-File -Append `$f"
    [void](Wait-Pane @('-S',$sockA) 'probe' '>\s*$')
    & $PSMUX -S $sockA send-keys -t probe $cmd Enter 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000 -and -not ((Get-Content $out -EA SilentlyContinue) -contains 'DONE')) { Start-Sleep -Milliseconds 200 }
    $lines = @(Get-Content $out -EA SilentlyContinue)
    Write-Info ($lines -join ' | ')
    $tm = ($lines | Where-Object { $_ -like 'TMUX=*' } | Select-Object -First 1)
    if ($tm -and $tm.Substring(5).Split(',')[0] -eq $sockA) { Write-Pass "`$TMUX first field is the -S path" }
    else { Write-Fail "`$TMUX in the -S pane: $tm" }
    if ($lines -contains 'SPATH=[]') { Write-Pass "the server's PSMUX_SOCKET_PATH does not leak into the pane" }
    else { Write-Fail "pane environment: $($lines -join ' | ')" }
    if ($lines -contains "VIAS=$aPid") { Write-Pass "-S `"`${TMUX%%,*}`" from the pane reaches its own server" }
    else { Write-Fail "-S from `$TMUX: $($lines -join ' | ')" }
    if ($lines -contains "BARE=$aPid") { Write-Pass "a bare command in the pane routes to its own -S server" }
    else { Write-Fail "bare command in the pane: $($lines -join ' | ')" }

    Write-Host "`n=== the tmux alias binary ===" -ForegroundColor Yellow
    if (Test-Path $TMUXBIN) {
        $tp = ((& $TMUXBIN -S $sockA display-message -t probe -p '#{socket_path} #{pid}' 2>&1) -join "`n")
        if ($tp -eq "$sockA $aPid") { Write-Pass "tmux -S reaches the -S server and reports its path" }
        else { Write-Fail "tmux -S answered '$tp', expected '$sockA $aPid'" }
    } else { Write-Skip "no tmux.exe next to $PSMUX" }

    Write-Host "`n=== -S kill-server leaves the default server alone ===" -ForegroundColor Yellow
    & $PSMUX -S $sockA kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $after = Q @('display-message','-t','base730','-p','#{pid}')
    if ($after -eq $defPid) { Write-Pass "the default server survived -S kill-server ($after)" }
    else { Write-Fail "the default server is gone after -S kill-server: $after" }
    $lAfter = Q @('-L',$NS,'display-message','-p','#{pid}')
    if ($lAfter -eq $lpid) { Write-Pass "the -L server survived -S kill-server" }
    else { Write-Fail "the -L server after -S kill-server: $lAfter" }
    $gone = Q @('-S',$sockA,'list-sessions')
    $goneRc = $LASTEXITCODE
    if ($goneRc -ne 0 -and $gone -match [regex]::Escape($sockA)) { Write-Pass "-S list-sessions after kill: no server, error names the path" }
    else { Write-Fail "-S list-sessions after kill rc=$goneRc '$gone'" }
    $kill2 = Q @('-S',$sockA,'kill-server')
    if ($LASTEXITCODE -ne 0) { Write-Pass "a second -S kill-server reports no server ($kill2)" }
    else { Write-Fail "a second -S kill-server claimed success" }
    $empty = Q @('-S','','list-sessions')
    if ($LASTEXITCODE -ne 0 -and $empty -match 'non-empty') { Write-Pass "an empty -S path is refused loudly ($empty)" }
    else { Write-Fail "empty -S: $empty" }
} finally {
    & $PSMUX -S $sockA kill-server 2>&1 | Out-Null
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    & $PSMUX kill-session -t base730 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    # Anything still registered in the scratch data dir was started by this
    # test: stop exactly those pids, never anything by name.
    Get-ChildItem $dataDir -Filter *.pid -EA SilentlyContinue | ForEach-Object {
        $p = 0
        if ([int]::TryParse((Get-Content $_.FullName -EA SilentlyContinue | Select-Object -First 1), [ref]$p) -and $p -gt 0) {
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
