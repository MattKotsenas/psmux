# Issue #504: "Ctrl+Space prefix doesn't work in Alacritty"
#
# What this proves, in order:
#   Part A  What Alacritty on Windows actually delivers for Ctrl+Space, at the
#           console-record level, compared against conhost.  (Alacritty sends a
#           bare 0x20 with no Ctrl flag: an upstream Alacritty defect that no
#           multiplexer can detect.)
#   Part B  Alacritty's documented workaround (bind Ctrl+Space to send a literal
#           NUL) DOES reach the console, encoded by ConPTY as VK_2 + UnicodeChar 0
#           + CTRL|SHIFT.  psmux must fold that onto C-Space.
#   Part C  psmux arms a `C-Space` prefix for every encoding of NUL, and still
#           arms it for a properly reported conhost Ctrl+Space.
#   Part D  Regression guards: plain Space, Ctrl+B, plain "2" and Ctrl+1 must not
#           be mistaken for the prefix.
#   Part E  Real psmux inside a real Alacritty window, driven by real hardware
#           keystrokes, with the reporter's own config.
#   Part F  Win32 TUI verification (mandatory layer).
#
# Requires Alacritty on PATH or at the default install location.  Parts that
# need it are skipped (not failed) when it is absent.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$tmp = Join-Path $env:TEMP "psmux_issue504"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkYellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

$alacritty = $null
$alacCmd = Get-Command alacritty -EA SilentlyContinue
if ($alacCmd) { $alacritty = $alacCmd.Source }
elseif (Test-Path "C:\Program Files\Alacritty\alacritty.exe") { $alacritty = "C:\Program Files\Alacritty\alacritty.exe" }

# --------------------------------------------------------------------------
# Build the helper executables
# --------------------------------------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$keydumpExe   = "$tmp\keydump504.exe"
$sendhwExe    = "$tmp\sendhw504.exe"
$rawinjectExe = "$tmp\rawinject504.exe"

# keydump: dumps console input records / raw VT bytes to a log
$keydumpSrc = @'
using System;using System.IO;using System.Runtime.InteropServices;using System.Text;using System.Threading;
class KeyDump{
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Auto)] static extern IntPtr CreateFile(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetConsoleMode(IntPtr h,out uint m);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetConsoleMode(IntPtr h,uint m);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(IntPtr h,byte[] b,uint n,out uint r,IntPtr o);
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool ReadConsoleInputW(IntPtr h,[Out] IR[] b,uint l,out uint r);
 [DllImport("kernel32.dll")] static extern bool GetNumberOfConsoleInputEvents(IntPtr h,out uint n);
 [StructLayout(LayoutKind.Explicit)] struct IR{[FieldOffset(0)]public ushort T;[FieldOffset(4)]public KE K;}
 [StructLayout(LayoutKind.Sequential)] struct KE{public int Down;public ushort Rep;public ushort Vk;public ushort Sc;public ushort Ch;public uint Ctrl;}
 static StreamWriter log; static void L(string s){log.WriteLine(s);log.Flush();}
 static int Main(string[] a){
  string mode=a[0]; int secs=int.Parse(a[1]); log=new StreamWriter(a[2],false,new UTF8Encoding(false));
  IntPtr h=CreateFile("CONIN$",0x80000000|0x40000000,1|2,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)){L("CONIN_FAIL");return 1;}
  uint orig;GetConsoleMode(h,out orig);
  SetConsoleMode(h, mode=="vt" ? 0x0200u|0x0008u : 0x0008u|0x0010u);
  L("READY");
  var dl=DateTime.UtcNow.AddSeconds(secs); var recs=new IR[64]; var buf=new byte[256];
  while(DateTime.UtcNow<dl){
   uint p; if(!GetNumberOfConsoleInputEvents(h,out p)){break;} if(p==0){Thread.Sleep(10);continue;}
   if(mode=="vt"){uint r;if(!ReadFile(h,buf,(uint)buf.Length,out r,IntPtr.Zero))break;
    var sb=new StringBuilder("BYTES:");for(int i=0;i<r;i++)sb.Append(" ").Append(buf[i].ToString("X2"));L(sb.ToString());}
   else{uint r;if(!ReadConsoleInputW(h,recs,64,out r))break;
    for(int i=0;i<r;i++){if(recs[i].T!=1)continue;var k=recs[i].K;
     L(string.Format("KEY down={0} vk=0x{1:X2} uchar=0x{2:X4} ctrl=0x{3:X}",k.Down,k.Vk,k.Ch,k.Ctrl));}}
  }
  SetConsoleMode(h,orig); L("DONE"); log.Close(); return 0;}}
'@

# sendhw: real hardware keystrokes (SendInput) into a focused GUI window
$sendhwSrc = @'
using System;using System.Diagnostics;using System.Runtime.InteropServices;using System.Text;using System.Threading;
class SendHw{
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] p,int cb);
 [DllImport("user32.dll")] static extern short VkKeyScan(char c);
 [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c,uint t);
 [StructLayout(LayoutKind.Sequential)] struct INPUT{public uint type;public KB ki;public int p1;public int p2;}
 [StructLayout(LayoutKind.Sequential)] struct KB{public ushort Vk;public ushort Sc;public uint Fl;public uint Tm;public IntPtr Ex;}
 static void K(ushort vk,bool up){var i=new INPUT[1];i[0].type=1;i[0].ki.Vk=vk;i[0].ki.Sc=(ushort)MapVirtualKey(vk,0);i[0].ki.Fl=up?2u:0u;SendInput(1,i,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(25);}
 static int Main(string[] a){
  IntPtr hwnd=IntPtr.Zero; int pid=int.Parse(a[0].Substring(4));
  for(int i=0;i<60&&hwnd==IntPtr.Zero;i++){try{var p=Process.GetProcessById(pid);p.Refresh();hwnd=p.MainWindowHandle;}catch{}
   if(hwnd==IntPtr.Zero)Thread.Sleep(200);}
  if(hwnd==IntPtr.Zero){Console.WriteLine("NO_WINDOW");return 2;}
  ShowWindow(hwnd,9);
  for(int i=0;i<20;i++){SetForegroundWindow(hwnd);Thread.Sleep(100);if(GetForegroundWindow()==hwnd)break;}
  if(GetForegroundWindow()!=hwnd){Console.WriteLine("NO_FOCUS");return 3;}
  Thread.Sleep(400);
  for(int i=1;i<a.Length;i++){string s=a[i];
   if(s.StartsWith("sleep:")){Thread.Sleep(int.Parse(s.Substring(6)));continue;}
   bool ctrl=false,shift=false; string b=s;
   while(b.Length>2&&b[1]=='-'){char m=char.ToUpper(b[0]);if(m=='C')ctrl=true;else if(m=='S')shift=true;b=b.Substring(2);}
   ushort key;
   if(b.ToLower()=="space")key=0x20; else if(b.ToLower()=="enter")key=0x0D;
   else{short vs=VkKeyScan(b[0]);key=(ushort)(vs&0xFF);if((vs&0x100)!=0)shift=true;}
   if(ctrl)K(0x11,false); if(shift)K(0x10,false);
   K(key,false);K(key,true);
   if(shift)K(0x10,true); if(ctrl)K(0x11,true);
   Thread.Sleep(150);}
  Console.WriteLine("SENT");return 0;}}
'@

# rawinject: writes EXACT INPUT_RECORDs into a target console input buffer
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

Write-Host "`n=== Issue #504: Ctrl+Space prefix in Alacritty ===" -ForegroundColor Cyan
Write-Host "[build] compiling probe helpers" -ForegroundColor DarkGray
$keydumpSrc   | Set-Content "$tmp\keydump504.cs"   -Encoding UTF8
$sendhwSrc    | Set-Content "$tmp\sendhw504.cs"    -Encoding UTF8
$rawinjectSrc | Set-Content "$tmp\rawinject504.cs" -Encoding UTF8
& $csc /nologo /optimize /out:$keydumpExe   "$tmp\keydump504.cs"   2>&1 | Out-Null
& $csc /nologo /optimize /out:$sendhwExe    "$tmp\sendhw504.cs"    2>&1 | Out-Null
& $csc /nologo /optimize /out:$rawinjectExe "$tmp\rawinject504.cs" 2>&1 | Out-Null
if (-not (Test-Path $rawinjectExe)) { Write-Fail "could not compile helpers"; exit 1 }

function Kill-Session($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

# Launch an attached psmux window with a given config, return the process.
function Start-Psmux($name, $configLines) {
    Kill-Session $name
    $conf = "$tmp\$name.conf"
    ($configLines -join "`n") + "`n" | Set-Content $conf -Encoding UTF8
    $env:PSMUX_CONFIG_FILE = $conf
    $env:PSMUX_NO_WARM = "1"
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$name -PassThru
    Start-Sleep -Seconds 6
    $env:PSMUX_CONFIG_FILE = $null
    & $PSMUX has-session -t $name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $p
}

function Wins($name) { [int](& $PSMUX display-message -t $name -p '#{session_windows}' 2>&1 | Out-String).Trim() }

# Inject a record then the 'c' key; a new window means the prefix armed.
function Test-PrefixArms($name, $proc, $spec) {
    $before = Wins $name
    & $rawinjectExe $proc.Id $spec "sleep:400" "char:c" | Out-Null
    Start-Sleep -Milliseconds 2400
    return ((Wins $name) -gt $before)
}

# ==========================================================================
# PART A: what each terminal delivers for Ctrl+Space
# ==========================================================================
Write-Host "`n[Part A] Console records for Ctrl+Space, per terminal host" -ForegroundColor Yellow

# sendhw drives the real hardware input queue, so it only works when the target
# window can be brought to the foreground. It already reports that itself: it
# prints NO_FOCUS and exits 3 when SetForegroundWindow loses. Every call site
# used to pipe that to Out-Null, throwing away the one signal that separates
# "this desktop refused focus" from "psmux is broken", so an unattended or
# locked session reported product failures for keystrokes that were never
# delivered. Capture it instead and let callers skip.
function Invoke-SendHw {
    param([string[]]$SendArgs)
    $out = (& $sendhwExe @SendArgs 2>&1 | Out-String)
    return [pscustomobject]@{
        Focused = -not ($out -match "NO_FOCUS")
        Output  = $out.Trim()
    }
}

function Get-KeyRecords($launch, $mode, $keys, $tag) {
    $log = "$tmp\rec_$tag.log"
    Remove-Item $log -Force -EA SilentlyContinue
    $p = & $launch $mode $log
    if (-not $p) { return $null }
    Start-Sleep -Seconds 3
    $sendArgs = @("pid:$($p.Id)", "sleep:900") + $keys
    $script:LastSendFocused = (Invoke-SendHw -SendArgs $sendArgs).Focused
    Start-Sleep -Seconds 12
    try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}
    if (Test-Path $log) { return (Get-Content $log) }
    return $null
}

$launchConhost = {
    param($mode, $log)
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c",$keydumpExe,$mode,"14",$log) -PassThru
}
$launchAlacritty = {
    param($mode, $log)
    if (-not $alacritty) { return $null }
    Start-Process -FilePath $alacritty -ArgumentList @("-e",$keydumpExe,$mode,"14",$log) -PassThru
}

$conRecs = Get-KeyRecords $launchConhost "rec" @("C-Space") "conhost"
if ($conRecs) {
    $spaceRec = $conRecs | Where-Object { $_ -match "vk=0x20" -and $_ -match "down=1" } | Select-Object -First 1
    Write-Info "conhost   Ctrl+Space -> $spaceRec"
    # Separate "conhost answered wrongly" from "the keys never arrived".
    #
    # This probe is the one place that cannot use WriteConsoleInput: it exists to
    # measure what CONHOST makes of a real HARDWARE key, so it must use SendInput,
    # and SendInput goes to the FOREGROUND window. sendhw calls
    # SetForegroundWindow up to 20 times, but on a busy desktop, over RDP, or on a
    # locked session, focus can simply be refused and not one keystroke lands.
    #
    # An empty record set means exactly that: no key was seen at all, which says
    # nothing about conhost's Ctrl reporting. Reporting it as a failure blamed
    # psmux for the desktop refusing focus. A record that IS present but lacks the
    # Ctrl flag is still a genuine finding and still fails.
    $anyKeyRec = $conRecs | Where-Object { $_ -match "vk=0x" } | Select-Object -First 1
    if (-not $anyKeyRec) {
        Write-Skip "conhost probe captured no keystrokes at all (SendInput needs foreground focus; none was granted)"
    } elseif ($spaceRec -match "ctrl=0x8") {
        Write-Pass "conhost reports Ctrl+Space WITH the Ctrl flag (ctrl=0x8)"
    } elseif (-not $spaceRec) {
        Write-Skip "conhost probe saw keys but no Ctrl+Space record (keystroke lost before conhost)"
    } else {
        Write-Fail "conhost did not report a Ctrl flag: $spaceRec"
    }
} else { Write-Skip "conhost record probe produced no log" }

if ($alacritty) {
    $alacRecs = Get-KeyRecords $launchAlacritty "rec" @("C-Space","sleep:500","Space") "alac"
    if ($alacRecs) {
        $downs = @($alacRecs | Where-Object { $_ -match "down=1" -and $_ -match "vk=0x20" })
        Write-Info "alacritty Ctrl+Space -> $($downs[0])"
        Write-Info "alacritty plain Space -> $($downs[1])"
        # Same discrimination the conhost arm above already makes: no key record
        # at all means nothing was delivered, which says nothing about what
        # Alacritty reports for Ctrl.
        $anyAlacRec = $alacRecs | Where-Object { $_ -match "vk=0x" } | Select-Object -First 1
        if (-not $anyAlacRec) {
            if (-not $script:LastSendFocused) {
                Write-Skip "Alacritty probe: focus was refused, no keystroke was delivered (SendInput needs the foreground)"
            } else {
                Write-Skip "Alacritty probe captured no keystrokes at all"
            }
        } elseif ($downs.Count -ge 1 -and $downs[0] -match "ctrl=0x0\b") {
            Write-Pass "CONFIRMED upstream Alacritty defect: Ctrl+Space arrives with NO Ctrl flag"
        } else {
            Write-Fail "expected Alacritty to drop the Ctrl flag, got: $($downs[0])"
        }
        if ($downs.Count -ge 2 -and $downs[0] -eq $downs[1]) {
            Write-Pass "Alacritty's Ctrl+Space is byte-identical to plain Space (undetectable by any multiplexer)"
        } elseif ($downs.Count -ge 2) {
            Write-Info "Ctrl+Space and Space records differ: '$($downs[0])' vs '$($downs[1])'"
        }
    } else { Write-Skip "Alacritty record probe produced no log" }
} else { Write-Skip "Alacritty not installed - skipping Part A Alacritty probe" }

# ==========================================================================
# PART B: the documented NUL workaround reaches the console
# ==========================================================================
Write-Host "`n[Part B] Alacritty's NUL workaround, at the record level" -ForegroundColor Yellow

if ($alacritty) {
    # chars = "\u0000" written without letting PowerShell eat the escape
    $nulConf = "$tmp\alac_nul504.toml"
    $q = [char]34
    $toml = "[keyboard]`nbindings = [`n  { key = ${q}Space${q}, mods = ${q}Control${q}, chars = ${q}\u0000${q} }`n]`n"
    Set-Content -Path $nulConf -Value $toml -Encoding UTF8 -NoNewline

    $log = "$tmp\rec_alacnul.log"
    Remove-Item $log -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $alacritty -ArgumentList @("--config-file",$nulConf,"-e",$keydumpExe,"rec","14",$log) -PassThru
    Start-Sleep -Seconds 3
    $sent = Invoke-SendHw -SendArgs @("pid:$($p.Id)", "sleep:900", "C-Space")
    Start-Sleep -Seconds 12
    try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}

    if (Test-Path $log) {
        $recs = Get-Content $log
        $nulRec = $recs | Where-Object { $_ -match "down=1" -and $_ -match "vk=0x32" } | Select-Object -First 1
        $anyRec = $recs | Where-Object { $_ -match "vk=0x" } | Select-Object -First 1
        if ($nulRec) {
            Write-Info "alacritty + NUL workaround -> $nulRec"
            if ($nulRec -match "uchar=0x0000") {
                Write-Pass "the NUL DOES reach the console, as VK_2 with UnicodeChar 0 (ConPTY's Ctrl+@ encoding)"
            } else {
                Write-Fail "unexpected UnicodeChar in NUL record: $nulRec"
            }
        } elseif (-not $anyRec) {
            # The probe ran (READY/DONE markers) but saw no key whatsoever, so
            # the keystroke never left the input queue. Blaming the NUL
            # workaround for that is blaming psmux for a refused foreground.
            if (-not $sent.Focused) {
                Write-Skip "NUL workaround probe: focus was refused, no keystroke was delivered"
            } else {
                Write-Skip "NUL workaround probe captured no keystrokes at all; records were: $($recs -join ' | ')"
            }
        } else {
            Write-Fail "NUL workaround produced no VK_2 record; records were: $($recs -join ' | ')"
        }
    } else { Write-Skip "NUL workaround probe produced no log" }
} else { Write-Skip "Alacritty not installed - skipping Part B" }

# ==========================================================================
# PART C: psmux arms a C-Space prefix for every NUL encoding
# ==========================================================================
Write-Host "`n[Part C] psmux prefix arming for each NUL encoding" -ForegroundColor Yellow

$S = "issue504_c"
$proc = Start-Psmux $S @("set -g prefix C-Space")
if (-not $proc) {
    Write-Fail "could not start session $S"
} else {
    $pfx = (& $PSMUX show-options -t $S -g prefix 2>&1 | Out-String).Trim()
    if ($pfx -match "C-Space") { Write-Pass "set -g prefix C-Space is stored ($pfx)" }
    else { Write-Fail "prefix option not stored: $pfx" }

    # This is the record Alacritty's workaround produces (measured in Part B).
    if (Test-PrefixArms $S $proc "raw:0x32,0x00,0x18") {
        Write-Pass "NUL as VK_2 + CTRL|SHIFT arms the prefix  <-- the #504 fix"
    } else {
        Write-Fail "NUL as VK_2 + CTRL|SHIFT did NOT arm the prefix (#504 regression)"
    }

    if (Test-PrefixArms $S $proc "raw:0x32,0x00,0x8") {
        Write-Pass "NUL as VK_2 + CTRL arms the prefix"
    } else {
        Write-Fail "NUL as VK_2 + CTRL did NOT arm the prefix"
    }

    if (Test-PrefixArms $S $proc "raw:0x20,0x20,0x8") {
        Write-Pass "conhost-native Ctrl+Space still arms the prefix (no regression)"
    } else {
        Write-Fail "conhost-native Ctrl+Space stopped arming the prefix"
    }

    if (Test-PrefixArms $S $proc "raw:0x20,0x00,0x8") {
        Write-Pass "Ctrl+Space reported with a zero UnicodeChar arms the prefix"
    } else {
        Write-Fail "Ctrl+Space with a zero UnicodeChar did NOT arm the prefix"
    }
    Kill-Session $S
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# ==========================================================================
# PART D: regression guards - the fold must not be greedy
# ==========================================================================
Write-Host "`n[Part D] Regression guards" -ForegroundColor Yellow

$S = "issue504_d"
$proc = Start-Psmux $S @("set -g prefix C-Space")
if (-not $proc) {
    Write-Fail "could not start session $S"
} else {
    if (-not (Test-PrefixArms $S $proc "raw:0x20,0x20,0x0")) {
        Write-Pass "plain Space does NOT arm the prefix"
    } else {
        Write-Fail "plain Space wrongly armed the prefix"
    }
    if (-not (Test-PrefixArms $S $proc "raw:0x42,0x02,0x8")) {
        Write-Pass "Ctrl+B does NOT arm the prefix when the prefix is C-Space"
    } else {
        Write-Fail "Ctrl+B wrongly armed the prefix"
    }
    if (-not (Test-PrefixArms $S $proc "raw:0x32,0x32,0x0")) {
        Write-Pass "typing plain '2' does NOT arm the prefix"
    } else {
        Write-Fail "plain '2' wrongly armed the prefix"
    }
    if (-not (Test-PrefixArms $S $proc "raw:0x31,0x00,0x8")) {
        Write-Pass "Ctrl+1 does NOT arm the prefix"
    } else {
        Write-Fail "Ctrl+1 wrongly armed the prefix"
    }
    Kill-Session $S
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# The default prefix must be entirely unaffected by the fold.
$S = "issue504_d2"
$proc = Start-Psmux $S @("set -g prefix C-b")
if ($proc) {
    if (Test-PrefixArms $S $proc "raw:0x42,0x02,0x8") {
        Write-Pass "default prefix C-b still arms normally"
    } else {
        Write-Fail "default prefix C-b stopped working"
    }
    if (-not (Test-PrefixArms $S $proc "raw:0x32,0x00,0x18")) {
        Write-Pass "a NUL does NOT arm a C-b prefix"
    } else {
        Write-Fail "a NUL wrongly armed a C-b prefix"
    }
    Kill-Session $S
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# An existing `bind-key C-2` must keep firing after the fold.
$S = "issue504_d3"
$proc = Start-Psmux $S @("set -g prefix C-b", "bind-key -T root C-2 new-window")
if ($proc) {
    $before = Wins $S
    & $rawinjectExe $proc.Id "raw:0x32,0x00,0x8" | Out-Null
    Start-Sleep -Milliseconds 2400
    if ((Wins $S) -gt $before) {
        Write-Pass "an existing bind-key C-2 still fires (fold applied symmetrically)"
    } else {
        Write-Fail "bind-key C-2 stopped firing after the fold"
    }
    Kill-Session $S
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# ==========================================================================
# PART E: real psmux inside real Alacritty, real hardware keystrokes
# ==========================================================================
Write-Host "`n[Part E] Real psmux in a real Alacritty window (the reporter's setup)" -ForegroundColor Yellow

if ($alacritty) {
    $S = "issue504_e"
    Kill-Session $S
    $pconf = "$tmp\$S.conf"
    "set -g prefix C-Space`n" | Set-Content $pconf -Encoding UTF8

    $nulConf = "$tmp\alac_nul504.toml"
    if (-not (Test-Path $nulConf)) {
        $q = [char]34
        $toml = "[keyboard]`nbindings = [`n  { key = ${q}Space${q}, mods = ${q}Control${q}, chars = ${q}\u0000${q} }`n]`n"
        Set-Content -Path $nulConf -Value $toml -Encoding UTF8 -NoNewline
    }

    $env:PSMUX_CONFIG_FILE = $pconf
    $env:PSMUX_NO_WARM = "1"
    $ap = Start-Process -FilePath $alacritty `
        -ArgumentList @("--config-file",$nulConf,"-e",$PSMUX,"new-session","-s",$S) -PassThru
    Start-Sleep -Seconds 8
    $env:PSMUX_CONFIG_FILE = $null

    & $PSMUX has-session -t $S 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Skip "psmux session did not start inside Alacritty"
    } else {
        $before = Wins $S
        # Real Ctrl+Space, then real 'c', straight from the hardware input queue.
        $sentE = Invoke-SendHw -SendArgs @("pid:$($ap.Id)", "sleep:1200", "C-Space", "sleep:600", "c")
        Start-Sleep -Seconds 4
        $after = Wins $S
        Write-Info "windows in Alacritty session: $before -> $after"
        if ($after -gt $before) {
            Write-Pass "REAL Ctrl+Space in REAL Alacritty opened a window: the prefix works end to end"
        } elseif (-not $sentE.Focused) {
            # Nothing was typed, so nothing can be concluded about the prefix.
            # Part C already proved the NUL fold itself over WriteConsoleInput,
            # which needs no foreground.
            Write-Skip "Alacritty end to end: focus was refused, no keystroke was delivered"
        } else {
            Write-Fail "Ctrl+Space in Alacritty did not trigger the prefix (windows $before -> $after)"
        }
        Kill-Session $S
    }
    try { Stop-Process -Id $ap.Id -Force -EA SilentlyContinue } catch {}
} else { Write-Skip "Alacritty not installed - skipping Part E" }

# ==========================================================================
# PART F: Win32 TUI verification (mandatory layer)
# ==========================================================================
Write-Host "`n[Part F] Win32 TUI verification" -ForegroundColor Yellow

$S = "issue504_tui"
$proc = Start-Psmux $S @("set -g prefix C-Space")
if (-not $proc) {
    Write-Fail "could not start TUI session"
} else {
    & $PSMUX split-window -v -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $panes = (& $PSMUX display-message -t $S -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: split-window produced 2 panes" }
    else { Write-Fail "TUI: expected 2 panes, got $panes" }

    & $PSMUX resize-pane -Z -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $z = (& $PSMUX display-message -t $S -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
    if ($z -eq "1") { Write-Pass "TUI: resize-pane -Z zoomed" }
    else { Write-Fail "TUI: zoom expected 1, got $z" }

    # The TUI is alive and the C-Space prefix still drives it.
    if (Test-PrefixArms $S $proc "raw:0x32,0x00,0x18") {
        Write-Pass "TUI: NUL-delivered prefix drives a live rendered session"
    } else {
        Write-Fail "TUI: NUL-delivered prefix did not work in the live session"
    }
    Kill-Session $S
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

# ==========================================================================
Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object {
    try { $null = $_ } catch {}
}
Remove-Item "$psmuxDir\issue504_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor DarkYellow
exit $script:TestsFailed
