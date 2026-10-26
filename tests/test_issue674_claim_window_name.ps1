# Issue #674: "new-session -n NAME can lose the name on the warm claim path".
#
# WHAT WAS REPRODUCED (worktree build of master 2cd4cb3, isolated data root)
#
#   The warm claim wire carries the session name, the client cwd, the priority
#   and the environment file, but NOT the window name. `-n NAME` is applied
#   afterwards, by a SECOND request (`rename-window`) whose result the CLI
#   throws away. So the claimed session is briefly visible under the standby's
#   pool name, and if that second request does not land the name is lost for
#   good:
#
#     direct claim wire, `claim-session S -n main`, first observation
#         window_name|automatic-rename = 'pwsh|on'      (the -n was ignored)
#
#     `new-session -d -s S -n main` with a 1 ms poll from the moment the
#     session answers, 20 rounds
#         first observation 'pwsh|on' in 20 of 20, only later 'main'
#
#     the same call with the session key file held unreadable for 400 ms so
#     the post claim rename cannot authenticate, 20 rounds
#         window_name 'pwsh', automatic-rename 'on', permanently, 20 of 20
#
#   That last line is the sweep observation this issue was filed for
#   (`0:pwsh` where the rig asked for `0:main`).
#
# tmux PARITY
#
#   cmd-new-session.c names the window and turns automatic-rename off for it
#   BEFORE the session becomes visible: the name is part of creating the
#   session, never a follow up command that can fail. psmux's cold spawn path
#   already does this (run_server applies -n before the server loop starts).
#   The fix makes the claim carry `-n` too, so the ClaimSession handler applies
#   the name and manual_rename together, before it answers OK.
#
# WHAT THIS SUITE PINS
#   * a standby really is claimed (the server command line carries __warm__)
#   * the claim wire honours -n: the FIRST observation of the claimed session
#     already reads the requested name with automatic-rename off
#   * `new-session -d -n main` on the warm path never shows the pool name,
#     at a 1 ms poll, over 20 rounds
#   * the name survives even when a follow up request could not have worked
#     (session key held unreadable across the claim)
#   * without -n the window is still named by the automatic rename walk
#
# Set PSMUX_TEST_BIN to test a non-installed binary.
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue674_claim_window_name.ps1

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else {
    $local = Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue
    if ($local) { $local.Path } else { (Get-Command psmux -EA Stop).Source }
}
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# Inherited routing would aim every call at somebody else's server.
foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_TARGET_SESSION') {
    Set-Item -Path "env:$v" -Value $null -EA SilentlyContinue
}

$NS   = "e674"                                     # private namespace, never the default one
$rig  = Join-Path $env:TEMP ("psmux674-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$DATA = Join-Path $rig 'data'                      # private data root, never ~/.psmux
New-Item -ItemType Directory -Force -Path $rig, $DATA | Out-Null
$env:PSMUX_DATA_DIR = $DATA

# A tiny helper process that holds a file with FileShare::None, so a reader
# that must open it fails for as long as it is held.
$holdScript = Join-Path $rig 'holdkey.ps1'
@'
param([string]$Path, [int]$HoldMs = 400, [int]$SpinMs = 12000)
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt $SpinMs) {
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        Start-Sleep -Milliseconds $HoldMs
        $fs.Close()
        Write-Output "HELD"
        exit 0
    } catch { }
}
Write-Output "NEVER_APPEARED"
'@ | Set-Content -Path $holdScript -Encoding UTF8

function OneShot {
    param([int]$Port, [string]$Key, [string[]]$Lines)
    $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 20000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth" }
    foreach ($l in $Lines) { $wr.WriteLine($l) }
    $wr.Flush()
    $out = @()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $out += $l }
    $tcp.Close(); return $out
}
function PortOf($base) {
    $p = Join-Path $DATA "$base.port"
    if (-not (Test-Path $p)) { return $null }
    try { return [int]((Get-Content $p -Raw).Trim()) } catch { return $null }
}
function KeyOf($base) {
    $p = Join-Path $DATA "$base.key"
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw).Trim() } catch { return $null }
}
function NameOf($base) {
    $p = PortOf $base; $k = KeyOf $base
    if (-not $p -or -not $k) { return $null }
    try { return ((OneShot $p $k @('list-windows -F "#{window_name}"')) -join ' ').Trim() } catch { return $null }
}
$script:Nudge = 0
function PollWarm([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if (Test-Path (Join-Path $DATA "$($NS)____warm__.port")) { return $true }
        Start-Sleep -Milliseconds 25
    }
    return $false
}
# The pool only refills when a session is created or claimed, so a rig that
# refuses to create a session until a standby exists can wait forever: under
# load the replenish can lose its advisory spawn lock (the holder is stale for
# 20 s) and nothing else ever asks for a standby. Clear a stale lock in this
# rig's own private root and create one throwaway session, which is what asks
# the pool to refill, then wait again.
function WaitWarm([int]$ms = 12000) {
    if (PollWarm $ms) { return $true }
    $lock = Join-Path $DATA "$($NS)____warm__.spawnlock"
    if (Test-Path $lock) { Remove-Item -LiteralPath $lock -Force -EA SilentlyContinue }
    $script:Nudge++
    $n = "nudge$($script:Nudge)"
    & $PSMUX -L $NS new-session -d -s $n 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $NS kill-session -t $n 2>&1 | Out-Null
    return (PollWarm $ms)
}
function Cleanup {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

try {

Cleanup
& $PSMUX -L $NS new-session -d -s seed 2>&1 | Out-Null
if (-not (WaitWarm)) {
    Write-Skip "no warm standby appeared in this environment, the claim path cannot be exercised"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed:  $($script:Pass)"; Write-Host "  Failed:  $($script:Fail)"; Write-Host "  Skipped: $($script:Skip)"
    exit $script:Fail
}
Start-Sleep -Milliseconds 400

# ---------------------------------------------------------------- the standby is real
$warmPid = $null
$pidf = Join-Path $DATA "$($NS)____warm__.pid"
if (Test-Path $pidf) { try { $warmPid = [int](((Get-Content $pidf -Raw).Trim() -split ':')[0]) } catch { } }
$cl = if ($warmPid) { (Get-CimInstance Win32_Process -Filter "ProcessId=$warmPid" -EA SilentlyContinue).CommandLine } else { "" }
if ($cl -match '__warm__') {
    Write-Pass "a standby is parked (pid $warmPid, server command line carries __warm__)"
} else {
    Write-Fail "no parked standby to claim (pid='$warmPid' cmdline='$cl'), the rest of this suite would not test the claim path"
}

# ---------------------------------------------------------------- 1. the claim wire honours -n
Write-Host "`n[1] the claim request itself carries the window name" -ForegroundColor Cyan
$wp = PortOf "$($NS)____warm__"; $wk = KeyOf "$($NS)____warm__"
if (-not $wp -or -not $wk) {
    Write-Fail "could not read the standby's port/key"
} else {
    # Claim exactly the way the CLI does, minus the follow up rename: rename the
    # handoff .port aside first so the pool self heals, then send ONE request.
    $claiming = Join-Path $DATA "$($NS)____warm__.claiming"
    Move-Item -Force (Join-Path $DATA "$($NS)____warm__.port") $claiming -EA SilentlyContinue
    $resp = ""
    try { $resp = (OneShot $wp $wk @('claim-session A674 -n main -p normal')) -join ' ' } catch { $resp = "EXC $_" }
    Remove-Item -Force $claiming -EA SilentlyContinue
    Write-Info "claim response: '$resp'"
    if ($resp -notmatch 'OK') {
        Write-Fail "the standby refused the claim: '$resp'"
    } else {
        # FIRST observation: poll for the beacon and query immediately.
        $ap = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 8000 -and -not $ap) { $ap = PortOf "$($NS)__A674" }
        $first = NameOf "$($NS)__A674"
        Write-Info "first observation of the claimed session: window_name='$first'"
        if ($first -eq 'main') {
            Write-Pass "the claim answered OK with the window already named 'main' (no follow up request needed)"
        } else {
            Write-Fail "the claimed session's first observation is '$first', the -n on the claim wire was not applied"
        }
        $ar = (& $PSMUX -L $NS show-options -w -v automatic-rename -t "A674:0" 2>&1) -join ' '
        if ($ar.Trim() -eq 'off') {
            Write-Pass "automatic-rename is off for that window at the first observation (tmux cmd-new-session.c parity)"
        } else {
            Write-Fail "automatic-rename is '$($ar.Trim())' for the claimed window, so the shell will rename it"
        }
        & $PSMUX -L $NS kill-session -t A674 2>&1 | Out-Null
    }
}

# ---------------------------------------------------------------- 2. tight poll, the pool name is never visible
Write-Host "`n[2] new-session -d -n main on the warm path, polled from the first answer" -ForegroundColor Cyan
$rounds = 20; $poolSeen = 0; $badFinal = 0; $skipped = 0; $firsts = @{}
for ($i = 1; $i -le $rounds; $i++) {
    if (-not (WaitWarm 9000)) {
        $skipped++
        $diag = ((Get-ChildItem $DATA -Filter "$($NS)*" -EA SilentlyContinue | ForEach-Object Name) -join ',')
        $sess = ((& $PSMUX -L $NS list-sessions 2>&1) -join '; ')
        Write-Info "round $i had no standby, skipped (files=$diag sessions=$sess)"
        continue
    }
    Start-Sleep -Milliseconds 150
    $S = "W$i"; $base = "$($NS)__$S"
    $proc = Start-Process -FilePath $PSMUX -ArgumentList @("-L", $NS, "new-session", "-d", "-s", $S, "-n", "main") -PassThru -NoNewWindow
    $samples = @(); $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000) {
        $n = NameOf $base
        if ($n) {
            if ($samples.Count -eq 0 -or $samples[-1] -ne $n) { $samples += $n }
            if ($n -eq 'main') { break }
        }
    }
    try { $proc.WaitForExit(10000) | Out-Null } catch { }
    Start-Sleep -Milliseconds 800
    $final = NameOf $base
    $first = if ($samples.Count) { $samples[0] } else { "NONE" }
    if (-not $firsts.ContainsKey($first)) { $firsts[$first] = 0 }
    $firsts[$first] = $firsts[$first] + 1
    if (($samples | Where-Object { $_ -ne 'main' }).Count -gt 0) {
        $poolSeen++
        Write-Info "round $i saw [$($samples -join ' -> ')]"
    }
    if ($final -ne 'main') { $badFinal++ }
    & $PSMUX -L $NS kill-session -t $S 2>&1 | Out-Null
}
Write-Info ("firsts: " + (($firsts.GetEnumerator() | ForEach-Object { "'$($_.Key)' x$($_.Value)" }) -join ', ') + " (skipped $skipped)")
if ($skipped -ge $rounds) {
    Write-Skip "no standby was ever available, the warm path was not exercised"
} elseif ($poolSeen -eq 0) {
    Write-Pass "over $($rounds - $skipped) rounds the window was never observed under any name but 'main'"
} else {
    Write-Fail "the pool/shell name was observed before 'main' in $poolSeen of $($rounds - $skipped) rounds"
}
if ($badFinal -eq 0) {
    Write-Pass "every round settled on 'main'"
} else {
    Write-Fail "$badFinal of $($rounds - $skipped) rounds did not end up named 'main'"
}

# ---------------------------------------------------------------- 3. the reported outcome: a follow up request cannot help
Write-Host "`n[3] the name survives when a second request could not have authenticated" -ForegroundColor Cyan
$hrounds = 6; $lost = 0; $held = 0; $hskipped = 0
for ($i = 1; $i -le $hrounds; $i++) {
    if (-not (WaitWarm 20000)) { $hskipped++; continue }
    Start-Sleep -Milliseconds 150
    $S = "H$i"
    $keyPath = Join-Path $DATA "$($NS)__$S.key"
    $hout = Join-Path $rig "hold$i.txt"
    $holder = Start-Process pwsh -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$holdScript,"-Path",$keyPath,"-HoldMs","400") -PassThru -NoNewWindow -RedirectStandardOutput $hout
    Start-Sleep -Milliseconds 700
    & $PSMUX -L $NS new-session -d -s $S -n main 2>&1 | Out-Null
    try { $holder.WaitForExit(15000) | Out-Null } catch { }
    $hres = (Get-Content $hout -Raw -EA SilentlyContinue)
    if ($hres -match 'HELD') { $held++ }
    Start-Sleep -Milliseconds 1200
    $wn = NameOf "$($NS)__$S"
    if ($wn -ne 'main') { $lost++; Write-Info "round $i window_name='$wn' (holder=$($hres.Trim()))" }
    & $PSMUX -L $NS kill-session -t $S 2>&1 | Out-Null
}
if ($hskipped -ge $hrounds) {
    Write-Skip "no standby was available for the key holding rounds"
} elseif ($held -eq 0) {
    Write-Skip "the session key was never caught unreadable, this round proves nothing"
} elseif ($lost -eq 0) {
    Write-Pass "the name held in all $($hrounds - $hskipped) rounds with the key held unreadable ($held caught)"
} else {
    Write-Fail "the name was lost in $lost of $($hrounds - $hskipped) rounds when the key was unreadable ($held caught)"
}

# ---------------------------------------------------------------- 4. without -n the automatic rename still names the window
Write-Host "`n[4] no -n: automatic-rename stays on and the shell names the window" -ForegroundColor Cyan
if (WaitWarm 20000) { Start-Sleep -Milliseconds 150 }
& $PSMUX -L $NS new-session -d -s P674 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
$pn = NameOf "$($NS)__P674"
$par = (& $PSMUX -L $NS show-options -w -v automatic-rename -t "P674:0" 2>&1) -join ' '
Write-Info "no -n: window_name='$pn' automatic-rename='$($par.Trim())'"
if ($par.Trim() -eq 'on') {
    Write-Pass "automatic-rename is still on for a session created without -n"
} else {
    Write-Fail "automatic-rename is '$($par.Trim())' without -n, the claim must not pin a name nobody asked for"
}
if ($pn -and $pn -ne 'main' -and $pn.Length -gt 0) {
    Write-Pass "the window carries the automatic name '$pn', not a name from the claim"
} else {
    Write-Fail "unexpected window name '$pn' for a session created without -n"
}
& $PSMUX -L $NS kill-session -t P674 2>&1 | Out-Null

}
finally {
    Cleanup
    Remove-Item -LiteralPath $rig -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed:  $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:Skip)" -ForegroundColor Yellow
exit $script:Fail
