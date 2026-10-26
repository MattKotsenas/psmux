# Issue #598 follow up: the mouse wheel over pstop (a Windows htop) typed the raw
# SGR mouse report into pstop, which opened its incremental search and filled it
# with the digits of the report.
#
# Reporter larroy, 2026-09-22, on psmux 3.3.8 (66cf613 2026-08-18) with pstop 0.5.4:
#   "scrolling with the mouse wheel over pstop still corrupts the terminal /
#    triggers the same garbage-input behavior as before"
#
# Measured on 66cf613, one wheel notch at the pane centre, capture-pane:
#
#   Search: 64;61;15M[<64;61;15M[<64;61;15M_  Not found
#   EscCancel F3Next S-F3Prev F10Quit
#
# That is `ESC[<64;61;15M` read as typed characters.  pstop is a Win32 RECORD
# reader: it calls ReadConsoleInput and consumes INPUT_RECORDs, so a mouse report
# delivered as VT bytes arrives as a run of KEY_EVENTs, one per character.
#
# Two things had to be true for pstop to come out clean, and only the pair fixes it:
#
#   1357bc1 (#598)  a mouse report is only written to a pane whose application
#                   actually enabled a mouse protocol (tmux input-keys.c:805,
#                   `if (m->ignore || (s->mode & ALL_MOUSE_MODES) == 0) return;`).
#                   pstop DOES enable one, so this gate forwards for pstop and is
#                   not by itself what saves it.
#   dc6ff84 +
#   36bbaf7 (#623)  psmux no longer forces ENABLE_VIRTUAL_TERMINAL_INPUT on a pane
#                   whose child reads INPUT_RECORDs.  Without this the wheel reached
#                   pstop as conhost's VT translation, which is the garbage above.
#
# The pane must stay sane: pstop's function key footer stays "F1Help F2Setup
# F3Search...", never "EscCancel F3Next S-F3Prev", and no SGR report text appears
# anywhere on the screen.
#
# Layers: E2E with a real attached client, real WriteConsoleInput MOUSE_EVENT
#         wheel records, capture-pane content assertions, and the wheel gate's own
#         decision read back out of PSMUX_MOUSE_DEBUG.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$NS      = "i598pstop"
$SESSION = "test_i598_pstop"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Px { & $PSMUX -L $NS @args }

Write-Host "`n=== Issue #598 (pstop): the wheel must not type its own report into pstop ===" -ForegroundColor Cyan

# --- pstop is the subject of the report; without it there is nothing to measure.
$pstop = $null
foreach ($cand in @(
    (Get-Command pstop -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "$env:USERPROFILE\.cargo\bin\pstop.exe")) {
    if ($cand -and (Test-Path $cand)) { $pstop = $cand; break }
}
if (-not $pstop) {
    Write-Host "  [SKIP] pstop is not installed; this regression needs the reporter's tool" -ForegroundColor Yellow
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: 0"
    Write-Host "  Failed: 0"
    exit 0
}
Write-Host "  pstop: $pstop  ($(& $pstop --version))" -ForegroundColor DarkGray

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$inj = "$env:TEMP\psmux_i598_pstop_injector.exe"
Remove-Item $inj -Force -EA SilentlyContinue
& $csc /nologo /optimize /out:$inj (Join-Path $repoTests "mouse_injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $inj)) { Write-Host "FATAL: could not compile mouse_injector.cs" -ForegroundColor Red; exit 1 }

# The gate's decision is only written when the server itself has the flag, and a
# warm server spawned earlier would not have it.
$prevMouseDebug = $env:PSMUX_MOUSE_DEBUG
$prevNoWarm     = $env:PSMUX_NO_WARM
$env:PSMUX_MOUSE_DEBUG = "1"
$env:PSMUX_NO_WARM     = "1"
$mouseLog = "$psmuxDir\mouse_debug.log"
Remove-Item $mouseLog -Force -EA SilentlyContinue

$proc = $null
# The pane's process tree (shell and descendants), by PID and start time.  The
# app is quit with its own key before the session goes, and the test checks
# that nothing of the tree outlives the server: sweep 2026-10-02 ended with 48
# orphaned pstop processes each burning half a core.
function Get-PaneTreeRecs([int]$root) {
    $all = @(Get-CimInstance Win32_Process -EA SilentlyContinue); $by = @{}
    foreach ($p in $all) { $by[[int]$p.ProcessId] = $p }
    if (-not $by[$root]) { return @() }
    $out = @(); $q = [System.Collections.Queue]::new(); $q.Enqueue($root)
    while ($q.Count) {
        $id = $q.Dequeue(); $p = $by[$id]
        $out += [pscustomobject]@{ Pid = $id; Name = $p.Name; Start = $p.CreationDate }
        foreach ($c in $all) { if ([int]$c.ParentProcessId -eq $id -and [int]$c.ProcessId -ne $id -and $c.CreationDate -ge $p.CreationDate) { $q.Enqueue([int]$c.ProcessId) } }
    }
    $out
}
function Test-RecAlive($r) { $g = Get-Process -Id $r.Pid -EA SilentlyContinue; $g -and ([Math]::Abs(($g.StartTime - $r.Start).TotalSeconds) -lt 2) }
$script:paneTree = @()
function Cleanup {
    $pp = Px display-message -p -t $SESSION '#{pane_pid}' 2>$null
    if ($pp -match '^\d+$') { $script:paneTree = @(Get-PaneTreeRecs ([int]$pp)) }
    $apps = @($script:paneTree | Where-Object { $_.Name -match '^(pstop|htop)\.exe$' })
    if ($apps.Count) {
        foreach ($key in 'q', 'F10') {
            if (-not @($apps | Where-Object { Test-RecAlive $_ }).Count) { break }
            Px send-keys -t $SESSION $key 2>&1 | Out-Null
            for ($i = 0; $i -lt 15 -and @($apps | Where-Object { Test-RecAlive $_ }).Count; $i++) { Start-Sleep -Milliseconds 200 }
        }
        $still = @($apps | Where-Object { Test-RecAlive $_ })
        if ($still.Count) {
            Write-Fail "pstop did not quit on q or F10: $(($still | ForEach-Object { "$($_.Name):$($_.Pid)" }) -join ' ')"
            foreach ($r in $still) { Stop-Process -Id $r.Pid -Force -EA SilentlyContinue }
        } else { Write-Pass "pstop quit on its own key before the session was killed" }
    }
    Px kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Px kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    if ($script:proc) { try { Stop-Process -Id $script:proc.Id -Force -EA SilentlyContinue } catch {} }
    if ($script:paneTree.Count) {
        $left = @()
        for ($i = 0; $i -lt 25; $i++) { $left = @($script:paneTree | Where-Object { Test-RecAlive $_ }); if (-not $left.Count) { break }; Start-Sleep -Milliseconds 200 }
        if ($left.Count) {
            Write-Fail "the pane's processes outlived the server: $(($left | ForEach-Object { "$($_.Name):$($_.Pid)" }) -join ' ')"
            foreach ($r in $left) { Stop-Process -Id $r.Pid -Force -EA SilentlyContinue }
        } else { Write-Pass "nothing of the pane's process tree outlived the server" }
    }
}

try {
    $script:proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$SESSION -PassThru
    $up = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        Px has-session -t $SESSION 2>$null
        if ($LASTEXITCODE -eq 0) { $up = $true; break }
    }
    if (-not $up) {
        Write-Fail "the attached client never brought up session $SESSION"
    } else {
        Px set-option -t $SESSION -g mouse on 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        Px send-keys -t $SESSION "$pstop" Enter 2>&1 | Out-Null

        # Wait for pstop to take the alternate screen and paint its footer.
        $painted = $false
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 500
            $c = (Px capture-pane -p -t $SESSION 2>&1) -join "`n"
            if ($c -match 'F3Search' -and $c -match 'F10Quit') { $painted = $true; break }
        }
        if ($painted) { Write-Pass "pstop painted its full screen UI in the pane" }
        else { Write-Fail "pstop never painted (no F3Search/F10Quit footer)" }

        $alt = (Px display-message -t $SESSION -p '#{alternate_on}' 2>&1).Trim()
        if ($alt -eq "1") { Write-Pass "pstop holds the alternate screen (alternate_on=1)" }
        else { Write-Fail "pstop is not on the alternate screen (alternate_on=$alt)" }

        $geo = ((Px list-panes -t $SESSION -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}') | Select-Object -First 1) -split '\|'
        $target = $geo[0]
        $px = [int]$geo[1] + [int]([int]$geo[3] / 2)
        $py = [int]$geo[2] + [int]([int]$geo[4] / 2)

        # The reported gesture: scroll back over pstop.  Three notches up, three down.
        $corrupt = @()
        foreach ($dir in @("up","down")) {
            for ($n = 1; $n -le 3; $n++) {
                & $inj $script:proc.Id $dir 1 $px $py | Out-Null
                Start-Sleep -Milliseconds 900
                $screen = (Px capture-pane -p -t $target 2>&1) -join "`n"
                # The report reaching pstop as keystrokes shows up as its search
                # prompt carrying the digits of the SGR report.
                if ($screen -match 'Search:\s*\S') {
                    $corrupt += "$dir#${n}: " + (($screen -split "`n" | Where-Object { $_ -match 'Search:' } | Select-Object -First 1).Trim())
                } elseif ($screen -match '<?\d+;\d+;\d+M') {
                    $corrupt += "$dir#${n}: SGR report text on screen: " + (($screen -split "`n" | Where-Object { $_ -match '\d+;\d+;\d+M' } | Select-Object -First 1).Trim())
                }
            }
        }

        if ($corrupt.Count -eq 0) {
            Write-Pass "6 wheel notches over pstop left no search prompt and no SGR report text"
        } else {
            Write-Fail "BUG #598: pstop was corrupted on $($corrupt.Count) of 6 notches"
            $corrupt | Select-Object -First 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkRed }
        }

        $final = (Px capture-pane -p -t $target 2>&1) -join "`n"
        if ($final -match 'F1Help' -and $final -match 'F3Search' -and $final -notmatch 'EscCancel') {
            Write-Pass "pstop's function key footer survived the scrolling intact"
        } else {
            $foot = ($final -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
            Write-Fail "pstop's footer was replaced by its search bar: '$($foot.Trim())'"
        }

        # tmux alternate_on parity: a full screen app must not be hidden behind
        # the copy overlay (key-bindings.c:510, the alternate_on term).
        $mode = (Px display-message -t $target -p '#{pane_in_mode}' 2>&1).Trim()
        if ($mode -eq "0") { Write-Pass "psmux stayed out of copy mode over pstop (tmux alternate_on parity)" }
        else { Write-Fail "psmux entered copy mode over pstop (pane_in_mode=$mode)" }

        # The gate has to have made a decision, and for pstop it must be "forward":
        # pstop really does enable a mouse protocol, so tmux would `send -M` here.
        if (Test-Path $mouseLog) {
            $gate = @(Get-Content $mouseLog | Where-Object { $_ -match 'wheel gate: forward=' })
            if ($gate.Count -ge 6) { Write-Pass "the wheel gate logged a decision for every notch ($($gate.Count) lines)" }
            else { Write-Fail "the wheel gate logged only $($gate.Count) decisions for 6 notches" }

            $fwd = @($gate | Where-Object { $_ -match 'forward=true' })
            if ($fwd.Count -eq $gate.Count -and $gate.Count -gt 0) {
                Write-Pass "the gate forwarded to pstop, which owns a mouse protocol: $(($gate | Select-Object -Last 1).Trim())"
            } else {
                Write-Fail "the gate refused a pane that owns a mouse protocol ($($fwd.Count)/$($gate.Count) forwarded)"
            }
        } else {
            Write-Fail "PSMUX_MOUSE_DEBUG produced no log at $mouseLog"
        }
    }
} finally {
    Cleanup
    $env:PSMUX_MOUSE_DEBUG = $prevMouseDebug
    $env:PSMUX_NO_WARM     = $prevNoWarm
    Remove-Item $inj -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
