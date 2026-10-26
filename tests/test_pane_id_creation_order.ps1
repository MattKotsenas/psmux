# test_pane_id_creation_order.ps1 - the Nth creation gets the Nth pane id.
#
# WHAT THIS PINS
#
# tmux allocates a pane id when the pane is created and the sequence never goes
# backwards, so scripts address panes as %1, %2, %3 on that basis. psmux pre
# spawns spare shells, and a spare's id is allocated when it is SPAWNED, not when
# it is claimed, because the id is planted in the shell's environment as
# TMUX_PANE and a child's environment cannot be rewritten afterwards. That makes
# the claim order the visible id order, and two things had broken it:
#
#   - The pool handed out the first spare to have LANDED, and refills are spawned
#     concurrently, so they land in whatever order the OS finishes them. Ten
#     splits in a row came out %2 %3 %4 %5 %12 %9 %11 %6 %7 %8.
#   - A claim preferred the first spare to be READY, which is also not id order
#     for the same reason.
#
# The visible symptom was tests/test_pr255_visual_proof.ps1 failing only when the
# session server had built its own pool: it splits twice and then addresses the
# panes as %2 and %3, and the inverted ids made the geometry assertions read
# upside down. tests/test_issue569_ambiguous_pane_id.ps1 failed the same way, on
# "beta owns %2".
#
# Cold and warm are both covered because they differ: a cold server builds its
# own pool, a warm one inherits the standby's.
#
# Readiness is "the active pane id changed AND that pane shows a prompt", so a
# split refused for lack of room cannot be counted as a creation.
param(
    [string]$Binary = "",
    [int]$Count = 10,
    [int]$SettleMs = 2500,
    [int]$PollMs = 10
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }

if (-not $Binary) { $Binary = $env:PSMUX_TEST_EXE }
if (-not $Binary) {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if ($cmd) { $Binary = $cmd.Source }
}
if (-not $Binary) {
    foreach ($n in @("psmux.exe", "pmux.exe", "tmux.exe")) {
        $c = Join-Path $PSScriptRoot "..\target\release\$n"
        if (Test-Path $c) { $Binary = $c; break }
    }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Fail "no psmux binary found"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
$Binary = (Resolve-Path $Binary).Path
$imgName = [IO.Path]::GetFileNameWithoutExtension($Binary).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) {
    Write-Fail "'$imgName' is not a recognised server image name; the warm server claim would be disabled"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
Write-Info "Using: $Binary"

$DataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR.TrimEnd('\', '/') } else { "$env:USERPROFILE\.psmux" }
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION = $null
$Ns = "pid$PID"
$Sess = "ord"
$PromptRe = 'PS [A-Z]:\\'

function Remove-Namespace {
    try { & $Binary -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 500
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# One authenticated round trip. Returns @{ ok; lines } and never a bare
# collection: PowerShell unrolls an empty one to $null, and new-window answers
# with no output at all.
function Invoke-Psmux {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 20000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $false
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $Key"); $wr.Flush()
        if ($rd.ReadLine() -ne "OK") { return @{ ok = $false; lines = @() } }
        $wr.WriteLine("TARGET $Sess")
        $wr.WriteLine($Cmd)
        $wr.Flush()
        $acc = New-Object System.Collections.Generic.List[string]
        while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $acc.Add($l) }
        return @{ ok = $true; lines = $acc.ToArray() }
    } catch { return @{ ok = $false; lines = @() } } finally { $tcp.Close() }
}
function Get-Text { param($r) if ($null -eq $r -or -not $r.ok) { return "" } return ($r.lines -join "`n") }

function Wait-Registered {
    param([int]$TimeoutMs = 20000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $pf = "$DataDir\$($Ns)__$Sess.port"; $kf = "$DataDir\$($Ns)__$Sess.key"
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            try {
                $p = [int](Get-Content $pf -Raw).Trim(); $k = (Get-Content $kf -Raw).Trim()
                if ($p -gt 0 -and $k) { return @{ Port = $p; Key = $k } }
            } catch {}
        }
        Start-Sleep -Milliseconds 10
    }
    return $null
}
function Get-ActiveId { param($i) (Get-Text (Invoke-Psmux $i.Port $i.Key "display-message -p '#{pane_id}'")).Trim().Trim("'") }
function Get-AllIds { param($i)
    @((Get-Text (Invoke-Psmux $i.Port $i.Key "list-panes -a -F '#{pane_id}'")) -split "`n" |
        ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ })
}
function To-Num { param([string[]]$ids) @($ids | ForEach-Object { [int]($_ -replace '%','') }) }
function Test-Increasing { param([int[]]$n)
    for ($k = 1; $k -lt $n.Count; $k++) { if ($n[$k] -le $n[$k-1]) { return $false } }
    return $true
}

# Starts a session and returns its connection info. `Warm` leaves the standby in
# place so the session claims it; otherwise the standby is retired first and the
# session server builds its own pool.
function Start-Session {
    param([switch]$Warm)
    Remove-Namespace
    if ($Warm) {
        # Create and discard one session so a standby exists to be claimed.
        Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-d", "-s", "seed" -WindowStyle Hidden | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 20000 -and -not (Test-Path "$DataDir\$($Ns)____warm__.port")) { Start-Sleep -Milliseconds 25 }
        Start-Sleep -Milliseconds 1200
    }
    Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-d", "-s", $Sess -WindowStyle Hidden | Out-Null
    $inf = Wait-Registered
    if ($null -eq $inf) { return $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 25000) {
        if ((Get-Text (Invoke-Psmux $inf.Port $inf.Key "capture-pane -p")) -match $PromptRe) { break }
        Start-Sleep -Milliseconds 10
    }
    Start-Sleep -Milliseconds $SettleMs
    return $inf
}

# ── sequential: the Nth creation gets the Nth id ──────────────────────────
function Test-Sequential {
    param([string]$Label, [string]$Cmd, [switch]$Warm, [switch]$KillAfter)
    Write-Test "$Label - $Count consecutive creations, ids must increase"
    $inf = Start-Session -Warm:$Warm
    if ($null -eq $inf) { Write-Fail "$Label - the session never registered"; Remove-Namespace; return }
    $seen = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $old = Get-ActiveId $inf
        $r = Invoke-Psmux $inf.Port $inf.Key $Cmd
        if (($r.lines -join ' ') -match 'too small|no space') { Write-Info "  refused at #$($i+1) for lack of room, stopping"; break }
        $sw = [Diagnostics.Stopwatch]::StartNew(); $id = $old
        while ($sw.ElapsedMilliseconds -lt 25000) {
            $id = Get-ActiveId $inf
            if ($id -and $id -ne $old -and (Get-Text (Invoke-Psmux $inf.Port $inf.Key "capture-pane -p -t $id")) -match $PromptRe) { break }
            Start-Sleep -Milliseconds $PollMs
        }
        if (-not $id -or $id -eq $old) { Write-Fail "$Label - creation #$($i+1) produced no pane"; Remove-Namespace; return }
        $seen += $id
        if ($KillAfter) { Invoke-Psmux $inf.Port $inf.Key "kill-pane" | Out-Null; Start-Sleep -Milliseconds 120 }
    }
    Remove-Namespace
    if ($seen.Count -lt $Count) { Write-Fail "$Label - only $($seen.Count) of $Count creations happened"; return }
    $nums = To-Num $seen
    if (Test-Increasing $nums) {
        Write-Pass "$Label ids are strictly increasing in creation order: $($seen -join ' ')"
    } else {
        Write-Fail "$Label ids are NOT in creation order: $($seen -join ' ') - a spare was handed out ahead of an older one"
    }
    # Contiguity is not promised by tmux and is not asserted, but when the whole
    # run is served from the pool it does hold, and saying so makes a future
    # regression easier to read.
    $contig = $true
    for ($k = 1; $k -lt $nums.Count; $k++) { if ($nums[$k] -ne $nums[$k-1] + 1) { $contig = $false } }
    Write-Info "  $Label contiguous: $contig"
}

# ── burst: no waiting at all between creations ────────────────────────────
function Test-Burst {
    param([int]$N = 5)
    Write-Test "burst of $N new-windows with no waiting, ids must still increase"
    $inf = Start-Session
    if ($null -eq $inf) { Write-Fail "burst - the session never registered"; Remove-Namespace; return }
    $before = Get-AllIds $inf
    for ($k = 0; $k -lt $N; $k++) { Invoke-Psmux $inf.Port $inf.Key "new-window" | Out-Null }
    Start-Sleep -Seconds 4
    $after = Get-AllIds $inf
    Remove-Namespace
    # `list-panes -a` walks windows in creation order, so for a burst of
    # new-window the listed order IS the creation order.
    $new = @($after | Where-Object { $before -notcontains $_ })
    if ($new.Count -lt $N) { Write-Fail "burst - only $($new.Count) of $N windows appeared"; return }
    $nums = To-Num $new
    if (Test-Increasing $nums) {
        Write-Pass "burst ids are strictly increasing: $($new -join ' ')"
    } else {
        Write-Fail "burst ids are NOT increasing: $($new -join ' ')"
    }
}

Write-Host ""
Write-Host ("=" * 76)
Write-Host " Pane ids must be handed out in creation order, pooled spares or not"
Write-Host ("=" * 76)

Test-Sequential -Label "split-window -v, cold server" -Cmd "split-window -v" -KillAfter
Test-Sequential -Label "split-window -h, cold server" -Cmd "split-window -h" -KillAfter
Test-Sequential -Label "new-window, cold server"      -Cmd "new-window"
Test-Sequential -Label "split-window -v, warm claim"  -Cmd "split-window -v" -Warm -KillAfter
Test-Sequential -Label "new-window, warm claim"       -Cmd "new-window"      -Warm
Test-Burst -N 5

Remove-Namespace
Write-Host ""
Write-Host ("Tests passed: {0}, failed: {1}" -f $script:TestsPassed, $script:TestsFailed) -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
