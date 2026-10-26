# Issue #271: Warm-created pane retains 2000-line scrollback despite configured history-limit
# Tests whether config-set history-limit actually applies to the pane's scrollback buffer

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup-Sessions {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    # Only the DEFAULT namespace's registry, which is what the bare kill-server
    # above tore down. A namespaced file is "<ns>__<session>.<ext>" with a
    # non-empty ns that does not start with an underscore ("__warm__" itself is
    # the default namespace's standby). The old "*.port" wildcard deleted every
    # -L namespace's registry too and knocked out every sibling server on the
    # machine (2026-09-16).
    Get-ChildItem "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -EA SilentlyContinue |
        Where-Object { $_.BaseName -notmatch '^[^_].*?__' } |
        Remove-Item -Force -EA SilentlyContinue
}

function Wait-PanePrompt {
    param([string]$Target, [int]$TimeoutMs = 15000, [string]$Pattern = "PS [A-Z]:\\")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
            if ($cap -match $Pattern) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Generate-Output {
    param([string]$Target, [int]$Lines = 5000)
    # Use a one-line PowerShell expression that emits N lines
    $cmd = "1..$Lines | ForEach-Object { `"line `$_`" }"
    & $PSMUX send-keys -t $Target $cmd Enter 2>&1 | Out-Null
}

function Wait-OutputComplete {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 30000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Marker) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Get-RetainedLines {
    param([string]$Target)
    # Capture deep scrollback and count "line N" occurrences
    $deep = & $PSMUX capture-pane -t $Target -S -200000 -p 2>&1 | Out-String
    if ($null -eq $deep -or $deep.Length -eq 0) { return @{ Total=0; Min=0; Max=0; Range="" } }
    $matches = [regex]::Matches($deep, '(?m)^line (\d+)\b')
    if ($matches.Count -eq 0) { return @{ Total=0; Min=0; Max=0; Range="" } }
    $nums = $matches | ForEach-Object { [int]$_.Groups[1].Value }
    $min = ($nums | Measure-Object -Minimum).Minimum
    $max = ($nums | Measure-Object -Maximum).Maximum
    return @{ Total=$matches.Count; Min=$min; Max=$max; Range="$min..$max" }
}

Write-Host "`n=== Issue #271: warm pane history-limit honoured? ===" -ForegroundColor Cyan

# Build a config that sets a very large history-limit
$configFile = "$env:TEMP\psmux_test_271.conf"
@"
set -g history-limit 100000
set -g mouse on
"@ | Set-Content -Path $configFile -Encoding UTF8

# === PART 1: COLD PATH (first session - this often gets the warm pane) ===
Write-Host "`n[Part 1] First session (cold path / warm pane consumer)" -ForegroundColor Yellow
Cleanup-Sessions

$env:PSMUX_CONFIG_FILE = $configFile
$SESSION1 = "issue271_cold"
& $PSMUX new-session -d -s $SESSION1 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-PanePrompt -Target $SESSION1)) {
    Write-Fail "Session 1: shell prompt did not appear within 15s"
} else {
    Write-Pass "Session 1: shell ready"

    # Verify the option is set
    $hl = (& $PSMUX show-options -g -v history-limit -t $SESSION1 2>&1).Trim()
    Write-Info "show-options -g -v history-limit = $hl"
    if ($hl -eq "100000") { Write-Pass "Session 1: global history-limit correctly reports 100000" }
    else { Write-Fail "Session 1: history-limit expected 100000, got '$hl'" }

    $hlp = (& $PSMUX display-message -t $SESSION1 -p '#{history_limit}' 2>&1).Trim()
    Write-Info "display-message #{history_limit} = $hlp"
    if ($hlp -eq "100000") { Write-Pass "Session 1: pane #{history_limit} reports 100000" }
    else { Write-Fail "Session 1: pane #{history_limit} expected 100000, got '$hlp'" }

    # Generate 5000 lines of output
    Write-Info "Generating 5000 lines of output..."
    Generate-Output -Target $SESSION1 -Lines 5000
    if (-not (Wait-OutputComplete -Target $SESSION1 -Marker "line 4990" -TimeoutMs 60000)) {
        Write-Fail "Session 1: 5000 lines did not all appear in pane within 60s"
    } else {
        Write-Pass "Session 1: 5000 lines generated"
        Start-Sleep -Seconds 2

        # Now check actual retained scrollback
        $r = Get-RetainedLines -Target $SESSION1
        Write-Info "Retained: $($r.Total) lines, range [$($r.Range)]"

        # The history_size format variable
        $hs = (& $PSMUX display-message -t $SESSION1 -p '#{history_size}' 2>&1).Trim()
        Write-Info "display-message #{history_size} = $hs"

        # If history-limit is honoured, we should retain ALL 5000 lines (since 5000 < 100000)
        # If bug is real, we'll see only ~2000 retained
        if ($r.Total -ge 4900) {
            Write-Pass "Session 1: scrollback retains all 5000 lines (history-limit honoured)"
        } elseif ($r.Total -lt 2500 -and $r.Total -gt 1500) {
            Write-Fail "Session 1: BUG CONFIRMED - only $($r.Total) lines retained (expected ~5000, history-limit=100000 NOT honoured)"
        } else {
            Write-Fail "Session 1: unexpected retention count $($r.Total) (expected ~5000)"
        }

        # Per the bug report: history_size should report ACTUAL retained, not configured limit
        if ($hs -eq "100000") {
            Write-Fail "Session 1: history_size=100000 looks like the CONFIGURED limit, not actual retention"
        } elseif ([int]$hs -gt 0 -and [int]$hs -lt 100000) {
            Write-Pass "Session 1: history_size=$hs reflects actual retained content (not just configured limit)"
        }
    }
}

& $PSMUX kill-session -t $SESSION1 2>&1 | Out-Null
Start-Sleep -Seconds 1

# === PART 2: SECOND SESSION (server still running, warm-pane respawn path) ===
Write-Host "`n[Part 2] Second session against same warm server" -ForegroundColor Yellow

# Don't kill server. Create another session - this exercises the warm-pane respawn
$SESSION2 = "issue271_warm"
& $PSMUX new-session -d -s $SESSION2 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-PanePrompt -Target $SESSION2)) {
    Write-Fail "Session 2: shell prompt did not appear within 15s"
} else {
    Write-Pass "Session 2: shell ready"

    $hl2 = (& $PSMUX show-options -g -v history-limit -t $SESSION2 2>&1).Trim()
    Write-Info "Session 2: show-options -g -v history-limit = $hl2"

    Generate-Output -Target $SESSION2 -Lines 5000
    if (Wait-OutputComplete -Target $SESSION2 -Marker "line 4990" -TimeoutMs 60000) {
        Start-Sleep -Seconds 2
        $r2 = Get-RetainedLines -Target $SESSION2
        Write-Info "Session 2 retained: $($r2.Total) lines, range [$($r2.Range)]"

        if ($r2.Total -ge 4900) {
            Write-Pass "Session 2: scrollback retains all 5000 lines"
        } elseif ($r2.Total -lt 2500 -and $r2.Total -gt 1500) {
            Write-Fail "Session 2: BUG CONFIRMED - only $($r2.Total) lines retained on warm server"
        } else {
            Write-Fail "Session 2: unexpected retention count $($r2.Total)"
        }
    }
}

& $PSMUX kill-session -t $SESSION2 2>&1 | Out-Null

# === PART 3: NEW WINDOW IN EXISTING SESSION (warm pane reuse) ===
Write-Host "`n[Part 3] new-window in existing session (warm-pane respawn path)" -ForegroundColor Yellow

$SESSION3 = "issue271_newwin"
& $PSMUX new-session -d -s $SESSION3 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX new-window -t $SESSION3 2>&1 | Out-Null
Start-Sleep -Seconds 4

# Get the new window's target
$panes = & $PSMUX list-panes -t $SESSION3 -F '#{window_index}.#{pane_index}' 2>&1
Write-Info "Session 3 panes: $panes"
$target3 = "${SESSION3}:1"

if (-not (Wait-PanePrompt -Target $target3)) {
    Write-Fail "Session 3 new window: shell prompt did not appear"
} else {
    Write-Pass "Session 3 new window: shell ready"

    Generate-Output -Target $target3 -Lines 5000
    if (Wait-OutputComplete -Target $target3 -Marker "line 4990" -TimeoutMs 60000) {
        Start-Sleep -Seconds 2
        $r3 = Get-RetainedLines -Target $target3
        Write-Info "Session 3 new-window retained: $($r3.Total) lines, range [$($r3.Range)]"

        if ($r3.Total -ge 4900) {
            Write-Pass "new-window scrollback retains all 5000 lines"
        } elseif ($r3.Total -lt 2500 -and $r3.Total -gt 1500) {
            Write-Fail "new-window: BUG CONFIRMED - only $($r3.Total) lines retained"
        } else {
            Write-Fail "new-window: unexpected retention count $($r3.Total)"
        }
    }
}

& $PSMUX kill-session -t $SESSION3 2>&1 | Out-Null

# === PART 4: BASELINE - command-set history-limit on a fresh pane ===
Write-Host "`n[Part 4] Baseline: set-option after pane created via command, then split-window" -ForegroundColor Yellow
$env:PSMUX_CONFIG_FILE = $null
$SESSION4 = "issue271_runtime"
& $PSMUX new-session -d -s $SESSION4 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Set after creation (no config file used this time)
& $PSMUX set-option -g history-limit 100000 -t $SESSION4 2>&1 | Out-Null
$hl4 = (& $PSMUX show-options -g -v history-limit -t $SESSION4 2>&1).Trim()
Write-Info "After set-option, history-limit = $hl4"

# Now split-window - does the NEW pane get the new limit?
& $PSMUX split-window -v -t $SESSION4 2>&1 | Out-Null
Start-Sleep -Seconds 4
$target4b = "${SESSION4}:0.1"

if (Wait-PanePrompt -Target $target4b) {
    Generate-Output -Target $target4b -Lines 5000
    if (Wait-OutputComplete -Target $target4b -Marker "line 4990" -TimeoutMs 60000) {
        Start-Sleep -Seconds 2
        $r4 = Get-RetainedLines -Target $target4b
        Write-Info "Split pane (set-option then split) retained: $($r4.Total) lines"
        if ($r4.Total -ge 4900) {
            Write-Pass "split-window after set-option: retains all 5000 lines"
        } elseif ($r4.Total -lt 2500) {
            Write-Fail "split-window after set-option: only $($r4.Total) retained - new pane did NOT pick up new limit"
        }
    }
}

& $PSMUX kill-session -t $SESSION4 2>&1 | Out-Null

# Cleanup
Cleanup-Sessions
Remove-Item $configFile -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
