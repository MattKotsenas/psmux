# Source and target specs that name another session, or a pane by %id.
#
# Found while verifying namespaced targets (after #725 and the -L identity
# fix).  psmux runs one server per session, and three things went wrong:
#
#  1. `join-pane -s %N -t sess:0` with %N already in window 0 exited 0 and
#     did nothing.  The CLI sent it without reading a reply and the server
#     read `-s %N` as pane INDEX N of the active window.  tmux 3.x answers
#     `can't join a pane to its own window` at exit 1.  A `-s %N` in another
#     window must still move that pane.
#  2. `swap-pane -s sb:0.0 -t sa:0.1`, `link-window -s sb:0 -t sa:5` and
#     `move-window -s sb:0 -t sa:6` exited 0 and acted on sa's OWN pane or
#     window of the same number: the session in -s was dropped.  A cross
#     session swap, link or move cannot be carried by two servers faithfully,
#     so each is now refused at exit 1 and nothing moves.
#  3. A cross session join-pane that names a target pane landed beside the
#     target session's ACTIVE pane: the target spec was computed and never
#     sent.  A source window other than 0 (`-s sb:1.0`) was read as window 0.
#
# Every case is judged on where the panes and windows are afterwards, with
# and without -L (the no -L run uses an isolated PSMUX_DATA_DIR).
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_cross_session_source_targets.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "xsrc$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','PSMUX_TARGET_SESSION','PSMUX_TARGET_FULL','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_xsrc_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

$script:UseNs = $true
function P { if ($script:UseNs) { & $PSMUX -L $NS @args 2>&1 } else { & $PSMUX @args 2>&1 } }
function Wait-Panes([string]$S, [int]$N) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if (@(P list-panes -s -t $S -F '#{pane_id}' | Where-Object { "$_".Trim() -like '%*' }).Count -ge $N) { return }
        Start-Sleep -Milliseconds 100
    }
}
# "<window>.<pane>=<id>" for every pane of a session, in order.
function Layout([string]$S) { (P list-panes -s -t $S -F '#{window_index}.#{pane_index}=#{pane_id}') -join ' ' }
function Windows([string]$S) { (P list-windows -t $S -F '#{window_index}') -join ',' }
function PaneAt([string]$T) { "$(P display-message -p -t $T '#{pane_id}')".Trim() }
# sa: window 0 split in three (%1 %2 %3), window 1 one pane.
# sb: window 0 split in two, window 1 one pane.
function Fresh {
    foreach ($s in 'sa', 'sb') { P kill-session -t $s | Out-Null }
    P new-session -d -s sa -x 140 -y 50 | Out-Null
    P new-session -d -s sb -x 140 -y 50 | Out-Null
    Wait-Panes sa 1; Wait-Panes sb 1
    P split-window -t sa:0 | Out-Null
    P split-window -t sa:0 | Out-Null
    P new-window -d -t sa | Out-Null
    P split-window -t sb:0 | Out-Null
    P new-window -d -t sb | Out-Null
    Wait-Panes sa 4; Wait-Panes sb 3
    P select-pane -t sa:0.2 | Out-Null
}
function Wait-Layout([string]$S, [string]$Before) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 4000) {
        if ((Layout $S) -ne $Before) { return }
        Start-Sleep -Milliseconds 100
    }
}

function Run-Matrix([string]$Label) {
    Write-Host "`n=== $Label : 1. join-pane -s %id ===" -ForegroundColor Yellow
    Fresh
    $id = PaneAt 'sa:0.1'
    $before = "$(Layout sa) | $(Layout sb)"
    $out = P join-pane -s $id -t sa:0
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 500
    $after = "$(Layout sa) | $(Layout sb)"
    if ($rc -ne 0 -and ($out -join ' ') -match "can't join a pane to its own window" -and $after -eq $before) {
        Write-Pass "join-pane -s $id -t sa:0 refused at rc $rc, layout unchanged: $($out -join ' ')"
    } else {
        Write-Fail "join-pane -s $id -t sa:0 rc=$rc out=<$($out -join ' | ')> layout $before -> $after"
    }

    Fresh
    $id = PaneAt 'sa:0.1'
    $out = P join-pane -s $id -t sa:1
    $rc = $LASTEXITCODE
    Wait-Layout sa ''
    Start-Sleep -Milliseconds 400
    $ids1 = @(P list-panes -t sa:1 -F '#{pane_id}' | ForEach-Object { "$_".Trim() })
    $ids0 = @(P list-panes -t sa:0 -F '#{pane_id}' | ForEach-Object { "$_".Trim() })
    if ($rc -eq 0 -and $ids1 -contains $id -and $ids0 -notcontains $id -and $ids0.Count -eq 2) {
        Write-Pass "join-pane -s $id -t sa:1 moved $id into window 1 ($(Layout sa))"
    } else {
        Write-Fail "join-pane -s $id -t sa:1 rc=$rc out=<$($out -join ' | ')> layout $(Layout sa)"
    }

    Fresh
    $w1 = PaneAt 'sa:1.0'
    $tgt = PaneAt 'sa:0.0'
    $out = P join-pane -s sa:1 -t "sa:$tgt"
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 500
    $at1 = PaneAt 'sa:0.1'
    if ($rc -eq 0 -and $at1 -eq $w1 -and (Windows sa) -eq '0') {
        Write-Pass "join-pane -s sa:1 -t $tgt put $w1 right after $tgt ($(Layout sa))"
    } else {
        Write-Fail "join-pane -s sa:1 -t $tgt rc=$rc out=<$($out -join ' | ')> layout $(Layout sa)"
    }

    $out = P join-pane -s '%99' -t sa:0
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and ($out -join ' ') -match "can't find pane: %99") { Write-Pass "join-pane -s %99 refused: $($out -join ' ')" }
    else { Write-Fail "join-pane -s %99 rc=$rc out=<$($out -join ' | ')>" }

    Write-Host "`n=== $Label : 2. cross session swap-pane, link-window, move-window ===" -ForegroundColor Yellow
    $cases = @(
        @{ c = @('swap-pane', '-s', 'sb:0.0', '-t', 'sa:0.1'); n = 'swap-pane' },
        @{ c = @('swap-pane', '-s', 'sa:0.1', '-t', 'sb:0.0'); n = 'swap-pane' },
        @{ c = @('link-window', '-s', 'sb:0', '-t', 'sa:5'); n = 'link-window' },
        @{ c = @('move-window', '-s', 'sb:0', '-t', 'sa:6'); n = 'move-window' },
        @{ c = @('move-window', '-s', 'sb:1', '-t', 'sa:7'); n = 'move-window' }
    )
    foreach ($k in $cases) {
        Fresh
        $before = "sa[$(Layout sa)] sb[$(Layout sb)]"
        $out = P @($k.c)
        $rc = $LASTEXITCODE
        Start-Sleep -Milliseconds 600
        $after = "sa[$(Layout sa)] sb[$(Layout sb)]"
        $msg = ($out -join ' ')
        if ($rc -ne 0 -and $after -eq $before -and $msg -match "cross-session $($k.n) is not supported") {
            Write-Pass "$($k.c -join ' ') refused at rc $rc, nothing moved: $msg"
        } else {
            Write-Fail "$($k.c -join ' ') rc=$rc out=<$msg> $before -> $after"
        }
    }

    # The same commands inside one session, spelled with the session, still act.
    Fresh
    $a = PaneAt 'sa:0.0'; $c = PaneAt 'sa:0.1'
    $out = P swap-pane -s sa:0.0 -t sa:0.1
    if ($LASTEXITCODE -eq 0 -and (PaneAt 'sa:0.0') -eq $c) { Write-Pass "swap-pane -s sa:0.0 -t sa:0.1 inside sa still swaps" }
    else { Write-Fail "swap-pane inside sa rc=$LASTEXITCODE out=<$($out -join ' | ')> layout $(Layout sa)" }
    $out = P move-window -s sa:1 -t sa:6
    if ($LASTEXITCODE -eq 0 -and (Windows sa) -eq '0,6') { Write-Pass "move-window -s sa:1 -t sa:6 inside sa still moves (windows $(Windows sa))" }
    else { Write-Fail "move-window inside sa rc=$LASTEXITCODE out=<$($out -join ' | ')> windows $(Windows sa)" }
    $out = P link-window -s sa:6 -t sa:8
    if ($LASTEXITCODE -eq 0 -and (Windows sa) -eq '0,6,8') { Write-Pass "link-window -s sa:6 -t sa:8 inside sa still links (windows $(Windows sa))" }
    else { Write-Fail "link-window inside sa rc=$LASTEXITCODE out=<$($out -join ' | ')> windows $(Windows sa)" }

    Write-Host "`n=== $Label : 3. cross session join-pane honours the target pane ===" -ForegroundColor Yellow
    # sa:0 is %1 %2 %3 with %3 (pane 2) active.  tmux puts the joined pane
    # right after the TARGET pane, so it must become sa:0.1, not sa:0.3.
    foreach ($t in 'sa:0.0', 'sa:0.1') {
        Fresh
        $tp = PaneAt $t
        $tidx = [int]($t.Split('.')[1])
        $before = Layout sa
        $out = P join-pane -s sb:0.1 -t $t
        $rc = $LASTEXITCODE
        Wait-Layout sa $before
        Start-Sleep -Milliseconds 300
        $atTarget = PaneAt "sa:0.$tidx"
        $next = PaneAt "sa:0.$($tidx + 1)"
        $nb = @(P list-panes -t sb:0 -F '#{pane_id}').Count
        $known = @($before.Split(' ') | ForEach-Object { $_.Split('=')[1] })
        if ($rc -eq 0 -and $atTarget -eq $tp -and $known -notcontains $next -and $nb -eq 1) {
            Write-Pass "join-pane -s sb:0.1 -t $t landed right after $tp as $next ($(Layout sa))"
        } else {
            Write-Fail "join-pane -s sb:0.1 -t $t rc=$rc out=<$($out -join ' | ')> sa $before -> $(Layout sa), sb:0 has $nb"
        }
    }

    # A source window other than 0: `1.0` used to be read as session "1"
    # pane 0, so window 0's pane moved instead.
    Fresh
    $b0 = "$(Layout sb)"
    $out = P join-pane -s sb:1.0 -t sa:1
    $rc = $LASTEXITCODE
    Wait-Layout sa ''
    Start-Sleep -Milliseconds 600
    $nsa1 = @(P list-panes -t sa:1 -F '#{pane_id}').Count
    if ($rc -eq 0 -and (Windows sb) -eq '0' -and @(P list-panes -t sb:0 -F '#{pane_id}').Count -eq 2 -and $nsa1 -eq 2) {
        Write-Pass "join-pane -s sb:1.0 -t sa:1 took sb's window 1 pane (sb now $(Layout sb), sa:1 has $nsa1)"
    } else {
        Write-Fail "join-pane -s sb:1.0 -t sa:1 rc=$rc out=<$($out -join ' | ')> sb $b0 -> $(Layout sb), sa $(Layout sa)"
    }

    # A target that does not exist is refused before anything is extracted.
    Fresh
    $before = "sa[$(Layout sa)] sb[$(Layout sb)]"
    $out = P join-pane -s sb:0.1 -t sa:0.7
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 600
    $after = "sa[$(Layout sa)] sb[$(Layout sb)]"
    if ($rc -ne 0 -and $after -eq $before -and ($out -join ' ') -match "can't find pane") {
        Write-Pass "join-pane -s sb:0.1 -t sa:0.7 refused, nothing moved: $($out -join ' ')"
    } else {
        Write-Fail "join-pane -s sb:0.1 -t sa:0.7 rc=$rc out=<$($out -join ' | ')> $before -> $after"
    }

    foreach ($s in 'sa', 'sb') { P kill-session -t $s | Out-Null }
}

try {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $script:UseNs = $true
    Run-Matrix "-L $NS"
    $script:UseNs = $false
    Run-Matrix "no -L (isolated data dir)"
} finally {
    $script:UseNs = $false
    foreach ($s in 'sa', 'sb') { P kill-session -t $s | Out-Null }
    $script:UseNs = $true
    foreach ($s in 'sa', 'sb') { P kill-session -t $s | Out-Null }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
