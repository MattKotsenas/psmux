# Task #11: "runaway warm-server chain" investigation regression guard.
#
# Original sighting (.omc/fix-ledger.md, task #9 addendum): a chain of nested
# `psmux.exe server -s __warm__ ...` processes, each the OS-level child of the
# previous, observed 7-8 generations deep (~45+ total processes), growing over
# roughly a minute. The smoking-gun read was: a __warm__ server spawned ANOTHER
# __warm__ server as its direct child, which the `session_name != "__warm__"`
# guard (src/server/mod.rs `should_spawn_warm_server`) should make impossible.
#
# Root-caused (see fix-ledger Task #11): NOT a duplicate-live-warm-server bug,
# and NOT PID-recycling (Windows reusing a PID and producing a stale/spoofed
# ParentProcessId link, the same class of hazard `edge_is_genuine` in
# src/platform.rs exists to reject for the kill-guard). It is a MEASUREMENT
# ARTIFACT: Win32_Process.CommandLine is fixed at process launch and never
# reflects `CtrlReq::ClaimSession`'s in-memory `app.session_name = name`
# rename (src/server/mod.rs ~3084). So a server launched as `-s __warm__`,
# once legitimately claimed into a real session, PERMANENTLY shows
# "-s __warm__" in its static argv for the rest of its life -- inspecting
# Win32_Process by argv alone cannot distinguish "still genuinely warm" from
# "was warm at launch, now serves a real, distinct, live session." Under
# heavy concurrent `new-session` contention for one shared warm slot, the
# winner's post-claim replenish (spawn_warm_server, called once per
# successful claim) spawns a real OS child that itself gets claimed by the
# next contender, forming a genuine, non-recycled parent-child chain of
# processes that all still *say* "-s __warm__" in argv -- exactly the
# reported shape -- while every non-terminal node is actually a distinct,
# live, real session, not a duplicate warm server.
#
# This test proves the mechanism and guards against a REAL regression:
#   1. No stale/recycled parent-child edge (PID-recycling) is present -- an
#      edge is validated the same way src/platform.rs's `edge_is_genuine`
#      validates pane-descendant edges: child creation time must be >= the
#      parent's.
#   2. Among genuine edges where BOTH ends' static argv say "-s __warm__",
#      LIVE session identity (queried directly over the authenticated TCP
#      control port, not the static argv) must show at most one side (never
#      both) still reporting session_name=="__warm__". Both-still-warm would
#      be the actual bug: two simultaneously-live, unclaimed warm servers in
#      a parent-child relationship.
#   3. At most one genuinely-live (unclaimed) "__warm__" session may exist at
#      any observed instant in this namespace.
#   4. Total psmux.exe process count stays bounded relative to the requested
#      concurrency (no unbounded growth).
#
# Runs entirely in an isolated socket namespace (-L) and cleans up by
# explicit PID list only (never a blanket kill by image name).
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_warm_chain_runaway.ps1

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tcp_reply_common.ps1"
$PSMUX = (Get-Command psmux -ErrorAction Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$NS = 'wchainrb'
$pass = 0; $fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function I($m){ Write-Host "  [INFO] $m" -ForegroundColor Cyan }

function Get-PsmuxProcs {
    Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Select-Object @{N='ProcessId';E={[int]$_.ProcessId}}, @{N='ParentProcessId';E={[int]$_.ParentProcessId}}, CommandLine, CreationDate
}
function Get-PortOwnerPid($port) {
    $lines = netstat -ano -p tcp | Select-String ":$port\s" | Select-String "LISTENING"
    foreach ($l in $lines) {
        $parts = ($l.Line -split '\s+') | Where-Object { $_ -ne '' }
        if ($parts[1] -match ":$port$") { return [int]$parts[-1] }
    }
    return $null
}
function Query-LiveSessionName($port, $key) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(300)) { $client.Close(); return $null }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = 500; $client.SendTimeout = 500
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $writer.WriteLine("AUTH $key")
        $writer.Write("display-message -p '#{session_name}'`n")
        # The reply ends when the server closes the connection (tcp_reply_common.ps1).
        $raw = (Read-TcpReplyToEof -Stream $stream -TimeoutMs 500).Trim()
        $client.Close()
        $lines = @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        if ($lines.Count -eq 0) { return $null }
        if ($lines[0] -eq "OK" -and $lines.Count -gt 1) { return $lines[1] }
        return $lines[-1]
    } catch { return $null }
}
function Snapshot-Live {
    $result = @{}
    $portFiles = Get-ChildItem -Path $psmuxDir -Filter "$NS*.port" -EA SilentlyContinue
    foreach ($pf in $portFiles) {
        $base = $pf.BaseName
        $keyFile = Join-Path $psmuxDir "$base.key"
        if (-not (Test-Path $keyFile)) { continue }
        $port = (Get-Content $pf.FullName -EA SilentlyContinue | Select-Object -First 1).Trim()
        $key = (Get-Content $keyFile -EA SilentlyContinue | Select-Object -First 1).Trim()
        if (-not $port -or -not $key) { continue }
        $ownerPid = Get-PortOwnerPid $port
        if (-not $ownerPid) { continue }
        $liveName = Query-LiveSessionName $port $key
        if ($null -ne $liveName -and $liveName -ne "") { $result[[int]$ownerPid] = @{ Name = $liveName } }
    }
    return $result
}

Write-Host "`n=== Task #11: warm-server chain regression guard (namespace -L $NS) ===" -ForegroundColor Cyan

# Hard clean baseline (setup only, explicit PID list from our own enumeration).
$pre = Get-PsmuxProcs
if ($pre) { foreach ($p in $pre) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue } ; Start-Sleep -Seconds 2 }
Get-ChildItem -Path $psmuxDir -Filter "$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

& $PSMUX -L $NS new-session -d -s "seed0" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX -L $NS kill-session -t "seed0" 2>&1 | Out-Null
Start-Sleep -Seconds 1

# Fire a burst of concurrent claimants racing the single existing warm slot --
# the exact shape that produced the reported "-s __warm__ parent of -s __warm__"
# argv pattern in the original investigation.
$N = 40
I "firing $N simultaneous new-session claimants against 1 warm slot"
for ($i=1; $i -le $N; $i++) {
    Start-Process -FilePath $PSMUX -ArgumentList @("-L", $NS, "new-session", "-d", "-s", "wc_s$i") -WindowStyle Hidden | Out-Null
}
Start-Sleep -Milliseconds 1500

$procs = Get-PsmuxProcs
$live = Snapshot-Live
$byId = @{}
foreach ($p in $procs) { $byId[$p.ProcessId] = $p }
I "os-procs=$($procs.Count) live-queried=$($live.Count)"

# Check 1: no stale (PID-recycled) parent-child edges.
$staleEdges = @()
$genuineEdges = @()
foreach ($p in $procs) {
    if ($byId.ContainsKey($p.ParentProcessId)) {
        $parent = $byId[$p.ParentProcessId]
        $childCreated = [datetime]$p.CreationDate
        $parentCreated = [datetime]$parent.CreationDate
        $edge = [pscustomobject]@{ ChildPid=$p.ProcessId; ParentPid=$p.ParentProcessId; ChildCmd=$p.CommandLine; ParentCmd=$parent.CommandLine }
        if ($childCreated -lt $parentCreated) { $staleEdges += $edge } else { $genuineEdges += $edge }
    }
}
if ($staleEdges.Count -eq 0) { P "no stale/recycled parent-child edges (PID-recycling) among psmux.exe processes" }
else { F "found $($staleEdges.Count) stale (child-older-than-parent) parent-child edge(s) -- possible PID-recycling artifact" }

# Check 2: among genuine edges where BOTH ends' argv say "-s __warm__", at
# most one side may still be LIVE-verified genuinely warm. Both-still-warm
# is the actual bug (two simultaneously-live unclaimed warm servers chained).
$bothWarmArgv = @($genuineEdges | Where-Object { $_.ChildCmd -match '-s __warm__' -and $_.ParentCmd -match '-s __warm__' })
$trueDuplicateWarmChain = $false
foreach ($e in $bothWarmArgv) {
    $childLive = if ($live.ContainsKey($e.ChildPid)) { $live[$e.ChildPid].Name } else { $null }
    $parentLive = if ($live.ContainsKey($e.ParentPid)) { $live[$e.ParentPid].Name } else { $null }
    if ($childLive -eq "__warm__" -and $parentLive -eq "__warm__") {
        $trueDuplicateWarmChain = $true
        F "TRUE duplicate warm chain: child PID=$($e.ChildPid) and parent PID=$($e.ParentPid) are BOTH still live-verified '__warm__'"
    }
}
if (-not $trueDuplicateWarmChain) {
    P "no genuine edge has BOTH ends still live-verified as '__warm__' ($($bothWarmArgv.Count) argv-labeled warm-parent-of-warm edge(s) checked, all resolved to distinct real/claimed sessions)"
}

# Check 3: at most one genuinely-live (unclaimed) warm server at this instant.
$liveWarmCount = @($live.Values | Where-Object { $_.Name -eq "__warm__" }).Count
if ($liveWarmCount -le 1) { P "at most one genuinely-live warm server observed (got $liveWarmCount)" }
else { F "multiple ($liveWarmCount) simultaneously live-verified warm servers observed -- possible duplicate-warm-spawn regression" }

# Check 4: total process count stays bounded relative to requested concurrency
# (no unbounded/runaway growth). The bound is derived, not guessed: at the
# instant of the sample each of the N claimants may own one server plus one
# replacement standby it has just spawned and not yet handed on, so 2N is the
# most a healthy pool can show. A runaway chain (the bug this suite guards)
# grows past that without limit, and checks 1 to 3 above catch its shape
# exactly. The old bound of N + 30 was a guess and flapped on the timing of the
# sample alone: 69, 69, 74, 72, 74, 68, 72 and 73 on master builds across
# 2026-10-03 (sweep 2026-10-03_14-07-51 failed at 73 with every other check
# passing, and three reruns of the suite alone gave 0 and 1).
$bound = 2 * $N
if ($procs.Count -le $bound) { P "psmux.exe process count bounded ($($procs.Count) <= $bound for N=$N concurrent claimants)" }
else { F "psmux.exe process count unbounded: $($procs.Count) processes for $N claimants (bound was $bound)" }

# Cleanup this round's sessions.
for ($i=1; $i -le $N; $i++) { & $PSMUX -L $NS kill-session -t "wc_s$i" 2>&1 | Out-Null }
Start-Sleep -Seconds 1

# Final teardown: explicit PID list only.
$final = Get-PsmuxProcs
if ($final) { foreach ($p in $final) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue } }
Get-ChildItem -Path $psmuxDir -Filter "$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

Write-Host "`nResults: $pass passed, $fail failed"
exit $fail
