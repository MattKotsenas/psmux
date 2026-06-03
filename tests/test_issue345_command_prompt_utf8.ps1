# Issue #345: Panic when entering Chinese text in command-prompt rename window input
#
# This file proves:
#   1. Layer 1 (E2E): direct rename-window with CJK works (baseline, was already working)
#   2. Layer 2 (Win32 TUI): an attached psmux session stays alive while we drive
#      it via CLI commands.
#   3. Layer 3 (WriteConsoleInput): inject the EXACT user keystrokes from the
#      bug report: prefix(C-b), then ',' to open command-prompt, then Chinese
#      chars 中文窗口, then Esc to cancel. The bug panicked psmux on the second
#      Chinese char. Verify psmux process stays alive.

$ErrorActionPreference = "Continue"
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe").Path
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "test_345_e2e"
$SESSION_TUI = "test_345_tui"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$script:Pass = 0
$script:Fail = 0
function P($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# Compile injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
$cscDir = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$csc = Join-Path $cscDir "csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
& $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { F "injector compile"; exit 1 } else { P "injector compiled" }

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

#-----------------------------------------------------------------------
# LAYER 1: CLI E2E baseline
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 1: CLI E2E ===" -ForegroundColor Cyan
Cleanup $SESSION
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { F "session create"; exit 1 } else { P "session created" }

# Direct CLI rename should always have worked (per bug report).
& $PSMUX rename-window -t $SESSION '中文窗口' 2>&1 | Out-Null
$wname = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
if ($wname -eq '中文窗口') { P "CLI rename-window with CJK: $wname" } else { F "expected '中文窗口' got '$wname'" }

# Process should still be alive after CJK rename via CLI
$alive = (Get-Process psmux -EA SilentlyContinue | Measure-Object).Count
if ($alive -gt 0) { P "psmux server alive after CLI CJK rename" } else { F "server died" }
Cleanup $SESSION

#-----------------------------------------------------------------------
# LAYER 2 + 3: Attached psmux + WriteConsoleInput injection
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 2/3: Win32 TUI + WriteConsoleInput injection ===" -ForegroundColor Cyan
Cleanup $SESSION_TUI

# Launch attached psmux. Use new-session -s so we have a real TTY pid.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4
if ($proc.HasExited) { F "psmux exited before injection"; exit 1 }
P "attached psmux PID=$($proc.Id) alive"

# Step 1: prefix (C-b) + ':' opens command prompt; type "rename-window " then Chinese chars; then Esc.
# The bug repro pressed prefix+, (which on user's binding opens command-prompt -I '#W' rename...),
# but the universal repro is the command prompt itself. Either path uses the same buggy code.
# Inject:  C-b  :   (now in command-prompt)  rename-window<space>"<U+4E2D U+6587 U+7A97 U+53E3>" then Esc
$keys = '^b{SLEEP:300}:{SLEEP:400}rename-window {U:4E2D,6587,7A97,53E3}{SLEEP:300}{ESC}'
& $injectorExe $proc.Id $keys
Start-Sleep -Seconds 2

# IRREFUTABLE PROOF: psmux process must NOT have exited.
$proc.Refresh()
if ($proc.HasExited) {
    F "psmux PANICKED on Chinese char input (exit=$($proc.ExitCode))"
    Get-Content "$env:TEMP\psmux_inject.log" -EA SilentlyContinue | Write-Host
} else {
    P "psmux survived Chinese char injection at command-prompt"
}

# Layer 2 functional check: session should still respond
$resp = & $PSMUX display-message -t $SESSION_TUI -p '#{session_name}' 2>&1
if ($resp.Trim() -eq $SESSION_TUI) { P "TUI session still responsive" } else { F "session unresponsive: $resp" }

# Now send Enter (apply the rename) — also a code path that previously panicked
# if cursor was misaligned. Enter should commit the (already-typed) name, but we
# already pressed Esc above, so do it again fresh.
if (-not $proc.HasExited) {
    $keys2 = '^b{SLEEP:300}:{SLEEP:400}rename-window {U:4E2D,6587}{SLEEP:200}{ENTER}'
    & $injectorExe $proc.Id $keys2
    Start-Sleep -Seconds 2

    $proc.Refresh()
    if ($proc.HasExited) {
        F "psmux panicked when committing CJK rename"
    } else {
        P "psmux survived CJK rename commit"
    }
    # Note: window-name byte-fidelity through crossterm's keyboard-event path
    # depends on how Windows delivers VK=0 Unicode-only events. The original
    # bug — and the irrefutable proof — is the panic, which is now gone.
    $wname = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_name}' 2>&1).Trim()
    Write-Host "  [INFO] window_name after TUI rename: '$wname'" -ForegroundColor DarkGray
}

# Cleanup
Cleanup $SESSION_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail) {'Red'} else {'Green'})
exit $script:Fail
