# Issue #725: after join-pane pulled a pane into the current window, no pane
# had keyboard focus.  Typed keys reached no pane, and the pane the user saw as
# active was not the one tmux makes active.
#
# Root cause: the graft turns the target leaf into a split and the window's
# active_path, which named that leaf, was left naming the SPLIT.  The input
# path walks active_path to a pane and found none, so keys were dropped, while
# #{pane_active} falls back to the first child of a split and kept reporting
# the original pane.  A later command that saved and restored the focus by pane
# id re-anchored the path, so the defect showed as "the first line typed after
# join-pane from the command prompt goes nowhere".
#
# tmux: the joined pane becomes the active pane unless -d (cmd-join-pane.c:515
# to 517), -b grafts it before the target (SPAWN_BEFORE, :478), and without -d
# the target window is selected.
#
# Test 1 runs everywhere (CLI only).  Tests 2 to 6 type into a REAL attached
# client through tests\injector.cs (WriteConsoleInput into the client's
# console); a nonzero exit from the injector means the desktop refused the
# attach, which is reported as SKIP, not as a psmux result.
#
# On master 6fb5d8c 19 of 30 checks fail: the joined pane is never active and
# -b is ignored (test 1), the first line typed after a join from the command
# prompt lands in NO pane, with or without -d (tests 2, 3 and 6), and after a
# CLI join typed text lands in the old pane, not the joined one (tests 4, 5).
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue725_join_pane_focus.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i725join$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i725_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
$conf = Join-Path $root "empty.conf"
"" | Set-Content -Path $conf -Encoding ASCII

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injector = Join-Path $root "injector725.exe"
& $csc /nologo /platform:x64 /out:$injector (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $injector)) { Write-Host "FATAL: could not compile tests\injector.cs" -ForegroundColor Red; exit 1 }

Write-Host "`n=== Issue #725: join-pane leaves the window with a focused pane ===" -ForegroundColor Cyan
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function P { & $PSMUX -L $NS @args 2>&1 }
function Wait-Until([scriptblock]$cond, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 150 }
    return [bool](& $cond)
}
function Wait-Prompt($target) {
    Wait-Until { ((P capture-pane -p -t $target) -join "`n") -match 'PS [A-Z]:\\' } 15000 | Out-Null
}
# The pane id (%N) that is active in window $w of session $s.
function Active-In($s, $w) {
    ((P list-panes -t "${s}:$w" -F '#{pane_active} #{pane_id}') | Where-Object { "$_" -match '^1 ' } | ForEach-Object { ("$_" -split ' ')[1] }) -join ','
}
function Pane-Ids($s, $w) { ((P list-panes -t "${s}:$w" -F '#{pane_id}') | ForEach-Object { "$_".Trim() }) -join ' ' }
# Every pane of the session whose screen shows $mark, as "%N" (or NOWHERE).
function Where-Mark($s, $mark) {
    $hits = @()
    foreach ($line in (P list-panes -s -t $s -F '#{window_index}.#{pane_index}|#{pane_id}')) {
        $parts = "$line" -split '\|'
        if ($parts.Count -lt 2) { continue }
        $screen = (P capture-pane -p -t "${s}:$($parts[0])") -join "`n"
        if ($screen -match [regex]::Escape($mark)) { $hits += $parts[1].Trim() }
    }
    if ($hits.Count) { $hits -join ',' } else { 'NOWHERE' }
}
function Wait-Mark($s, $mark, [int]$ms = 6000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do { $w = Where-Mark $s $mark; if ($w -ne 'NOWHERE') { return $w }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
    return 'NOWHERE'
}
# Three one pane windows, :0 current.  Returns the pane ids of :0 :1 :2.
function New-ThreeWindows($s, [switch]$Attached) {
    if (-not $Attached) { P -f $conf new-session -d -s $s -x 160 -y 40 | Out-Null }
    Wait-Until { & $PSMUX -L $NS has-session -t $s 2>$null; $LASTEXITCODE -eq 0 } 15000 | Out-Null
    P new-window -d -t $s | Out-Null
    P new-window -d -t $s | Out-Null
    foreach ($w in 0, 1, 2) { Wait-Prompt "${s}:$w" }
    return @((Pane-Ids $s 0), (Pane-Ids $s 1), (Pane-Ids $s 2))
}
function Inject($clientPid, $keys) {
    & $injector $clientPid $keys 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

try {
    # =========================================================================
    # TEST 1: CLI join-pane, detached: which pane is active, and where do keys go
    # =========================================================================
    Write-Host "`n[Test 1] join-pane from the CLI (detached session)" -ForegroundColor Yellow
    $cases = @(
        @{ Name = 'join-pane -h -s :1 -t :0';    Args = @('-h','-s','t1a:1','-t','t1a:0');      S = 't1a'; Want = 'joined'; Order = 'orig,joined' },
        @{ Name = 'join-pane -v -s :1 -t :0';    Args = @('-v','-s','t1b:1','-t','t1b:0');      S = 't1b'; Want = 'joined'; Order = 'orig,joined' },
        @{ Name = 'join-pane -d -h -s :1 -t :0'; Args = @('-d','-h','-s','t1c:1','-t','t1c:0'); S = 't1c'; Want = 'orig';   Order = 'orig,joined' },
        @{ Name = 'join-pane -b -h -s :1 -t :0'; Args = @('-b','-h','-s','t1d:1','-t','t1d:0'); S = 't1d'; Want = 'joined'; Order = 'joined,orig' },
        @{ Name = 'move-pane -h -s :1 -t :0';    Args = @('-h','-s','t1e:1','-t','t1e:0');      S = 't1e'; Want = 'joined'; Order = 'orig,joined'; Cmd = 'move-pane' }
    )
    foreach ($c in $cases) {
        $ids = New-ThreeWindows $c.S
        $orig = $ids[0]; $joined = $ids[1]
        $cmd = if ($c.Cmd) { $c.Cmd } else { 'join-pane' }
        P $cmd @($c.Args) | Out-Null
        Start-Sleep -Milliseconds 500
        $want = if ($c.Want -eq 'joined') { $joined } else { $orig }
        $active = Active-In $c.S 0
        if ($active -eq $want) { Write-Pass "$($c.Name): $want is the active pane" }
        else { Write-Fail "$($c.Name): active pane is [$active], tmux makes it $want ($($c.Want))" }
        $order = ($c.Order -replace 'orig', $orig -replace 'joined', $joined) -replace ',', ' '
        $got = Pane-Ids $c.S 0
        if ($got -eq $order) { Write-Pass "$($c.Name): pane order [$got]" }
        else { Write-Fail "$($c.Name): pane order [$got], expected [$order]" }
        $mark = "M725$($c.S)"
        P send-keys -t $c.S "echo $mark" Enter | Out-Null
        $where = Wait-Mark $c.S $mark
        if ($where -eq $want) { Write-Pass "$($c.Name): send-keys to the session landed in $want" }
        else { Write-Fail "$($c.Name): send-keys to the session landed in [$where], expected $want" }
        P kill-session -t $c.S | Out-Null
    }

    # select-pane -L / -R after a join move between the two panes and back
    $ids = New-ThreeWindows 't1f'
    P join-pane -h -s 't1f:1' -t 't1f:0' | Out-Null
    Start-Sleep -Milliseconds 400
    P select-pane -t 't1f:0' -L | Out-Null
    $afterL = Active-In 't1f' 0
    P select-pane -t 't1f:0' -R | Out-Null
    $afterR = Active-In 't1f' 0
    if ($afterL -eq $ids[0] -and $afterR -eq $ids[1]) { Write-Pass "select-pane -L then -R after join: $afterL then $afterR" }
    else { Write-Fail "select-pane -L then -R after join: [$afterL] then [$afterR], expected $($ids[0]) then $($ids[1])" }
    P kill-session -t 't1f' | Out-Null

    # =========================================================================
    # TESTS 2 and 3: a real attached client, keys typed into its console
    # =========================================================================
    $conhost = "$env:WINDIR\System32\conhost.exe"
    $attachCases = @(
        @{ Name = 'prompt join-pane -h -s :1 (current window)'; S = 'a2'; Via = 'prompt'; Cmd = 'join-pane -h -s :1'; Win = 0 },
        @{ Name = 'prompt join-pane -d -h -s :1';                S = 'a2d'; Via = 'prompt'; Cmd = 'join-pane -d -h -s :1'; Win = 0; Detach = $true },
        @{ Name = 'CLI join-pane -h -s :1 -t :0';                S = 'a3'; Via = 'cli'; Cmd = 'join-pane -h -s a3:1 -t a3:0'; Win = 0 },
        @{ Name = 'CLI join-pane -h -s :1 -t :2 (window not current)'; S = 'a3b'; Via = 'cli'; Cmd = 'join-pane -h -s a3b:1 -t a3b:2'; Win = 2 },
        @{ Name = 'prompt join-pane -h -s :1 -t :2 (window not current)'; S = 'a2b'; Via = 'prompt'; Cmd = 'join-pane -h -s :1 -t :2'; Win = 2 }
    )
    $n = 1
    foreach ($c in $attachCases) {
        $n++
        Write-Host "`n[Test $n] attached client: $($c.Name)" -ForegroundColor Yellow
        $proc = Start-Process -FilePath $conhost -ArgumentList "`"$PSMUX`"", '-L', $NS, '-f', "`"$conf`"", 'new-session', '-s', $c.S, '-x', '160', '-y', '40' -WindowStyle Hidden -PassThru
        try {
            $ids = New-ThreeWindows $c.S -Attached
            $client = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | Where-Object { $_.Name -like 'psmux*' } | Select-Object -First 1
            if (-not $client) { Write-Fail "no psmux client under conhost $($proc.Id)"; continue }
            $cpid = [int]$client.ProcessId
            Wait-Until { (P list-clients | Out-String).Trim().Length -gt 0 } 8000 | Out-Null
            $orig = if ($c.Win -eq 2) { $ids[2] } else { $ids[0] }
            $joined = $ids[1]
            if ($c.Via -eq 'cli') {
                P @($c.Cmd -split ' ') | Out-Null
            } elseif (-not (Inject $cpid "^b{SLEEP:300}:$($c.Cmd){ENTER}")) {
                Write-Skip "injection refused by the desktop (not a psmux result)"; continue
            }
            Start-Sleep -Milliseconds 1200
            $want = if ($c.Detach) { $orig } else { $joined }
            # Nothing but typing between the join and the check: no CLI query
            # may run first, since a query that restores the focus by pane id
            # used to re-anchor the broken path and hide the defect.
            $mark1 = "T725A$($c.S)"
            if (-not (Inject $cpid "echo $mark1{ENTER}")) { Write-Skip "injection refused by the desktop (not a psmux result)"; continue }
            $where = Wait-Mark $c.S $mark1
            if ($where -eq $want) { Write-Pass "the first line typed after the join landed in $want" }
            else { Write-Fail "the first line typed after the join landed in [$where], expected $want" }
            $winNow = ((P display -p -t $c.S '#{window_index}') -join '').Trim()
            if ($winNow -eq "$($c.Win)") { Write-Pass "window $($c.Win) is current" }
            else { Write-Fail "current window is [$winNow], expected $($c.Win)" }
            if (-not $c.Detach) {
                # prefix Left moves to the original pane, prefix Right back.
                [void](Inject $cpid "^b{SLEEP:300}{LEFT}")
                Start-Sleep -Milliseconds 600
                $mark2 = "T725B$($c.S)"
                [void](Inject $cpid "echo $mark2{ENTER}")
                $where2 = Wait-Mark $c.S $mark2
                [void](Inject $cpid "^b{SLEEP:300}{RIGHT}")
                Start-Sleep -Milliseconds 600
                $mark3 = "T725C$($c.S)"
                [void](Inject $cpid "echo $mark3{ENTER}")
                $where3 = Wait-Mark $c.S $mark3
                if ($where2 -eq $orig -and $where3 -eq $joined) { Write-Pass "prefix Left typed into $where2, prefix Right typed into $where3" }
                else { Write-Fail "prefix Left typed into [$where2] (want $orig), prefix Right typed into [$where3] (want $joined)" }
            }
        } finally {
            P kill-session -t $c.S | Out-Null
            Start-Sleep -Milliseconds 500
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
        }
    }
} finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
