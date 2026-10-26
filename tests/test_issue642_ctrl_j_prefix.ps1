# Issue #642: "C-j prefix broken under WezTerm on Windows (VT path)"
#
# WezTerm on Windows 11, psmux 3.3.8.  With `set -g prefix C-j` the prefix never
# armed, while `C-b`, `C-Space` and `C-a` all worked in the same window and the
# same `C-j` config worked under Windows Terminal.  `PSMUX_SSH_DEBUG=1` showed
# the byte arriving intact and the key being lost inside psmux:
#
#   KEY vk=0x0000 scan=0x0000 u_char=0x000A ctrl=0x00000000
#     -> emit(char): Key(KeyEvent { code: Enter, modifiers: KeyModifiers(0x0) })
#
# `VtParser::on_ground` shared one arm between CR and LF, so 0x0a was reported
# as an unmodified Enter and never reached the Ctrl+A..Ctrl+Z arm that turns
# 0x02 into C-b.  tmux folds every C0 byte with no named key into a Ctrl key and
# excludes exactly Tab, CR and Escape (tty-keys.c), so 0x0a is C-j there, and
# psmux's own output encoder already agreed, since `C-j` encodes back to 0x0a.
#
# WHAT THIS SUITE PINS.  Only a client for which `needs_vt_input()` is true ever
# feeds bytes to the VT parser, so every check below puts the client under test
# on that path for real and drives the byte 0x0a into it.
#
# HARNESS.  An OUTER psmux session owns a ConPTY; the client under test runs
# INSIDE it with the WezTerm env vars set, so its stdin is a real pseudoconsole
# and `send-keys C-j` on the outer pane puts the genuine 0x0a byte on it, which
# is exactly what a physical Ctrl+J produces.  Part D adds a real WezTerm window
# driven through `wezterm cli send-text --no-paste`, and Part E the native
# INPUT_RECORD path, which must stay unchanged.
#
# Layers: E2E over a real ConPTY, VT input path, real WezTerm window, native
#         record path regression guard, Win32 TUI verification.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE }
         elseif ($env:PSMUX_TEST_EXE) { $env:PSMUX_TEST_EXE }
         else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$NS_OUT = "i642out"
$NS_IN  = "i642in"
$S_OUT  = "i642outer"
$S_IN   = "i642inner"

$tmp = Join-Path $env:TEMP "psmux_issue642"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$script:TestsPassed  = 0
$script:TestsFailed  = 0
$script:TestsSkipped = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkYellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

# Every window and process this suite opens is tracked here and closed by pid.
$script:OpenedPids = @()

function Write-Conf($name, $lines) {
    $path = Join-Path $tmp "$name.conf"
    (($lines -join "`n") + "`n") | Set-Content $path -Encoding UTF8
    return $path
}

function Cleanup-Link {
    & $PSMUX -L $NS_IN  kill-session -t $S_IN  2>&1 | Out-Null
    & $PSMUX -L $NS_OUT kill-session -t $S_OUT 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\${NS_IN}__$S_IN.*","$psmuxDir\${NS_OUT}__$S_OUT.*" -Force -EA SilentlyContinue
}

# Bring up OUTER (the ConPTY that stands in for the terminal emulator) and
# INNER (the client under test, routed onto the VT input path).
function Start-Link($conf) {
    Cleanup-Link
    & $PSMUX -L $NS_OUT new-session -d -s $S_OUT -x 120 -y 40 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    & $PSMUX -L $NS_OUT has-session -t $S_OUT 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    # PSMUX_SESSION must go or the inner client refuses to nest.  TERM_PROGRAM
    # and WEZTERM_PANE are what put it on the VT input path, exactly as a real
    # WezTerm window would (ssh_input::needs_vt_input).
    $cmd = "Remove-Item Env:\PSMUX_SESSION,Env:\PSMUX_SESSION_NAME,Env:\PSMUX_PANE -EA SilentlyContinue; " +
           "`$env:TERM_PROGRAM='WezTerm'; `$env:WEZTERM_PANE='0'; `$env:PSMUX_NO_WARM='1'; " +
           "& '$PSMUX' -L $NS_IN -f '$conf' new-session -s $S_IN"
    & $PSMUX -L $NS_OUT send-keys -t $S_OUT $cmd Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 9
    & $PSMUX -L $NS_IN has-session -t $S_IN 2>$null
    return ($LASTEXITCODE -eq 0)
}

function InnerPanes { [int]((& $PSMUX -L $NS_IN display-message -t $S_IN -p '#{window_panes}' 2>&1 | Out-String).Trim()) }

# Put one key on the inner client's real ConPTY stdin.  `send-keys C-j` writes
# the single byte 0x0a, which is the wire form of a physical Ctrl+J.
function Send-Outer([string[]]$keys) {
    $a = @("-L", $NS_OUT, "send-keys", "-t", $S_OUT) + $keys
    & $PSMUX @a 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
}

Write-Host "`n=== Issue #642: C-j prefix on the VT input path ===" -ForegroundColor Cyan
Write-Info "psmux under test: $PSMUX"

# ==========================================================================
# PART A: the dead scenario, a C-j prefix on the VT input path
# ==========================================================================
Write-Host "`n[Part A] VT input path: does a C-j prefix arm?" -ForegroundColor Yellow

$confCj = Write-Conf "cj" @("set -g prefix C-j", "bind c split-window")
if (-not (Start-Link $confCj)) {
    Write-Fail "could not bring up the ConPTY link for Part A"
} else {
    $before = InnerPanes
    Send-Outer @("C-j")
    Send-Outer @("c")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    Write-Info "panes $before -> $after"
    if ($after -gt $before) {
        Write-Pass "0x0a arms a C-j prefix on the VT path and 'c' splits  <-- the #642 fix"
    } else {
        Write-Fail "C-j prefix did not arm on the VT path (panes $before -> $after)"
    }

    # Enter is a different key and must not arm a C-j prefix.
    $before = InnerPanes
    Send-Outer @("Enter")
    Send-Outer @("c")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    if ($after -eq $before) {
        Write-Pass "Enter (0x0d) does NOT arm the C-j prefix, so 0x0a and 0x0d stay separate keys"
    } else {
        Write-Fail "Enter wrongly armed the C-j prefix (panes $before -> $after)"
    }
    Cleanup-Link
}

# ==========================================================================
# PART B: the neighbouring keys must not move
# ==========================================================================
Write-Host "`n[Part B] Neighbouring keys on the VT path" -ForegroundColor Yellow

$confCb = Write-Conf "cb" @("set -g prefix C-b", "bind c split-window", "bind -n C-j split-window")
if (-not (Start-Link $confCb)) {
    Write-Fail "could not bring up the ConPTY link for Part B"
} else {
    $before = InnerPanes
    Send-Outer @("C-b")
    Send-Outer @("c")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    if ($after -gt $before) {
        Write-Pass "a C-b prefix still arms on the VT path"
    } else {
        Write-Fail "C-b prefix stopped arming on the VT path (panes $before -> $after)"
    }

    $before = InnerPanes
    Send-Outer @("C-j")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    if ($after -gt $before) {
        Write-Pass "a root-table 'bind -n C-j' fires on 0x0a, like tmux"
    } else {
        Write-Fail "root-table C-j binding did not fire on 0x0a (panes $before -> $after)"
    }

    # Tab is 0x09 and Enter is 0x0d: both keep their named keys, so neither may
    # reach the C-j binding.
    $before = InnerPanes
    Send-Outer @("Tab")
    Send-Outer @("Enter")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    if ($after -eq $before) {
        Write-Pass "Tab and Enter keep their named keys and do not reach the C-j binding"
    } else {
        Write-Fail "Tab or Enter leaked into the C-j binding (panes $before -> $after)"
    }
    Cleanup-Link
}

# ==========================================================================
# PART C: a bare LF still reaches the pane as the same byte
# ==========================================================================
Write-Host "`n[Part C] Byte round trip: C-j in, 0x0a out" -ForegroundColor Yellow

$confPass = Write-Conf "pass" @("set -g prefix C-b", "bind c split-window")
if (-not (Start-Link $confPass)) {
    Write-Fail "could not bring up the ConPTY link for Part C"
} else {
    # The inner client forwards the decoded key to its own pane.  Ask that pane's
    # shell to report the byte it received.  `send-keys C-j` on the OUTER pane is
    # 0x0a on the inner client's stdin; the inner client re-encodes C-j and the
    # inner pane's PSReadLine sees 0x0a, which is not a submit, so the marker text
    # typed around it stays on one line.
    Send-Outer @("-l", "echo I642MARK")
    Send-Outer @("C-j")
    Send-Outer @("Enter")
    Start-Sleep -Seconds 2
    $rows = (& $PSMUX -L $NS_IN capture-pane -t $S_IN -p 2>&1 | Out-String)
    if ($rows -match "I642MARK") {
        Write-Pass "the inner pane accepted the keystroke stream around a bare 0x0a"
    } else {
        Write-Fail "the inner pane never showed the marker (capture was: $($rows.Trim().Substring(0, [Math]::Min(120, $rows.Trim().Length))))"
    }
    Cleanup-Link
}

# ==========================================================================
# PART D: a real WezTerm window
# ==========================================================================
Write-Host "`n[Part D] Real psmux in a real WezTerm window" -ForegroundColor Yellow

$weztermGui = $null
$weztermCli = $null
foreach ($cand in @("C:\Program Files\WezTerm\wezterm-gui.exe",
                    "$env:LOCALAPPDATA\wezterm\wezterm-gui.exe")) {
    if (Test-Path $cand) { $weztermGui = $cand; $weztermCli = (Join-Path (Split-Path $cand) "wezterm.exe"); break }
}
if (-not $weztermGui) {
    $wcmd = Get-Command wezterm-gui -EA SilentlyContinue
    if ($wcmd) { $weztermGui = $wcmd.Source; $weztermCli = (Join-Path (Split-Path $wcmd.Source) "wezterm.exe") }
}

if (-not $weztermGui -or -not (Test-Path $weztermCli)) {
    Write-Skip "WezTerm is not installed, so the real window part cannot run"
} else {
    $S_WZ = "i642wz"
    $NS_WZ = "i642wz"
    & $PSMUX -L $NS_WZ kill-session -t $S_WZ 2>&1 | Out-Null

    # `wezterm cli` only reaches the GUI's own mux when WEZTERM_UNIX_SOCKET
    # points at it, and that value is visible only to the process the GUI
    # spawned.  So the GUI is asked to run a tiny wrapper that records the
    # socket path and the pane id before handing over to psmux.
    $info = Join-Path $tmp "wezinfo.txt"
    $lch  = Join-Path $tmp "wezlaunch.cmd"
    Remove-Item $info -Force -EA SilentlyContinue
    @"
@echo off
> "$info" echo %WEZTERM_UNIX_SOCKET%
>> "$info" echo %WEZTERM_PANE%
"$PSMUX" -L $NS_WZ -f "$confCj" new-session -s $S_WZ
"@ | Set-Content $lch -Encoding ASCII

    # -n skips the user's wezterm.lua so stock defaults apply.
    $wp = Start-Process -FilePath $weztermGui -ArgumentList @("-n","start","--","cmd.exe","/c",$lch) -PassThru
    $script:OpenedPids += $wp.Id
    Start-Sleep -Seconds 10

    & $PSMUX -L $NS_WZ has-session -t $S_WZ 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Skip "psmux did not start inside WezTerm"
    } else {
        $sock = $null; $paneId = $null
        if (Test-Path $info) {
            $ln = @(Get-Content $info)
            if ($ln.Count -ge 2) { $sock = $ln[0].Trim(); $paneId = $ln[1].Trim() }
        }
        $before = [int]((& $PSMUX -L $NS_WZ display-message -t $S_WZ -p '#{window_panes}' 2>&1 | Out-String).Trim())
        if (-not $sock -or -not $paneId) {
            Write-Skip "WezTerm did not expose its mux socket, so no keystroke was delivered"
        } else {
            $env:WEZTERM_UNIX_SOCKET = $sock
            $lf = [string][char]0x0A
            & $weztermCli cli send-text --no-paste --pane-id $paneId $lf 2>&1 | Out-Null
            Start-Sleep -Milliseconds 700
            & $weztermCli cli send-text --no-paste --pane-id $paneId "c" 2>&1 | Out-Null
            Remove-Item Env:WEZTERM_UNIX_SOCKET -EA SilentlyContinue
            Start-Sleep -Seconds 3
            $after = [int]((& $PSMUX -L $NS_WZ display-message -t $S_WZ -p '#{window_panes}' 2>&1 | Out-String).Trim())
            Write-Info "panes in the WezTerm session: $before -> $after"
            if ($after -gt $before) {
                Write-Pass "REAL Ctrl+J in a REAL WezTerm window armed the prefix and split the window"
            } else {
                Write-Fail "Ctrl+J in WezTerm did not arm the prefix (panes $before -> $after)"
            }
        }
        & $PSMUX -L $NS_WZ kill-session -t $S_WZ 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
    }
    try { Stop-Process -Id $wp.Id -Force -EA SilentlyContinue } catch {}
    $script:OpenedPids = $script:OpenedPids | Where-Object { $_ -ne $wp.Id }
    Remove-Item "$psmuxDir\${NS_WZ}__$S_WZ.*" -Force -EA SilentlyContinue
}

# ==========================================================================
# PART E: the native INPUT_RECORD path must not move
# ==========================================================================
Write-Host "`n[Part E] Native input path regression guard" -ForegroundColor Yellow

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
$rawinjectExe = "$tmp\rawinject642.exe"
$rawinjectSrc = @'
using System;using System.Runtime.InteropServices;using System.Threading;
class RawInject{
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AttachConsole(uint p);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool FreeConsole();
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Auto)] static extern IntPtr CreateFile(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteConsoleInputW(IntPtr h,IR[] b,uint l,out uint w);
 [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c,uint t);
 [StructLayout(LayoutKind.Explicit)] struct IR{[FieldOffset(0)]public ushort T;[FieldOffset(4)]public int Down;
  [FieldOffset(8)]public ushort Rep;[FieldOffset(10)]public ushort Vk;[FieldOffset(12)]public ushort Sc;
  [FieldOffset(14)]public ushort Ch;[FieldOffset(16)]public uint Ctrl;}
 static IntPtr h;
 static void Send(ushort vk,ushort ch,uint ctrl){var r=new IR[2];
  for(int i=0;i<2;i++){r[i].T=1;r[i].Down=i==0?1:0;r[i].Rep=1;r[i].Vk=vk;r[i].Sc=(ushort)MapVirtualKey(vk,0);r[i].Ch=ch;r[i].Ctrl=ctrl;}
  uint w;WriteConsoleInputW(h,r,2,out w);Thread.Sleep(60);}
 static ushort P(string s){s=s.Trim();return s.StartsWith("0x")?Convert.ToUInt16(s.Substring(2),16):ushort.Parse(s);}
 static int Main(string[] a){
  uint pid=uint.Parse(a[0]); FreeConsole();
  if(!AttachConsole(pid)){Console.Error.WriteLine("ATTACH_FAIL");return 2;}
  h=CreateFile("CONIN$",0x80000000|0x40000000,1|2,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)){Console.Error.WriteLine("CONIN_FAIL");return 3;}
  for(int i=1;i<a.Length;i++){string s=a[i];
   if(s.StartsWith("sleep:")){Thread.Sleep(int.Parse(s.Substring(6)));continue;}
   if(s.StartsWith("raw:")){var p=s.Substring(4).Split(',');Send(P(p[0]),P(p[1]),p.Length>2?(uint)P(p[2]):0u);continue;}
   if(s.StartsWith("char:")){char c=s[5];Send((ushort)char.ToUpper(c),(ushort)c,0);continue;}}
  return 0;}}
'@
$rawinjectSrc | Set-Content "$tmp\rawinject642.cs" -Encoding UTF8
& $csc /nologo /optimize /out:$rawinjectExe "$tmp\rawinject642.cs" 2>&1 | Out-Null

if (-not (Test-Path $rawinjectExe)) {
    Write-Skip "could not compile the record injector, so the native path guard cannot run"
} else {
    $NS_NAT = "i642nat"
    $S_NAT  = "i642native"
    & $PSMUX -L $NS_NAT kill-session -t $S_NAT 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $env:PSMUX_NO_WARM = "1"
    $np = Start-Process -FilePath $PSMUX `
        -ArgumentList @("-L",$NS_NAT,"-f",$confCj,"new-session","-s",$S_NAT) -PassThru
    $script:OpenedPids += $np.Id
    Start-Sleep -Seconds 7
    Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue

    & $PSMUX -L $NS_NAT has-session -t $S_NAT 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Skip "could not start an attached client for the native path guard"
    } else {
        $before = [int]((& $PSMUX -L $NS_NAT display-message -t $S_NAT -p '#{window_panes}' 2>&1 | Out-String).Trim())
        # conhost reports a physical Ctrl+J as VK_J with the LF payload and the
        # CTRL flag; that already resolved to Char('j') + CONTROL before #642.
        & $rawinjectExe $np.Id "raw:0x4A,0x0A,0x8" "sleep:500" "char:c" 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $after = [int]((& $PSMUX -L $NS_NAT display-message -t $S_NAT -p '#{window_panes}' 2>&1 | Out-String).Trim())
        if ($after -gt $before) {
            Write-Pass "native path: the conhost Ctrl+J record still arms a C-j prefix"
        } else {
            Write-Fail "native path: the conhost Ctrl+J record stopped arming a C-j prefix (panes $before -> $after)"
        }

        $before = [int]((& $PSMUX -L $NS_NAT display-message -t $S_NAT -p '#{window_panes}' 2>&1 | Out-String).Trim())
        & $rawinjectExe $np.Id "raw:0x0D,0x0D,0x0" "sleep:500" "char:c" 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $after = [int]((& $PSMUX -L $NS_NAT display-message -t $S_NAT -p '#{window_panes}' 2>&1 | Out-String).Trim())
        if ($after -eq $before) {
            Write-Pass "native path: a plain Enter record still does NOT arm a C-j prefix"
        } else {
            Write-Fail "native path: a plain Enter record wrongly armed a C-j prefix (panes $before -> $after)"
        }
        & $PSMUX -L $NS_NAT kill-session -t $S_NAT 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
    }
    try { Stop-Process -Id $np.Id -Force -EA SilentlyContinue } catch {}
    $script:OpenedPids = $script:OpenedPids | Where-Object { $_ -ne $np.Id }
    Remove-Item "$psmuxDir\${NS_NAT}__$S_NAT.*" -Force -EA SilentlyContinue
}

# ==========================================================================
# PART F: Win32 TUI verification (mandatory layer)
# ==========================================================================
Write-Host "`n[Part F] Win32 TUI verification" -ForegroundColor Yellow

if (-not (Start-Link $confCj)) {
    Write-Fail "could not bring up the ConPTY link for Part F"
} else {
    & $PSMUX -L $NS_IN split-window -v -t $S_IN 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $panes = (& $PSMUX -L $NS_IN display-message -t $S_IN -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: split-window produced 2 panes" }
    else { Write-Fail "TUI: expected 2 panes, got $panes" }

    & $PSMUX -L $NS_IN resize-pane -Z -t $S_IN 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $z = (& $PSMUX -L $NS_IN display-message -t $S_IN -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
    if ($z -eq "1") { Write-Pass "TUI: resize-pane -Z zoomed" }
    else { Write-Fail "TUI: zoom expected 1, got $z" }

    & $PSMUX -L $NS_IN resize-pane -Z -t $S_IN 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    # The live rendered VT-path session is still driven by the C-j prefix.
    $before = InnerPanes
    Send-Outer @("C-j")
    Send-Outer @("c")
    Start-Sleep -Seconds 2
    $after = InnerPanes
    if ($after -gt $before) {
        Write-Pass "TUI: the C-j prefix drives a live rendered VT-path session"
    } else {
        Write-Fail "TUI: the C-j prefix did not work in the live session (panes $before -> $after)"
    }
    Cleanup-Link
}

# ==========================================================================
# Close everything this suite opened, by pid, and drop its state files.
# ==========================================================================
foreach ($openPid in $script:OpenedPids) {
    try { Stop-Process -Id $openPid -Force -EA SilentlyContinue } catch {}
}
Cleanup-Link
# Every namespace this suite touched, including the warm standby each server
# keeps, so no psmux process outlives the run.
foreach ($ns in @($NS_IN, $NS_OUT, "i642wz", "i642nat")) {
    & $PSMUX -L $ns kill-server 2>&1 | Out-Null
}
Start-Sleep -Milliseconds 800
Remove-Item "$psmuxDir\i642*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor DarkYellow
exit $script:TestsFailed
