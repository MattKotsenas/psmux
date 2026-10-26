# Issue #656: split-window and select-layout with a bare `%N` pane id were routed
# by recency instead of to the session that owns the pane.
#
# The #627 owner resolution (cli_validate_window_pane_target) only ran for the
# commands in the #545 list. split-window and select-layout were not on it, so
# with two sessions alive a `-t %N` for a pane in the OLDER session was sent to
# the newest server:
#
#   split-window  -t %5   ->  ERROR: can't find pane: %5   rc 1   (server reply,
#                             from a session that never had %5)
#   select-layout -t %5   ->  rc 0, layout of the owning window unchanged, the
#                             other session's active window re-laid-out instead
#
# Reported by psmux-resurrect's reconcile path (psmux-plugins#36): it creates a
# window with `new-window -d -P -F '#{pane_id}'` in a running session and splits
# it by that id, which failed whenever another session existed.
#
# What this suite pins, on a rig of two sessions where the owning one is OLDER:
#   * split-window -t %N (pane in a non-active window of the older session)
#     creates the pane IN THAT WINDOW, rc 0, and prints the new %id with -P
#   * split-pane / splitw aliases behave the same
#   * select-layout -t %N changes THAT window's layout and leaves the newer
#     session's window alone
#   * a %N that no session owns still exits 1 with the client's "can't find pane"
#   * a %N owned by two sessions while a third, newest one is routed is
#     refused as ambiguous (the #569 rule) and nothing is split anywhere
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function Write-Section($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME   = $null
$env:PSMUX_SESSION        = $null
$env:PSMUX_TARGET_SESSION = $null
$env:PSMUX_PANE           = $null
$env:TMUX                 = $null
$env:TMUX_PANE            = $null
$env:PSMUX_NO_WARM        = '1'

$rig  = Join-Path $env:TEMP ("psmux656-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$root = Join-Path $rig 'data'
New-Item -ItemType Directory -Force -Path $rig, $root | Out-Null
$env:PSMUX_DATA_DIR = $root
$conf = Join-Path $rig 'empty.conf'
Set-Content -Path $conf -Value '' -Encoding ascii

$NS = 'bug656-' + [guid]::NewGuid().ToString('N').Substring(0,6)
$SA = 'i656work'     # created FIRST: the owner of the panes under test
$SB = 'i656done'     # created LAST: where recency routing used to send them

function Run($argv) {
    $all = & $PSMUX @argv 2>&1
    $rc  = $LASTEXITCODE
    $so  = @(); $se = @()
    foreach ($r in $all) {
        if ($r -is [System.Management.Automation.ErrorRecord]) { $se += $r.ToString() }
        else { $so += ($r | Out-String).TrimEnd() }
    }
    return [pscustomobject]@{
        rc     = $rc
        stdout = (($so -join "`n") -replace "`r", '').Trim()
        stderr = (($se -join "`n") -replace "`r", '').Trim()
        all    = (((($all | Out-String) -replace "`r", '')).Trim())
    }
}
function Px($argv) { return Run (@('-L', $NS, '-f', $conf) + $argv) }
function Panes($target) {
    return @(((Px @('list-panes', '-t', $target, '-F', '#{pane_id}')).stdout -split "`n") | Where-Object { $_ -match '^%\d+$' })
}
function Layout($target) { return (Px @('list-windows', '-t', $target, '-F', '#{window_index}|#{window_layout}')).stdout }

# ── rig ────────────────────────────────────────────────────────────────────
Write-Section "SETUP: work (older) with a detached second window, done (newer) with one window"
Px @('new-session', '-d', '-s', $SA, '-n', 'editor') | Out-Null
Start-Sleep -Milliseconds 700
Px @('new-session', '-d', '-s', $SB, '-n', 'solo') | Out-Null
Start-Sleep -Milliseconds 700
$nw = Px @('new-window', '-d', '-t', $SA, '-n', 'build', '-P', '-F', '#{pane_id}')
$paneId = ($nw.stdout -split "`n" | Where-Object { $_ -match '^%\d+$' } | Select-Object -First 1)
if (-not $paneId) { Write-Fail "could not create the detached window in ${SA}: $($nw.all)"; exit 1 }
$owner = (Px @('display-message', '-p', '-t', $paneId, '#{session_name}/#{window_index}')).stdout
Write-Info "new pane $paneId reported by display-message as $owner"
if ($owner -ne "$SA/1") { Write-Fail "rig: expected $paneId to be ${SA}/1, got '$owner'"; exit 1 }
$donePanesBefore = (Panes "${SB}:0").Count
$doneLayoutBefore = Layout $SB

# ── split-window by bare pane id ───────────────────────────────────────────
Write-Section "split-window -t $paneId (pane in the older session's non-active window)"
$sp = Px @('split-window', '-t', $paneId, '-P', '-F', '#{pane_id}')
$newPane = ($sp.stdout -split "`n" | Where-Object { $_ -match '^%\d+$' } | Select-Object -First 1)
if ($sp.rc -eq 0 -and $newPane) {
    Write-Pass "split-window exits 0 and prints the new pane id ($newPane)"
} else {
    Write-Fail "split-window -> rc=$($sp.rc) output='$($sp.all)'"
}
$buildPanes = Panes "${SA}:1"
if ($buildPanes.Count -eq 2 -and $buildPanes -contains $paneId -and ($newPane -and $buildPanes -contains $newPane)) {
    Write-Pass "the split landed in ${SA}:1 (panes: $($buildPanes -join ', '))"
} else {
    Write-Fail "${SA}:1 panes after split: [$($buildPanes -join ', ')]"
}
if ((Panes "${SB}:0").Count -eq $donePanesBefore) {
    Write-Pass "the newer session's window was not split"
} else {
    Write-Fail "the newer session gained a pane: $((Panes "${SB}:0") -join ', ')"
}

Write-Section "aliases: split-pane and splitw"
foreach ($alias in @('split-pane', 'splitw')) {
    $before = (Panes "${SA}:1").Count
    $r = Px @($alias, '-t', $paneId, '-P', '-F', '#{pane_id}')
    $after = (Panes "${SA}:1").Count
    if ($r.rc -eq 0 -and $after -eq ($before + 1)) {
        Write-Pass "$alias -t $paneId adds a pane to ${SA}:1 ($before -> $after)"
    } else {
        Write-Fail "$alias -> rc=$($r.rc) panes $before -> $after output='$($r.all)'"
    }
}

# ── select-layout by bare pane id ──────────────────────────────────────────
Write-Section "select-layout -t $paneId"
$lb = Layout $SA
$sl = Px @('select-layout', '-t', $paneId, 'even-horizontal')
$la = Layout $SA
$buildLayoutAfter = ($la -split "`n" | Where-Object { $_ -like '1|*' })
if ($sl.rc -eq 0 -and $buildLayoutAfter -match '\{' -and $buildLayoutAfter -notmatch '\[') {
    Write-Pass "even-horizontal applied to ${SA}:1 (layout: $buildLayoutAfter)"
} else {
    Write-Fail "select-layout -> rc=$($sl.rc) output='$($sl.all)' layouts before/after:`n$lb`n$la"
}
if ((Layout $SB) -eq $doneLayoutBefore) {
    Write-Pass "the newer session's layout is untouched"
} else {
    Write-Fail "the newer session's layout changed: $(Layout $SB)"
}
$sv = Px @('select-layout', '-t', $paneId, 'even-vertical')
$buildLayoutV = ((Layout $SA) -split "`n" | Where-Object { $_ -like '1|*' })
if ($sv.rc -eq 0 -and $buildLayoutV -match '\[' -and $buildLayoutV -notmatch '\{') {
    Write-Pass "even-vertical applied to ${SA}:1 too (layout: $buildLayoutV)"
} else {
    Write-Fail "second select-layout -> rc=$($sv.rc) layout: $buildLayoutV"
}

# ── errors keep the #627 contract ──────────────────────────────────────────
Write-Section "a pane nobody owns, and an ambiguous one"
$nx = Px @('split-window', '-t', '%9999')
if ($nx.rc -eq 1 -and $nx.all -match "can't find pane: %9999" -and $nx.all -notmatch '^ERROR:') {
    Write-Pass "split-window -t %9999 exits 1 with the client's can't find pane"
} else {
    Write-Fail "split-window -t %9999 -> rc=$($nx.rc) '$($nx.all)'"
}
# Same shape as #627's ambiguity case: give done a %2 too, then create a third
# session LAST so recency routes there and it owns no %2. Several owners, none
# of them routed: the #569 rule refuses rather than splitting somewhere.
$SC = 'i656other'
Px @('split-window', '-d', '-t', "${SB}:0") | Out-Null
Start-Sleep -Milliseconds 500
Px @('new-session', '-d', '-s', $SC, '-n', 'o1') | Out-Null
Start-Sleep -Milliseconds 700
$workBefore = (Panes "${SA}:1").Count; $doneBefore = (Panes "${SB}:0").Count; $otherBefore = (Panes "${SC}:0").Count
$amb = Px @('split-window', '-t', '%2')
if ($amb.rc -eq 1 -and $amb.all -match 'ambiguous pane id %2' -and $amb.all -match 'qualify as session:window.pane') {
    Write-Pass "split-window -t %2 (owned by $SA and $SB, routed to $SC) is refused: $($amb.all)"
} else {
    Write-Fail "split-window -t %2 -> rc=$($amb.rc) '$($amb.all)'"
}
if ((Panes "${SA}:1").Count -eq $workBefore -and (Panes "${SB}:0").Count -eq $doneBefore -and (Panes "${SC}:0").Count -eq $otherBefore) {
    Write-Pass "the refused split changed nothing anywhere"
} else {
    Write-Fail "a pane appeared somewhere after the refused split"
}

# ── teardown ───────────────────────────────────────────────────────────────
Write-Section "TEARDOWN"
foreach ($s in @($SA, $SB, $SC)) { Px @('kill-session', '-t', $s) | Out-Null }
Start-Sleep -Milliseconds 800
Remove-Item -Recurse -Force $rig -EA SilentlyContinue

Write-Host ""
Write-Host "PASS: $script:Pass  FAIL: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
