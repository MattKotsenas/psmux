# A `sess:win` target inside a `-L` namespace names the routed session.
#
# Found while working on #728.  Under `-L ns` the CLI routes on the registry
# base `ns__sess` (PSMUX_TARGET_SESSION) while the user types the short name
# `sess`.  join-pane and move-pane compared those two strings, decided the
# target was another session, took the cross session path and died with
#   psmux: cross-session join-pane failed: no server for session 'sess'
# for `-t sess:1` and `-t sess:1.0`, while `-t :1` worked.  A genuinely cross
# session move between two sessions of one namespace failed the same way
# (`no server for session 'sa'`), because the bare names never gained the
# prefix the registry is keyed by.
#
# Covered: join-pane and move-pane with every session spelling under -L, the
# own window refusal, a cross session move under -L, the other commands that
# take a `sess:win` target under -L (judged on their effect), and the same
# matrix without -L in an isolated data dir.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_namespaced_session_targets.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "nstgt$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','PSMUX_TARGET_SESSION','PSMUX_TARGET_FULL','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_nstgt_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

# $script:UseNs decides whether P passes -L.  Without -L the isolated
# PSMUX_DATA_DIR makes the default namespace a scratch one.
$script:UseNs = $true
function P { if ($script:UseNs) { & $PSMUX -L $NS @args 2>&1 } else { & $PSMUX @args 2>&1 } }
function Wait-Panes([string]$S, [int]$N) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if (@(P list-panes -s -t $S -F '#{pane_id}').Count -ge $N) { return }
        Start-Sleep -Milliseconds 100
    }
}
function Count-Panes([string]$T) { @(P list-panes -t $T -F '#{pane_id}' | Where-Object { "$_".Trim() -like '%*' }).Count }
function Layout([string]$S) { (P list-panes -s -t $S -F '#{window_index}.#{pane_index}=#{pane_id}') -join ' ' }
function Win-Of([string]$S, [string]$PaneId) {
    foreach ($l in (P list-panes -s -t $S -F '#{pane_id} #{window_index}')) {
        $p = "$l".Split(' '); if ($p[0] -eq $PaneId) { return $p[1] }
    }
    return $null
}
# sess with window 0 split in two (%a %c) and window 1 holding one pane (%b).
function New-Sess([string]$S = "sess") {
    P kill-session -t $S | Out-Null
    P new-session -d -s $S -x 120 -y 40 | Out-Null
    Wait-Panes $S 1
    P new-window -t $S | Out-Null
    P split-window -t "${S}:0" | Out-Null
    Wait-Panes $S 3
}

function Run-Matrix([string]$Label) {
    Write-Host "`n=== $Label : join-pane and move-pane with a session in -t ===" -ForegroundColor Yellow
    foreach ($cmd in 'join-pane', 'move-pane') {
        foreach ($t in 'sess:1', 'sess:1.0', '=sess:1', ':1') {
            New-Sess
            $src = "$(P display-message -p -t sess:0.1 '#{pane_id}')".Trim()
            $out = P $cmd -s $src -t $t
            $rc = $LASTEXITCODE
            Start-Sleep -Milliseconds 300
            $w = Win-Of 'sess' $src
            if ($rc -eq 0 -and $w -eq '1' -and (Count-Panes sess:1) -eq 2) {
                Write-Pass "$cmd -s $src -t $t moved the pane into window 1"
            } else {
                Write-Fail "$cmd -s $src -t $t rc=$rc out=<$($out -join ' | ')> pane now in window '$w', layout $(Layout sess)"
            }
        }
    }

    Write-Host "`n=== $Label : own window refusal still holds with a session in -t ===" -ForegroundColor Yellow
    New-Sess
    $src = "$(P display-message -p -t sess:0.1 '#{pane_id}')".Trim()
    foreach ($pair in @(,@('sess:0.1', 'sess:0'))) {
        $out = P join-pane -s $pair[0] -t $pair[1]
        $rc = $LASTEXITCODE
        if ($rc -ne 0 -and ($out -join ' ') -match "can't join a pane to its own window|source and target panes must be different" -and ($out -join ' ') -notmatch 'cross-session') {
            Write-Pass "join-pane -s $($pair[0]) -t $($pair[1]) refused as the same window: $($out -join ' ')"
        } else {
            Write-Fail "join-pane -s $($pair[0]) -t $($pair[1]) rc=$rc out=<$($out -join ' | ')>"
        }
    }

    Write-Host "`n=== $Label : a genuinely cross session move ===" -ForegroundColor Yellow
    foreach ($cmd in 'move-pane', 'join-pane') {
        P kill-session -t sa | Out-Null; P kill-session -t sb | Out-Null
        P new-session -d -s sa -x 120 -y 40 | Out-Null
        P new-session -d -s sb -x 120 -y 40 | Out-Null
        Wait-Panes sa 1; Wait-Panes sb 1
        P split-window -t sa:0 | Out-Null
        Wait-Panes sa 2
        $out = P $cmd -s sa:0.1 -t sb:0
        $rc = $LASTEXITCODE
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 5000 -and (Count-Panes sb:0) -lt 2) { Start-Sleep -Milliseconds 100 }
        $na = (Count-Panes sa:0); $nb = (Count-Panes sb:0)
        if ($rc -eq 0 -and $na -eq 1 -and $nb -eq 2) {
            Write-Pass "$cmd -s sa:0.1 -t sb:0 moved the pane across sessions (sa 1 pane, sb 2 panes)"
        } else {
            Write-Fail "$cmd -s sa:0.1 -t sb:0 rc=$rc out=<$($out -join ' | ')> sa=$na sb=$nb"
        }
        P kill-session -t sa | Out-Null; P kill-session -t sb | Out-Null
    }

    Write-Host "`n=== $Label : other commands with a sess:win target ===" -ForegroundColor Yellow
    New-Sess
    $a = "$(P display-message -p -t sess:0.0 '#{pane_id}')".Trim()
    $c = "$(P display-message -p -t sess:0.1 '#{pane_id}')".Trim()
    $out = P swap-pane -s sess:0.0 -t sess:0.1
    $na = "$(P display-message -p -t sess:0.0 '#{pane_id}')".Trim()
    if ($LASTEXITCODE -eq 0 -and $na -eq $c) { Write-Pass "swap-pane -s sess:0.0 -t sess:0.1 swapped ($a <-> $c)" }
    else { Write-Fail "swap-pane out=<$($out -join ' | ')> 0.0 is now $na, want $c" }

    $out = P break-pane -d -s sess:0.1 -t sess:5
    $rc = $LASTEXITCODE
    if ($rc -eq 0 -and (Win-Of 'sess' $a) -eq '5') { Write-Pass "break-pane -s sess:0.1 -t sess:5 made window 5" }
    else { Write-Fail "break-pane rc=$rc out=<$($out -join ' | ')> layout $(Layout sess)" }

    $out = P split-window -d -t sess:1.0
    $rc = $LASTEXITCODE
    Wait-Panes sess 4
    if ($rc -eq 0 -and (Count-Panes sess:1) -eq 2) { Write-Pass "split-window -t sess:1.0 split window 1" }
    else { Write-Fail "split-window rc=$rc out=<$($out -join ' | ')> layout $(Layout sess)" }

    $out = P select-pane -t sess:1.1
    $act = "$(P display-message -p -t sess:1 '#{pane_index}')".Trim()
    if ($LASTEXITCODE -eq 0 -and $act -eq '1') { Write-Pass "select-pane -t sess:1.1 made pane 1 active" }
    else { Write-Fail "select-pane out=<$($out -join ' | ')> active $act" }

    $out = P send-keys -t sess:1.0 'echo NSTGT_MARK' Enter
    $seen = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000) {
        if (((P capture-pane -p -t sess:1.0) -join "`n") -match 'NSTGT_MARK') { $seen = $true; break }
        Start-Sleep -Milliseconds 150
    }
    if ($seen) { Write-Pass "send-keys -t sess:1.0 reached the pane" } else { Write-Fail "send-keys -t sess:1.0 text never appeared (out=<$($out -join ' | ')>)" }

    $pidBefore = "$(P display-message -p -t sess:1.0 '#{pane_pid}')".Trim()
    $out = P respawn-pane -k -t sess:1.0
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 800
    $pidAfter = "$(P display-message -p -t sess:1.0 '#{pane_pid}')".Trim()
    if ($rc -eq 0 -and $pidAfter -and $pidAfter -ne $pidBefore) { Write-Pass "respawn-pane -k -t sess:1.0 replaced the shell ($pidBefore -> $pidAfter)" }
    else { Write-Fail "respawn-pane rc=$rc out=<$($out -join ' | ')> pid $pidBefore -> $pidAfter" }

    $out = P move-window -s sess:5 -t sess:7
    $wins = (P list-windows -t sess -F '#{window_index}') -join ','
    if ($LASTEXITCODE -eq 0 -and $wins -eq '0,1,7') { Write-Pass "move-window -s sess:5 -t sess:7 (windows $wins)" }
    else { Write-Fail "move-window out=<$($out -join ' | ')> windows $wins" }

    $out = P link-window -s sess:7 -t sess:8
    $wins = (P list-windows -t sess -F '#{window_index}') -join ','
    if ($LASTEXITCODE -eq 0 -and $wins -eq '0,1,7,8') { Write-Pass "link-window -s sess:7 -t sess:8 (windows $wins)" }
    else { Write-Fail "link-window out=<$($out -join ' | ')> windows $wins" }

    $out = P select-window -t sess:1
    $aw = "$(P display-message -p -t sess '#{window_index}')".Trim()
    if ($LASTEXITCODE -eq 0 -and $aw -eq '1') { Write-Pass "select-window -t sess:1 made window 1 current" }
    else { Write-Fail "select-window out=<$($out -join ' | ')> current $aw" }

    $out = P switch-client -t sess:0
    if ($LASTEXITCODE -eq 0 -and ($out -join ' ') -notmatch 'no server|cross-session') { Write-Pass "switch-client -t sess:0 accepted" }
    else { Write-Fail "switch-client -t sess:0 rc=$LASTEXITCODE out=<$($out -join ' | ')>" }

    P kill-session -t sess | Out-Null
}

try {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $script:UseNs = $true
    Run-Matrix "-L $NS"
    $script:UseNs = $false
    Run-Matrix "no -L (isolated data dir)"
} finally {
    $script:UseNs = $false
    foreach ($s in 'sess', 'sa', 'sb') { P kill-session -t $s | Out-Null }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
