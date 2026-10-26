# kill-server must end the namespace's warm standby too.
#
# `psmux -L ns new-session -d -s x` followed at once by `psmux -L ns
# kill-server` left the namespace's `__warm__` standby running. The session
# server spawns its standby a moment after it registers, and the standby only
# registers a few hundred milliseconds later; kill-server enumerated the
# registry in between, ended the session server and returned, and the standby
# registered afterwards with nothing left to end it. A benchmark leaked 37
# namespaces this way, and an orphan rebuilt its data directory after the
# directory had been deleted. Measured on the unfixed build (10 rounds each):
#
#   gap 0 ms     leaked 10/10
#   gap 20 ms    leaked  0/10, dead standby registry files left 6/10
#   gap 50+ ms   leaked  0/10
#   data dir deleted right after kill-server: orphan alive 10/10, and it
#   recreated the directory
#
# tmux's kill-server ends the whole server; psmux's standby is our own
# addition and has to die with the namespace.
#
# What this suite pins:
#   * new-session -d then kill-server at gaps 0 and 200 ms leaves no process of
#     the namespace and no registry file
#   * deleting the data dir right after kill-server leaves no process and the
#     directory stays deleted
#   * the warm pool still works after a kill: a new session in the same
#     namespace gets a fresh standby that the earlier kill does not touch, and
#     the next new-session claims it
#
# Every server started here lives in an isolated PSMUX_DATA_DIR and a unique
# `-L wo_<rand>` namespace. Cleanup is `-L <ns> kill-server` plus, for a
# leaked process of this suite's own namespace, Stop-Process by exact PID
# after its command line was checked to carry that namespace.
#
# Binary: PSMUX_TEST_BIN, else target\release of this checkout prepended to
# PATH (and checked with Get-Command).

$ErrorActionPreference = "Continue"
if ($env:PSMUX_TEST_BIN) {
    $env:PATH = (Split-Path $env:PSMUX_TEST_BIN) + ";" + $env:PATH
} else {
    $rel = (Resolve-Path "$PSScriptRoot\..\target\release" -EA SilentlyContinue).Path
    if ($rel) { $env:PATH = "$rel;" + $env:PATH }
}
$PSMUX = (Get-Command psmux -EA SilentlyContinue).Source
if (-not $PSMUX) { Write-Host "FATAL: psmux binary not found" -ForegroundColor Red; exit 1 }
Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

# Inherited session routing would aim these calls at somebody else's server.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_TARGET_SESSION = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null
$env:PSMUX_NO_WARM      = $null

$rig = Join-Path $env:TEMP ("psmux-killwarm-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $rig | Out-Null

function New-Ns { "wo_" + [guid]::NewGuid().ToString('N').Substring(0, 10) }

function Get-NsProcs($ns) {
    @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match "-L $ns(\s|$)" })
}

function Get-NsRegFiles($dd, $ns) {
    if (-not (Test-Path $dd)) { return @() }
    @(Get-ChildItem -File $dd -EA SilentlyContinue |
        Where-Object { $_.Name -like "${ns}__*" -and $_.Extension -in '.port', '.pid', '.key', '.sid' } |
        ForEach-Object Name)
}

function Clear-Ns($ns, $dd) {
    $env:PSMUX_DATA_DIR = $dd
    if (Test-Path $dd) { & $PSMUX -L $ns kill-server 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 300
    foreach ($p in (Get-NsProcs $ns)) {
        # Our own namespace, confirmed by command line above: exact PID only.
        Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue
    }
}

function Test-Round($gap, [switch]$DeleteDir) {
    $ns = New-Ns
    $dd = Join-Path $rig $ns
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    $env:PSMUX_DATA_DIR = $dd
    & $PSMUX -L $ns new-session -d -s x 2>&1 | Out-Null
    if ($gap -gt 0) { Start-Sleep -Milliseconds $gap }
    & $PSMUX -L $ns kill-server 2>&1 | Out-Null
    if ($DeleteDir) { Remove-Item -Recurse -Force $dd -EA SilentlyContinue }
    # The standby registers within about a second of its spawn; give it well
    # beyond that to show up if it is going to survive. With the data dir
    # deleted, wait past the 5 s registry self heal, which is what rebuilt the
    # directory on the unfixed build.
    Start-Sleep -Milliseconds $(if ($DeleteDir) { 7000 } else { 4000 })
    $procs = Get-NsProcs $ns
    $files = Get-NsRegFiles $dd $ns
    $dirBack = $DeleteDir -and (Test-Path $dd)
    $r = [pscustomobject]@{
        ns = $ns; procs = $procs.Count; files = $files.Count; dirBack = $dirBack
        detail = (($procs | ForEach-Object { "$($_.ProcessId)" }) -join ',') + ' ' + ($files -join ',')
    }
    if ($DeleteDir -and -not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Clear-Ns $ns $dd
    Remove-Item -Recurse -Force $dd -EA SilentlyContinue
    return $r
}

try {
    foreach ($case in @(@{ gap = 0; n = 10 }, @{ gap = 200; n = 5 })) {
        Write-Host "`n=== new-session -d, kill-server after $($case.gap) ms ($($case.n) rounds) ===" -ForegroundColor Cyan
        $rs = @(1..$case.n | ForEach-Object { Test-Round $case.gap })
        $leaked = @($rs | Where-Object { $_.procs -gt 0 })
        $stale = @($rs | Where-Object { $_.files -gt 0 })
        foreach ($x in @($rs | Where-Object { $_.procs -gt 0 -or $_.files -gt 0 })) { Write-Info "$($x.ns): $($x.detail)" }
        if ($leaked.Count -eq 0) { Write-Pass "no process of the namespace survived (0/$($case.n))" }
        else { Write-Fail "a process of the namespace survived kill-server in $($leaked.Count)/$($case.n) rounds" }
        if ($stale.Count -eq 0) { Write-Pass "no registry file of the namespace left (0/$($case.n))" }
        else { Write-Fail "registry files left in $($stale.Count)/$($case.n) rounds" }
    }

    Write-Host "`n=== data dir deleted right after kill-server (5 rounds) ===" -ForegroundColor Cyan
    $rs = @(1..5 | ForEach-Object { Test-Round 0 -DeleteDir })
    $leaked = @($rs | Where-Object { $_.procs -gt 0 })
    $back = @($rs | Where-Object { $_.dirBack })
    foreach ($x in $leaked) { Write-Info "$($x.ns): $($x.detail)" }
    if ($leaked.Count -eq 0) { Write-Pass "no orphan outlived its data dir (0/5)" }
    else { Write-Fail "an orphan outlived its data dir in $($leaked.Count)/5 rounds" }
    if ($back.Count -eq 0) { Write-Pass "the deleted data dir stayed deleted (0/5)" }
    else { Write-Fail "the deleted data dir was recreated in $($back.Count)/5 rounds" }

    Write-Host "`n=== the warm pool still works after a kill ===" -ForegroundColor Cyan
    $ns = New-Ns
    $dd = Join-Path $rig $ns
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    $env:PSMUX_DATA_DIR = $dd
    try {
        & $PSMUX -L $ns new-session -d -s a 2>&1 | Out-Null
        & $PSMUX -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        & $PSMUX -L $ns new-session -d -s b 2>&1 | Out-Null
        $warmPort = Join-Path $dd "${ns}____warm__.port"
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path $warmPort) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        # Several orphan check intervals: a standby the old kill wrongly
        # covered would be gone by now.
        Start-Sleep -Milliseconds 2500
        if (Test-Path $warmPort) { Write-Pass "a new standby registered after the kill and stayed up" }
        else { Write-Fail "no standby registered after a new session followed the kill" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $PSMUX -L $ns new-session -d -s c 2>&1 | Out-Null
        $sw.Stop()
        Write-Info ("new-session -s c took {0} ms" -f $sw.ElapsedMilliseconds)
        $names = @(& $PSMUX -L $ns ls -F '#{session_name}' 2>&1 | ForEach-Object { "$_".Trim() })
        if ($names -contains 'b' -and $names -contains 'c') { Write-Pass "sessions b and c both listed ($($names -join ','))" }
        else { Write-Fail "expected b and c, got '$($names -join ',')'" }
        # The standby that c claimed: c's server command line still says
        # __warm__ (a claimed standby keeps its argv), so a claim happened.
        $cPid = (Get-Content (Join-Path $dd "${ns}__c.pid") -EA SilentlyContinue) -replace ':.*$', ''
        $cCmd = if ($cPid) { (Get-CimInstance Win32_Process -Filter "ProcessId=$cPid" -EA SilentlyContinue).CommandLine } else { '' }
        if ($cCmd -match '__warm__') { Write-Pass "session c was served by the standby (warm claim)" }
        else { Write-Fail "session c was cold spawned, the standby was not claimed ('$cCmd')" }
        & $PSMUX -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 4000
        $left = Get-NsProcs $ns
        if ($left.Count -eq 0) { Write-Pass "kill-server ended sessions b, c and the replacement standby" }
        else { Write-Fail "$($left.Count) process(es) of the namespace left: $(($left | ForEach-Object ProcessId) -join ',')" }
    } finally {
        Clear-Ns $ns $dd
    }
} finally {
    $env:PSMUX_DATA_DIR = $null
    Remove-Item -Recurse -Force $rig -EA SilentlyContinue
}

Write-Host "`nResults: $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
