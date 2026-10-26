# Issue #502: "terminal color turns to chaos after nvim a file"
#
# A full screen app runs in the alternate screen. When it exits, the pane must
# come back with the graphic rendition the shell had BEFORE the app started.
# The reported failure was the shell prompt being redrawn with a stuck
# background (palette index 5, magenta), which made every following line, and
# then the whole pane after `clear`, solid magenta.
#
# Root cause was in the vendored vt100 parser: DECSC (ESC 7 / CSI s) and the
# DECSET 1049 alternate-screen save shared ONE saved-attributes slot, so an app
# that saved the cursor while its own colours were active overwrote what 1049
# had saved on entry. psmux creates pane ConPTYs with
# PSEUDOCONSOLE_PASSTHROUGH_MODE, so the child's raw DECSC reaches the parser.
#
# This suite guards the user-visible invariant end to end: after an alternate
# screen app exits, no stray SGR colour is left on the prompt.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue502"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# NO_COLOR makes crossterm drop every colour, which would make these assertions
# vacuously pass. Clear it for the duration of the run.
$env:NO_COLOR = $null
Remove-Item Env:\NO_COLOR -EA SilentlyContinue

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Capture the pane WITH escape sequences and return it as one string.
function Get-PaneEscaped {
    ((& $PSMUX capture-pane -t $SESSION -p -e 2>&1 | Out-String) -replace "`e", "<ESC>")
}

# The prompt line is the last non-empty line. A clean pane renders it as
# "<ESC>[0m" plus text; a leaked background shows up as extra SGR params.
function Get-LastLine($cap) {
    ($cap -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
}

$work = Join-Path $env:TEMP "psmux_issue502"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Build the stand-in full screen app: enters the alternate screen, sets its own
# colours, saves the cursor with DECSC while they are active, then exits.
$src = Join-Path $work "altapp502.cs"
@'
using System;
using System.Threading;
class AltApp502 {
    static void W(string s) {
        var b = System.Text.Encoding.ASCII.GetBytes(s);
        var o = Console.OpenStandardOutput();
        o.Write(b, 0, b.Length); o.Flush();
    }
    static void Main() {
        string e = "\x1b";
        W(e + "[32m");            Thread.Sleep(300);
        W(e + "[?1049h");         Thread.Sleep(500);
        W(e + "[35;45m");
        W("ALT SCREEN CONTENT");  Thread.Sleep(300);
        W(e + "7");               Thread.Sleep(500);   // DECSC with app colours live
        W(e + "[?1049l");         Thread.Sleep(300);
    }
}
'@ | Set-Content -Path $src -Encoding UTF8

$altExe = Join-Path $work "altapp502.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
& $csc /nologo /optimize /out:$altExe $src 2>&1 | Out-Null
if (-not (Test-Path $altExe)) {
    Write-Fail "could not compile the alternate-screen helper"
    exit 1
}

Write-Host "`n=== Issue #502: alternate screen SGR leak ===" -ForegroundColor Cyan

Cleanup
& $PSMUX new-session -d -s $SESSION -x 70 -y 12 -c $work 2>&1 | Out-Null
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

# === TEST 1: alternate screen app that uses DECSC must not stain the pane ===
Write-Host "`n[Test 1] alternate-screen app with DECSC leaves no stuck background" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION ".\altapp502.exe" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5
& $PSMUX send-keys -t $SESSION "echo AFTER_ALT" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

$cap = Get-PaneEscaped
if ($cap -match "AFTER_ALT") { Write-Pass "the shell ran after the app exited" }
else { Write-Fail "marker AFTER_ALT not found in pane" }

# The app's magenta background (SGR 45) must not survive into the main screen.
if ($cap -notmatch ";45m") { Write-Pass "no magenta background (SGR 45) leaked into the pane" }
else { Write-Fail "BUG #502: magenta background leaked: $(Get-LastLine $cap)" }
if ($cap -notmatch ";35;45m") { Write-Pass "no magenta-on-magenta run in the pane" }
else { Write-Fail "BUG #502: magenta fg+bg leaked: $(Get-LastLine $cap)" }

# === TEST 2: clear must not repaint the pane in the leaked colour ===
Write-Host "`n[Test 2] clear after the app does not fill the pane with a stuck colour" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$capClear = Get-PaneEscaped
if ($capClear -notmatch ";45m") { Write-Pass "pane is clean after clear" }
else { Write-Fail "BUG #502: pane still magenta after clear" }

# === TEST 3: real editor round trip (skipped when nvim is absent) ===
Write-Host "`n[Test 3] nvim round trip leaves the prompt clean" -ForegroundColor Yellow
$nvim = Get-Command nvim -EA SilentlyContinue
if ($nvim) {
    "Write-Host 'hello'" | Set-Content -Path (Join-Path $work "t502.ps1") -Encoding UTF8
    # Fresh session: the helper above deliberately leaves a foreground set on
    # the MAIN screen (correct behaviour, a real terminal keeps it too). This
    # test is about what the editor leaves behind, so start from a clean pane.
    Cleanup
    & $PSMUX new-session -d -s $SESSION -x 70 -y 12 -c $work 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    & $PSMUX send-keys -t $SESSION "nvim t502.ps1" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    & $PSMUX send-keys -t $SESSION Escape 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    & $PSMUX send-keys -t $SESSION ":q!" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $capNvim = Get-PaneEscaped
    $last = Get-LastLine $capNvim
    # The prompt must come back with no colour carried out of the editor.
    # "<ESC>[0m" alone is clean; anything like "<ESC>[0;96;45m" is the bug.
    if ($last -match '^<ESC>\[0m') { Write-Pass "prompt returned with a clean SGR state" }
    else { Write-Fail "BUG #502: prompt left with stray SGR: $last" }
    # The reported signature was fg and bg restored together as a pair.
    if ($capNvim -notmatch '<ESC>\[0;\d+;4\dm') { Write-Pass "no fg+bg pair carried out of the editor" }
    else { Write-Fail "BUG #502: editor colours restored into the shell: $last" }
} else {
    Write-Host "  [SKIP] nvim not installed" -ForegroundColor DarkGray
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
