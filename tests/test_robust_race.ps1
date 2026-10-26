# test_robust_race.ps1
# EXTREME robustness campaign: LIFECYCLE RACES / CONCURRENT MUTATION SAFETY
#
# Thesis: overlapping / contradictory operations leave the psmux server in a
# consistent, ALIVE state with no orphan processes for the namespace.
#
# Namespace: rbRace  (EVERY psmux call passes -L rbRace FIRST)
# Namespaced port/key files live at: $env:USERPROFILE\.psmux\rbRace__<session>.port|.key
#                                     (DOUBLE underscore between socket name and session)
#
# RULES OBSERVED:
#   - Never global kill-server, never Get-Process psmux|Stop-Process.
#   - Cleanup ONLY via `& psmux -L rbRace kill-server` in finally.
#   - Prove EXPECTED outcomes (deterministic queries), not merely "no crash".

$ErrorActionPreference = "Continue"

$script:TestsPassed = 0
$script:TestsFailed = 0

$Socket   = "rbRace"
$PsmuxDir = Join-Path $env:USERPROFILE ".psmux"

function Write-Pass {
    param([string]$Message)
    $script:TestsPassed++
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    $script:TestsFailed++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

# Run a psmux command in this namespace, returning a hashtable with
# Out (stdout text), Err (stderr text) and Code (exit code).
function Invoke-Psmux {
    # Simple function on purpose (no param block): an advanced function's
    # binder eats -d as the common -Debug switch, so `new-session -d` would
    # attach and hang. Automatic $args passes all tokens through verbatim.
    $allArgs = @("-L", $Socket) + $args
    $out = & psmux @allArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String).Trim()
    return @{ Out = $text; Code = $code }
}

# Deterministic: does the session exist? Returns $true if has-session exits 0.
function Test-HasSession {
    param([string]$Name)
    $r = Invoke-Psmux has-session -t $Name
    return ($r.Code -eq 0)
}

# Count namespaced .port files currently present for this socket.
function Get-NamespacePortFileCount {
    if (-not (Test-Path $PsmuxDir)) { return 0 }
    $files = Get-ChildItem -Path $PsmuxDir -Filter "$($Socket)__*.port" -ErrorAction SilentlyContinue
    if ($null -eq $files) { return 0 }
    return @($files).Count
}

# Read a format value (e.g. #{session_windows}) for a target via display-message -p.
function Get-Format {
    param([string]$Target, [string]$Format)
    $r = Invoke-Psmux display-message -p -t $Target $Format
    if ($r.Code -ne 0) { return $null }
    $val = $r.Out
    # display-message may emit extra lines; take the last non-empty trimmed line.
    $lines = @($val -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    if ($lines.Count -eq 0) { return $null }
    return $lines[-1].Trim()
}

# Count windows reported by list-windows for a session.
function Get-ListWindowsCount {
    param([string]$Session)
    $r = Invoke-Psmux list-windows -t $Session
    if ($r.Code -ne 0) { return -1 }
    if ([string]::IsNullOrWhiteSpace($r.Out)) { return 0 }
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    return $lines.Count
}

# Count panes reported by list-panes for a window target.
function Get-ListPanesCount {
    param([string]$Target)
    $r = Invoke-Psmux list-panes -t $Target
    if ($r.Code -ne 0) { return -1 }
    if ([string]::IsNullOrWhiteSpace($r.Out)) { return 0 }
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    return $lines.Count
}

# Fire-and-forget a psmux command (overlapping, not awaited) as a background process.
function Start-PsmuxAsync {
    # Simple function on purpose: see Invoke-Psmux (binder eats -d as -Debug).
    $allArgs = @("-L", $Socket) + $args
    return Start-Process -FilePath "psmux" -ArgumentList $allArgs -NoNewWindow -PassThru
}

# Safely wait for a collection of jobs with a timeout, then force-remove them.
# Never let a job hang the script.
function Resolve-Jobs {
    param([object[]]$Jobs, [int]$TimeoutSec = 30)
    if ($null -eq $Jobs -or $Jobs.Count -eq 0) { return }
    try {
        Wait-Job -Job $Jobs -Timeout $TimeoutSec | Out-Null
    } catch {
        Write-Info "Wait-Job raised: $($_.Exception.Message)"
    }
    foreach ($j in $Jobs) {
        try { Receive-Job -Job $j -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Write-Host "================ psmux ROBUSTNESS: LIFECYCLE RACES (-L $Socket) ================" -ForegroundColor Yellow

try {

    # Clean slate for the namespace (no global kill-server; only this socket).
    Invoke-Psmux kill-server | Out-Null
    Start-Sleep -Seconds 1

    # ----------------------------------------------------------------------
    # SCENARIO 1: DOUBLE KILL
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 1: DOUBLE KILL ---" -ForegroundColor Magenta
    $r = Invoke-Psmux new-session -d -s "rbRace_dk"
    Start-Sleep -Seconds 3
    if (Test-HasSession "rbRace_dk") {
        Write-Pass "DOUBLE KILL: rbRace_dk created and present"
    } else {
        Write-Fail "DOUBLE KILL: rbRace_dk was not created (code=$($r.Code) out=$($r.Out))"
    }

    # Fire two kill-session in quick succession; the second is a no-op on a dead session.
    $k1 = Start-PsmuxAsync kill-session -t "rbRace_dk"
    $k2 = Start-PsmuxAsync kill-session -t "rbRace_dk"
    $procs = @($k1, $k2) | Where-Object { $_ }
    if ($procs.Count -gt 0) {
        try { Wait-Process -Id ($procs.Id) -Timeout 20 -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 1

    if (-not (Test-HasSession "rbRace_dk")) {
        Write-Pass "DOUBLE KILL: session gone after double kill (has-session nonzero)"
    } else {
        Write-Fail "DOUBLE KILL: session still present after double kill"
    }

    # Server (namespace) must still be able to create a new session afterward.
    Invoke-Psmux new-session -d -s "rbRace_dk2" | Out-Null
    Start-Sleep -Seconds 1
    if (Test-HasSession "rbRace_dk2") {
        Write-Pass "DOUBLE KILL: namespace alive, created rbRace_dk2 after double kill"
        Invoke-Psmux kill-session -t "rbRace_dk2" | Out-Null
    } else {
        Write-Fail "DOUBLE KILL: could not create new session after double kill (namespace wedged)"
    }

    # ----------------------------------------------------------------------
    # SCENARIO 2: KILL WHILE SENDING KEYS
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 2: KILL WHILE SENDING KEYS ---" -ForegroundColor Magenta
    Invoke-Psmux new-session -d -s "rbRace_ks" | Out-Null
    Start-Sleep -Seconds 3
    if (Test-HasSession "rbRace_ks") {
        Write-Pass "KILL WHILE SENDING KEYS: rbRace_ks created"
    } else {
        Write-Fail "KILL WHILE SENDING KEYS: rbRace_ks not created"
    }

    # Background job streams send-keys; we kill the target mid-stream.
    $sendJob = Start-Job -ScriptBlock {
        param($sock, $target)
        for ($i = 0; $i -lt 50; $i++) {
            & psmux -L $sock send-keys -t $target "echo X" Enter 2>&1 | Out-Null
            Start-Sleep -Milliseconds 20
        }
    } -ArgumentList $Socket, "rbRace_ks"

    Start-Sleep -Milliseconds 300
    # Kill mid-stream.
    Invoke-Psmux kill-session -t "rbRace_ks" | Out-Null

    Resolve-Jobs -Jobs @($sendJob) -TimeoutSec 30
    Start-Sleep -Seconds 1

    # Server must survive: can create + query a new session after the storm.
    Invoke-Psmux new-session -d -s "rbRace_ks2" | Out-Null
    Start-Sleep -Seconds 1
    if (Test-HasSession "rbRace_ks2") {
        Write-Pass "KILL WHILE SENDING KEYS: server survived, rbRace_ks2 queryable"
    } else {
        Write-Fail "KILL WHILE SENDING KEYS: server did not survive kill-during-send"
    }

    # No hung psmux processes for the namespace: port file count should be sane
    # (only the surviving session and any default), not runaway.
    $portCount = Get-NamespacePortFileCount
    if ($portCount -ge 0 -and $portCount -le 5) {
        Write-Pass "KILL WHILE SENDING KEYS: namespace port-file count sane ($portCount)"
    } else {
        Write-Fail "KILL WHILE SENDING KEYS: unexpected namespace port-file count ($portCount)"
    }
    Invoke-Psmux kill-session -t "rbRace_ks2" | Out-Null

    # ----------------------------------------------------------------------
    # SCENARIO 3: CONCURRENT new-window STORM
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 3: CONCURRENT new-window STORM ---" -ForegroundColor Magenta
    Invoke-Psmux new-session -d -s "rbRace_nw" | Out-Null
    Start-Sleep -Seconds 3
    if (-not (Test-HasSession "rbRace_nw")) {
        Write-Fail "new-window STORM: rbRace_nw not created (skipping consistency check)"
    } else {
        $baseWin = [int](Get-ListWindowsCount -Session "rbRace_nw")
        Write-Info "new-window STORM: base window count = $baseWin"

        $nwJobs = @()
        for ($i = 0; $i -lt 10; $i++) {
            $nwJobs += Start-Job -ScriptBlock {
                param($sock, $sess)
                & psmux -L $sock new-window -t $sess 2>&1 | Out-Null
            } -ArgumentList $Socket, "rbRace_nw"
        }
        Resolve-Jobs -Jobs $nwJobs -TimeoutSec 60
        Start-Sleep -Seconds 2

        # Internal consistency: #{session_windows} MUST equal list-windows count.
        $fmtWinRaw = Get-Format -Target "rbRace_nw" -Format "#{session_windows}"
        $fmtWin = -1
        if ($fmtWinRaw -match '^\d+$') { $fmtWin = [int]$fmtWinRaw }
        $lwCount = [int](Get-ListWindowsCount -Session "rbRace_nw")

        Write-Info "new-window STORM: session_windows=$fmtWin list-windows=$lwCount base=$baseWin"

        if ($fmtWin -ge 0 -and $fmtWin -eq $lwCount) {
            Write-Pass "new-window STORM: consistency OK (session_windows == list-windows == $fmtWin)"
        } else {
            Write-Fail "new-window STORM: inconsistency (session_windows=$fmtWin vs list-windows=$lwCount)"
        }

        # And the count should be base + (number that succeeded), i.e. grew and not exceeding base+10.
        if ($fmtWin -ge $baseWin -and $fmtWin -le ($baseWin + 10)) {
            Write-Pass "new-window STORM: window count within expected bounds [$baseWin..$($baseWin + 10)] -> $fmtWin"
        } else {
            Write-Fail "new-window STORM: window count out of bounds ($fmtWin not in [$baseWin..$($baseWin + 10)])"
        }
    }
    Invoke-Psmux kill-session -t "rbRace_nw" | Out-Null

    # ----------------------------------------------------------------------
    # SCENARIO 4: CONCURRENT split STORM on same window
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 4: CONCURRENT split STORM ---" -ForegroundColor Magenta
    Invoke-Psmux new-session -d -s "rbRace_sp" | Out-Null
    Start-Sleep -Seconds 3
    if (-not (Test-HasSession "rbRace_sp")) {
        Write-Fail "split STORM: rbRace_sp not created (skipping consistency check)"
    } else {
        $basePanes = [int](Get-ListPanesCount -Target "rbRace_sp")
        Write-Info "split STORM: base pane count = $basePanes"

        $spJobs = @()
        for ($i = 0; $i -lt 8; $i++) {
            $spJobs += Start-Job -ScriptBlock {
                param($sock, $sess)
                & psmux -L $sock split-window -t $sess 2>&1 | Out-Null
            } -ArgumentList $Socket, "rbRace_sp"
        }
        Resolve-Jobs -Jobs $spJobs -TimeoutSec 60
        Start-Sleep -Seconds 2

        # Consistency: list-panes count == #{window_panes}.
        $fmtPanesRaw = Get-Format -Target "rbRace_sp" -Format "#{window_panes}"
        $fmtPanes = -1
        if ($fmtPanesRaw -match '^\d+$') { $fmtPanes = [int]$fmtPanesRaw }
        $lpCount = [int](Get-ListPanesCount -Target "rbRace_sp")

        Write-Info "split STORM: window_panes=$fmtPanes list-panes=$lpCount base=$basePanes"

        if ($fmtPanes -ge 0 -and $fmtPanes -eq $lpCount) {
            Write-Pass "split STORM: consistency OK (window_panes == list-panes == $fmtPanes)"
        } else {
            Write-Fail "split STORM: inconsistency (window_panes=$fmtPanes vs list-panes=$lpCount)"
        }

        # Server alive after the split storm.
        if (Test-HasSession "rbRace_sp") {
            Write-Pass "split STORM: server alive after split storm"
        } else {
            Write-Fail "split STORM: session vanished after split storm"
        }
    }
    Invoke-Psmux kill-session -t "rbRace_sp" | Out-Null

    # ----------------------------------------------------------------------
    # SCENARIO 5: RAPID kill-server THEN reuse
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 5: RAPID kill-server THEN reuse ---" -ForegroundColor Magenta
    Invoke-Psmux new-session -d -s "rbRace_r1" | Out-Null
    Invoke-Psmux new-session -d -s "rbRace_r2" | Out-Null
    Start-Sleep -Seconds 3

    Invoke-Psmux kill-server | Out-Null
    Start-Sleep -Seconds 2

    # Immediately create a NEW session in the SAME namespace; must work (no stale-port wedge).
    Invoke-Psmux new-session -d -s "rbRace_reuse" | Out-Null
    Start-Sleep -Seconds 2
    if (Test-HasSession "rbRace_reuse") {
        Write-Pass "RAPID kill-server reuse: namespace reusable after kill-server (rbRace_reuse alive)"
    } else {
        Write-Fail "RAPID kill-server reuse: namespace wedged, could not create rbRace_reuse"
    }

    # Old sessions must be gone.
    if (-not (Test-HasSession "rbRace_r1") -and -not (Test-HasSession "rbRace_r2")) {
        Write-Pass "RAPID kill-server reuse: old sessions r1/r2 gone after kill-server"
    } else {
        Write-Fail "RAPID kill-server reuse: old sessions survived kill-server"
    }
    Invoke-Psmux kill-session -t "rbRace_reuse" | Out-Null

    # ----------------------------------------------------------------------
    # SCENARIO 6: has-session CORRECTNESS under churn (20x)
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 6: has-session CORRECTNESS under churn ---" -ForegroundColor Magenta
    $churnOk = $true
    $churnFailDetail = ""
    for ($i = 1; $i -le 20; $i++) {
        Invoke-Psmux new-session -d -s "rbRace_h" | Out-Null
        if (-not (Test-HasSession "rbRace_h")) {
            $churnOk = $false
            $churnFailDetail = "iteration ${i}: has-session expected 0 after create"
            break
        }
        Invoke-Psmux kill-session -t "rbRace_h" | Out-Null
        if (Test-HasSession "rbRace_h") {
            $churnOk = $false
            $churnFailDetail = "iteration ${i}: has-session expected nonzero after kill"
            break
        }
    }
    if ($churnOk) {
        Write-Pass "has-session CHURN: 20 create/kill cycles all correct (0 after create, nonzero after kill)"
    } else {
        Write-Fail "has-session CHURN: $churnFailDetail"
    }

    # ----------------------------------------------------------------------
    # SCENARIO 7: switch/select context overlap (detached command path)
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 7: switch-client / select overlap ---" -ForegroundColor Magenta
    Invoke-Psmux new-session -d -s "rbRace_a" | Out-Null
    Invoke-Psmux new-session -d -s "rbRace_b" | Out-Null
    Start-Sleep -Seconds 3

    if ((Test-HasSession "rbRace_a") -and (Test-HasSession "rbRace_b")) {
        Write-Pass "switch overlap: both rbRace_a and rbRace_b created"
    } else {
        Write-Fail "switch overlap: could not create both sessions"
    }

    # Fire overlapping switch-client / select commands (detached -> exercises command path).
    $swJobs = @()
    for ($i = 0; $i -lt 6; $i++) {
        $tgt = if ($i % 2 -eq 0) { "rbRace_a" } else { "rbRace_b" }
        $swJobs += Start-Job -ScriptBlock {
            param($sock, $t)
            & psmux -L $sock switch-client -t $t 2>&1 | Out-Null
            & psmux -L $sock select-window -t $t 2>&1 | Out-Null
        } -ArgumentList $Socket, $tgt
    }
    Resolve-Jobs -Jobs $swJobs -TimeoutSec 60
    Start-Sleep -Seconds 1

    if ((Test-HasSession "rbRace_a") -and (Test-HasSession "rbRace_b")) {
        Write-Pass "switch overlap: both sessions remain queryable, server alive"
    } else {
        Write-Fail "switch overlap: a session became unqueryable after overlapping switch/select"
    }
    Invoke-Psmux kill-session -t "rbRace_a" | Out-Null
    Invoke-Psmux kill-session -t "rbRace_b" | Out-Null

    # ----------------------------------------------------------------------
    # SCENARIO 8: ORPHAN PROCESS / PORT-FILE CHECK after teardown
    # ----------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 8: ORPHAN PORT-FILE CHECK ---" -ForegroundColor Magenta
    Invoke-Psmux kill-server | Out-Null
    Start-Sleep -Seconds 2
    $orphanCount = Get-NamespacePortFileCount
    if ($orphanCount -eq 0) {
        Write-Pass "ORPHAN CHECK: zero rbRace__*.port files remain after kill-server (clean teardown)"
    } else {
        Write-Fail "ORPHAN CHECK: $orphanCount stale rbRace__*.port file(s) remain after kill-server"
    }

}
finally {
    Write-Host "`n[CLEANUP] Tearing down namespace $Socket ..." -ForegroundColor DarkGray
    & psmux -L $Socket kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}

Write-Host "`n=== Results ===" -ForegroundColor Yellow
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red

exit $script:TestsFailed
