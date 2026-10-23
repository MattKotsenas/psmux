# Issue #719: what a pane program that enabled bracketed paste actually receives.
#
# CtrlCarlitos (psmux 3.3.8, Windows 11 24H2, Windows Terminal) reported three
# things.  Each is judged here on the BYTES a recorder pane child reads with
# ReadFile in virtual terminal input mode (tests\paste_probe719.cs), never on
# what a TUI renders.
#
#  Part 1, paste-buffer (no desktop needed).  tmux wraps paste-buffer in
#  ESC[200~ / ESC[201~ only when -p is given AND the pane enabled ?2004h
#  (cmd-paste-buffer.c:66, :97, :124; the default prefix ] binding is
#  "paste-buffer -p", key-bindings.c:422).  Without -p it writes the raw text.
#  It replaces every LF with the separator: -s, else LF for -r, else CR
#  (cmd-paste-buffer.c:88 to :95), and touches nothing else.  On 7f070fe psmux
#  wrote LF for a plain paste-buffer and CR for -p -r.
#
#  Part 2, a real Windows Terminal Ctrl+V (needs clipboard, focus and
#  SendInput).  No stray "[A" in front of the content, the content bracketed
#  with paste-detection on, and the content intact with it off.  Skipped with a
#  SKIP line when the desktop refuses this process or wt.exe is missing.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue719_paste_bytes.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i719bytes$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

# Set-Clipboard does not report a clipboard another window is holding open: the
# old contents stay and Ctrl+V pastes them (sweeps 2026-10-22 and 2026-10-23
# pasted the previous suite's selection, then the previous case's text). Wait
# until the clipboard really holds the test text before the gesture.
function Set-ClipboardVerified([string]$Value) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        try { Set-Clipboard -Value $Value -EA Stop } catch {}
        Start-Sleep -Milliseconds 100
        $now = try { (Get-Clipboard -Raw -EA Stop) } catch { $null }
        if ($null -ne $now -and $now.TrimEnd("`r", "`n") -eq $Value.TrimEnd("`r", "`n")) { return $true }
    }
    return $false
}

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i719_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$probe = Join-Path $root "paste_probe719.exe"
& $csc /nologo /optimize /platform:x64 /out:$probe (Join-Path $PSScriptRoot "paste_probe719.cs") 2>&1 | Out-Null
if (-not (Test-Path $probe)) { Write-Host "FATAL: could not compile tests\paste_probe719.cs" -ForegroundColor Red; exit 1 }
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function Read-ProbeText([string]$log) {
    $l = (Get-Content $log -EA SilentlyContinue | Where-Object { $_ -like 'TEXT *' }) -join ''
    if ($l.Length -ge 5) { return $l.Substring(5) } else { return "" }
}

function Start-Probe([string]$Sess, [string]$Bp) {
    $log = Join-Path $root "$Sess.log"; $stop = "$log.stop"
    Remove-Item $log, $stop -EA SilentlyContinue
    & $PSMUX -L $NS new-session -d -s $Sess -x 120 -y 30 -- $probe $log $Bp $stop 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if (((& $PSMUX -L $NS capture-pane -p -t $Sess) -join "`n") -match 'paste_probe719 bp=\w+ ready') { break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 400
    return @{ Log = $log; Stop = $stop; Sess = $Sess }
}
function Stop-Probe($p) {
    New-Item -ItemType File -Force $p.Stop | Out-Null
    Start-Sleep -Milliseconds 400
    $t = Read-ProbeText $p.Log
    & $PSMUX -L $NS kill-session -t $p.Sess 2>&1 | Out-Null
    return $t
}

try {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null

    Write-Host "`n=== Part 1: paste-buffer bytes against tmux's cmd-paste-buffer.c ===" -ForegroundColor Yellow
    $cases = @(
        @{ n = 'no -p, pane has 2004 on: raw text, no brackets'; bp = 'on';  buf = "PROBE-HELLO"; a = @();               want = 'PROBE-HELLO' },
        @{ n = '-p, pane has 2004 on: bracketed';                 bp = 'on';  buf = "PROBE-HELLO"; a = @('-p');           want = '<ESC>[200~PROBE-HELLO<ESC>[201~' },
        @{ n = '-p, pane has 2004 off: raw text';                 bp = 'off'; buf = "PROBE-HELLO"; a = @('-p');           want = 'PROBE-HELLO' },
        @{ n = 'default separator is CR';                         bp = 'on';  buf = "a`nb`nc";     a = @();               want = 'a<CR>b<CR>c' },
        @{ n = '-r keeps LF';                                     bp = 'on';  buf = "a`nb`nc";     a = @('-r');           want = 'a<LF>b<LF>c' },
        @{ n = '-s X replaces LF with X';                         bp = 'on';  buf = "a`nb`nc";     a = @('-s', 'X');      want = 'aXbXc' },
        @{ n = '-p keeps the CR separator inside the brackets';   bp = 'on';  buf = "a`nb`nc";     a = @('-p');           want = '<ESC>[200~a<CR>b<CR>c<ESC>[201~' },
        @{ n = '-p -r keeps LF inside the brackets';              bp = 'on';  buf = "a`nb`nc";     a = @('-p', '-r');     want = '<ESC>[200~a<LF>b<LF>c<ESC>[201~' },
        @{ n = 'a CRLF is one line break, not two';               bp = 'on';  buf = "a`r`nb";      a = @();               want = 'a<CR>b' },
        @{ n = '-p -r turns CRLF into one LF';                    bp = 'on';  buf = "a`r`nb";      a = @('-p', '-r');     want = '<ESC>[200~a<LF>b<ESC>[201~' }
    )
    $k = 0
    foreach ($c in $cases) {
        $k++
        $p = Start-Probe -Sess "p$k" -Bp $c.bp
        & $PSMUX -L $NS set-buffer -- $c.buf 2>&1 | Out-Null
        $pa = @('-L', $NS, 'paste-buffer') + $c.a + @('-t', $p.Sess)
        & $PSMUX @pa 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1000
        $got = Stop-Probe $p
        if ($got -eq $c.want) { Write-Pass "$($c.n): $got" }
        else { Write-Fail "$($c.n): want '$($c.want)' got '$got'" }
    }

    Write-Host "`n=== Part 2: a real Windows Terminal Ctrl+V into a 2004 pane ===" -ForegroundColor Yellow
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class I719Ui {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte sc, uint fl, UIntPtr ex);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] i, int sz);
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
    public static string Probe() {
        bool ok = OpenClipboard(IntPtr.Zero); int err = ok ? 0 : Marshal.GetLastWin32Error(); if (ok) CloseClipboard();
        string r = ""; if (!ok) r += "clipboard-denied(err=" + err + ")";
        if (GetForegroundWindow() == IntPtr.Zero) r += (r.Length > 0 ? " " : "") + "no-foreground";
        return r;
    }
    public static List<long> WtWindows() {
        var r = new List<long>();
        EnumWindows((h, l) => { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
            if (sb.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS") r.Add(h.ToInt64()); return true; }, IntPtr.Zero);
        return r;
    }
    public static bool Focus(long hl) {
        IntPtr h = new IntPtr(hl);
        for (int i = 0; i < 10; i++) {
            if (GetForegroundWindow() == h) return true;
            uint p; uint ft = GetWindowThreadProcessId(GetForegroundWindow(), out p); uint me = GetCurrentThreadId();
            AttachThreadInput(me, ft, true);
            keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
            ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
            AttachThreadInput(me, ft, false);
            Thread.Sleep(150);
        }
        return GetForegroundWindow() == h;
    }
    static INPUT K(ushort vk, bool up) { var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.dwFlags = up ? 2u : 0u; return i; }
    // Ctrl+V, but only into hl: never into whatever else holds the foreground.
    public static bool CtrlV(long hl) {
        if (GetForegroundWindow() != new IntPtr(hl)) return false;
        SendInput(2, new[] { K(0x11, false), K(0x56, false) }, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        SendInput(2, new[] { K(0x56, true), K(0x11, true) }, Marshal.SizeOf(typeof(INPUT)));
        return true;
    }
}
'@
    $wt = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (-not (Test-Path $wt)) { $c = Get-Command wt.exe -EA SilentlyContinue; $wt = if ($c) { $c.Source } else { $null } }
    $denied = [I719Ui]::Probe()
    if (-not $wt) {
        Write-Skip "wt.exe not found, the Windows Terminal half is not measurable here"
    } elseif ($denied) {
        Write-Skip "UI-ACCESS-DENIED: the desktop refuses this process ($denied); Ctrl+V into Windows Terminal not measurable"
    } else {
        $savedClip = try { Get-Clipboard -Raw -EA SilentlyContinue } catch { $null }
        $clips = @(
            @{ n = 'single line'; t = "PASTE-ONE-LINE-719"; plain = 'PASTE-ONE-LINE-719' },
            @{ n = 'three lines'; t = "line one 719`r`nline two 719`r`nline three 719"; plain = 'line one 719<CR>line two 719<CR>line three 719' }
        )
        foreach ($pd in @('on', 'off')) {
            $p = Start-Probe -Sess "wt$pd" -Bp 'on'
            & $PSMUX -L $NS set -s escape-time 0 2>&1 | Out-Null
            & $PSMUX -L $NS set -g paste-detection $pd 2>&1 | Out-Null
            $launcher = Join-Path $root "attach_$pd.cmd"
            Set-Content -Encoding ASCII $launcher ("@echo off`r`nset PSMUX_DATA_DIR=$env:PSMUX_DATA_DIR`r`nset PSMUX_NO_WARM=1`r`nset PSMUX_SESSION_NAME=`r`n`"$PSMUX`" -L $NS attach -t $($p.Sess)`r`n")
            $before = [I719Ui]::WtWindows()
            Start-Process -FilePath $wt -ArgumentList @('-w', 'new', 'new-tab', '--title', "i719$pd", 'cmd', '/c', $launcher) | Out-Null
            $hwnd = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 15000 -and -not $hwnd) {
                $new = @([I719Ui]::WtWindows() | Where-Object { $before -notcontains $_ })
                if ($new.Count -eq 1) { $hwnd = $new[0] } else { Start-Sleep -Milliseconds 100 }
            }
            $att = $false; $sw.Restart()
            while ($hwnd -and $sw.ElapsedMilliseconds -lt 15000) {
                if (((& $PSMUX -L $NS display-message -t $p.Sess -p '#{session_attached}') -join '').Trim() -eq '1') { $att = $true; break }
                Start-Sleep -Milliseconds 150
            }
            if (-not $att) {
                Write-Skip "paste-detection $pd`: no Windows Terminal client attached (window=$hwnd)"
            } else {
                Start-Sleep -Seconds 2
                foreach ($c in $clips) {
                    $strayA = 0; $ok = 0; $nofocus = 0; $bad = @()
                    for ($i = 1; $i -le 3; $i++) {
                        if (-not (Set-ClipboardVerified $c.t)) {
                            Write-Info "paste-detection $pd, $($c.n): the clipboard never took the test text in 5 s; it holds '$(try { Get-Clipboard -Raw } catch { '?' })'"
                            $nofocus++; continue
                        }
                        Start-Sleep -Milliseconds 200
                        $pre = (Read-ProbeText $p.Log).Length
                        if (-not ([I719Ui]::Focus($hwnd) -and [I719Ui]::CtrlV($hwnd))) { $nofocus++; continue }
                        Start-Sleep -Milliseconds 1500
                        $all = Read-ProbeText $p.Log
                        $got = if ($all.Length -ge $pre) { $all.Substring($pre) } else { $all }
                        if ($got -eq '') {
                            # Nothing at all arrived: not wrong bytes, no bytes. That is
                            # the chord landing before the window really had the
                            # foreground (sweep 2026-10-05_19-58-06 saw it on the first
                            # paste of two cells, overnight, with the same binary passing
                            # 18 of 18 standalone and in the sweep before it). A psmux
                            # defect shows up as wrong bytes, so one retry of the
                            # delivery is the honest move; a second empty result counts.
                            Start-Sleep -Milliseconds 500
                            $pre = (Read-ProbeText $p.Log).Length
                            if (-not ([I719Ui]::Focus($hwnd) -and [I719Ui]::CtrlV($hwnd))) { $nofocus++; continue }
                            Start-Sleep -Milliseconds 1500
                            $all = Read-ProbeText $p.Log
                            $got = if ($all.Length -ge $pre) { $all.Substring($pre) } else { $all }
                        }
                        $want = if ($pd -eq 'on') { "<ESC>[200~$($c.plain)<ESC>[201~" } else { $c.plain }
                        if ($got -match '(^|[^>])\[A') { $strayA++ }
                        if ($got -eq $want) { $ok++ } else { $bad += $got }
                    }
                    if ($nofocus -eq 3) { Write-Skip "paste-detection $pd, $($c.n): the Windows Terminal window never took the focus"; continue }
                    if ($strayA -eq 0) { Write-Pass "paste-detection $pd, $($c.n): no stray [A in $(3 - $nofocus) paste(s)" }
                    else { Write-Fail "paste-detection $pd, $($c.n): stray [A in $strayA paste(s)" }
                    if ($ok -eq 3 - $nofocus) { Write-Pass "paste-detection $pd, $($c.n): content arrived exactly ($ok of $(3 - $nofocus))" }
                    else { Write-Fail "paste-detection $pd, $($c.n): $ok of $(3 - $nofocus) exact; got '$($bad -join "' '")'" }
                }
            }
            # The client exits on detach, cmd /c ends and the tab closes itself.
            & $PSMUX -L $NS detach-client -s $p.Sess 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            [void](Stop-Probe $p)
            if ($hwnd -and [I719Ui]::IsWindow([IntPtr]$hwnd)) {
                [void][I719Ui]::PostMessageW([IntPtr]$hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
                Start-Sleep -Seconds 1
            }
            if ($hwnd -and [I719Ui]::IsWindow([IntPtr]$hwnd)) { Write-Info "window $hwnd still open after WM_CLOSE" }
        }
        if ($null -ne $savedClip -and $savedClip -ne '') { try { Set-Clipboard -Value $savedClip } catch {} }
        else { try { Set-Clipboard -Value $null } catch {} }
    }
} finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
