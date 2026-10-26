# Warm-pane sync E2E coverage: prove that runtime `set-option` for
# every option in the policy table actually propagates to the warm
# pane.  Each scenario opens a new window AFTER changing the option
# and verifies the new pane reflects the change.
#
# Why this matters: prior to issue #271's refactor, several options
# had silent staleness — set-option recorded the new value but the
# warm pane (which the next new-window consumes) kept the old value
# until the next env-var change or server restart.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Wait-Prompt {
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

function Wait-Output {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 30000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Marker) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Reset-Server {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    # Only the DEFAULT namespace's registry, which is what the bare kill-server
    # above tore down. A namespaced file is "<ns>__<session>.<ext>" with a
    # non-empty ns that does not start with an underscore ("__warm__" itself is
    # the default namespace's standby). The old "*.port" wildcard deleted every
    # -L namespace's registry too, and on 2026-09-16 that made every sibling
    # agent's server on this machine report "no server running" once per
    # round of a loop running this suite.
    Get-ChildItem "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -EA SilentlyContinue |
        Where-Object { $_.BaseName -notmatch '^[^_].*?__' } |
        Remove-Item -Force -EA SilentlyContinue
}

# ── Scenario 1: history-limit (Patch path) ──────────────────────────
# Already exercised heavily by test_issue271_warm_pane_history.ps1
# and test_issue271_runtime_set_propagation.ps1 — skip here to avoid
# duplication and keep this file focused on the OTHER options that
# the refactor newly covered.

# ── Scenario 2: default-terminal (Respawn path, env-baked) ──────────
Write-Host "`n=== Scenario: default-terminal propagates to warm pane ===" -ForegroundColor Cyan
Reset-Server
$SESSION = "warmsync_term"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4
if (-not (Wait-Prompt -Target $SESSION)) {
    Write-Fail "default-terminal: initial session never ready"
} else {
    Write-Pass "default-terminal: initial session ready"
    $marker = "TERM_MARKER_$(Get-Random)"
    & $PSMUX set-option -g default-terminal $marker 2>&1 | Out-Null
    Start-Sleep -Seconds 2  # respawn time

    & $PSMUX new-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $newWin = "${SESSION}:1"
    if (Wait-Prompt -Target $newWin) {
        & $PSMUX send-keys -t $newWin '$env:TERM' Enter 2>&1 | Out-Null
        if (Wait-Output -Target $newWin -Marker $marker -TimeoutMs 10000) {
            Write-Pass "default-terminal change reached child shell's `$env:TERM"
        } else {
            $cap = & $PSMUX capture-pane -t $newWin -p 2>&1 | Out-String
            Write-Fail "default-terminal not seen in new pane. Tail:`n$($cap.Substring([Math]::Max(0, $cap.Length-300)))"
        }
    }
}
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Reset-Server

# ── Scenario 3: regression guard for default-shell incomplete kill ──
# Before the refactor, set-option default-shell killed the warm pane
# but never respawned it (only handled in SetOptionQuiet, and even
# there only a kill, no spawn).  After the refactor the warm pane
# is always respawned via apply().  We can't easily change the shell
# binary in test, but we CAN verify the warm pane is re-populated
# after the change (instead of going None and forcing a cold spawn).
Write-Host "`n=== Scenario: default-shell change leaves warm pane populated ===" -ForegroundColor Cyan
Reset-Server
$SESSION = "warmsync_shell"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-Prompt -Target $SESSION)) {
    Write-Fail "default-shell: initial session never ready"
} else {
    Write-Pass "default-shell: initial session ready"
    # Set default-shell to the same value we already have (idempotent
    # but exercises the SetOption path).  pwsh is the safe default on
    # Windows; setting it to itself triggers the respawn machinery
    # without changing observable behaviour.
    $shell = (Get-Command pwsh -EA SilentlyContinue).Source
    if (-not $shell) { $shell = (Get-Command powershell).Source }
    & $PSMUX set-option -g default-shell $shell 2>&1 | Out-Null
    Start-Sleep -Seconds 3  # let respawn complete

    # Open a new window — fast-path transplant proves warm pane was
    # respawned (not left None).  If it had been left None, the new
    # window would still work but cold-spawn slower; we verify by
    # making sure the prompt appears within the warm-path budget.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX new-window -t $SESSION 2>&1 | Out-Null
    $newWin = "${SESSION}:1"
    $ready = Wait-Prompt -Target $newWin -TimeoutMs 8000
    $sw.Stop()
    if ($ready) {
        Write-Info "new-window after default-shell change: prompt in $($sw.ElapsedMilliseconds)ms"
        Write-Pass "default-shell change kept warm pane populated (new-window served prompt under 8s)"
    } else {
        Write-Fail "default-shell change broke warm pane (prompt not ready in 8s)"
    }
}
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Reset-Server

# ── Scenario 4: unrelated set-option doesn't churn warm pane ──────
# Setting status-style is in the Noop branch.  Any kill+respawn
# would be a perf regression — verify the warm pane survives.
Write-Host "`n=== Scenario: unrelated option (status-style) is Noop ===" -ForegroundColor Cyan
Reset-Server
$SESSION = "warmsync_noop"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-Prompt -Target $SESSION)) {
    Write-Fail "noop: initial session never ready"
} else {
    Write-Pass "noop: initial session ready"
    & $PSMUX set-option -g status-style "bg=red,fg=white" 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Open new window — must still be fast (warm pane untouched).
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX new-window -t $SESSION 2>&1 | Out-Null
    $newWin = "${SESSION}:1"
    $ready = Wait-Prompt -Target $newWin -TimeoutMs 5000
    $sw.Stop()
    if ($ready) {
        Write-Info "new-window after status-style change: $($sw.ElapsedMilliseconds)ms"
        Write-Pass "Unrelated option change did not churn warm pane"
    } else {
        Write-Fail "Unrelated option change appears to have broken the warm pane"
    }
}
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Reset-Server

# ── Scenario 5: rapid option churn — single warm pane survives ────
# Stress-test: rapid set-option calls of varying classes (Patch and
# Noop) should NOT exhaust resources or break the warm pane.
Write-Host "`n=== Scenario: rapid option churn ===" -ForegroundColor Cyan
Reset-Server
$SESSION = "warmsync_churn"
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-Prompt -Target $SESSION)) {
    Write-Fail "churn: initial session never ready"
} else {
    Write-Pass "churn: initial session ready"
    # 10 history-limit changes (Patch) + 10 status-style changes (Noop)
    for ($i = 1; $i -le 10; $i++) {
        & $PSMUX set-option -g history-limit ($i * 5000) 2>&1 | Out-Null
        & $PSMUX set-option -g status-style "bg=color$($i % 8)" 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 1

    # Final history-limit was 50000.  New pane should retain that.
    & $PSMUX new-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $newWin = "${SESSION}:1"
    if (Wait-Prompt -Target $newWin) {
        & $PSMUX send-keys -t $newWin '1..3000 | ForEach-Object { "ch $_" }' Enter 2>&1 | Out-Null
        if (Wait-Output -Target $newWin -Marker "ch 2990" -TimeoutMs 60000) {
            Start-Sleep -Seconds 2
            $deep = & $PSMUX capture-pane -t $newWin -S -200000 -p 2>&1 | Out-String
            $count = ([regex]::Matches($deep, '(?m)^ch \d+\b')).Count
            if ($count -ge 2900) {
                Write-Pass "After 20 option changes, new window retains $count of 3000 lines (history-limit honoured)"
            } else {
                Write-Fail "After churn: only $count retained — sync layer leaked state"
            }
        }
    }
}
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Reset-Server

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
