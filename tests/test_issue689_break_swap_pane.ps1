# =============================================================================
# Issue #689 E2E: break-pane -d / -s, the full break-pane flag set, and a
# swap-pane whose -s and -t live in two different windows.
#
# Reported by simon-bauer-sonarsource on psmux 3.3.8 (66cf613):
#   (a) `break-pane -d` always switched to the new window.
#   (b) `break-pane -s s:0.2` exited 0 and broke the ACTIVE pane instead.
#   (c) `swap-pane -s A -t B` did nothing at exit 0 when A and B were in
#       different windows.
#
# Layers, all self contained and in an isolated namespace:
#   1. CLI path   (main.rs -> server/connection.rs CLI dispatch)
#   2. raw TCP    (server/connection.rs control dispatch, no CLI in the way)
#   3. attached client window driven by CLI commands (the TUI proof)
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue689_break_swap_pane.ps1
# =============================================================================

param([switch]$Verbose)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info { param($m) Write-Host "  [INFO] $m" -ForegroundColor Cyan }
function Write-Test { param($m) Write-Host "  [TEST] $m" -ForegroundColor White }
function Write-Head { param($m) Write-Host "`n--- $m ---" -ForegroundColor Yellow }

# --- isolation: own data dir, own namespace, no warm pool -------------------
$NS = "bp689e"
$env:PSMUX_DATA_DIR = Join-Path $env:TEMP "bp689e-data"
$env:PSMUX_NO_WARM  = "1"
New-Item -ItemType Directory -Force -Path $env:PSMUX_DATA_DIR | Out-Null

# PSMUX_TEST_BIN pins the binary under test, which is how the pre fix counts
# for this suite were taken (build the parent commit, point this at it).
$PSMUX = $null
if ($env:PSMUX_TEST_BIN -and (Test-Path $env:PSMUX_TEST_BIN)) { $PSMUX = (Resolve-Path $env:PSMUX_TEST_BIN).Path }
if (-not $PSMUX) {
foreach ($cand in @("$PSScriptRoot\..\target-bp689\release\psmux.exe",
                    "$PSScriptRoot\..\target\release\psmux.exe",
                    "$PSScriptRoot\..\target\debug\psmux.exe")) {
    $p = Resolve-Path $cand -EA SilentlyContinue
    if ($p) { $PSMUX = $p.Path; break }
}
}
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }
Write-Info "Binary:   $PSMUX"
Write-Info "Data dir: $env:PSMUX_DATA_DIR"
Write-Info "Socket:   -L $NS"

$script:OpenedPids = @()

# No param block on purpose: every argument lands in $args verbatim, so a
# psmux flag like -t is never mistaken for a parameter of these helpers.
function P {
    $out = & $PSMUX -L $NS @args 2>&1 | Out-String
    $rc = $LASTEXITCODE
    return @{ out = $out.Trim(); code = $rc }
}
function Px {
    (& $PSMUX -L $NS @args 2>&1 | Out-String).Trim()
}

function Panes { param([string]$Sess)
    Px list-panes -a -t $Sess -F '#{window_index}.#{pane_index} #{pane_id} #{pane_active}'
}
function WinIndex { param([string]$Sess) Px display-message -p -t $Sess '#{window_index}' }

function New-Sess {
    param([string]$Name)
    & $PSMUX -L $NS kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    & $PSMUX -L $NS new-session -d -s $Name -x 120 -y 30 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if ((Px has-session -t $Name) -notmatch 'no ') { if ((Panes $Name)) { return $true } }
        Start-Sleep -Milliseconds 150
    }
    return $false
}
function Kill-Sess { param([string]$Name) & $PSMUX -L $NS kill-session -t $Name 2>&1 | Out-Null; Start-Sleep -Milliseconds 200 }

# --- raw TCP ----------------------------------------------------------------
function Send-Tcp {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    $base = "$($NS)__$Session"
    $portFile = Join-Path $env:PSMUX_DATA_DIR "$base.port"
    $keyFile  = Join-Path $env:PSMUX_DATA_DIR "$base.key"
    if (-not (Test-Path $portFile)) { return @{ ok = $false; err = "NO_PORT_FILE ($portFile)" } }
    if (-not (Test-Path $keyFile))  { return @{ ok = $false; err = "NO_KEY_FILE" } }
    try {
        $port = (Get-Content $portFile -Raw).Trim()
        $key  = (Get-Content $keyFile  -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($ns2)
        $wr.WriteLine("AUTH $key")
        $auth = $rd.ReadLine()
        if ($auth -ne "OK") { $tcp.Close(); return @{ ok = $false; err = "AUTH_FAIL: $auth" } }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $tcp.Close()
        return @{ ok = $true; resp = ($lines -join "`n") }
    } catch { return @{ ok = $false; err = $_.Exception.Message } }
}

function Assert-Eq {
    param($Label, $Expected, $Actual)
    if ("$Actual" -eq "$Expected") { Write-Pass "$Label (= '$Actual')" }
    else { Write-Fail "$Label -- expected '$Expected', got '$Actual'" }
}
function Assert-Match {
    param($Label, $Pattern, $Actual)
    if ("$Actual" -match $Pattern) { Write-Pass "$Label (matched '$Pattern')" }
    else { Write-Fail "$Label -- '$Actual' does not match '$Pattern'" }
}

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  Issue #689: break-pane -d / -s, swap-pane across windows" -ForegroundColor Magenta
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

# Start from an empty namespace. A half started server left by an aborted run
# answers with a stale window list, which reads as a phantom extra pane row.
# Scoped to this namespace and this data dir; nothing is killed by image name.
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
Get-ChildItem $env:PSMUX_DATA_DIR -Filter "$($NS)__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Write-Info "namespace reset; sessions now: '$(Px list-sessions)'"

# =============================================================================
# LAYER 1 - CLI path
# =============================================================================

Write-Head "(a) CLI: break-pane -d keeps the current window"
$S = "bp689_a"
if (-not (New-Sess $S)) { Write-Fail "session $S did not start"; }
else {
    Px split-window -h -t "$($S):0" | Out-Null
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ')"
    $r = P break-pane -d -t $S
    Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ')"
    Assert-Eq "break-pane -d exits 0" 0 $r.code
    Assert-Eq "the pane did move out (two windows now)" 2 ((Panes $S) -split "`r?`n" | Where-Object { $_ } ).Count
    Assert-Eq "#{window_index} stays 0 with -d" "0" (WinIndex $S)
    Kill-Sess $S
}

Write-Head "(a2) CLI: bare break-pane DOES switch (the -d contrast)"
$S = "bp689_a2"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px break-pane -t $S | Out-Null
    Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ')"
    Assert-Eq "bare break-pane switches to the new window" "1" (WinIndex $S)
    Kill-Sess $S
}

Write-Head "(b) CLI: break-pane -s moves the NAMED pane, not the active one"
$S = "bp689_b"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px split-window -v -t "$($S):0" | Out-Null
    Px select-pane -t "$($S):0.0" | Out-Null
    $before = Panes $S
    Write-Info "before: $($before -replace "`r?`n", ' | ')"
    $activeId = Px display-message -p -t $S '#{pane_id}'
    $namedId  = Px display-message -p -t "$($S):0.2" '#{pane_id}'
    Write-Info "active pane = $activeId ; -s names 0.2 = $namedId"
    $r = P break-pane -d -s "$($S):0.2" -t $S
    $after = Panes $S
    Write-Info "after:  $($after -replace "`r?`n", ' | ')"
    Assert-Eq "break-pane -s exits 0" 0 $r.code
    $moved = ($after -split "`r?`n" | Where-Object { $_ -match '^1\.' }) -join ' '
    Assert-Match "the pane named by -s ($namedId) is the one that moved" ([regex]::Escape($namedId)) $moved
    $stayed = ($after -split "`r?`n" | Where-Object { $_ -match '^0\.' }) -join ' '
    Assert-Match "the ACTIVE pane ($activeId) stayed in window 0" ([regex]::Escape($activeId)) $stayed
    Kill-Sess $S
}

Write-Head "(b2) CLI: break-pane -s by pane id, from another window"
$S = "bp689_b2"
if (New-Sess $S) {
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    $target = Px display-message -p -t "$($S):1.1" '#{pane_id}'
    $wBefore = WinIndex $S
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ') (current window $wBefore)"
    Write-Info "-s $target lives in window 1"
    $r = P break-pane -d -s $target -t $S
    $after = Panes $S
    Write-Info "after:  $($after -replace "`r?`n", ' | ')"
    Assert-Eq "exits 0" 0 $r.code
    $moved = ($after -split "`r?`n" | Where-Object { $_ -match '^2\.' }) -join ' '
    Assert-Match "$target was broken out of window 1 into window 2" ([regex]::Escape($target)) $moved
    Assert-Eq "-d left the current window where it was" $wBefore (WinIndex $S)
    Kill-Sess $S
}

Write-Head "(flags) CLI: -n names the window, -P prints where it landed"
$S = "bp689_f"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    $printed = Px break-pane -d -P -n "sidecar" -t $S
    Write-Info "-P printed: '$printed'"
    Assert-Match "-P prints session:window.pane" '^bp689_f:\d+\.\d+$' $printed
    $names = Px list-windows -t $S -F '#{window_index} #{window_name}'
    Write-Info "windows: $($names -replace "`r?`n", ' | ')"
    Assert-Match "-n named the new window" 'sidecar' $names
    Kill-Sess $S
}

Write-Head "(flags) CLI: -F overrides the -P template"
$S = "bp689_fmt"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    $id = Px display-message -p -t "$($S):0.1" '#{pane_id}'
    $printed = Px break-pane -d -P -F '#{pane_id}' -s "$($S):0.1" -t $S
    Write-Info "-F '#{pane_id}' printed: '$printed' (expected $id)"
    Assert-Eq "-P -F prints the requested format" $id $printed
    Kill-Sess $S
}

Write-Head "(flags) CLI: -t places the new window at a chosen index"
$S = "bp689_t"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    $r = P break-pane -d -t "$($S):7"
    $idx = Px list-windows -t $S -F '#{window_index}'
    Write-Info "window indices after -t 7: $($idx -replace "`r?`n", ',')"
    Assert-Eq "exits 0" 0 $r.code
    Assert-Match "the new window took index 7" '(^|,)7($|,)' ($idx -replace "`r?`n", ',')
    Kill-Sess $S
}

Write-Head "(flags) CLI: -a inserts right after the current window"
$S = "bp689_a3"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null      # index 1
    Px break-pane -d -a -t $S | Out-Null
    $rows = Px list-windows -t $S -F '#{window_index}'
    Write-Info "window indices after -a: $($rows -replace "`r?`n", ',')"
    Assert-Eq "-a shuffled the old window 1 up to 2" "0,1,2" ($rows -replace "`r?`n", ',')
    Kill-Sess $S
}

Write-Head "(errors) CLI: invalid targets exit non zero with tmux's message"
$S = "bp689_e"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null

    Write-Test "break-pane -s %999 (no such pane)"
    $r = P break-pane -s "%999" -t $S
    Write-Info "rc=$($r.code) out='$($r.out)'"
    if ($r.code -ne 0) { Write-Pass "exit code is non zero ($($r.code))" } else { Write-Fail "exit code was 0" }
    Assert-Match "tmux shaped message" "can't find pane" $r.out
    Assert-Eq "and nothing moved" 2 ((Panes $S) -split "`r?`n" | Where-Object { $_ }).Count

    Write-Test "break-pane -t with a PANE component (tmux refuses it)"
    $r = P break-pane -t "$($S):0.1"
    Write-Info "rc=$($r.code) out='$($r.out)'"
    if ($r.code -ne 0) { Write-Pass "exit code is non zero ($($r.code))" } else { Write-Fail "exit code was 0" }
    Assert-Match "tmux shaped message" "can't specify pane here" $r.out

    Write-Test "break-pane -t <index already in use>"
    Px new-window -d -t $S | Out-Null
    $r = P break-pane -t "$($S):1"
    Write-Info "rc=$($r.code) out='$($r.out)'"
    if ($r.code -ne 0) { Write-Pass "exit code is non zero ($($r.code))" } else { Write-Fail "exit code was 0" }
    Assert-Match "tmux shaped message" "index in use" $r.out

    Write-Test "swap-pane -t %999 (no such pane)"
    $r = P swap-pane -s "$($S):0.0" -t "%999"
    Write-Info "rc=$($r.code) out='$($r.out)'"
    if ($r.code -ne 0) { Write-Pass "exit code is non zero ($($r.code))" } else { Write-Fail "exit code was 0" }
    Assert-Match "tmux shaped message" "can't find pane" $r.out
    Kill-Sess $S
}

Write-Head "(c) CLI: swap-pane -s A -t B across two windows"
$S = "bp689_c"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    $before = Panes $S
    Write-Info "before: $($before -replace "`r?`n", ' | ')"
    $a = Px display-message -p -t "$($S):0.0" '#{pane_id}'
    $b = Px display-message -p -t "$($S):1.0" '#{pane_id}'
    Write-Info "swapping $a (0.0) with $b (1.0)"
    $r = P swap-pane -s "$($S):0.0" -t "$($S):1.0"
    $after = Panes $S
    Write-Info "after:  $($after -replace "`r?`n", ' | ')"
    Assert-Eq "exits 0" 0 $r.code
    $w0p0 = (($after -split "`r?`n" | Where-Object { $_ -match '^0\.0 ' }) -join ' ')
    $w1p0 = (($after -split "`r?`n" | Where-Object { $_ -match '^1\.0 ' }) -join ' ')
    Assert-Match "window 0 pane 0 now holds $b" ([regex]::Escape($b)) $w0p0
    Assert-Match "window 1 pane 0 now holds $a" ([regex]::Escape($a)) $w1p0
    Kill-Sess $S
}

Write-Head "(c2) CLI: cross window swap by pane id, and it swaps back"
$S = "bp689_c2"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    $a = Px display-message -p -t "$($S):0.1" '#{pane_id}'
    $b = Px display-message -p -t "$($S):1.1" '#{pane_id}'
    $orig = Panes $S
    Write-Info "before: $($orig -replace "`r?`n", ' | ')"
    Px swap-pane -s $a -t $b | Out-Null
    $mid = Panes $S
    Write-Info "swap:   $($mid -replace "`r?`n", ' | ')"
    Assert-Match "pane $b moved to window 0" ([regex]::Escape("0.1 $b")) $mid
    Px swap-pane -s $b -t $a | Out-Null
    $back = Panes $S
    Write-Info "back:   $($back -replace "`r?`n", ' | ')"
    Assert-Eq "swapping back restores the original layout" ($orig -replace "`r?`n", '|') ($back -replace "`r?`n", '|')
    Kill-Sess $S
}

Write-Head "(c3) CLI: swap-pane -d does not move the client's window"
$S = "bp689_c3"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    Px select-window -t "$($S):0" | Out-Null
    $a = Px display-message -p -t "$($S):0.0" '#{pane_id}'
    $b = Px display-message -p -t "$($S):1.0" '#{pane_id}'
    Px swap-pane -d -s "$($S):0.0" -t "$($S):1.0" | Out-Null
    Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ')"
    Assert-Eq "still on window 0" "0" (WinIndex $S)
    Assert-Match "the panes still traded places" ([regex]::Escape("0.0 $b")) (Panes $S)
    Assert-Match "and the other one arrived in window 1" ([regex]::Escape("1.0 $a")) (Panes $S)
    Kill-Sess $S
}

Write-Head "(join) CLI: join-pane -d grafts without switching"
# The client deliberately sits on a window that is NEITHER the source nor the
# destination, so "did it switch?" has a different answer with and without -d.
$S = "bp689_j"
if (New-Sess $S) {
    Px new-window -d -t $S | Out-Null          # window 1
    Px split-window -h -t "$($S):1" | Out-Null # window 1 gets a second pane
    Px new-window -d -t $S | Out-Null          # window 2, where the client waits
    Px select-window -t "$($S):2" | Out-Null
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ') (on window $(WinIndex $S))"
    Px join-pane -d -s "$($S):1.1" -t "$($S):0.0" | Out-Null
    Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ') (on window $(WinIndex $S))"
    Assert-Eq "join-pane -d did NOT move the client to the destination" "2" (WinIndex $S)
    Assert-Eq "window 0 now has two panes" 2 ((Panes $S) -split "`r?`n" | Where-Object { $_ -match '^0\.' }).Count

    Write-Test "and without -d it DOES switch (the contrast)"
    Px join-pane -s "$($S):0.1" -t "$($S):1.0" | Out-Null
    Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ') (on window $(WinIndex $S))"
    Assert-Eq "bare join-pane switched to the destination window" "1" (WinIndex $S)
    Kill-Sess $S
}

# =============================================================================
# LAYER 2 - raw TCP (the control dispatch, with no CLI in the way)
# =============================================================================

Write-Head "TCP: break-pane -d keeps the current window"
$S = "bp689_tcp"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ')"
    $r = Send-Tcp $S "break-pane -d"
    if (-not $r.ok) { Write-Fail "TCP send failed: $($r.err)" }
    else {
        Write-Info "after:  $((Panes $S) -replace "`r?`n", ' | ')"
        Assert-Eq "raw TCP break-pane -d stays on window 0" "0" (WinIndex $S)
        Assert-Eq "the pane still moved out" 2 ((Panes $S) -split "`r?`n" | Where-Object { $_ }).Count
    }
    Kill-Sess $S
}

Write-Head "TCP: break-pane -s names the pane to break"
$S = "bp689_tcp2"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px split-window -v -t "$($S):0" | Out-Null
    Px select-pane -t "$($S):0.0" | Out-Null
    $named = Px display-message -p -t "$($S):0.2" '#{pane_id}'
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ') ; -s $named"
    $r = Send-Tcp $S "break-pane -d -s $named"
    if (-not $r.ok) { Write-Fail "TCP send failed: $($r.err)" }
    else {
        $after = Panes $S
        Write-Info "after:  $($after -replace "`r?`n", ' | ')"
        $moved = ($after -split "`r?`n" | Where-Object { $_ -match '^1\.' }) -join ' '
        Assert-Match "raw TCP -s moved $named" ([regex]::Escape($named)) $moved
    }
    Kill-Sess $S
}

Write-Head "TCP: break-pane -P prints, and a bad -s is refused"
$S = "bp689_tcp3"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    $r = Send-Tcp $S "break-pane -d -P"
    Write-Info "-P replied: '$($r.resp)'"
    Assert-Match "raw TCP -P prints session:window.pane" 'bp689_tcp3:\d+\.\d+' $r.resp
    $r2 = Send-Tcp $S "break-pane -s %999"
    Write-Info "bad -s replied: '$($r2.resp)'"
    Assert-Match "raw TCP reports the refusal" "can't find pane" $r2.resp
    Kill-Sess $S
}

Write-Head "TCP: swap-pane across windows"
$S = "bp689_tcp4"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    $a = Px display-message -p -t "$($S):0.0" '#{pane_id}'
    $b = Px display-message -p -t "$($S):1.0" '#{pane_id}'
    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ')"
    $r = Send-Tcp $S "swap-pane -s $($S):0.0 -t $($S):1.0"
    if (-not $r.ok) { Write-Fail "TCP send failed: $($r.err)" }
    else {
        $after = Panes $S
        Write-Info "after:  $($after -replace "`r?`n", ' | ')"
        Assert-Match "raw TCP cross window swap put $b at 0.0" ([regex]::Escape("0.0 $b")) $after
        Assert-Match "raw TCP cross window swap put $a at 1.0" ([regex]::Escape("1.0 $a")) $after
    }
    Kill-Sess $S
}

# =============================================================================
# LAYER 3 - a real attached client window, driven by CLI commands (TUI proof)
# =============================================================================

Write-Head "TUI: a real attached client follows break-pane -d and the cross window swap"
$S = "bp689_tui"
if (New-Sess $S) {
    Px split-window -h -t "$($S):0" | Out-Null
    Px new-window -d -t $S | Out-Null
    Px split-window -h -t "$($S):1" | Out-Null
    Px select-window -t "$($S):0" | Out-Null

    # Attach a real client in its own console window. Its PID is recorded so
    # the window is closed again by PID at the end (never by image name).
    $proc = Start-Process -FilePath $PSMUX -ArgumentList @("-L", $NS, "attach-session", "-t", $S) -PassThru
    $script:OpenedPids += $proc.Id
    Write-Info "attached client pid $($proc.Id)"
    Start-Sleep -Seconds 3

    $clients = Px list-clients -t $S -F '#{client_name}'
    Write-Info "clients: $($clients -replace "`r?`n", ' | ')"
    if ($clients) { Write-Pass "a real client is attached" } else { Write-Fail "no client attached" }

    Write-Info "before: $((Panes $S) -replace "`r?`n", ' | ') (client on window $(WinIndex $S))"
    Px break-pane -d -s "$($S):0.1" -t $S | Out-Null
    Start-Sleep -Milliseconds 800
    Write-Info "after break-pane -d: $((Panes $S) -replace "`r?`n", ' | ') (client on window $(WinIndex $S))"
    Assert-Eq "the attached client stayed on window 0" "0" (WinIndex $S)

    $a = Px display-message -p -t "$($S):0.0" '#{pane_id}'
    $b = Px display-message -p -t "$($S):1.0" '#{pane_id}'
    Px swap-pane -s "$($S):0.0" -t "$($S):1.0" | Out-Null
    Start-Sleep -Milliseconds 800
    $after = Panes $S
    Write-Info "after swap: $($after -replace "`r?`n", ' | ')"
    Assert-Match "the live session shows $b in window 0" ([regex]::Escape("0.0 $b")) $after
    Assert-Match "the live session shows $a in window 1" ([regex]::Escape("1.0 $a")) $after

    # Prove the client is still alive and rendering after all that.
    if (Get-Process -Id $proc.Id -EA SilentlyContinue) { Write-Pass "the attached client survived the moves" }
    else { Write-Fail "the attached client died" }

    Px detach-client -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Kill-Sess $S
}

# =============================================================================
# Cleanup: kill only PIDs this script created, then the namespace server.
# =============================================================================
Write-Head "cleanup"
foreach ($pid2 in $script:OpenedPids) {
    $p = Get-Process -Id $pid2 -EA SilentlyContinue
    if ($p) { Stop-Process -Id $pid2 -Force -EA SilentlyContinue; Write-Info "closed pid $pid2" }
}
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$left = Px list-sessions
Write-Info "sessions left in -L $NS : '$left'"

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  PASSED: $script:TestsPassed   FAILED: $script:TestsFailed" -ForegroundColor Magenta
Write-Host "============================================================`n" -ForegroundColor Magenta
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
