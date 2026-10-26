# Issue #530: ~/.psmux accumulates .sid/.pid/.spawnlock files forever
#
# Claims under test:
#   1. kill-server removes .port/.key/.pid but strands the .sid, permanently.
#   2. Nothing ever reclaims a registry file whose sibling .port is gone,
#      because every sweep over the data directory is anchored on .port.
#   3. .spawnlock is released only by Drop, so a hard-killed holder strands it.
#   4. Namespace churn multiplies all of the above (one set per namespace).
#   5. Orphaned .sid files are re-read on every "$N" session-id lookup.
#
# The script runs ENTIRELY inside a redirected USERPROFILE/HOME so it can never
# touch the developer's real ~/.psmux. The live warm server (__warm__*) is
# excluded from leftover accounting: it is a legitimately running server.

param([string]$Binary = "")

$ErrorActionPreference = "Continue"
$PSMUX = if ($Binary) { (Resolve-Path $Binary).Path } else { (Get-Command psmux -EA Stop).Source }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

# --- Sandbox home -----------------------------------------------------------
$RUN = "i530_" + (Get-Random -Minimum 100000 -Maximum 999999)
$SANDBOX = Join-Path $env:TEMP $RUN
$PSMUXDIR = Join-Path $SANDBOX ".psmux"
New-Item -ItemType Directory -Path $SANDBOX -Force | Out-Null

$REAL_USERPROFILE = $env:USERPROFILE
$REAL_HOME = $env:HOME

function Use-SandboxEnv {
    $env:USERPROFILE = $SANDBOX
    $env:HOME = $SANDBOX
    $env:PSMUX_TEST_SANDBOX = "1"
}
function Restore-Env {
    $env:USERPROFILE = $REAL_USERPROFILE
    if ($null -eq $REAL_HOME) { Remove-Item Env:\HOME -EA SilentlyContinue } else { $env:HOME = $REAL_HOME }
}

function Invoke-Psmux {
    param([string[]]$PsmuxArgs)
    Use-SandboxEnv
    try {
        $out = & $PSMUX @PsmuxArgs 2>&1 | Out-String
        return @{ Out = $out; Code = $LASTEXITCODE }
    } finally { Restore-Env }
}

function Wait-SessionPort {
    param([string]$File, [int]$TimeoutMs = 25000)
    $pf = Join-Path $PSMUXDIR "$File.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

# Everything in the data dir EXCEPT the live warm server's own set and the
# fixed bookkeeping files (the id counter, the sweep stamp), which are one file
# each for the life of the directory rather than one per session.
function Get-Residue {
    if (-not (Test-Path $PSMUXDIR)) { return @() }
    $fixed = @("next_session_id", "next_session_id.lock", ".registry_sweep", "last_session")
    Get-ChildItem $PSMUXDIR -File -Force -EA SilentlyContinue |
        Where-Object { $_.Name -notlike "*__warm__*" -and $fixed -notcontains $_.Name -and $_.Extension -ne ".log" }
}

function Show-Dir {
    param([string]$label)
    Write-Host "  --- $label ---" -ForegroundColor DarkGray
    $files = Get-ChildItem $PSMUXDIR -File -EA SilentlyContinue
    if (-not $files) { Write-Host "    (empty)" -ForegroundColor DarkGray; return }
    foreach ($g in ($files | Group-Object Extension | Sort-Object Name)) {
        $n = if ($g.Name) { $g.Name } else { "(none)" }
        Write-Host ("    {0,-12} {1,4}  {2}" -f $n, $g.Count, (($g.Group.Name | Select-Object -First 6) -join ", ")) -ForegroundColor DarkGray
    }
}

function Clear-Dir {
    Get-ChildItem $PSMUXDIR -File -EA SilentlyContinue |
        Where-Object { $_.Name -notlike "*__warm__*" } | Remove-Item -Force -EA SilentlyContinue
}

# The sweep is rate limited by a `.registry_sweep` stamp so it never runs on
# every invocation. Removing the stamp stands in for the interval having
# elapsed, which is what lets these scenarios assert a sweep without waiting.
function Enable-Sweep {
    Remove-Item (Join-Path $PSMUXDIR ".registry_sweep") -Force -EA SilentlyContinue
}

# Run psmux until the sweep has nothing left to do. One sweep is deliberately
# capped at a budget of files so no single invocation does unbounded work, so a
# large backlog legitimately drains over several passes.
function Invoke-SweepUntilDrained {
    param([int]$MaxPasses = 40)
    for ($p = 0; $p -lt $MaxPasses; $p++) {
        Enable-Sweep
        Invoke-Psmux @("list-sessions") | Out-Null
        Start-Sleep -Milliseconds 150
    }
}

function Cleanup-Sandbox {
    if (Test-Path $PSMUXDIR) {
        foreach ($pf in Get-ChildItem $PSMUXDIR -Filter "*.port" -File -EA SilentlyContinue) {
            $n = [IO.Path]::GetFileNameWithoutExtension($pf.Name)
            if ($n -match '^(.*)__(.*)$' -and $n -notlike "__warm__*") {
                Invoke-Psmux @("-L", $Matches[1], "kill-session", "-t", $Matches[2]) | Out-Null
            } else {
                Invoke-Psmux @("kill-session", "-t", $n) | Out-Null
            }
        }
        foreach ($pf in Get-ChildItem $PSMUXDIR -Filter "*.pid" -File -EA SilentlyContinue) {
            $raw = (Get-Content $pf.FullName -Raw -EA SilentlyContinue)
            if ($raw -and $raw.Trim() -match '^(\d+)') {
                $procId = [int]$Matches[1]
                $p = Get-Process -Id $procId -EA SilentlyContinue
                if ($p -and $p.ProcessName -eq "psmux") { try { Stop-Process -Id $procId -Force -EA SilentlyContinue } catch {} }
            }
        }
    }
    Start-Sleep -Milliseconds 800
    Remove-Item $SANDBOX -Recurse -Force -EA SilentlyContinue
}

Write-Host ""
Write-Host "=== Issue #530: registry file accumulation ===" -ForegroundColor Cyan
Write-Host "  sandbox home: $SANDBOX" -ForegroundColor DarkGray
Write-Host "  binary:       $PSMUX" -ForegroundColor DarkGray

try {

# ============================================================================
# A: kill-session lifecycle (the control -- this path is expected to be clean)
# ============================================================================
Write-Host "`n[A] kill-session lifecycle leaves nothing behind" -ForegroundColor Yellow

$N = 5
for ($i = 1; $i -le $N; $i++) {
    Invoke-Psmux @("new-session", "-d", "-s", "acc$i") | Out-Null
    Wait-SessionPort "acc$i" | Out-Null
}
for ($i = 1; $i -le $N; $i++) { Invoke-Psmux @("kill-session", "-t", "acc$i") | Out-Null }
Start-Sleep -Seconds 3
Show-Dir "after kill-session on $N sessions"
$res = Get-Residue
if ($res.Count -eq 0) { Write-Pass "A1: kill-session removed the entire registry set for all $N sessions" }
else { Write-Fail "A1: kill-session stranded $($res.Count) file(s): $(($res.Name | Select-Object -First 10) -join ', ')" }

# ============================================================================
# B: kill-server teardown -- the reported .sid strand
# ============================================================================
Write-Host "`n[B] kill-server must remove the whole set, including .sid" -ForegroundColor Yellow

Clear-Dir
$ks = "ksrv"
Invoke-Psmux @("new-session", "-d", "-s", $ks) | Out-Null
if (Wait-SessionPort $ks) {
    Show-Dir "live session '$ks'"
    Invoke-Psmux @("kill-server", "-t", $ks) | Out-Null
    Start-Sleep -Seconds 3
    Show-Dir "after kill-server"
    $res = Get-Residue
    if ($res.Count -eq 0) { Write-Pass "B1: kill-server removed the ENTIRE registry set" }
    else { Write-Fail "B1: kill-server stranded: $(($res.Name) -join ', ')" }
} else { Write-Fail "B1: session '$ks' never came up" }

# ============================================================================
# C: repeated kill-server rounds -- monotonic growth
# ============================================================================
Write-Host "`n[C] repeated kill-server rounds must not grow the directory" -ForegroundColor Yellow

Clear-Dir
for ($round = 1; $round -le 3; $round++) {
    for ($i = 1; $i -le 3; $i++) {
        $n = "r${round}s$i"
        Invoke-Psmux @("new-session", "-d", "-s", $n) | Out-Null
        Wait-SessionPort $n | Out-Null
        Invoke-Psmux @("kill-server", "-t", $n) | Out-Null
        Start-Sleep -Milliseconds 700
    }
    $c = (Get-Residue).Count
    Write-Info "after round ${round} (3 sessions created+kill-server'd): residue = $c file(s)"
}
$res = Get-Residue
if ($res.Count -eq 0) { Write-Pass "C1: 9 create/kill-server cycles left 0 residue" }
else { Write-Fail "C1: 9 create/kill-server cycles left $($res.Count) file(s): $(($res.Name | Select-Object -First 12) -join ', ')" }

# ============================================================================
# D: orphaned files (no sibling .port) are unreachable by any sweep
# ============================================================================
Write-Host "`n[D] a registry file with no sibling .port is never reclaimed" -ForegroundColor Yellow

Clear-Dir
# Fabricate an aged backlog exactly like the one in the report.
$fab = @()
foreach ($ext in @("sid", "pid", "key", "spawnlock")) {
    for ($i = 0; $i -lt 25; $i++) {
        $f = Join-Path $PSMUXDIR "bulk$i.$ext"
        Set-Content -Path $f -Value "999999" -Encoding ASCII -NoNewline
        (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-21)
        $fab += "bulk$i.$ext"
    }
}
Write-Info "fabricated $($fab.Count) orphaned registry files, all 21 days old, no .port anywhere"

$sw2 = "sweeper"
Enable-Sweep
Invoke-Psmux @("new-session", "-d", "-s", $sw2) | Out-Null
Wait-SessionPort $sw2 | Out-Null
Start-Sleep -Seconds 3
Enable-Sweep
Invoke-Psmux @("list-sessions") | Out-Null
Invoke-Psmux @("kill-session", "-t", $sw2) | Out-Null
Start-Sleep -Seconds 2

$left = (Get-ChildItem $PSMUXDIR -Filter "bulk*" -File -EA SilentlyContinue).Count
Write-Info "orphans remaining after a full session lifecycle ran over the directory: $left / $($fab.Count)"
if ($left -eq 0) { Write-Pass "D1: orphaned registry files are reclaimed by a startup sweep" }
else { Write-Fail "D1: $left / $($fab.Count) orphaned registry files were NEVER reclaimed" }

# ============================================================================
# E: hard-killed server -- Drop never runs
# ============================================================================
Write-Host "`n[E] hard-killed server: .spawnlock and set reclaimed later?" -ForegroundColor Yellow

Clear-Dir
$hk = "hardkill"
Invoke-Psmux @("new-session", "-d", "-s", $hk) | Out-Null
if (Wait-SessionPort $hk) {
    $victim = $null
    $pidFile = Join-Path $PSMUXDIR "$hk.pid"
    if (Test-Path $pidFile) {
        $raw = (Get-Content $pidFile -Raw).Trim()
        if ($raw -match '^(\d+)') { $victim = [int]$Matches[1] }
    }
    if ($victim) {
        # Plant a spawnlock owned by the victim, as a warm spawn in flight would.
        $lockFile = Join-Path $PSMUXDIR "$hk.spawnlock"
        Set-Content -Path $lockFile -Value "$victim" -Encoding ASCII -NoNewline
        Write-Info "hard-killing psmux pid $victim (SIGKILL equivalent: Drop cannot run)"
        try { Stop-Process -Id $victim -Force -EA Stop } catch { Write-Info "stop failed: $_" }
        Start-Sleep -Seconds 2
        Show-Dir "immediately after the hard kill"

        # The .port/.key/.sid/.pid set is reaped on genuine liveness (the pid is
        # dead), so it needs no help. Only the .spawnlock does: it becomes
        # portless once that set goes, and a portless file must age past the
        # startup grace window before it can be judged. Age just that one rather
        # than sleeping for the whole window -- and note that backdating .pid or
        # .port instead would fake a dead server through two OLDER guards
        # (#448 pid recycle, pre-boot port) and prove nothing about #530.
        $lock = Get-Item $lockFile -EA SilentlyContinue
        if ($lock) { $lock.LastWriteTime = (Get-Date).AddMinutes(-30) }

        $sw3 = "postkill"
        Enable-Sweep
        Invoke-Psmux @("new-session", "-d", "-s", $sw3) | Out-Null
        Wait-SessionPort $sw3 | Out-Null
        Start-Sleep -Seconds 2
        Show-Dir "after an unrelated session started (sweep opportunity)"

        $hkLeft = @(Get-ChildItem $PSMUXDIR -Filter "$hk.*" -File -EA SilentlyContinue)
        if ($hkLeft.Count -eq 0) { Write-Pass "E1: dead server's registry set was reclaimed on the next startup" }
        else { Write-Fail "E1: dead server's files survive: $(($hkLeft.Name) -join ', ')" }
        Invoke-Psmux @("kill-session", "-t", $sw3) | Out-Null
    } else { Write-Fail "E1: could not read a pid for '$hk'" }
} else { Write-Fail "E1: session '$hk' never came up" }

# ============================================================================
# F: namespace churn -- disposable -L namespaces, torn down COMPLETELY
# ============================================================================
Write-Host "`n[F] disposable -L namespaces must not accumulate" -ForegroundColor Yellow

Clear-Dir
$instDirEarly = Join-Path $PSMUXDIR "instances"

# First: a LIVE namespace must keep its identity token across a sweep. Re-minting
# it would read as a server restart to anything watching #{server_instance}.
Invoke-Psmux @("-L", "keepme", "new-session", "-d", "-s", "work") | Out-Null
if (Wait-SessionPort "keepme__work") {
    $tokBefore = @(Get-ChildItem $instDirEarly -File -EA SilentlyContinue | Where-Object { $_.Name -like "keepme*" })
    $tokValue = if ($tokBefore.Count -eq 1) { (Get-Content $tokBefore[0].FullName -Raw).Trim() } else { "" }
    if (Test-Path $instDirEarly) {
        Get-ChildItem $instDirEarly -File -EA SilentlyContinue |
            ForEach-Object { try { $_.LastWriteTime = (Get-Date).AddMinutes(-30) } catch {} }
    }
    Enable-Sweep
    Invoke-Psmux @("list-sessions") | Out-Null
    Start-Sleep -Milliseconds 600
    $tokAfter = @(Get-ChildItem $instDirEarly -File -EA SilentlyContinue | Where-Object { $_.Name -like "keepme*" })
    $tokValue2 = if ($tokAfter.Count -eq 1) { (Get-Content $tokAfter[0].FullName -Raw).Trim() } else { "" }
    if ($tokAfter.Count -eq 1 -and $tokValue -ne "" -and $tokValue2 -eq $tokValue) {
        Write-Pass "F0: a LIVE namespace keeps its identity token (value unchanged: $tokValue)"
    } else {
        Write-Fail "F0: live namespace token changed or was pruned ('$tokValue' -> '$tokValue2')"
    }
    Invoke-Psmux @("-L", "keepme", "kill-server", "-t", "work") | Out-Null
    Start-Sleep -Milliseconds 500
    $wp = Join-Path $PSMUXDIR "keepme____warm__.pid"
    if (Test-Path $wp) {
        $raw = (Get-Content $wp -Raw -EA SilentlyContinue)
        if ($raw -and $raw.Trim() -match '^(\d+)') {
            $procId = [int]$Matches[1]
            $p = Get-Process -Id $procId -EA SilentlyContinue
            if ($p -and $p.ProcessName -eq "psmux") { try { Stop-Process -Id $procId -Force -EA SilentlyContinue } catch {} }
        }
    }
} else { Write-Fail "F0: namespace 'keepme' never came up" }
Clear-Dir

$nsRounds = 4
for ($i = 1; $i -le $nsRounds; $i++) {
    $ns = "nsp$i"
    Invoke-Psmux @("-L", $ns, "new-session", "-d", "-s", "work") | Out-Null
    Wait-SessionPort "${ns}__work" | Out-Null
    Invoke-Psmux @("-L", $ns, "kill-server", "-t", "work") | Out-Null
    Start-Sleep -Milliseconds 500
    # kill-server leaves the namespace's warm helper running (issue #459), so
    # take it down too: this scenario is about a namespace that is FULLY dead.
    $wpid = Join-Path $PSMUXDIR "${ns}____warm__.pid"
    if (Test-Path $wpid) {
        $raw = (Get-Content $wpid -Raw -EA SilentlyContinue)
        if ($raw -and $raw.Trim() -match '^(\d+)') {
            $procId = [int]$Matches[1]
            $p = Get-Process -Id $procId -EA SilentlyContinue
            if ($p -and $p.ProcessName -eq "psmux") { try { Stop-Process -Id $procId -Force -EA SilentlyContinue } catch {} }
        }
    }
    Start-Sleep -Milliseconds 400
}
Start-Sleep -Seconds 1
Show-Dir "after $nsRounds disposable namespaces created and FULLY torn down"

# Age everything past the startup grace window, then give a sweep a chance.
Get-ChildItem $PSMUXDIR -File -EA SilentlyContinue |
    ForEach-Object { try { $_.LastWriteTime = (Get-Date).AddMinutes(-30) } catch {} }
$instDir = Join-Path $PSMUXDIR "instances"
if (Test-Path $instDir) {
    Get-ChildItem $instDir -File -EA SilentlyContinue |
        ForEach-Object { try { $_.LastWriteTime = (Get-Date).AddMinutes(-30) } catch {} }
}
Invoke-SweepUntilDrained -MaxPasses 6
Show-Dir "after a sweep pass"

$instCount = 0
$instNames = @()
if (Test-Path $instDir) {
    $instFiles = @(Get-ChildItem $instDir -File -EA SilentlyContinue)
    $instCount = $instFiles.Count
    $instNames = $instFiles.Name
}
Write-Info "instances/ entries: $instCount  ($($instNames -join ', '))"
$livePorts = @(Get-ChildItem $PSMUXDIR -Filter "*.port" -File -EA SilentlyContinue).Count
Write-Info "live .port files at this point: $livePorts"

$res = Get-Residue
if ($res.Count -eq 0) { Write-Pass "F1: fully dead namespaces left no registry residue" }
else { Write-Fail "F1: $($res.Count) file(s) left by $nsRounds dead namespaces: $(($res.Name | Select-Object -First 12) -join ', ')" }

$nsTokens = @($instNames | Where-Object { $_ -like "nsp*" }).Count
if ($nsTokens -eq 0) { Write-Pass "F2: instances/ tokens for dead namespaces were reclaimed" }
else { Write-Fail "F2: instances/ holds $nsTokens token(s) for namespaces with no live server" }

# ============================================================================
# G: an orphaned .sid backlog must not break "$N" session-id resolution
# ============================================================================
Write-Host "`n[G] `$N id resolution with an orphaned .sid backlog" -ForegroundColor Yellow

Clear-Dir
$live = "idlive"
Invoke-Psmux @("new-session", "-d", "-s", $live) | Out-Null
if (Wait-SessionPort $live) {
    $sidFile = Join-Path $PSMUXDIR "$live.sid"
    $myId = if (Test-Path $sidFile) { (Get-Content $sidFile -Raw).Trim() } else { "?" }
    Write-Info "live session '$live' has session id $myId"

    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    $clean = Invoke-Psmux @("display-message", "-t", "`$$myId", "-p", "#{session_name}")
    $t0.Stop()
    Write-Info ("clean dir:  '`$$myId' -> '{0}' in {1:N0}ms" -f $clean.Out.Trim(), $t0.Elapsed.TotalMilliseconds)

    for ($i = 0; $i -lt 3000; $i++) {
        Set-Content -Path (Join-Path $PSMUXDIR "junk$i.sid") -Value "$($i + 5000)" -Encoding ASCII -NoNewline
    }
    $t1 = [System.Diagnostics.Stopwatch]::StartNew()
    $dirty = Invoke-Psmux @("display-message", "-t", "`$$myId", "-p", "#{session_name}")
    $t1.Stop()
    Write-Info ("3000 orphans: '`$$myId' -> '{0}' in {1:N0}ms" -f $dirty.Out.Trim(), $t1.Elapsed.TotalMilliseconds)

    if ($dirty.Out.Trim() -eq $live) { Write-Pass "G1: id lookup still resolves correctly with a 3000 file backlog" }
    else { Write-Fail "G1: id lookup returned '$($dirty.Out.Trim())', expected '$live'" }

    # Those 3000 were written seconds ago. A young portless set is exactly what
    # a server still coming up looks like (registry files are written before the
    # .port beacon), so the sweep must NOT take them yet. That guarantee is the
    # entire reason the grace window exists.
    $youngLeft = (Get-ChildItem $PSMUXDIR -Filter "junk*.sid" -File -EA SilentlyContinue).Count
    if ($youngLeft -eq 3000) { Write-Pass "G2: young orphans are protected by the startup grace window" }
    else { Write-Fail "G2: $(3000 - $youngLeft) young orphan(s) were pruned inside the grace window" }

    # Age them past the window, then give a sweep a chance.
    Get-ChildItem $PSMUXDIR -Filter "junk*.sid" -File -EA SilentlyContinue |
        ForEach-Object { $_.LastWriteTime = (Get-Date).AddMinutes(-30) }
    Invoke-Psmux @("kill-session", "-t", $live) | Out-Null
    Start-Sleep -Seconds 2
    Invoke-SweepUntilDrained -MaxPasses 20
    $junkLeft = (Get-ChildItem $PSMUXDIR -Filter "junk*.sid" -File -EA SilentlyContinue).Count
    if ($junkLeft -eq 0) { Write-Pass "G3: the aged 3000 orphan backlog was reclaimed" }
    else { Write-Fail "G3: $junkLeft / 3000 orphan .sid files still on disk" }
} else { Write-Fail "G1: session '$live' never came up" }

# ============================================================================
# H: Win32 TUI -- a real attached window must survive an aggressive sweep
# ============================================================================
Write-Host "`n[H] real attached session survives the sweep and stays usable" -ForegroundColor Yellow

Clear-Dir
$tui = "tuilive"
Use-SandboxEnv
$proc = $null
try {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session", "-s", $tui) -PassThru
} finally { Restore-Env }
Start-Sleep -Seconds 5

if (Wait-SessionPort $tui) {
    Show-Dir "attached TUI session '$tui' is live"

    # Plant an aged orphan backlog right next to the live session's own files.
    foreach ($ext in @("sid", "key", "pid", "spawnlock")) {
        for ($i = 0; $i -lt 20; $i++) {
            $f = Join-Path $PSMUXDIR "decoy$i.$ext"
            Set-Content -Path $f -Value "999999" -Encoding ASCII -NoNewline
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-9)
        }
    }
    # Age the LIVE session's .key/.sid too: they must be saved by having a .port
    # sibling, not merely by being young.
    #
    # .port and .pid are deliberately NOT backdated. Their mtimes already carry
    # meaning to two OLDER mechanisms, and faking them fakes a dead server:
    # a .port older than the last boot is reaped by the boot guard in
    # cleanup_stale_port_files, and a .pid written before its process was
    # created is read as a recycled PID by the #448 anchor. Either one would
    # tear down this live session for reasons that have nothing to do with #530.
    Get-ChildItem $PSMUXDIR -Filter "$tui.*" -File -EA SilentlyContinue |
        Where-Object { $_.Extension -eq ".key" -or $_.Extension -eq ".sid" } |
        ForEach-Object { $_.LastWriteTime = (Get-Date).AddDays(-9) }

    Invoke-SweepUntilDrained -MaxPasses 3
    Show-Dir "after the sweep ran with the TUI session attached"

    $decoysLeft = (Get-ChildItem $PSMUXDIR -Filter "decoy*" -File -EA SilentlyContinue).Count
    if ($decoysLeft -eq 0) { Write-Pass "H1: TUI: 80 aged orphans swept" }
    else { Write-Fail "H1: TUI: $decoysLeft / 80 aged orphans survived" }

    $mine = @(Get-ChildItem $PSMUXDIR -Filter "$tui.*" -File -EA SilentlyContinue).Name
    $need = @("$tui.port", "$tui.key", "$tui.sid", "$tui.pid")
    $missing = @($need | Where-Object { $mine -notcontains $_ })
    if ($missing.Count -eq 0) { Write-Pass "H2: TUI: the live session's whole registry set survived" }
    else { Write-Fail "H2: TUI: sweep removed live session files: $($missing -join ', ')" }

    # And the session is still operable through the surviving credentials.
    $nm = (Invoke-Psmux @("display-message", "-t", $tui, "-p", "#{session_name}")).Out.Trim()
    if ($nm -eq $tui) { Write-Pass "H3: TUI: session still answers after the sweep (auth intact)" }
    else { Write-Fail "H3: TUI: display-message returned '$nm', expected '$tui'" }

    Invoke-Psmux @("split-window", "-v", "-t", $tui) | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = (Invoke-Psmux @("display-message", "-t", $tui, "-p", "#{window_panes}")).Out.Trim()
    if ($panes -eq "2") { Write-Pass "H4: TUI: split-window still works after the sweep" }
    else { Write-Fail "H4: TUI: expected 2 panes, got '$panes'" }

    Invoke-Psmux @("kill-session", "-t", $tui) | Out-Null
    Start-Sleep -Seconds 2
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
} else {
    Write-Fail "H1: attached TUI session '$tui' never came up"
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
}

} finally {
    Cleanup-Sandbox
    Restore-Env
    Remove-Item Env:\PSMUX_TEST_SANDBOX -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
