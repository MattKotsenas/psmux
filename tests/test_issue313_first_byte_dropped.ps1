# Issue #313: First input byte dropped + PSReadLine bell on freshly-attached pane
# Claim: conpty_preemptive_dsr_response() writes raw VT DSR response (\x1b[1;1R)
# to ConPTY input pipe which is in Win32 input mode. The parser gets confused,
# eats the first user keystroke, and PSReadLine bells.
#
# This test REPRODUCES the claimed behavior by:
# 1. Creating a fresh detached session
# 2. Waiting for shell to be ready
# 3. Sending text via send-keys
# 4. Checking if the first character survives via capture-pane
# 5. Also tests split-window panes (the Claude Code agent-team scenario)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

function Wait-ForPrompt {
    param([string]$Target, [int]$TimeoutMs = 20000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
            if ($cap -match "PS [A-Z]:\\") { return $true }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Write-Host "`n=== Issue #313 Reproduction: First Byte Dropped ===" -ForegroundColor Cyan
Write-Host "Binary: $PSMUX" -ForegroundColor DarkGray

# ============================================================
# TEST 1: Fresh session - send-keys with a known string, check first char
# ============================================================
Write-Host "`n[Test 1] Fresh session: first character survival via send-keys" -ForegroundColor Yellow
$S1 = "repro313_t1"
Cleanup $S1

& $PSMUX new-session -d -s $S1
Start-Sleep -Seconds 4

& $PSMUX has-session -t $S1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session $S1 creation failed"
} else {
    # Wait for shell prompt to be ready
    $ready = Wait-ForPrompt -Target $S1 -TimeoutMs 15000
    if (-not $ready) {
        Write-Fail "Shell prompt never appeared in $S1"
    } else {
        Write-Pass "Shell prompt ready in $S1"

        # Extra wait to rule out PSReadLine cold-start (as reporter suggests)
        Start-Sleep -Seconds 3

        # Send a distinctive echo command via send-keys
        # If first byte is dropped, "echo XMARKER" becomes "cho XMARKER" 
        # which will error or produce wrong output
        & $PSMUX send-keys -t $S1 "echo XMARKER_FIRST_BYTE" Enter
        Start-Sleep -Seconds 2

        $cap1 = & $PSMUX capture-pane -t $S1 -p 2>&1 | Out-String
        Write-Host "  Captured output (last 10 lines):" -ForegroundColor DarkGray
        $lines = ($cap1 -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 10
        $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        # Check if the echo command executed properly (first char 'e' not dropped)
        if ($cap1 -match "XMARKER_FIRST_BYTE") {
            # The echo output appeared, meaning the command ran
            # But did it run as "echo" or "cho"?
            if ($cap1 -match "echo XMARKER_FIRST_BYTE") {
                Write-Pass "First byte survived: 'echo' command intact in capture"
            } else {
                # Check if we see the error from 'cho' not being recognized
                if ($cap1 -match "cho XMARKER" -or $cap1 -match "is not recognized") {
                    Write-Fail "FIRST BYTE DROPPED: 'echo' became 'cho' - BUG CONFIRMED"
                } else {
                    Write-Pass "XMARKER found in output (first byte likely OK)"
                }
            }
        } else {
            # No XMARKER at all - command may have completely failed
            if ($cap1 -match "cho " -or $cap1 -match "is not recognized") {
                Write-Fail "FIRST BYTE DROPPED: command failed entirely - BUG CONFIRMED"
            } else {
                Write-Fail "XMARKER not found in capture at all (inconclusive)"
            }
        }
    }
}

# ============================================================
# TEST 2: Split-window pane - the Claude Code agent-team scenario
# The reporter says: split-window + send-keys "cd ..." loses the 'c'
# ============================================================
Write-Host "`n[Test 2] Split-window pane: first byte after split" -ForegroundColor Yellow
$S2 = "repro313_t2"
Cleanup $S2

& $PSMUX new-session -d -s $S2
Start-Sleep -Seconds 4
$ready = Wait-ForPrompt -Target $S2 -TimeoutMs 15000
if (-not $ready) {
    Write-Fail "Base session prompt never ready"
} else {
    # Split window to create a new pane (this is what Claude Code does)
    & $PSMUX split-window -v -t $S2
    Start-Sleep -Seconds 4

    # Wait for the NEW pane's prompt
    # The split should make pane 1 active, so target it directly
    $paneTarget = "${S2}:0.1"
    $ready2 = Wait-ForPrompt -Target $paneTarget -TimeoutMs 15000
    if (-not $ready2) {
        # Try without specific pane (maybe auto-targets new pane)
        $ready2 = Wait-ForPrompt -Target $S2 -TimeoutMs 10000
        $paneTarget = $S2
    }

    if (-not $ready2) {
        Write-Fail "Split pane prompt never appeared"
    } else {
        Write-Pass "Split pane prompt ready"

        # Extra wait per reporter's observation (not a timing race)
        Start-Sleep -Seconds 3

        # This is the exact Claude Code scenario: send "cd <path>" 
        # If first byte dropped: "cd" becomes "d" which errors
        & $PSMUX send-keys -t $paneTarget "echo YFIRST_BYTE_SPLIT" Enter
        Start-Sleep -Seconds 2

        $cap2 = & $PSMUX capture-pane -t $paneTarget -p 2>&1 | Out-String
        Write-Host "  Split pane captured (last 10 lines):" -ForegroundColor DarkGray
        $lines2 = ($cap2 -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 10
        $lines2 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        if ($cap2 -match "YFIRST_BYTE_SPLIT") {
            if ($cap2 -match "echo YFIRST_BYTE_SPLIT") {
                Write-Pass "Split pane first byte survived: 'echo' intact"
            } else {
                Write-Pass "YFIRST_BYTE_SPLIT found (likely OK)"
            }
        } else {
            if ($cap2 -match "cho " -or $cap2 -match "is not recognized") {
                Write-Fail "SPLIT PANE FIRST BYTE DROPPED - BUG CONFIRMED"
            } else {
                Write-Fail "YFIRST_BYTE_SPLIT not found in split pane capture"
            }
        }
    }
}

# ============================================================
# TEST 3: Multiple rapid send-keys after new-window
# Tests if new-window also suffers the same issue
# ============================================================
Write-Host "`n[Test 3] New window: first byte after new-window" -ForegroundColor Yellow
$S3 = "repro313_t3"
Cleanup $S3

& $PSMUX new-session -d -s $S3
Start-Sleep -Seconds 4
$ready = Wait-ForPrompt -Target $S3 -TimeoutMs 15000
if (-not $ready) {
    Write-Fail "Base session prompt never ready"
} else {
    # Create a new window
    & $PSMUX new-window -t $S3
    Start-Sleep -Seconds 4

    # New window should be active, wait for prompt
    $ready3 = Wait-ForPrompt -Target $S3 -TimeoutMs 15000
    if (-not $ready3) {
        Write-Fail "New window prompt never appeared"
    } else {
        Write-Pass "New window prompt ready"
        Start-Sleep -Seconds 3

        & $PSMUX send-keys -t $S3 "echo ZWINDOW_FIRST" Enter
        Start-Sleep -Seconds 2

        $cap3 = & $PSMUX capture-pane -t $S3 -p 2>&1 | Out-String
        Write-Host "  New window captured (last 10 lines):" -ForegroundColor DarkGray
        $lines3 = ($cap3 -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 10
        $lines3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        if ($cap3 -match "ZWINDOW_FIRST") {
            if ($cap3 -match "echo ZWINDOW_FIRST") {
                Write-Pass "New window first byte survived"
            } else {
                Write-Pass "ZWINDOW_FIRST found (likely OK)"
            }
        } else {
            if ($cap3 -match "cho " -or $cap3 -match "is not recognized") {
                Write-Fail "NEW WINDOW FIRST BYTE DROPPED - BUG CONFIRMED"
            } else {
                Write-Fail "ZWINDOW_FIRST not found in new window capture"
            }
        }
    }
}

# ============================================================
# TEST 4: The EXACT Claude Code scenario  
# split-window then immediately send-keys "cd 'path' && command"
# This is what breaks agent-team worker spawning per the report
# ============================================================
Write-Host "`n[Test 4] Claude Code agent-team: split + immediate send-keys 'cd ...'" -ForegroundColor Yellow
$S4 = "repro313_t4"
Cleanup $S4

& $PSMUX new-session -d -s $S4
Start-Sleep -Seconds 4
$ready = Wait-ForPrompt -Target $S4 -TimeoutMs 15000
if (-not $ready) {
    Write-Fail "Base session prompt never ready"
} else {
    # Split and IMMEDIATELY send-keys (like Claude Code does, no extra wait)
    & $PSMUX split-window -v -t $S4
    Start-Sleep -Seconds 4

    # Wait for prompt in new pane
    $paneTarget4 = "${S4}:0.1"
    $ready4 = Wait-ForPrompt -Target $paneTarget4 -TimeoutMs 15000
    if (-not $ready4) {
        $paneTarget4 = $S4
        $ready4 = Wait-ForPrompt -Target $paneTarget4 -TimeoutMs 10000
    }

    if (-not $ready4) {
        Write-Fail "Split pane never got prompt"
    } else {
        # Simulate Claude Code: cd <path> && <command>
        # If 'c' is eaten: "cd C:\Users" -> "d C:\Users" -> error
        $testCmd = "cd C:\Users && echo CD_SUCCESS_313"
        & $PSMUX send-keys -t $paneTarget4 $testCmd Enter
        Start-Sleep -Seconds 3

        $cap4 = & $PSMUX capture-pane -t $paneTarget4 -p 2>&1 | Out-String
        Write-Host "  Claude Code scenario captured (last 10 lines):" -ForegroundColor DarkGray
        $lines4 = ($cap4 -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 10
        $lines4 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        if ($cap4 -match "CD_SUCCESS_313") {
            Write-Pass "Claude Code scenario: cd succeeded, first byte intact"
        } else {
            if ($cap4 -match "'d' is not recognized" -or $cap4 -match "d : The term" -or $cap4 -match "d C:\\") {
                Write-Fail "CLAUDE CODE SCENARIO BROKEN: 'cd' became 'd' - BUG CONFIRMED"
            } else {
                Write-Fail "CD_SUCCESS_313 not found (command may have failed differently)"
                Write-Host "  Full capture for analysis:" -ForegroundColor DarkGray
                Write-Host $cap4 -ForegroundColor DarkGray
            }
        }
    }
}

# ============================================================
# TEST 5: Direct character test via send-keys with single chars
# Send individual characters and verify ALL arrive
# ============================================================
Write-Host "`n[Test 5] Single character send-keys sequence verification" -ForegroundColor Yellow
$S5 = "repro313_t5"
Cleanup $S5

& $PSMUX new-session -d -s $S5
Start-Sleep -Seconds 5
$ready = Wait-ForPrompt -Target $S5 -TimeoutMs 15000
if (-not $ready) {
    Write-Fail "Session prompt never ready"
} else {
    Start-Sleep -Seconds 3

    # Clear the screen first
    & $PSMUX send-keys -t $S5 "clear" Enter
    Start-Sleep -Seconds 1

    # Send echo with a distinctive first character
    & $PSMUX send-keys -t $S5 "echo ABCDEFGH" Enter
    Start-Sleep -Seconds 2

    $cap5 = & $PSMUX capture-pane -t $S5 -p 2>&1 | Out-String
    Write-Host "  Single char test (last 8 lines):" -ForegroundColor DarkGray
    $lines5 = ($cap5 -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 8
    $lines5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if ($cap5 -match "ABCDEFGH") {
        Write-Pass "All characters ABCDEFGH survived"
    } else {
        if ($cap5 -match "BCDEFGH" -and $cap5 -notmatch "ABCDEFGH") {
            Write-Fail "First char 'A' DROPPED: got BCDEFGH instead of ABCDEFGH - BUG CONFIRMED"
        } elseif ($cap5 -match "cho ABCDEFGH" -or $cap5 -match "cho BCDEFGH") {
            Write-Fail "First char of 'echo' dropped - BUG CONFIRMED"
        } else {
            Write-Fail "ABCDEFGH not found in capture"
        }
    }
}

# ============================================================
# TEST 6: TUI attached session with WriteConsoleInput injection
# This tests the REAL keystroke path, not send-keys TCP path
# The bug may manifest differently via real keystrokes vs send-keys
# ============================================================
Write-Host "`n[Test 6] TUI Visual: Attached session with CLI verification" -ForegroundColor Yellow
$S6 = "repro313_tui"
Cleanup $S6

$psmuxExe = (Get-Command psmux -EA Stop).Source
$proc = Start-Process -FilePath $psmuxExe -ArgumentList "new-session","-s",$S6 -PassThru
Start-Sleep -Seconds 5

& $PSMUX has-session -t $S6 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI session creation failed"
} else {
    Write-Pass "TUI session created with visible window"
    
    $ready6 = Wait-ForPrompt -Target $S6 -TimeoutMs 15000
    if ($ready6) {
        Write-Pass "TUI session has prompt"

        # Drive via CLI send-keys
        & $PSMUX send-keys -t $S6 "echo TUI_FIRSTBYTE_OK" Enter
        Start-Sleep -Seconds 2

        $cap6 = & $PSMUX capture-pane -t $S6 -p 2>&1 | Out-String
        if ($cap6 -match "TUI_FIRSTBYTE_OK") {
            Write-Pass "TUI: send-keys first byte survived"
        } else {
            Write-Fail "TUI: first byte possibly dropped in attached session"
        }

        # Split in TUI and test new pane
        & $PSMUX split-window -v -t $S6
        Start-Sleep -Seconds 4
        
        $panes = (& $PSMUX display-message -t $S6 -p '#{window_panes}' 2>&1).Trim()
        if ($panes -eq "2") {
            Write-Pass "TUI: split created 2 panes"
        } else {
            Write-Fail "TUI: expected 2 panes, got $panes"
        }
    } else {
        Write-Fail "TUI session prompt never appeared"
    }
}

# Cleanup TUI
& $PSMUX kill-session -t $S6 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# ============================================================
# CLEANUP ALL
# ============================================================
Write-Host "`n--- Cleanup ---" -ForegroundColor DarkGray
foreach ($s in @("repro313_t1","repro313_t2","repro313_t3","repro313_t4","repro313_t5","repro313_tui")) {
    Cleanup $s
}

Write-Host "`n=== Issue #313 Reproduction Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) {
    Write-Host "`n  CONCLUSION: Bug from issue #313 is CONFIRMED" -ForegroundColor Red
} else {
    Write-Host "`n  CONCLUSION: Bug from issue #313 NOT reproduced via send-keys path" -ForegroundColor Yellow
    Write-Host "  NOTE: The bug may only manifest via REAL keystrokes (WriteConsoleInput)" -ForegroundColor Yellow
    Write-Host "  Need to test with keystroke injector to be sure" -ForegroundColor Yellow
}

exit $script:TestsFailed
