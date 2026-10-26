# Issue #454: "Ctrl+Break kills session"
#
# Reported: pressing Ctrl+Break to kill a non-responsive program detaches/kills
# the psmux session (the attached window vanishes) while the program keeps
# running, exactly the opposite of Windows Terminal where Ctrl+Break interrupts
# the program and you stay in your shell.
#
# Root cause: the attached CLIENT installed NO console control handler. Windows
# ALWAYS delivers Ctrl+Break as a CTRL_BREAK_EVENT console signal (it can never
# arrive as a keystroke, even in raw mode), so the crossterm key loop never sees
# it and the OS default handler terminated the client.
#
# Fix:
#   1. Client installs a console control handler that survives Ctrl+Break /
#      Ctrl+C and flags the main loop to forward "send-key C-Break".
#   2. The server's send-key "C-Break" delivers a GENUINE CTRL_BREAK_EVENT to the
#      pane's ConPTY child: it briefly AttachConsole()s to the child's console and
#      broadcasts CTRL_BREAK to process group 0 (send_ctrl_break_event).  This DOES
#      reach the child — proven to kill a Ctrl+C-immune program — matching Windows
#      Terminal.  The old approach routed Ctrl+Break through the Ctrl+C path (raw
#      0x03 + CTRL_C_EVENT), which a Ctrl+C-immune program simply swallowed, so it
#      kept running (the "not solved" report).
#   3. During the broadcast the server registers a survive-Ctrl+Break handler so
#      its own broadcast can never tear the server (and every session) down.
#
# Verification cannot use send-keys/WriteConsoleInput because Ctrl+Break is a
# SIGNAL, not a keystroke. This test compiles ctrl_break_sender.cs which raises a
# genuine CTRL_BREAK_EVENT on the client's console, the true real-world path, and
# ctrlc_immune_helper.cs, a program that ignores Ctrl+C but dies on Ctrl+Break.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# --- Compile the Ctrl+Break signal sender -----------------------------------
$breakExe = "$env:TEMP\psmux_ctrl_break_sender.exe"
$src = Join-Path $PSScriptRoot "ctrl_break_sender.cs"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
& $csc /nologo /optimize /out:$breakExe $src 2>&1 | Out-Null
if (-not (Test-Path $breakExe)) { Write-Host "Cannot compile ctrl_break_sender.cs" -ForegroundColor Red; exit 1 }

# --- Compile a Ctrl+C-immune program (faithful "unresponsive program") --------
# It ignores Ctrl+C entirely but dies on a genuine Ctrl+Break — exactly the case
# the first fix missed (Ctrl+Break was routed through the Ctrl+C path, which such
# a program swallows).  A real terminal kills it with Ctrl+Break; psmux must too.
$immuneExe = "$env:TEMP\psmux_ctrlc_immune.exe"
$immuneSrc = Join-Path $PSScriptRoot "ctrlc_immune_helper.cs"
& $csc /nologo /optimize /out:$immuneExe $immuneSrc 2>&1 | Out-Null
if (-not (Test-Path $immuneExe)) { Write-Host "Cannot compile ctrlc_immune_helper.cs" -ForegroundColor Red; exit 1 }

function New-Sess($s) {
    & $PSMUX kill-session -t $s 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$s -PassThru
    Start-Sleep -Seconds 5
    return $p
}
function Alive($s) { & $PSMUX has-session -t $s 2>$null; return ($LASTEXITCODE -eq 0) }

Write-Host "`n=== Issue #454: Ctrl+Break must interrupt the program, not kill the session ===" -ForegroundColor Cyan

# ── TEST 1: idle shell — client + session + shell all survive Ctrl+Break ──────
Write-Host "`n[Test 1] Idle shell survives Ctrl+Break (client, session, shell)" -ForegroundColor Yellow
$s1 = "iss454_idle"
$p1 = New-Sess $s1
& $PSMUX send-keys -t $s1 "echo IDLE_READY" Enter
Start-Sleep -Seconds 2
& $breakExe $p1.Id break
Start-Sleep -Seconds 2
$p1.Refresh()
if (-not $p1.HasExited) { Write-Pass "client still attached after Ctrl+Break (was killed before fix)" }
else { Write-Fail "client process exited on Ctrl+Break (bug)" }
if (Alive $s1) { Write-Pass "session still alive after Ctrl+Break" }
else { Write-Fail "session died on Ctrl+Break" }
& $PSMUX send-keys -t $s1 "echo SHELL_ALIVE_1" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t $s1 -p 2>&1 | Out-String
if ($cap1 -match "SHELL_ALIVE_1") { Write-Pass "shell still executes commands after Ctrl+Break" }
else { Write-Fail "shell unresponsive after Ctrl+Break" }
& $PSMUX kill-session -t $s1 2>&1 | Out-Null
try { if (-not $p1.HasExited) { Stop-Process -Id $p1.Id -Force -EA SilentlyContinue } } catch {}
Start-Sleep -Milliseconds 500

# ── TEST 2: Ctrl+C-IMMUNE program — the reported scenario ─────────────────────
# The reporter's "unresponsive program" is one Ctrl+C cannot stop.  The first fix
# routed Ctrl+Break through the Ctrl+C path, so such a program kept running.  A
# genuine Ctrl+Break must kill it (as Windows Terminal does) while the session,
# client and shell all survive and the shell returns to its prompt.
Write-Host "`n[Test 2] Ctrl+Break kills a Ctrl+C-IMMUNE program and returns to prompt" -ForegroundColor Yellow
$s2 = "iss454_child"
$immBaseline = @(Get-CimInstance Win32_Process -Filter "Name='psmux_ctrlc_immune.exe'" | Select-Object -Expand ProcessId)
$p2 = New-Sess $s2
& $PSMUX send-keys -t $s2 "& '$immuneExe'" Enter
Start-Sleep -Seconds 3
$immPids = @(Get-CimInstance Win32_Process -Filter "Name='psmux_ctrlc_immune.exe'" | Select-Object -Expand ProcessId |
    Where-Object { $_ -notin $immBaseline })
$cap2a = & $PSMUX capture-pane -t $s2 -p 2>&1 | Out-String
if ($cap2a -match "CTRLC_IMMUNE_READY") { Write-Pass "Ctrl+C-immune program is running in the pane" }
else { Write-Fail "immune program did not start" }

& $breakExe $p2.Id break
# Poll up to ~6s for the child to be gone (signal delivery is async).
$immStillUp = $immPids
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 500
    $immStillUp = @(Get-Process -Id $immPids -EA SilentlyContinue)
    if ($immStillUp.Count -eq 0) { break }
}
$p2.Refresh()
if (-not $p2.HasExited) { Write-Pass "client survived Ctrl+Break with a running child" }
else { Write-Fail "client exited on Ctrl+Break" }
if (Alive $s2) { Write-Pass "session survived Ctrl+Break with a running child" }
else { Write-Fail "session died on Ctrl+Break" }
if ($immStillUp.Count -eq 0) { Write-Pass "Ctrl+C-immune program was KILLED by a genuine Ctrl+Break" }
else { Write-Fail "immune program still running after Ctrl+Break ($($immStillUp.Count) left) — routed via Ctrl+C path?" }
& $PSMUX send-keys -t $s2 "echo SHELL_BACK_2" Enter
Start-Sleep -Seconds 2
$cap2b = & $PSMUX capture-pane -t $s2 -p 2>&1 | Out-String
if ($cap2b -match "SHELL_BACK_2") { Write-Pass "shell returned to prompt after killing the program" }
else { Write-Fail "shell did not return to prompt" }
& $PSMUX kill-session -t $s2 2>&1 | Out-Null
try { if (-not $p2.HasExited) { Stop-Process -Id $p2.Id -Force -EA SilentlyContinue } } catch {}
Get-Process -Id $immPids -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 500

# ── TEST 3: server survives a direct Ctrl+Break (regression guard) ────────────
Write-Host "`n[Test 3] Server survives a direct Ctrl+Break signal" -ForegroundColor Yellow
$s3 = "iss454_srv"
$p3 = New-Sess $s3
$serverPid = $null
for ($i = 0; $i -lt 20; $i++) {
    if (Test-Path "$psmuxDir\$s3.pid") {
        # .pid body is "pid" or "pid:creation_filetime" (PR #404); keep the pid part
        $serverPid = ((Get-Content "$psmuxDir\$s3.pid" -Raw).Trim().Split(':'))[0]
        if ($serverPid -match '^\d+$') { break }
    }
    Start-Sleep -Milliseconds 250
}
if (-not ($serverPid -match '^\d+$')) { Write-Fail "could not read server pid"; $serverPid = "0" }
& $breakExe $serverPid break
Start-Sleep -Seconds 2
if (Get-Process -Id $serverPid -EA SilentlyContinue) { Write-Pass "server process survived a direct Ctrl+Break" }
else { Write-Fail "server process died on direct Ctrl+Break" }
if (Alive $s3) { Write-Pass "session still reachable after server-directed Ctrl+Break" }
else { Write-Fail "session unreachable after server-directed Ctrl+Break" }
& $PSMUX kill-session -t $s3 2>&1 | Out-Null
try { if (-not $p3.HasExited) { Stop-Process -Id $p3.Id -Force -EA SilentlyContinue } } catch {}
Start-Sleep -Milliseconds 500

# ── TEST 4: Win32 TUI visual verification (CLI-driven) ────────────────────────
Write-Host "`n[Test 4] Win32 TUI: session remains functional through Ctrl+Break" -ForegroundColor Yellow
$s4 = "iss454_tui"
$p4 = New-Sess $s4
& $PSMUX split-window -v -t $s4 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panesBefore = (& $PSMUX display-message -t $s4 -p '#{window_panes}' 2>&1).Trim()
& $breakExe $p4.Id break
Start-Sleep -Seconds 2
$p4.Refresh()
$panesAfter = (& $PSMUX display-message -t $s4 -p '#{window_panes}' 2>&1).Trim()
if (-not $p4.HasExited -and $panesAfter -eq $panesBefore -and $panesAfter -eq "2") {
    Write-Pass "TUI: 2-pane layout intact and window alive after Ctrl+Break"
} else {
    Write-Fail "TUI: layout/window changed after Ctrl+Break (panes $panesBefore -> $panesAfter, exited=$($p4.HasExited))"
}
& $PSMUX kill-session -t $s4 2>&1 | Out-Null
try { if (-not $p4.HasExited) { Stop-Process -Id $p4.Id -Force -EA SilentlyContinue } } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
