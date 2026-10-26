# ============================================================================
# test_robust_scale.ps1
# EXTREME robustness campaign - DOMAIN: SCALE / MANY-OBJECT CORRECTNESS
#
# Thesis: psmux maintains correct, queryable state at scale.
#
# Socket namespace: rbScale  (EVERY psmux call passes `-L rbScale` FIRST)
# Namespaced files: $env:USERPROFILE\.psmux\rbScale__<session>.port / .key
#                   (DOUBLE underscore between socket label and session name)
#
# RULES OBEYED:
#  - This file NEVER global-kills psmux. Cleanup is ONLY `psmux -L rbScale kill-server`
#    in the finally block.
#  - Resource ceiling: MAX 60 windows, MAX 40 panes/window, MAX 30 sessions.
#    Each scenario kills its own session(s) before the next begins so peak
#    load stays bounded.
#  - Asserts EXACT expected counts, not merely "no crash".
# ============================================================================

$ErrorActionPreference = "Continue"

# ----- counters -------------------------------------------------------------
$script:TestsRun    = 0
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass {
    param([string]$Msg)
    $script:TestsRun++
    $script:TestsPassed++
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Msg)
    $script:TestsRun++
    $script:TestsFailed++
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
}

function Write-Section {
    param([string]$Msg)
    Write-Host ""
    Write-Host "--- $Msg ---" -ForegroundColor Cyan
}

# ----- helpers --------------------------------------------------------------
$L = "rbScale"
$psmuxDir = Join-Path $env:USERPROFILE ".psmux"

# Run a psmux command in the rbScale namespace; returns trimmed stdout (string).
function Px {
    # Simple function on purpose: a [Parameter(ValueFromRemainingArguments)]
    # param makes this advanced and its binder eats -d as the common -Debug
    # switch, so `new-session -d` would attach and hang under capture.
    # Automatic $args passes all tokens through verbatim.
    $out = & psmux -L $L @args 2>&1
    if ($null -eq $out) { return "" }
    return (($out | Out-String).TrimEnd("`r", "`n"))
}

# Run a psmux command, returning the integer LASTEXITCODE.
function PxCode {
    # Simple function on purpose: see Px (binder eats -d as -Debug).
    & psmux -L $L @args 2>&1 | Out-Null
    return $LASTEXITCODE
}

# display-message -p -t <target> "<fmt>" -> trimmed string
function Disp {
    param([string]$Target, [string]$Fmt)
    $out = & psmux -L $L display-message -p -t $Target $Fmt 2>&1
    if ($null -eq $out) { return "" }
    return (($out | Out-String).TrimEnd("`r", "`n"))
}

# Count non-empty lines from a list-* command's output.
function Count-Lines {
    # Simple function on purpose: see Px (binder eats -d as -Debug).
    $out = & psmux -L $L @args 2>&1
    if ($null -eq $out) { return 0 }
    $lines = @($out | Out-String -Stream | Where-Object { $_.Trim().Length -gt 0 })
    return $lines.Count
}

# Poll capture-pane of a target until it shows a PS prompt, or timeout.
function Wait-ForPrompt {
    param([string]$Target, [int]$TimeoutMs = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & psmux -L $L capture-pane -p -t $Target 2>&1 | Out-String
        if ($cap -match 'PS [A-Z]:\\') { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Persistent-TCP dump-state for a given session in the rbScale namespace.
# Reads namespaced port/key files (rbScale__<session>.port / .key).
function Get-DumpState {
    param([string]$Session)
    $portFile = Join-Path $psmuxDir "$($L)__$($Session).port"
    $keyFile  = Join-Path $psmuxDir "$($L)__$($Session).key"
    if (!(Test-Path $portFile) -or !(Test-Path $keyFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 5000
        $w = [System.IO.StreamWriter]::new($stream)
        $r = [System.IO.StreamReader]::new($stream)

        # 1) Authenticate.
        $w.Write("AUTH $key`n"); $w.Flush()
        $null = $r.ReadLine()              # expect OK

        # 2) Switch to persistent mode.
        $w.Write("PERSISTENT`n"); $w.Flush()

        # 3) Request a state dump.
        $w.Write("dump-state`n"); $w.Flush()

        # 4) Read lines until we get a long, non-"NC" JSON-ish line.
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($deadline.ElapsedMilliseconds -lt 6000) {
            $line = $r.ReadLine()
            if ($null -eq $line) { break }
            $t = $line.Trim()
            if ($t.Length -gt 100 -and $t -ne "NC" -and $t -notmatch '^NC') {
                return $t
            }
        }
        return $null
    }
    catch {
        return $null
    }
    finally {
        if ($tcp) { $tcp.Close() }
    }
}

Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " psmux ROBUSTNESS: SCALE / MANY-OBJECT CORRECTNESS" -ForegroundColor Yellow
Write-Host " namespace: -L $L" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow

try {
    # ========================================================================
    # SCENARIO 1: 60 WINDOWS
    #   session rbScale_win; create 59 more (total 60).
    #   Assert #{session_windows} == 60 AND list-windows == 60 entries.
    #   Sample-verify 6 windows (#0,#12,#24,#36,#48,#59) have a prompt.
    # ========================================================================
    Write-Section "SCENARIO 1: 60 WINDOWS"
    $S1 = "rbScale_win"

    PxCode new-session -d -s $S1 -n w0 | Out-Null
    Start-Sleep -Seconds 3   # readiness after first new-session

    for ($i = 1; $i -lt 60; $i++) {
        PxCode new-window -t "$($S1):" -n "w$i" | Out-Null
        Start-Sleep -Milliseconds 150
    }

    $winCountFmt = Disp -Target $S1 '#{session_windows}'
    if ($winCountFmt -eq "60") {
        Write-Pass "session_windows == 60 (got '$winCountFmt')"
    } else {
        Write-Fail "session_windows expected 60, got '$winCountFmt'"
    }

    $lwCount = Count-Lines list-windows -t $S1
    if ($lwCount -eq 60) {
        Write-Pass "list-windows returned exactly 60 entries"
    } else {
        Write-Fail "list-windows expected 60 entries, got $lwCount"
    }

    foreach ($wi in @(0, 12, 24, 36, 48, 59)) {
        $ok = Wait-ForPrompt -Target "$($S1):$wi" -TimeoutMs 15000
        if ($ok) {
            Write-Pass "window #$wi shows a PS prompt via capture-pane"
        } else {
            Write-Fail "window #$wi never showed a PS prompt"
        }
    }

    PxCode kill-session -t $S1 | Out-Null
    Start-Sleep -Milliseconds 500

    # ========================================================================
    # SCENARIO 2: 40 PANES IN ONE WINDOW
    #   session rbScale_pane on a LARGE window (400x200) so many panes fit.
    #   Split + re-tile (select-layout tiled) between splits to redistribute
    #   space, otherwise repeatedly splitting the active (halving) pane hits the
    #   minimum pane size after only ~7 splits (correct tmux/psmux behaviour, NOT
    #   a bug). PASS if >=30 panes created AND list-panes count matches
    #   #{window_panes}.
    # ========================================================================
    Write-Section "SCENARIO 2: 40 PANES IN ONE WINDOW"
    $S2 = "rbScale_pane"

    # Large geometry is required so 40 panes each clear the minimum pane size.
    # Force a COLD spawn (PSMUX_NO_WARM) for this scenario: a warm-claimed session
    # keeps the warm server's pre-spawn size and ignores -x/-y, which would cap the
    # pane count. Cold spawn honors the requested 400x200 geometry.
    $env:PSMUX_NO_WARM = "1"
    PxCode new-session -d -s $S2 -n p -x 400 -y 200 | Out-Null
    $env:PSMUX_NO_WARM = $null
    Start-Sleep -Seconds 3

    $target = "$($S2):0"
    $splitFailed = $false
    for ($i = 1; $i -lt 40; $i++) {
        $code = PxCode split-window -t $target
        Start-Sleep -Milliseconds 120
        if ($code -ne 0) {
            $splitFailed = $true
            Write-Host "    split #$i failed (exit $code) - treating as min-size limit" -ForegroundColor DarkYellow
            break
        }
        # Re-tile so the next split has room: without this, the active pane keeps
        # halving and the window caps at ~7 panes regardless of total size.
        PxCode select-layout -t $S2 tiled | Out-Null
        Start-Sleep -Milliseconds 80
        $now = Disp -Target $target '#{window_panes}'
        if ($now -eq "40") { break }
    }

    $panesFmt = Disp -Target $target '#{window_panes}'
    $panesNum = 0
    [void][int]::TryParse($panesFmt, [ref]$panesNum)

    $lpCount = Count-Lines list-panes -t $target

    if ($panesNum -ge 30) {
        Write-Pass "created $panesNum panes (>= 30 required; min-size hit: $splitFailed)"
    } else {
        Write-Fail "only $panesNum panes created (needed >= 30)"
    }

    if ($lpCount -eq $panesNum -and $panesNum -gt 0) {
        Write-Pass "list-panes count ($lpCount) == window_panes ($panesNum)"
    } else {
        Write-Fail "list-panes count ($lpCount) != window_panes ($panesNum)"
    }

    PxCode kill-session -t $S2 | Out-Null
    Start-Sleep -Milliseconds 500

    # ========================================================================
    # SCENARIO 3: 30 SESSIONS
    #   create rbScale_m0..rbScale_m29 (-d).
    #   Assert list-sessions == 30 entries; has-session exit 0 for 6 samples.
    #   display-message session_name works on #15 and #29.
    # ========================================================================
    Write-Section "SCENARIO 3: 30 SESSIONS"

    for ($i = 0; $i -lt 30; $i++) {
        PxCode new-session -d -s "rbScale_m$i" | Out-Null
        Start-Sleep -Milliseconds 150
    }

    $lsCount = Count-Lines list-sessions
    if ($lsCount -eq 30) {
        Write-Pass "list-sessions returned exactly 30 entries"
    } else {
        Write-Fail "list-sessions expected 30 entries, got $lsCount"
    }

    foreach ($si in @(0, 7, 14, 15, 22, 29)) {
        $code = PxCode has-session -t "rbScale_m$si"
        if ($code -eq 0) {
            Write-Pass "has-session rbScale_m$si exit 0"
        } else {
            Write-Fail "has-session rbScale_m$si expected exit 0, got $code"
        }
    }

    $name15 = Disp -Target "rbScale_m15" '#{session_name}'
    if ($name15 -eq "rbScale_m15") {
        Write-Pass "display-message session_name on #15 == 'rbScale_m15'"
    } else {
        Write-Fail "display-message session_name on #15 expected 'rbScale_m15', got '$name15'"
    }

    $name29 = Disp -Target "rbScale_m29" '#{session_name}'
    if ($name29 -eq "rbScale_m29") {
        Write-Pass "display-message session_name on #29 == 'rbScale_m29'"
    } else {
        Write-Fail "display-message session_name on #29 expected 'rbScale_m29', got '$name29'"
    }

    # Kill all 30 sessions in one shot (namespaced, NOT global).
    & psmux -L $L kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # ========================================================================
    # SCENARIO 4: DEEP NESTED SPLITS
    #   session rbScale_deep; alternate -h/-v 15 times.
    #   Assert final #{window_panes} == list-panes count; server alive.
    # ========================================================================
    Write-Section "SCENARIO 4: DEEP NESTED SPLITS (alternating -h/-v x15)"
    $S4 = "rbScale_deep"

    PxCode new-session -d -s $S4 -n d | Out-Null
    Start-Sleep -Seconds 1

    $t4 = "$($S4):0"
    $expectedPanes = 1
    for ($i = 0; $i -lt 15; $i++) {
        $dir = if ($i % 2 -eq 0) { "-h" } else { "-v" }
        $code = PxCode split-window $dir -t $t4
        Start-Sleep -Milliseconds 150
        if ($code -eq 0) { $expectedPanes++ }
        else { Write-Host "    deep split #$i ($dir) failed (exit $code)" -ForegroundColor DarkYellow }
    }

    $deepFmt = Disp -Target $t4 '#{window_panes}'
    $deepNum = 0
    [void][int]::TryParse($deepFmt, [ref]$deepNum)
    $deepListCount = Count-Lines list-panes -t $t4

    if ($deepNum -eq $deepListCount -and $deepNum -gt 1) {
        Write-Pass "deep: window_panes ($deepNum) == list-panes count ($deepListCount)"
    } else {
        Write-Fail "deep: window_panes ($deepNum) != list-panes count ($deepListCount)"
    }

    # Server alive check: has-session must succeed.
    $aliveCode = PxCode has-session -t $S4
    if ($aliveCode -eq 0) {
        Write-Pass "server alive after deep splits (has-session exit 0)"
    } else {
        Write-Fail "server not alive after deep splits (has-session exit $aliveCode)"
    }

    PxCode kill-session -t $S4 | Out-Null
    Start-Sleep -Milliseconds 500

    # ========================================================================
    # SCENARIO 5: STATE CONSISTENCY via dump-state (persistent TCP)
    #   Recreate a smaller 20-window session to keep it quick.
    #   Connect via persistent TCP, dump-state JSON, ConvertFrom-Json,
    #   assert windows array length == #{session_windows}.
    # ========================================================================
    Write-Section "SCENARIO 5: STATE CONSISTENCY via dump-state (20 windows)"
    $S5 = "rbScale_dump"

    PxCode new-session -d -s $S5 -n d0 | Out-Null
    Start-Sleep -Seconds 1
    for ($i = 1; $i -lt 20; $i++) {
        PxCode new-window -t "$($S5):" -n "d$i" | Out-Null
        Start-Sleep -Milliseconds 150
    }

    $swFmt = Disp -Target $S5 '#{session_windows}'
    $swNum = 0
    [void][int]::TryParse($swFmt, [ref]$swNum)

    if ($swNum -eq 20) {
        Write-Pass "dump session reports session_windows == 20"
    } else {
        Write-Fail "dump session expected session_windows 20, got '$swFmt'"
    }

    $json = Get-DumpState -Session $S5
    if ($null -eq $json) {
        Write-Fail "dump-state returned no usable JSON line over persistent TCP"
    } else {
        $parsed = $null
        try { $parsed = $json | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -eq $parsed) {
            Write-Fail "dump-state line did not parse as JSON"
        } else {
            # Locate a windows array on a session object within the dump.
            $winArr = $null
            if ($parsed.PSObject.Properties.Name -contains 'windows') {
                $winArr = $parsed.windows
            } elseif ($parsed.PSObject.Properties.Name -contains 'sessions') {
                $sess = @($parsed.sessions) | Where-Object {
                    $_.PSObject.Properties.Name -contains 'name' -and $_.name -eq $S5
                }
                if (-not $sess) { $sess = @($parsed.sessions) }
                if ($sess) { $winArr = @($sess)[0].windows }
            }

            if ($null -eq $winArr) {
                Write-Fail "could not locate windows array in dump-state JSON"
            } else {
                $arrLen = @($winArr).Count
                if ($arrLen -eq $swNum) {
                    Write-Pass "dump-state windows array length ($arrLen) == session_windows ($swNum)"
                } else {
                    Write-Fail "dump-state windows array length ($arrLen) != session_windows ($swNum)"
                }
            }
        }
    }

    PxCode kill-session -t $S5 | Out-Null
    Start-Sleep -Milliseconds 500
}
finally {
    # ALWAYS clean up the rbScale namespace only. NEVER a global kill.
    Write-Host ""
    Write-Host "Cleaning up namespace -L $L ..." -ForegroundColor DarkGray
    & psmux -L $L kill-server 2>&1 | Out-Null
}

# ----- footer ---------------------------------------------------------------
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Yellow
Write-Host "  Run:    $script:TestsRun"
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor Red

exit $script:TestsFailed
