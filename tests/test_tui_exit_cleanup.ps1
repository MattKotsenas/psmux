<#
.SYNOPSIS
  Test terminal state cleanup after TUI app exit inside psmux.
  
  Verifies that after a TUI app (pstop, opencode, claude, fake-crash TUI)
  exits, the psmux terminal is fully restored:
  - No garbled mouse escape sequences in the output
  - No TUI content remnants from alternate-screen apps
  - Shell prompt is visible and responsive
  - Typing produces correct output
  - Arrow-key cursor navigation works (visual matches actual)
  
  Root cause being tested: the Ctrl+C handler must NOT prematurely exit the
  alternate screen -- it must let the TUI app flush its own cleanup sequences
  via the reader thread.  Premature exit causes the TUI's final output to
  corrupt the primary grid.
#>
$ErrorActionPreference = "Continue"
$results = @()

function Add-Result($name, $pass, $detail="") {
    $script:results += [PSCustomObject]@{ Test=$name; Result=if($pass){"PASS"}else{"FAIL"}; Detail=$detail }
    $mark = if($pass) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $mark $name$(if($detail){' '+$detail}else{''})"
}

# Wait for a real TUI app to take over the pane, and for the shell to come back
# afterwards. Fixed sleeps do not work here: opencode is a Bun/Node TUI that takes
# about ten seconds to draw its first frame on this machine, so a 750ms sleep sent
# Ctrl+C while the shell was still launching it. The app then started AFTER the
# interrupt and kept running, leaving the pane with no prompt and failing every
# check that followed. Given time to start, Ctrl+C exits it cleanly.
function Wait-AppTookOver($session, $timeoutSec = 25) {
    # Two conditions, both required:
    #   1. the shell prompt is gone from the WHOLE pane, not just the last line
    #   2. the app has actually drawn something
    #
    # Condition 2 is what makes this reliable. A TUI clears the screen the moment
    # it starts, so for the first several seconds the pane is BLANK: the prompt is
    # already gone but the app is not up yet. Checking only "the last line is not
    # a prompt" was satisfied by that blank screen and declared the app ready
    # after about a second, which sent Ctrl+C straight into opencode's startup.
    # Measured lifecycle: blank at t+3s and t+6s, first frame at t+9s, and once
    # it is really up Ctrl+C returns the prompt within 3 seconds.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $cap = psmux capture-pane -t $session -p 2>&1 | Out-String
        if ($cap -match 'PS [A-Z]:\\') { continue }
        $last = ($cap -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        if ($last -and $last.Trim().Length -gt 0) { return $true }
    }
    return $false
}

function Wait-ShellBack($session, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $cap = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $cap = psmux capture-pane -t $session -p 2>&1 | Out-String
        if ($cap -match 'PS [A-Z]:\\') { break }
    }
    return $cap
}

# Create a fake TUI that enables all terminal modes and exits cleanly
$fakeTuiClean = @'
$esc = [char]27
Write-Host -NoNewline "$esc[?1049h"
Write-Host -NoNewline "$esc[?1003h$esc[?1006h"
Write-Host -NoNewline "$esc[?1h"
Write-Host -NoNewline "$esc[?2004h"
Write-Host -NoNewline "$esc[2 q"
Write-Host -NoNewline "$esc[1;1H$esc[44m$esc[37m=== FAKE TUI APP ===$esc[0m"
Write-Host -NoNewline "$esc[2;1H$esc[42mProcess list here...$esc[0m"
Write-Host -NoNewline "$esc[3;1H$esc[41mCPU: 100%$esc[0m"
Start-Sleep -Seconds 1
Write-Host -NoNewline "$esc[?1003l$esc[?1006l"
Write-Host -NoNewline "$esc[?1l"
Write-Host -NoNewline "$esc[?2004l"
Write-Host -NoNewline "$esc[0m$esc[?25h"
Write-Host -NoNewline "$esc[?1049l"
'@

# Create a fake TUI that exits WITHOUT cleanup (simulates crash)
$fakeTuiCrash = @'
$esc = [char]27
Write-Host -NoNewline "$esc[?1049h"
Write-Host -NoNewline "$esc[?1003h$esc[?1006h"
Write-Host -NoNewline "$esc[?1h"
Write-Host -NoNewline "$esc[?2004h"
Write-Host -NoNewline "$esc[2 q"
Write-Host -NoNewline "$esc[1;1H$esc[44m$esc[37m=== CRASH TUI ===$esc[0m"
Write-Host -NoNewline "$esc[2;1H$esc[41mAbout to crash...$esc[0m"
Start-Sleep -Seconds 1
'@

$cleanScript = "$env:TEMP\fake_tui_clean.ps1"
$crashScript = "$env:TEMP\fake_tui_crash.ps1"
Set-Content -Path $cleanScript -Value $fakeTuiClean -Encoding UTF8
Set-Content -Path $crashScript -Value $fakeTuiCrash -Encoding UTF8

Write-Host "=== TUI Exit Cleanup Test ==="
Write-Host ""

psmux kill-server 2>$null
Start-Sleep -Seconds 1

# =====================================================================
# TEST GROUP 1: Clean TUI exit (sends RMCUP + disables modes)
# =====================================================================
Write-Host "--- Group 1: Clean TUI exit ---"
psmux new-session -d -s tui_clean -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 750

psmux send-keys -t tui_clean "pwsh -NoProfile -File `"$cleanScript`"" Enter
Start-Sleep -Seconds 4

$cap = psmux capture-pane -t tui_clean -p 2>&1 | Out-String
$hasEscGarbage = $cap -match '\[[\d;]+[Mm]' -and $cap -match '555|1003|1006'
Add-Result "Clean exit: no mouse escape garbage" (-not $hasEscGarbage)

$hasTuiContent = $cap -match 'FAKE TUI APP' -or $cap -match 'Process list here' -or $cap -match 'CPU: 100%'
Add-Result "Clean exit: no TUI content remnants" (-not $hasTuiContent)

$hasPrompt = $cap -match 'PS [A-Z]:\\'
Add-Result "Clean exit: shell prompt visible" $hasPrompt

psmux send-keys -t tui_clean "echo cursor_test_ok" Enter
Start-Sleep -Seconds 1
$cap2 = psmux capture-pane -t tui_clean -p 2>&1 | Out-String
Add-Result "Clean exit: typing works" ($cap2 -match 'cursor_test_ok')

psmux send-keys -t tui_clean "echo arrow_ABC" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_clean Left Left Left ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_clean "X" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_clean Enter
Start-Sleep -Seconds 1
$cap3 = psmux capture-pane -t tui_clean -p 2>&1 | Out-String
Add-Result "Clean exit: arrow keys work (cursor in sync)" ($cap3 -match 'arrow_XABC')

psmux kill-session -t tui_clean 2>$null
Start-Sleep -Seconds 1

# =====================================================================
# TEST GROUP 2: TUI crash (no cleanup) + Ctrl+C recovery
# =====================================================================
Write-Host "`n--- Group 2: TUI crash (no cleanup) ---"
psmux new-session -d -s tui_crash -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 750

psmux send-keys -t tui_crash "pwsh -NoProfile -File `"$crashScript`"" Enter
Start-Sleep -Seconds 1

psmux send-keys -t tui_crash C-c
Start-Sleep -Milliseconds 750

$cap4 = psmux capture-pane -t tui_crash -p 2>&1 | Out-String
$hasEscGarbage2 = $cap4 -match '\[\d{2,};[\d;]+[Mm]'
Add-Result "Crash exit: no mouse escape garbage" (-not $hasEscGarbage2)

$hasPrompt2 = $cap4 -match 'PS [A-Z]:\\'
Add-Result "Crash exit: prompt visible after Ctrl+C" $hasPrompt2

psmux send-keys -t tui_crash "echo crash_test_ok" Enter
Start-Sleep -Seconds 1
$cap5 = psmux capture-pane -t tui_crash -p 2>&1 | Out-String
Add-Result "Crash exit: typing works" ($cap5 -match 'crash_test_ok')

psmux send-keys -t tui_crash "echo crash_DEF" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_crash Left Left Left ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_crash "Y" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_crash Enter
Start-Sleep -Seconds 1
$cap6 = psmux capture-pane -t tui_crash -p 2>&1 | Out-String
Add-Result "Crash exit: arrow keys work" ($cap6 -match 'crash_YDEF')

# On ConPTY (Windows), a crashed TUI that never sent RMCUP will leave alt-screen
# content visible because ConPTY never receives the restore sequence.  This is
# expected behaviour (same as tmux).  Verify the shell IS responsive instead.
$shellResponsive = $cap5 -match 'crash_test_ok' -and ($cap4 -match 'PS [A-Z]:\\')
Add-Result "Crash exit: shell responsive despite TUI remnants" $shellResponsive

psmux kill-session -t tui_crash 2>$null
Start-Sleep -Seconds 1

# =====================================================================
# TEST GROUP 3: Real pstop.exe test (clean 'q' exit)
# On Windows, ConPTY sends Ctrl+C to all console processes, killing the
# shell alongside pstop.  Use pstop's 'q' key for a clean exit that sends
# RMCUP.  The Ctrl+C + crash behaviour is covered by Group 2 (fake TUI)
# and Group 3b (force-kill).
# =====================================================================
$pstopPath = Get-Command pstop.exe -ErrorAction SilentlyContinue
if ($pstopPath) {
    Write-Host "`n--- Group 3: pstop.exe (clean 'q' exit) ---"
    psmux new-session -d -s tui_pstop -x 120 -y 30 2>$null
    Start-Sleep -Milliseconds 750
    
    psmux send-keys -t tui_pstop "pstop.exe" Enter
    Start-Sleep -Seconds 1
    
    psmux send-keys -t tui_pstop "q"
    Start-Sleep -Seconds 1
    
    $capP = psmux capture-pane -t tui_pstop -p 2>&1 | Out-String
    
    $hasPstopRemnants = $capP -match 'CPU%.*MEM%|PID\s+PPID|Tasks:.*thr.*running'
    Add-Result "pstop clean exit: no TUI content on primary grid" (-not $hasPstopRemnants)
    
    $hasPstopGarbage = $capP -match '\[\d{2,};[\d;]+[Mm]'
    Add-Result "pstop clean exit: no garbled mouse sequences" (-not $hasPstopGarbage)
    
    $hasPstopPrompt = $capP -match 'PS [A-Z]:\\'
    Add-Result "pstop clean exit: shell prompt visible" $hasPstopPrompt
    
    psmux send-keys -t tui_pstop "echo pstop_test_ok" Enter
    Start-Sleep -Seconds 1
    $capP2 = psmux capture-pane -t tui_pstop -p 2>&1 | Out-String
    Add-Result "pstop clean exit: typing works" ($capP2 -match 'pstop_test_ok')
    
    psmux send-keys -t tui_pstop "echo pstop_GHI" ""
    Start-Sleep -Milliseconds 500
    psmux send-keys -t tui_pstop Left Left Left ""
    Start-Sleep -Milliseconds 500
    psmux send-keys -t tui_pstop "Z" ""
    Start-Sleep -Milliseconds 500
    psmux send-keys -t tui_pstop Enter
    Start-Sleep -Seconds 1
    $capP3 = psmux capture-pane -t tui_pstop -p 2>&1 | Out-String
    Add-Result "pstop clean exit: arrow keys work (cursor in sync)" ($capP3 -match 'pstop_ZGHI')
    
    psmux kill-session -t tui_pstop 2>$null
    Start-Sleep -Seconds 1

    # --- pstop crash case: Ctrl+C then force-kill (no RMCUP) ---
    Write-Host "`n--- Group 3b: pstop force-kill crash (no RMCUP) ---"
    psmux new-session -d -s tui_pstop_fk -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    
    psmux send-keys -t tui_pstop_fk "pstop.exe" Enter
    Start-Sleep -Seconds 1
    
    # Ctrl+C (sets ctrl_c_at) then immediately force-kill
    psmux send-keys -t tui_pstop_fk C-c
    Start-Sleep -Milliseconds 200
    # Force-kill THIS pane's pstop by PID.  A by-name kill here used to end
    # every pstop on the machine, the user's own included.
    $fkPane = psmux display-message -p -t tui_pstop_fk '#{pane_pid}' 2>$null
    if ($fkPane -match '^\d+$') {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$fkPane AND Name='pstop.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    
    # Wait for 2s timeout + buffer
    Start-Sleep -Milliseconds 750
    
    $capFK = psmux capture-pane -t tui_pstop_fk -p 2>&1 | Out-String
    # On ConPTY (Windows), a force-killed TUI that never sent RMCUP will leave
    # alt-screen content visible.  Verify the shell IS responsive instead.
    $hasFK_Prompt = $capFK -match 'PS [A-Z]:\\'
    Add-Result "pstop force-kill: prompt visible" $hasFK_Prompt
    
    psmux send-keys -t tui_pstop_fk "echo fk_test_ok" Enter
    Start-Sleep -Seconds 1
    $capFK2 = psmux capture-pane -t tui_pstop_fk -p 2>&1 | Out-String
    Add-Result "pstop force-kill: typing works" ($capFK2 -match 'fk_test_ok')
    
    psmux kill-session -t tui_pstop_fk 2>$null
    Start-Sleep -Seconds 1
} else {
    Write-Host "`n--- Group 3: pstop.exe not found, skipping ---"
}

# =====================================================================
# TEST GROUP 4: Real opencode test (Ctrl+C exit)
# =====================================================================
$opencodePath = Get-Command opencode -ErrorAction SilentlyContinue
if ($opencodePath) {
    Write-Host "`n--- Group 4: opencode (Ctrl+C exit) ---"
    psmux new-session -d -s tui_oc -x 120 -y 30 2>$null
    Start-Sleep -Milliseconds 750
    
    # Wait for opencode to actually BE RUNNING before interrupting it, and then
    # for the shell to actually come back. The old code slept 750ms after
    # launching and 1s after Ctrl+C.
    #
    # opencode is a Bun/Node TUI and takes several seconds to draw its first
    # frame: measured at roughly 10 seconds on this machine. So Ctrl+C landed
    # while the shell was still starting it, and opencode then came up AFTER the
    # interrupt and kept running, which is why the pane had no prompt and the
    # three checks below failed. Given time to start, Ctrl+C exits it cleanly and
    # the prompt returns (verified: last pane line "PS C:\cctest>").
    psmux send-keys -t tui_oc "cd c:\cctest && opencode" Enter
    Add-Result "opencode: launched and took over the pane" (Wait-AppTookOver 'tui_oc' 25)
    psmux send-keys -t tui_oc C-c
    $capOC = Wait-ShellBack 'tui_oc' 15
    
    $hasOcGarbage = $capOC -match '\[\d{2,};[\d;]+[Mm]'
    Add-Result "opencode Ctrl+C: no garbled mouse sequences" (-not $hasOcGarbage)

    # Interrupting opencode sometimes takes the SHELL with it, which ends the
    # session. See the long note in Group 6: psmux's Ctrl+C decision is identical
    # in the runs where the shell survives and the runs where it does not (same
    # three PSMUX_MOUSE_DEBUG lines, raw 0x03 only, no console broadcast), and the
    # shell dies 1ms BEFORE the server, which is "last pane exited so the session
    # ended", not something killing the server. That is opencode's teardown.
    #
    # So this checks what psmux owes: either the session is up and fully usable,
    # or it is gone cleanly with nothing wedged behind it.
    # A returned prompt is owed only by a run whose shell survived: when
    # opencode's teardown takes the shell early there is never a prompt to see,
    # and that run is held to the teardown contract below instead. Recorded here
    # against the capture Wait-ShellBack already made, reported with the rest of
    # the "still usable" checks once it is known which outcome this run took.
    $hasOcPrompt = $capOC -match 'PS [A-Z]:\\'

    # Which of the two acceptable outcomes this run takes is NOT decidable from
    # one has-session sample, because the session is still settling for seconds
    # after the prompt comes back. Measured on 2026-09-19, four rounds of each
    # app in an isolated namespace, polled every 200 ms:
    #
    #   opencode  prompt back at ~250 ms, shell PROCESS and session both gone at
    #             7.3 to 7.7 s, 4 of 4
    #   pstop     prompt back at ~240 ms, both still alive at the end of the
    #             window, 4 of 4
    #
    # and psmux's decision is identical for both, the same three lines under
    # PSMUX_MOUSE_DEBUG=1 ending in "raw-mode non-shell foreground: deliver raw
    # 0x03, skip CTRL_C_EVENT". So psmux writes one byte and broadcasts nothing;
    # the seven second teardown that takes the shell belongs to opencode, and
    # psmux ending a session whose last pane's child exited is correct tmux
    # behaviour.
    #
    # The old code sampled has-session once, right after the prompt returned,
    # and committed to the "still usable" branch. When the teardown landed in
    # the second that followed, every command ran against a server that was gone
    # and two assertions failed on output that could never appear (the sweep of
    # 2026-09-19 and 2 of 3 reruns). Nothing is pre-committed now: the usable
    # checks run and are abandoned the moment the session goes, and a run that
    # loses its shell is held to the teardown contract instead.
    function Test-OcAlive {
        psmux has-session -t tui_oc 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    $ocGone = -not (Test-OcAlive)
    $ocUsable = @(@{ n = "opencode Ctrl+C: shell prompt visible"; p = [bool]$hasOcPrompt })

    if (-not $ocGone) {
        psmux send-keys -t tui_oc "echo oc_test_ok" Enter
        Start-Sleep -Seconds 1
        if (Test-OcAlive) {
            $capOC2 = psmux capture-pane -t tui_oc -p 2>&1 | Out-String
            $ocUsable += @{ n = "opencode Ctrl+C: typing works"; p = [bool]($capOC2 -match 'oc_test_ok') }
        } else { $ocGone = $true }
    }

    if (-not $ocGone) {
        psmux send-keys -t tui_oc "echo oc_RST" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc Left Left Left ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc "V" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc Enter
        Start-Sleep -Seconds 1
        if (Test-OcAlive) {
            $capOC3 = psmux capture-pane -t tui_oc -p 2>&1 | Out-String
            $ocUsable += @{ n = "opencode Ctrl+C: arrow keys work"; p = [bool]($capOC3 -match 'oc_VRST') }
        } else { $ocGone = $true }
    }

    if (-not $ocGone) {
        # The session outlived the whole group: it owes a working pane.
        foreach ($chk in $ocUsable) { Add-Result $chk.n $chk.p }
    } else {
        Write-Host "  [INFO] opencode's teardown took the shell with it; holding psmux to the clean teardown contract instead"
        # The port file is removed as the server shuts down, so give that a
        # moment rather than racing it: has-session failing only means the
        # server has stopped answering.
        $ocPortLeft = $true
        for ($i = 0; $i -lt 20; $i++) {
            $ocPortLeft = Test-Path "$env:USERPROFILE\.psmux\tui_oc.port"
            if (-not $ocPortLeft) { break }
            Start-Sleep -Milliseconds 250
        }
        Add-Result "opencode Ctrl+C: shell exited, session torn down with no stale port file" (-not $ocPortLeft)

        psmux new-session -d -s tui_oc2 -x 120 -y 30 2>$null
        Start-Sleep -Seconds 4
        psmux send-keys -t tui_oc2 "echo oc_recovered_ok" Enter
        Start-Sleep -Seconds 2
        $capOCR = psmux capture-pane -t tui_oc2 -p 2>&1 | Out-String
        Add-Result "opencode Ctrl+C: psmux still healthy after the shell exited" ($capOCR -match 'oc_recovered_ok')

        # And the arrow-key/terminal-state check that matters is still made, just
        # on a pane that exists: a TUI app must not leave the next shell broken.
        psmux send-keys -t tui_oc2 "echo oc_RST" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc2 Left Left Left ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc2 "V" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_oc2 Enter
        Start-Sleep -Seconds 1
        $capOCR2 = psmux capture-pane -t tui_oc2 -p 2>&1 | Out-String
        Add-Result "opencode Ctrl+C: arrow keys work in a fresh pane" ($capOCR2 -match 'oc_VRST')
        psmux kill-session -t tui_oc2 2>$null
    }
    
    psmux kill-session -t tui_oc 2>$null
    Start-Sleep -Seconds 1
} else {
    Write-Host "`n--- Group 4: opencode not found, skipping ---"
}

# =====================================================================
# TEST GROUP 5: Multiple TUI launches in same pane
# =====================================================================
Write-Host "`n--- Group 5: Multiple TUI launches ---"
psmux new-session -d -s tui_multi -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 750

for ($i = 1; $i -le 3; $i++) {
    psmux send-keys -t tui_multi "pwsh -NoProfile -File `"$cleanScript`"" Enter
    Start-Sleep -Seconds 1
}

psmux send-keys -t tui_multi "echo multi_test_ok" Enter
# The three queued fake-TUI launches take ~2s each (pwsh startup + sleep 1), so
# the echo only runs once the third one exits. A fixed 1s capture raced that
# and failed while the terminal was provably fine (the arrow-key round trip
# below passed). Poll like Wait-ShellBack instead of sampling once.
$capM = ""
$deadlineM = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadlineM) {
    Start-Sleep -Milliseconds 500
    $capM = psmux capture-pane -t tui_multi -p 2>&1 | Out-String
    if ($capM -match 'multi_test_ok') { break }
}
Add-Result "Multi TUI: terminal works after 3 launches" ($capM -match 'multi_test_ok')

$hasMultiGarbage = $capM -match '\[\d{2,};[\d;]+[Mm]'
Add-Result "Multi TUI: no escape garbage" (-not $hasMultiGarbage)

psmux send-keys -t tui_multi "echo multi_JKL" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_multi Left Left Left ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_multi "W" ""
Start-Sleep -Milliseconds 500
psmux send-keys -t tui_multi Enter
Start-Sleep -Seconds 1
$capM2 = psmux capture-pane -t tui_multi -p 2>&1 | Out-String
Add-Result "Multi TUI: arrow keys work after 3 launches" ($capM2 -match 'multi_WJKL')

psmux kill-session -t tui_multi 2>$null
Start-Sleep -Seconds 1

# =====================================================================
# TEST GROUP 6: pstop then opencode back-to-back in same pane
# =====================================================================
if ($pstopPath -and $opencodePath) {
    Write-Host "`n--- Group 6: pstop then opencode back-to-back ---"
    psmux new-session -d -s tui_combo -x 120 -y 30 2>$null
    Start-Sleep -Milliseconds 750
    
    # Same rule as Group 4: wait for each app to actually take over the pane
    # before interrupting it, and for the shell to come back before moving on.
    # Interrupting opencode 750ms after launch left it starting up AFTER the
    # Ctrl+C, so it was still running when the checks below ran.
    psmux send-keys -t tui_combo "pstop.exe" Enter
    Add-Result "Combo: pstop took over the pane" (Wait-AppTookOver 'tui_combo' 20)
    psmux send-keys -t tui_combo C-c
    $null = Wait-ShellBack 'tui_combo' 15

    psmux send-keys -t tui_combo "cd c:\cctest && opencode" Enter
    Add-Result "Combo: opencode took over the pane" (Wait-AppTookOver 'tui_combo' 25)
    psmux send-keys -t tui_combo C-c
    $null = Wait-ShellBack 'tui_combo' 15

    # After interrupting opencode the SHELL sometimes exits, which ends the
    # session. That is opencode's teardown, not a psmux defect, and psmux ending a
    # session whose last pane's shell exited is correct tmux behaviour. Evidence:
    #
    #   * psmux's Ctrl+C decision is byte for byte IDENTICAL in the runs where the
    #     shell survives and the runs where it does not. With PSMUX_MOUSE_DEBUG=1
    #     all four runs log the same three lines:
    #         console mode=0x0006 PROCESSED_INPUT=false fg_is_shell=false
    #         raw-mode non-shell foreground: deliver raw 0x03, skip CTRL_C_EVENT
    #     so psmux never broadcasts a console event here, it only writes raw 0x03.
    #   * Polled at 100ms, the SHELL dies first and the server follows 1ms later
    #     (484ms vs 485ms), which is the ordering of "last pane exited, so the
    #     session ended", not of something killing the server.
    #
    # Asserting "the shell must survive two Ctrl+C" therefore asserts something
    # about opencode. What psmux owes is checked instead: if the session is still
    # up it must be fully usable, and if the shell exited the session must be gone
    # CLEANLY rather than left wedged or half alive.
    # Not pre-committed, for the reason measured in Group 4: opencode's teardown
    # lands about seven seconds after the interrupt, so a single has-session
    # sample here can read true and then false a second later.
    function Test-ComboAlive {
        psmux has-session -t tui_combo 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    $comboGone = -not (Test-ComboAlive)
    $comboUsable = @()

    if (-not $comboGone) {
        psmux send-keys -t tui_combo "echo combo_test_ok" Enter
        Start-Sleep -Seconds 2
        if (Test-ComboAlive) {
            $capC = psmux capture-pane -t tui_combo -p 2>&1 | Out-String
            $comboUsable += @{ n = "Combo test: typing works"; p = [bool]($capC -match 'combo_test_ok') }
            $comboUsable += @{ n = "Combo test: no garbled text"; p = -not [bool]($capC -match '\[\d{2,};[\d;]+[Mm]') }
        } else { $comboGone = $true }
    }

    if (-not $comboGone) {
        psmux send-keys -t tui_combo "echo combo_ABC" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_combo Left Left Left ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_combo "X" ""
        Start-Sleep -Milliseconds 500
        psmux send-keys -t tui_combo Enter
        Start-Sleep -Seconds 1
        if (Test-ComboAlive) {
            $capC2 = psmux capture-pane -t tui_combo -p 2>&1 | Out-String
            $comboUsable += @{ n = "Combo test: arrow keys work"; p = [bool]($capC2 -match 'combo_XABC') }
        } else { $comboGone = $true }
    }

    if (-not $comboGone) {
        foreach ($chk in $comboUsable) { Add-Result $chk.n $chk.p }
    } else {
        # The shell exited. psmux must have torn the session down completely: no
        # port file left claiming a live server, and a brand new session must
        # still start and work, proving nothing was left wedged.
        Write-Host "  [INFO] opencode's teardown took the shell with it; holding psmux to the clean teardown contract instead"
        $portLeft = $true
        for ($i = 0; $i -lt 20; $i++) {
            $portLeft = Test-Path "$env:USERPROFILE\.psmux\tui_combo.port"
            if (-not $portLeft) { break }
            Start-Sleep -Milliseconds 250
        }
        Add-Result "Combo test: shell exited, session torn down with no stale port file" (-not $portLeft)

        psmux new-session -d -s tui_combo2 -x 120 -y 30 2>$null
        Start-Sleep -Seconds 4
        psmux send-keys -t tui_combo2 "echo combo_recovered_ok" Enter
        Start-Sleep -Seconds 2
        $capR = psmux capture-pane -t tui_combo2 -p 2>&1 | Out-String
        Add-Result "Combo test: psmux still healthy after the shell exited" ($capR -match 'combo_recovered_ok')
        psmux kill-session -t tui_combo2 2>$null
    }
    
    psmux kill-session -t tui_combo 2>$null
    Start-Sleep -Seconds 1
} else {
    Write-Host "`n--- Group 6: Skipped (requires both pstop + opencode) ---"
}

# =====================================================================
# TEST GROUP 7: Screen cleanliness
# =====================================================================
Write-Host "`n--- Group 7: Screen cleanliness ---"
psmux new-session -d -s tui_clean_chk -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 750

psmux send-keys -t tui_clean_chk "pwsh -NoProfile -File `"$cleanScript`"" Enter
Start-Sleep -Seconds 1

for ($i = 1; $i -le 5; $i++) {
    psmux send-keys -t tui_clean_chk "echo line_$i" Enter
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Seconds 1

$capClean = psmux capture-pane -t tui_clean_chk -p 2>&1 | Out-String
$lines = ($capClean -split "`n") | Where-Object { $_.Trim().Length -gt 0 }
Add-Result "Screen clean: output lines visible" ($lines.Count -ge 5) "($($lines.Count) non-empty lines)"

$allLinesPresent = $true
for ($i = 1; $i -le 5; $i++) {
    if ($capClean -notmatch "line_$i") { $allLinesPresent = $false; break }
}
Add-Result "Screen clean: all typed lines present" $allLinesPresent

psmux kill-session -t tui_clean_chk 2>$null

# =====================================================================
# TEST GROUP 8: TUI exit in split panes
# =====================================================================
Write-Host "`n--- Group 8: TUI exit in split panes ---"
if ($pstopPath) {
    # Vertical split
    psmux new-session -d -s tui_split -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    psmux split-window -t tui_split -v
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_split "pstop.exe" Enter
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_split "q"
    Start-Sleep -Seconds 1
    $capSV = psmux capture-pane -t tui_split -p 2>&1 | Out-String
    $hasSV = $capSV -match 'CPU%|F1Help|PID\s+PPID'
    Add-Result "Split-V: no pstop remnants" (-not $hasSV)
    psmux send-keys -t tui_split "echo split_v_ok" Enter
    Start-Sleep -Seconds 1
    $capSV2 = psmux capture-pane -t tui_split -p 2>&1 | Out-String
    Add-Result "Split-V: typing works" ($capSV2 -match 'split_v_ok')
    psmux kill-session -t tui_split 2>$null
    Start-Sleep -Seconds 1

    # Horizontal split
    psmux new-session -d -s tui_splith -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    psmux split-window -t tui_splith -h
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_splith "pstop.exe" Enter
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_splith "q"
    Start-Sleep -Seconds 1
    $capSH = psmux capture-pane -t tui_splith -p 2>&1 | Out-String
    $hasSH = $capSH -match 'CPU%|F1Help|PID\s+PPID'
    Add-Result "Split-H: no pstop remnants" (-not $hasSH)
    psmux send-keys -t tui_splith "echo split_h_ok" Enter
    Start-Sleep -Seconds 1
    $capSH2 = psmux capture-pane -t tui_splith -p 2>&1 | Out-String
    Add-Result "Split-H: typing works" ($capSH2 -match 'split_h_ok')
    psmux kill-session -t tui_splith 2>$null
    Start-Sleep -Seconds 1

    # Both panes in a split running pstop simultaneously
    psmux new-session -d -s tui_multi -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    psmux split-window -t tui_multi -v
    Start-Sleep -Seconds 1
    psmux send-keys -t "tui_multi:0.1" "pstop.exe" Enter
    Start-Sleep -Seconds 1
    psmux select-pane -t "tui_multi:0.0"
    Start-Sleep -Milliseconds 500
    psmux send-keys -t "tui_multi:0.0" "pstop.exe" Enter
    Start-Sleep -Seconds 1
    psmux send-keys -t "tui_multi:0.0" "q"
    psmux send-keys -t "tui_multi:0.1" "q"
    Start-Sleep -Seconds 1
    $capM0 = psmux capture-pane -t "tui_multi:0.0" -p 2>&1 | Out-String
    $capM1 = psmux capture-pane -t "tui_multi:0.1" -p 2>&1 | Out-String
    $hm0 = $capM0 -match 'CPU%|F1Help|PID\s+PPID'
    $hm1 = $capM1 -match 'CPU%|F1Help|PID\s+PPID'
    Add-Result "Multi-split pane0: no pstop remnants" (-not $hm0)
    Add-Result "Multi-split pane1: no pstop remnants" (-not $hm1)
    psmux kill-session -t tui_multi 2>$null
    Start-Sleep -Seconds 1
} else {
    Write-Host "  [SKIP] pstop not found"
}

# =====================================================================
# TEST GROUP 9: TUI exit in new window (not initial session window)
# =====================================================================
Write-Host "`n--- Group 9: TUI exit in new window ---"
if ($pstopPath) {
    psmux new-session -d -s tui_newwin -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    psmux new-window -t tui_newwin
    Start-Sleep -Milliseconds 500
    psmux send-keys -t tui_newwin "pstop.exe" Enter
    Start-Sleep -Milliseconds 750
    psmux send-keys -t tui_newwin "q"
    Start-Sleep -Seconds 1
    $capNW = psmux capture-pane -t tui_newwin -p 2>&1 | Out-String
    $hasNW = $capNW -match 'CPU%|F1Help|PID\s+PPID'
    Add-Result "New-window: no pstop remnants" (-not $hasNW)
    psmux send-keys -t tui_newwin "echo newwin_ok" Enter
    Start-Sleep -Seconds 1
    $capNW2 = psmux capture-pane -t tui_newwin -p 2>&1 | Out-String
    Add-Result "New-window: typing works" ($capNW2 -match 'newwin_ok')
    psmux kill-session -t tui_newwin 2>$null
    Start-Sleep -Seconds 1

    # New window with split inside
    psmux new-session -d -s tui_nwsplit -x 120 -y 30 2>$null
    Start-Sleep -Seconds 1
    psmux new-window -t tui_nwsplit
    Start-Sleep -Milliseconds 300
    psmux split-window -t tui_nwsplit -v
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_nwsplit "pstop.exe" Enter
    Start-Sleep -Seconds 1
    psmux send-keys -t tui_nwsplit "q"
    Start-Sleep -Seconds 1
    $capNWS = psmux capture-pane -t tui_nwsplit -p 2>&1 | Out-String
    $hasNWS = $capNWS -match 'CPU%|F1Help|PID\s+PPID'
    Add-Result "New-win+split: no pstop remnants" (-not $hasNWS)
    psmux send-keys -t tui_nwsplit "echo nwsplit_ok" Enter
    Start-Sleep -Seconds 1
    $capNWS2 = psmux capture-pane -t tui_nwsplit -p 2>&1 | Out-String
    Add-Result "New-win+split: typing works" ($capNWS2 -match 'nwsplit_ok')
    psmux kill-session -t tui_nwsplit 2>$null
    Start-Sleep -Seconds 1
} else {
    Write-Host "  [SKIP] pstop not found"
}

# Cleanup
Remove-Item $cleanScript -Force -ErrorAction SilentlyContinue
Remove-Item $crashScript -Force -ErrorAction SilentlyContinue
psmux kill-server 2>$null

# --- Summary ---
Write-Host "`n=== RESULTS ==="
$results | Format-Table -AutoSize | Out-String | Write-Host
$pass = ($results | Where-Object { $_.Result -eq "PASS" }).Count
$fail = ($results | Where-Object { $_.Result -eq "FAIL" }).Count
Write-Host "Total: $($results.Count)  Pass: $pass  Fail: $fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
