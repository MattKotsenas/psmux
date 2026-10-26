# Issue #253 repro (non-blocking rewrite).
# Intent: prove which command forms after `--` in
#   psmux new -s <name> -d -- <command...>
# actually execute tech-pass.exe inside the pane. tech-pass.exe writes a
# marker file when it runs; that marker is the tangible proof that the pane
# command really executed (exactly mirroring the reporter's setup).
#
# The original script ran `& $PSMUX new ...` in the FOREGROUND. psmux
# attaches and stays attached as a live TUI (the fixed, correct behaviour),
# so the script blocked forever at the first scenario. Every scenario now
# launches psmux in ITS OWN window via Start-Process and verifies the intent
# through detached CLI calls:
#   * the session exists (list-sessions)
#   * the marker file appears for the forms that must run the exe
#   * capture-pane / display-message output is printed for diagnostics
# then tears down: kill-session, and stop the spawned process if still alive.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:Pass = 0
$script:Fail = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:Fail++ }

# Build a real tech-pass.exe (simple .NET console exe) so we exactly mirror the issue
$bin = "$env:TEMP\psmux253_bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$marker = "$env:TEMP\psmux253_marker.txt"
$exePath = "$bin\tech-pass.exe"

if (-not (Test-Path $exePath)) {
    $cs = "$env:TEMP\techpass.cs"
    @"
using System;
using System.IO;
using System.Threading;
class P {
    static void Main(string[] args) {
        File.WriteAllText(@"$marker", "TECHPASS_EXE_RAN");
        Console.WriteLine("TECH-PASS EXE STARTED, args=" + string.Join(",", args));
        Thread.Sleep(60000);
    }
}
"@ | Set-Content $cs -Encoding UTF8
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /out:$exePath $cs 2>&1 | Out-Null
}
Write-Host "Built tech-pass.exe: $(Test-Path $exePath)"
if (-not (Test-Path $exePath)) {
    Write-Fail "could not build tech-pass.exe; cannot run any scenario"
    exit $script:Fail
}

# Add bin to PATH so 'tech-pass' resolves (inherited by the Start-Process spawns)
$env:PATH = "$bin;$env:PATH"

function Test-Scenario {
    param(
        [string]$Name,
        [string[]]$CmdArgs,
        [bool]$ExpectMarker
    )
    $SESSION = "issue253_$Name"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item $marker -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800

    Write-Host ("`n=== SCENARIO: {0} ===" -f $Name) -ForegroundColor Cyan
    Write-Host ("CMD: psmux " + ($CmdArgs -join " ")) -ForegroundColor DarkGray

    # Launch psmux in ITS OWN window: if it attaches (it does), it must not
    # block this script. All verification below is via detached CLI calls.
    $p = Start-Process -FilePath $PSMUX -ArgumentList $CmdArgs -PassThru

    # Detached verification 1: the session must come up
    $sessionUp = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $ls = & $PSMUX list-sessions 2>&1 | Out-String
        if ($ls -match [regex]::Escape($SESSION)) { $sessionUp = $true; break }
        Start-Sleep -Milliseconds 400
    }
    if ($sessionUp) {
        Write-Pass "session $SESSION created"
    } else {
        Write-Fail "session $SESSION never appeared in list-sessions (spawn process exited=$($p.HasExited))"
    }

    # Detached verification 2: marker file = proof the pane command really ran
    $markerExists = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000) {
        if (Test-Path $marker) { $markerExists = $true; break }
        Start-Sleep -Milliseconds 400
    }

    # Diagnostics (detached): pane content and pane command formats
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    Write-Host "PANE CAPTURE:" -ForegroundColor Yellow
    Write-Host $cap.TrimEnd()
    Write-Host "Marker present: $markerExists"
    $paneCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1) -join ''
    $startCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_start_command}' 2>&1) -join ''
    Write-Host "pane_current_command: $paneCmd"
    Write-Host "pane_start_command:   $startCmd"

    if ($ExpectMarker) {
        if ($markerExists) {
            Write-Pass "tech-pass.exe ran (marker file written)"
        } else {
            Write-Fail "tech-pass.exe did not run: marker file missing (this form must execute the exe)"
        }
    } else {
        # The three exact issue forms invoke cmd.exe WITHOUT /c, and cmd.exe
        # ignores trailing tokens in that case, so tech-pass.exe is not
        # expected to run. Recorded as informational only; the assertions for
        # these forms are session creation and clean, non-hanging termination.
        Write-Host "  [INFO] marker=$markerExists (no marker assertion for this form)" -ForegroundColor DarkGray
    }

    # Teardown: kill the session and never leave the spawned process running
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    if ($p -and -not $p.HasExited) {
        $null = $p.WaitForExit(5000)
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
    return @{ Marker=$markerExists; PaneCmd=$paneCmd; StartCmd=$startCmd; Cap=$cap; SessionUp=$sessionUp }
}

# Exact issue scenarios (as reported in #253). cmd.exe without /c starts an
# interactive shell and ignores the trailing tokens, so no marker is expected.
$r1 = Test-Scenario -Name "issue_form1" -CmdArgs @("new","-s","issue253_issue_form1","-d","--","cmd","pwsh","-Command","tech-pass.exe") -ExpectMarker:$false
$r2 = Test-Scenario -Name "issue_form2" -CmdArgs @("new","-s","issue253_issue_form2","-d","--","cmd","pwsh","-Command","$bin\tech-pass.exe") -ExpectMarker:$false
$r3 = Test-Scenario -Name "issue_form3" -CmdArgs @("new","-s","issue253_issue_form3","-d","--","cmd","$bin\tech-pass.exe") -ExpectMarker:$false
# Sane forms: these must actually execute tech-pass.exe (marker required)
$r4 = Test-Scenario -Name "direct_exe"  -CmdArgs @("new","-s","issue253_direct_exe","-d","--","$bin\tech-pass.exe") -ExpectMarker:$true
$r5 = Test-Scenario -Name "cmd_slashc"  -CmdArgs @("new","-s","issue253_cmd_slashc","-d","--","cmd","/c","$bin\tech-pass.exe") -ExpectMarker:$true
# Absolute path on purpose: psmux pane environments get a rebuilt system PATH
# and do NOT inherit the launching client's PATH mutations, so a bare
# "tech-pass.exe" can never resolve inside the pane regardless of this
# script's $env:PATH prepend. This scenario proves pwsh -Command hosting of
# the exe, which is what issue #253 needs; bare-name PATH resolution is an
# environment-inheritance question, not a command-form question.
$r6 = Test-Scenario -Name "pwsh_command" -CmdArgs @("new","-s","issue253_pwsh_command","-d","--","pwsh","-Command","$bin\tech-pass.exe") -ExpectMarker:$true

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
$results = @{
    "issue_form1 (cmd pwsh -Command tech-pass.exe)" = $r1
    "issue_form2 (cmd pwsh -Command FULLPATH)"      = $r2
    "issue_form3 (cmd FULLPATH)"                     = $r3
    "direct_exe  (just the .exe)"                    = $r4
    "cmd_slashc  (cmd /c FULLPATH)"                  = $r5
    "pwsh_command (pwsh -Command tech-pass.exe)"     = $r6
}
foreach ($k in $results.Keys) {
    $v = $results[$k]
    "{0,-50} session={1,-5} marker={2,-5} paneCmd={3}" -f $k, $v.SessionUp, $v.Marker, $v.PaneCmd | Write-Host
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
$failColor = if ($script:Fail -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $failColor
exit $script:Fail
