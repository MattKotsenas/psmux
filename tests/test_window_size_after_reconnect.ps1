# A client that reconnects must re-report its size.
#
# The server keys `client_sizes` on the connection, and a reconnect is a new TCP
# connection with a new server-side client id. So the size the window was being
# sized from dies with the old connection. Before the fix the reconnected client
# reported nothing, which made it invisible to `window-size latest` for the rest
# of its life: typing in it could not move the window (a client with no recorded
# size is ignored by `note_client_activity`), and once the other client left,
# `client_sizes` was empty, `refresh_dynamic_window_sizes` had nothing to
# compute, and the window stayed at the other client's size.
#
# Reported shape: a Termius/SSH phone client narrows the window, the desktop
# client's connection is torn down by a read that merely timed out, and the
# window never comes back -- not by using the desktop, not by the phone leaving.
#
# This script proves the user-visible outcome with two real clients:
#
#   1. a real attach client (the desktop) is attached; W_A is the window size
#      while it is the only client -- the size it must get back;
#   2. the desktop is forced to reconnect (frozen socket reader + output flood,
#      the writer-path teardown issue #434 already uses for this);
#   3. a protocol client attaches at a distinctive small size, moving the window
#      away from W_A, and then leaves;
#   4. the window must be W_A again.
#
# Step 4 is the whole test: with a reconnect that does not re-report, the window
# is still the small size, because the desktop has no size left on the server.
#
# Isolation is the shared helper's: a throwaway USERPROFILE/HOME (so the data
# dir, config and warm pool are all private) and the inherited session vars
# scrubbed, which is what lets this attach a real client even when it is run
# from inside a psmux pane. Teardown is namespace-scoped, never a bare
# kill-server.

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\psmux_test_helpers.ps1"

$ctx = New-PsmuxTestEnv -Tag 'wsz'
$PSMUX = $ctx.PsmuxExe
$ns = Register-PsmuxNamespace -Ctx $ctx -Namespace "wsz"
$S = "wsz"
$base = "${ns}__${S}"
$portFile = Join-Path $ctx.PsmuxDir "$base.port"
$keyFile = Join-Path $ctx.PsmuxDir "$base.key"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

# ---- suspend/resume helper (freeze a real client's socket reader) ----
$suspSrc = "$env:TEMP\psmux_suspend_wsz.cs"
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
        if (resume) NtResumeProcess(h); else NtSuspendProcess(h);
        CloseHandle(h);
    }
}
'@ | Set-Content -Path $suspSrc -Encoding UTF8
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$susp = "$env:TEMP\psmux_suspend_wsz.exe"
& $csc /nologo /optimize /out:$susp $suspSrc 2>&1 | Out-Null

function WinSize($s){ (& $PSMUX -L $ns display-message -t $s -p '#{window_width}x#{window_height}' 2>&1 | Out-String).Trim() }
function Attached($s){ (& $PSMUX -L $ns display-message -t $s -p '#{session_attached}' 2>&1 | Out-String).Trim() }
function RealClientCount($s){ @(& $PSMUX -L $ns list-clients -t $s 2>&1 | Where-Object { $_ -match '/dev/pts/([1-9]\d*):' }).Count }

# A protocol client: AUTH / PERSISTENT / client-attach / client-size, exactly the
# bytes src/client.rs puts on the wire. It is not drained, so it must not be kept
# alive long: the server's writer path times a slow client out after 5 s.
function New-Probe($w, $h){
  $key = (Get-Content $keyFile -Raw).Trim()
  $port = [int](Get-Content $portFile -Raw).Trim()
  $c = New-Object System.Net.Sockets.TcpClient
  $c.Connect("127.0.0.1", $port)
  $st = $c.GetStream()
  $sw = New-Object System.IO.StreamWriter($st, (New-Object System.Text.UTF8Encoding($false)))
  $sw.AutoFlush = $true
  $sr = New-Object System.IO.StreamReader($st)
  $sw.WriteLine("AUTH $key")
  $ack = $sr.ReadLine()
  if (-not ($ack -and $ack.StartsWith("OK"))) { throw "probe auth failed: $ack" }
  $sw.WriteLine("PERSISTENT")
  $sw.WriteLine("client-attach")
  $sw.WriteLine("client-size $w $h")
  return @{ Client = $c; Reader = $sr }
}

Write-Host "`n=== window size after a client reconnect (window-size latest) ===" -ForegroundColor Cyan
Write-Host "binary: $PSMUX" -ForegroundColor DarkGray
Write-Host "namespace: $ns" -ForegroundColor DarkGray

$probe = $null
$clientProc = $null
try {
  & $PSMUX -L $ns new-session -d -s $S 2>&1 | Out-Null
  Start-Sleep -Seconds 3

  # ---- 1. the desktop is the only client: this is the size it must get back ----
  $clientProc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$ns,"attach-session","-t",$S -PassThru -WindowStyle Minimized
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 15) {
    if ((Attached $S) -eq "1" -and (RealClientCount $S) -ge 1) { break }
    Start-Sleep -Milliseconds 200
  }
  $WA = WinSize $S
  if ((Attached $S) -eq "1" -and $WA -match '^\d+x\d+$') {
    Write-Pass "desktop attached, window=$WA (the size the fix must restore)"
  } else {
    Write-Fail "desktop attach did not register (attached=$(Attached $S), window=$WA)"
    throw "cannot continue without an attached client"
  }

  # ---- 2. force the desktop to reconnect: freeze its reader, flood the pane ----
  & $susp $clientProc.Id | Out-Null
  Start-Sleep -Milliseconds 500
  $pane = (& $PSMUX -L $ns display-message -t $S -p '#{pane_id}' 2>&1 | Out-String).Trim()
  & $PSMUX -L $ns send-keys -t $pane "1..400000 | ForEach-Object { 'FLOOD_' + `$_ + '_' + ('x'*80) }" Enter 2>&1 | Out-Null
  Start-Sleep -Seconds 7   # the writer's 5 s timeout tears the frozen client down
  & $susp $clientProc.Id resume | Out-Null

  $t1 = Get-Date
  $reconnected = $false
  while (((Get-Date) - $t1).TotalSeconds -lt 20) {
    if ((Attached $S) -eq "1" -and (RealClientCount $S) -ge 1) { $reconnected = $true; break }
    Start-Sleep -Milliseconds 200
  }
  if (-not $reconnected) {
    Write-Fail "the desktop never reconnected (attached=$(Attached $S), clients=$(RealClientCount $S))"
    throw "cannot test the reconnect path without a reconnect"
  }
  # Let the reconnected client settle a tick so it has re-sent client-size.
  Start-Sleep -Seconds 2
  Write-Pass "desktop reconnected and is counted again (window=$(WinSize $S))"

  # ---- 3. another client moves the window away, then leaves ----
  $probe = New-Probe 37 11
  $t2 = Get-Date
  while (((Get-Date) - $t2).TotalSeconds -lt 8) {
    if ((WinSize $S) -eq "37x11") { break }
    Start-Sleep -Milliseconds 150
  }
  if ((WinSize $S) -eq "37x11") {
    Write-Pass "second client moved the window to 37x11"
  } else {
    Write-Fail "the second client's size never reached the window (window=$(WinSize $S))"
    throw "cannot test the recovery without the window having moved"
  }
  $probe.Client.Close()
  $probe = $null
  $t3 = Get-Date
  while (((Get-Date) - $t3).TotalSeconds -lt 8) {
    if ((RealClientCount $S) -le 1) { break }
    Start-Sleep -Milliseconds 150
  }

  # ---- 4. the window must be the desktop's size again ----
  $t4 = Get-Date
  $final = WinSize $S
  while (((Get-Date) - $t4).TotalSeconds -lt 6) {
    $final = WinSize $S
    if ($final -eq $WA) { break }
    Start-Sleep -Milliseconds 200
  }
  if ($final -eq $WA) {
    Write-Pass "the window came back to the desktop's $WA after the other client left"
  } else {
    Write-Fail "window is $final, expected ${WA}: the reconnected desktop has no size on the server"
  }
} finally {
  if ($probe) { try { $probe.Client.Close() } catch {} }
  if ($clientProc) { Stop-Process -Id $clientProc.Id -Force -EA SilentlyContinue }
  Remove-Item $susp, $suspSrc -Force -EA SilentlyContinue
  Remove-PsmuxTestEnv -Ctx $ctx -Namespace $ns
}

Write-Host "`n=== $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor $(if ($script:TestsFailed) { "Red" } else { "Green" })
exit $(if ($script:TestsFailed) { 1 } else { 0 })
