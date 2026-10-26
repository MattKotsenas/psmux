# Docker env: the VISIBLE interactive `docker exec -it psmux attach` path,
# driven from the Windows host with the SAME win32 WriteConsoleInput injector
# (tests\injector.cs) used for local psmux TUI tests.
#
# Unlike test_docker_exec_interactive.ps1 (which is deliberately HEADLESS: it
# uses `docker exec -d` + an in-container ConPTY harness so nothing appears on
# screen), this suite opens a REAL console window on the desktop via
# Start-Process running `docker exec -it psmux-dev psmux attach`, PROVES that
# window is actually visible (EnumWindows + IsWindowVisible), then injects real
# keystrokes (typed text, prefix+c, prefix+:, prefix+%, prefix+d) so the
# automation happens in front of you. Every state change is verified against
# CLI ground truth (`docker exec ... display-message`).
#
# Injected single-key prefix chords (prefix+c / prefix+%) can occasionally be
# dropped if the key lands just after the prefix window closes on a slow ConPTY
# relay, so those steps retry until the count actually changes (a ">" proof).
#
# Prereqs: psmux-dev container running with psmux installed inside
# (cargo install --path .). Must run in an interactive desktop session
# (WinSta0\Default): a headless/service session has no visible desktop, so the
# visibility assertion will (correctly) fail. Session names stay <= 9 chars
# (status bar truncation, see docker gotchas).

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "test_docker_exec_lib.ps1")

$SESS  = "dkrvis"
$PSMUX = "C:\cargo\bin\psmux.exe"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# --- win32 helpers: window-station name + visible-window enumeration ---------
if (-not ("VisChk" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VisChk {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int idx, StringBuilder pv, int n, out int need);
  public static string StationName() { var sb = new StringBuilder(256); int n; GetUserObjectInformation(GetProcessWindowStation(), 2, sb, 256, out n); return sb.ToString(); }
  public static bool HasVisibleTitled(string needle) {
    bool found = false; string nl = needle.ToLower();
    EnumWindows((h, l) => { if (IsWindowVisible(h)) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); if (sb.ToString().ToLower().Contains(nl)) found = true; } return true; }, IntPtr.Zero);
    return found;
  }
}
'@
}

function Wins()  { (Invoke-CExec "$PSMUX display-message -t $SESS -p #{session_windows}").Trim() }
function Panes() { (Invoke-CExec "$PSMUX display-message -t $SESS -p #{window_panes}").Trim() }
function WName() { (Invoke-CExec "$PSMUX display-message -t $SESS -p #{window_name}").Trim() }

# Inject a chord, then poll a metric until it reaches >= target. If it does not
# within the window, re-inject (single dropped keystroke recovery). Returns the
# final metric value.
function Inject-UntilMetric {
    param([int]$Pid2, [string]$Chord, [scriptblock]$Metric, [int]$Target, [int]$Tries = 4, [int]$WaitSec = 5)
    for ($t = 0; $t -lt $Tries; $t++) {
        & $script:Inj $Pid2 $Chord | Out-Null
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            if ([int](& $Metric) -ge $Target) { return [int](& $Metric) }
            Start-Sleep -Milliseconds 500
        }
    }
    return [int](& $Metric)
}

Write-Host "`n=== VISIBLE docker exec -it psmux attach (win32 injector driven) ===" -ForegroundColor Cyan
Resolve-DockerEnv

# Interactive desktop is required for a window to be visible.
$station = [VisChk]::StationName()
if ($station -match 'WinSta0') { Write-Pass "running on interactive window station ($station)" }
else { Write-Fail "not on interactive desktop (window station '$station') - no visible window possible" }

# --- fresh single-window session so counts are deterministic (start at 1) ----
if (-not (New-ContainerSession $SESS)) { Write-Fail "session '$SESS' never reached a prompt"; exit 1 }
if ((Wins) -eq "1") { Write-Pass "fresh session '$SESS': 1 window, 1 pane" }
else { Write-Fail "expected 1 window at start, got $(Wins)" }

# --- compile the win32 injector on the host ----------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$script:Inj = "$env:TEMP\psmux_injector.exe"
& $csc /nologo /optimize /out:$script:Inj (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (Test-Path $script:Inj) { Write-Pass "injector compiled from tests\injector.cs" }
else { Write-Fail "injector compile failed"; exit 1 }

# --- [1] open a VISIBLE window running the real docker exec -it attach --------
Write-Host "`n[1] open a visible window on the desktop (docker exec -it attach)" -ForegroundColor Yellow
$proc = Start-Process -FilePath $script:DockerExe `
    -ArgumentList "exec","-it",$script:ContainerName,$PSMUX,"attach","-t",$SESS `
    -PassThru -WindowStyle Normal
Start-Sleep -Seconds 7
if ($proc -and -not $proc.HasExited) { Write-Pass "attach process is running (pid $($proc.Id))" }
else { Write-Fail "attach process exited immediately" }

# PROVE the window is genuinely on the visible desktop (not just a hidden console)
$seen = $false
for ($i = 0; $i -lt 15; $i++) { if ([VisChk]::HasVisibleTitled("psmux.exe")) { $seen = $true; break }; Start-Sleep -Milliseconds 700 }
if ($seen) { Write-Pass "a VISIBLE window titled '*psmux.exe*' is on the desktop (EnumWindows+IsWindowVisible)" }
else { Write-Fail "no visible attach window found on the desktop" }

# --- [2] typed keystrokes into the pane --------------------------------------
Write-Host "`n[2] inject: echo VISIBLE_MARK <Enter>" -ForegroundColor Yellow
& $script:Inj $proc.Id "echo VISIBLE_MARK{ENTER}"
Start-Sleep -Seconds 3
if ((Invoke-CExec "$PSMUX capture-pane -t $SESS -p") -match "VISIBLE_MARK") { Write-Pass "typed command ran in the pane" }
else { Write-Fail "marker not found in pane capture" }

# --- [3] prefix+c new window (retry-until-change) ----------------------------
Write-Host "`n[3] inject: prefix+c (new window)" -ForegroundColor Yellow
$wb = [int](Wins)
$wa = Inject-UntilMetric -Pid2 $proc.Id -Chord "^b{SLEEP:400}c" -Metric { Wins } -Target ($wb + 1)
if ($wa -gt $wb) { Write-Pass "prefix+c created a new window (session_windows $wb -> $wa)" }
else { Write-Fail "expected more than $wb windows, got $wa" }

# --- [4] prefix+: command prompt rename --------------------------------------
Write-Host "`n[4] inject: prefix+: rename-window livewin <Enter>" -ForegroundColor Yellow
& $script:Inj $proc.Id "^b{SLEEP:400}:{SLEEP:900}rename-window livewin{ENTER}"
Start-Sleep -Seconds 4
if ((WName) -eq "livewin") { Write-Pass "command prompt renamed window to 'livewin'" }
else { Write-Fail "window_name expected 'livewin', got '$(WName)'" }

# --- [5] prefix+% split pane (retry-until-change) ----------------------------
Write-Host "`n[5] inject: prefix+% (split pane)" -ForegroundColor Yellow
$pbi = [int](Panes)
$pai = Inject-UntilMetric -Pid2 $proc.Id -Chord '^b{SLEEP:400}%' -Metric { Panes } -Target ($pbi + 1)
if ($pai -gt $pbi) { Write-Pass "prefix+% split the pane (window_panes $pbi -> $pai)" }
else { Write-Fail "expected more than $pbi panes, got $pai" }

# --- [6] prefix+d detach: window closes, session survives --------------------
Write-Host "`n[6] inject: prefix+d (detach)" -ForegroundColor Yellow
& $script:Inj $proc.Id "^b{SLEEP:400}d"
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Pass "attach window closed on detach" }
else { Write-Fail "window still open after prefix+d"; try { $proc.Kill() } catch {} }
if (Test-ContainerSession $SESS) { Write-Pass "session survived the detach" }
else { Write-Fail "session died on detach" }

# --- teardown ----------------------------------------------------------------
Invoke-CExec "$PSMUX kill-session -t $SESS" | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
