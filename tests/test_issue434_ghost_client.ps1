# Issue #434: Ghost-client leak + attached_clients over-decrement.
#
# Proves the invariant `session_attached` tracks the real client_registry across
# abnormal teardown paths:
#   - reader-EOF teardown (plain abnormal kill)
#   - writer-only teardown (client frozen/suspended so it stops reading its
#     socket while the server floods frames -> writer write-timeout path)
#   - reconnect churn (rapid attach/kill, some mid-handshake)
# In every case: no ghost record lingers and the attached counter never desyncs
# below the number of real clients.
#
# Requires a suspend/resume helper (NtSuspendProcess) to freeze a real attach
# client's socket reader and force the writer-only teardown path.

$ErrorActionPreference = "Continue"
# Set PSMUX_TEST_BIN to exercise a binary that is not the installed one (a
# worktree build, say), and PSMUX_DATA_DIR to keep the sessions this suite
# creates out of the shared data root. Both follow the convention the rest of
# the tree already uses, and together they let this suite run beside a live
# psmux without touching it. src/paths.rs psmux_dir() reads PSMUX_DATA_DIR with
# no trailing separator, so trim one here too.
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$dir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR.TrimEnd('\', '/') } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

# ---- build suspend helper ----
$suspSrc = "$env:TEMP\psmux_suspend434.cs"
@'
using System;
using System.Runtime.InteropServices;
class P {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool i, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static void Main(string[] a){
        int pid = int.Parse(a[0]);
        bool resume = a.Length > 1 && a[1] == "resume";
        IntPtr h = OpenProcess(0x1F0FFF, false, pid);
        if(h == IntPtr.Zero){ Console.WriteLine("open failed"); return; }
        int r = resume ? NtResumeProcess(h) : NtSuspendProcess(h);
        CloseHandle(h);
    }
}
'@ | Set-Content -Path $suspSrc -Encoding UTF8
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$susp = "$env:TEMP\psmux_suspend434.exe"
& $csc /nologo /optimize /out:$susp $suspSrc 2>&1 | Out-Null

function RealClientCount($s){
  @(& $PSMUX list-clients -t $s 2>&1 | Where-Object { $_ -match '/dev/pts/([1-9]\d*):' }).Count
}
function Attached($s){ (& $PSMUX display-message -t $s -p '#{session_attached}' 2>&1).Trim() }
function Cleanup($s){ & $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$dir\$s.*" -Force -EA SilentlyContinue }

Write-Host "`n=== Issue #434: ghost-client / attached-count consistency ===" -ForegroundColor Cyan

# ============================================================
# TEST 1: writer-only teardown (suspend + flood) must not ghost/desync
# ============================================================
Write-Host "`n[Test 1] Writer-only teardown (frozen client + flood)" -ForegroundColor Yellow
$S = "iss434_writer"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
if ((Attached $S) -eq "1" -and (RealClientCount $S) -ge 1) { Write-Pass "client attached (attached=1)" }
else { Write-Fail "attach did not register (attached=$(Attached $S), clients=$(RealClientCount $S))" }

& $susp $p.Id | Out-Null           # freeze socket reader -> force writer path
Start-Sleep -Seconds 1
& $PSMUX send-keys -t $S "1..300000 | ForEach-Object { 'FLOOD_' + `$_ + '_' + ('x'*80) }" Enter
# wait for writer teardown to take effect
$desync = $false
for ($i=0; $i -lt 12; $i++) {
  Start-Sleep -Seconds 2
  $a = Attached $S; $rc = RealClientCount $S
  # DESYNC = attached reads 0 while a real (pts>=1) client record still lingers = ghost
  if ($a -eq "0" -and $rc -ge 1) { $desync = $true; break }
}
if (-not $desync) { Write-Pass "no ghost/desync during writer teardown (counter tracks registry)" }
else { Write-Fail "GHOST/DESYNC: attached=0 while a real client record lingers" }

# Reconnect after resume must yield a counted client again.
#
# POLLED, not a fixed sleep (issue #675). The flood is still running when the
# client resumes, so the reconnect competes with it: the client has to drain
# the frames buffered in its socket, notice EOF, reconnect and have the server
# process `client-attach` on a main loop that is busy pumping the flood. A
# fixed 3 s sleep sampled that race once and read 0 on a loaded machine.
#
# The poll also records the whole timeline, which separates the two ways this
# can fail: a reconnect that simply lands LATE (counter goes 0 -> 1 and stays),
# versus one that lands and is torn down AGAIN by the writer path (counter
# reaches 1 and drops back to 0). The timeline is printed on failure so the
# next occurrence says which it was without needing a rerun. Pair it with
# PSMUX_CLIENT_DEBUG=1, which appends every reconnect attempt to
# ~/.psmux/client_reconnect.log with its elapsed time and outcome; that file
# is appended rather than truncated precisely so Test 3's churn clients cannot
# erase what Test 1's client recorded.
& $susp $p.Id resume | Out-Null
$rcT0 = Get-Date
$rcTimeline = @()
$rcFirstOk = $null
$rcDrops = 0
$rcWasOk = $false
$rcPolls = 0
while (((Get-Date) - $rcT0).TotalSeconds -lt 10) {
  $a = Attached $S; $rc = RealClientCount $S
  $rcPolls++
  $ms = [int]((Get-Date) - $rcT0).TotalMilliseconds
  $rcTimeline += "${ms}ms a=$a c=$rc"
  $ok = ($a -eq "1" -and $rc -ge 1)
  if ($ok -and -not $rcFirstOk) { $rcFirstOk = $ms }
  if ($rcWasOk -and -not $ok) { $rcDrops++ }
  $rcWasOk = $ok
  if ($ok -and $ms -ge 1000) { break }   # stable for at least one extra poll
  Start-Sleep -Milliseconds 100
}
if ($rcFirstOk -ne $null -and $rcWasOk) {
  Write-Pass "client reconnected & counted after resume (after ${rcFirstOk}ms, $rcPolls polls, $rcDrops drops)"
} else {
  $rcClientAlive = [bool](Get-Process -Id $p.Id -EA SilentlyContinue)
  # The exit code names who ended the client (issue #675): 1 is a
  # TerminateProcess from psmux's own kill guard, 0xC000013A is the console
  # closing on it, -1 is Stop-Process, 0 is a normal return from run_remote.
  $rcExit = if ($rcClientAlive) { "alive" } else { try { $p.WaitForExit(1000) | Out-Null; ("0x{0:X8} ({0})" -f $p.ExitCode) } catch { "unknown" } }
  Write-Fail "reconnect failed (attached=$(Attached $S), clients=$(RealClientCount $S)) after $rcPolls polls over 10s; firstOk=$(if ($rcFirstOk -ne $null) { "${rcFirstOk}ms" } else { 'NEVER' }) drops=$rcDrops clientProcessAlive=$rcClientAlive clientExitCode=$rcExit"
  Write-Host "  [timeline] $($rcTimeline -join ' | ')" -ForegroundColor DarkGray
  if ($rcDrops -gt 0) {
    Write-Host "  [diagnosis] the client DID reattach and was torn down again -> writer path teardown of a live client" -ForegroundColor DarkGray
  } else {
    Write-Host "  [diagnosis] the client never reattached inside 10s -> the reconnect never completed" -ForegroundColor DarkGray
  }
  $rcLog = "$dir\client_reconnect.log"
  if (Test-Path $rcLog) {
    Write-Host "  [client_reconnect.log, last 20 lines]" -ForegroundColor DarkGray
    Get-Content $rcLog -Tail 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
  } else {
    Write-Host "  [client_reconnect.log absent; rerun with PSMUX_CLIENT_DEBUG=1 to capture the attempts]" -ForegroundColor DarkGray
  }
  $crash = Get-ChildItem "$dir\client_crash.*.log" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($crash) {
    Write-Host "  [client panicked: $($crash.Name)]" -ForegroundColor DarkGray
    Get-Content $crash.FullName -TotalCount 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
  }
}
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 2: abnormal kill (reader-EOF path) reaps cleanly
# ============================================================
Write-Host "`n[Test 2] Abnormal kill reaps cleanly (reader-EOF path)" -ForegroundColor Yellow
$S = "iss434_kill"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
$before = Attached $S
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Start-Sleep -Seconds 4
$after = Attached $S; $rc = RealClientCount $S
if ($before -eq "1" -and $after -eq "0" -and $rc -eq 0) { Write-Pass "1 -> 0 attached, 0 ghost records" }
else { Write-Fail "unexpected: before=$before after=$after ghosts=$rc" }
Cleanup $S

# ============================================================
# TEST 3: reconnect churn must not accumulate ghosts / desync
# ============================================================
Write-Host "`n[Test 3] 30x reconnect churn (some mid-handshake kills)" -ForegroundColor Yellow
$S = "iss434_churn"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$rng = [Random]::new(777)
for ($i=0; $i -lt 30; $i++) {
  $p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
  Start-Sleep -Milliseconds $rng.Next(40,1200)
  Stop-Process -Id $p.Id -Force -EA SilentlyContinue
}
Start-Sleep -Seconds 3
$a = Attached $S; $rc = RealClientCount $S
if ($a -eq "0" -and $rc -eq 0) { Write-Pass "no ghosts after churn (attached=0, 0 real records)" }
else { Write-Fail "churn left residue: attached=$a real_records=$rc" }

# sanity: a fresh attach after churn counts correctly (counter not stuck below 0)
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
if ((Attached $S) -eq "1") { Write-Pass "fresh attach after churn counts to 1 (no stuck counter)" }
else { Write-Fail "post-churn attach shows attached=$(Attached $S)" }
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 3b: comment-5027591125 scenario A -- a detached session that was
# NEVER attached must show ZERO list-clients rows (no synthesized pts/0 ghost).
# ============================================================
Write-Host "`n[Test 3b] Detached session (never attached) shows no client rows" -ForegroundColor Yellow
$S = "iss434_neverattach"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$rows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match '^/dev/pts/\d+: ' + [regex]::Escape($S) + ' \[' })
$att  = Attached $S
if ($rows.Count -eq 0 -and $att -eq "0") {
  Write-Pass "never-attached session: 0 client rows AND session_attached=0"
} else {
  Write-Fail "ghost row on never-attached session: rows=$($rows.Count) [$($rows -join '|')] attached=$att"
}
Cleanup $S

# ============================================================
# TEST 3c: comment-5027591125 scenario B -- after a clean in-pane
# detach-client, the row must disappear (registry is the source of truth).
# ============================================================
Write-Host "`n[Test 3c] Clean detach-client leaves no residual row" -ForegroundColor Yellow
$S = "iss434_cleandetach"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
$dRows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match '^/dev/pts/\d+: ' + [regex]::Escape($S) + ' \[' })
if ((Attached $S) -eq "1" -and $dRows.Count -eq 1) { Write-Pass "attached: exactly 1 row, attached=1" }
else { Write-Fail "attach state wrong: rows=$($dRows.Count) attached=$(Attached $S)" }
# `-s` is the SESSION selector; `-t` names a CLIENT (a tty or %id), per tmux and
# psmux since #565. This used to read `-t $S` and worked only because the flag
# was stripped before it reached the handler, which silently promoted the
# command to `-a`. Once `-t` was honoured, `-t <session-name>` correctly matched
# no client and detached nothing. The intent here is "detach this session's
# client", so `-s` is the right selector.
& $PSMUX detach-client -s $S 2>&1 | Out-Null
Start-Sleep -Seconds 3
$aRows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match '^/dev/pts/\d+: ' + [regex]::Escape($S) + ' \[' })
$aAtt  = Attached $S
$pDead = -not (Get-Process -Id $p.Id -EA SilentlyContinue)
if ($aRows.Count -eq 0 -and $aAtt -eq "0" -and $pDead) {
  Write-Pass "after clean detach: 0 rows, attached=0, attach process exited"
} else {
  Write-Fail "residual after detach: rows=$($aRows.Count) [$($aRows -join '|')] attached=$aAtt procDead=$pDead"
}
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 4 (TUI visual verification via CLI): live window stays functional
# ============================================================
Write-Host "`n[Test 4] Win32 TUI visual verification (CLI-driven)" -ForegroundColor Yellow
$S = "iss434_tui"
Cleanup $S
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$panes = (& $PSMUX display-message -t $S -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" } else { Write-Fail "TUI: panes=$panes" }
$a = Attached $S
if ($a -eq "1") { Write-Pass "TUI: the visible window counts as 1 attached client" } else { Write-Fail "TUI: attached=$a" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Cleanup $S

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
