# Issue #685: a pane child's OSC 4 palette sets were dropped, so a record
# reading app like Far Manager painted with the OUTER terminal's scheme.
#
# What was measured before the fix, with the psmux CLIENT hosted under a real
# pseudoconsole (tests/conptyfeed610.cs) so its own output bytes can be read:
#
#   pane emits   ESC]4;4;rgb:00/00/80 ESC\   then  ESC[44m "   "
#   client wrote MARK_A<ESC>[44m               <- index 4, painted Campbell
#
# and after the fix, same capture:
#
#   client wrote MARK_A<ESC>[48;2;0;0;128m     <- the pane's own #000080
#
# In pixels, Far Manager's panels in a Windows Terminal window:
#
#   Far in a plain WT tab           #000080 / #008080 / #00FFFF
#   Far in a psmux pane, before     #0037DA / #3A96DD / #61D6D6
#   Far in a psmux pane, after      #000080 / #008080 / #00FFFF
#
# tmux parity: input.c:2733 dispatches OSC 4 to input_osc_4 (input.c:2927),
# which fills the per pane `struct colour_palette` (tmux.h:764, held by
# window_pane at tmux.h:1379) through colour_palette_set (colour.c:1272);
# input_osc_104 (input.c:3446) resets it, RIS clears it (input.c:1407), a
# respawn keeps it (Group 6), and
# tty_check_fg / tty_check_bg / tty_check_us (tty.c:2822, 2892, 2945) apply it
# on the way to the terminal.  psmux applies it where a cell is serialised for
# the client, which is the same place in its own pipeline.
#
# Deliberately NOT done: forwarding OSC 4 to the outer terminal.  Two panes
# with different palettes would fight over one terminal, which is exactly why
# tmux resolves per pane.  This test asserts the client forwards none.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } else { (Get-Command psmux -EA Stop).Source }
$SOCK = "i685"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }

$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm = $env:PSMUX_NO_WARM
$savedNoColor = $env:NO_COLOR
$env:PSMUX_DATA_DIR = "$env:TEMP\psmux_685_root"
$env:PSMUX_NO_WARM = "1"
# A NO_COLOR in the caller's environment suppresses every SGR the client would
# write, which would make every assertion below vacuous.
$env:NO_COLOR = $null

$TESTS = Split-Path -Parent $MyInvocation.MyCommand.Path
$OUT = "$env:TEMP\psmux_685_out"
New-Item -ItemType Directory -Force $OUT | Out-Null

# --- helper binaries ---------------------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    Write-Host "csc.exe not found; cannot build the helpers" -ForegroundColor Red
    exit 1
}
$emit = "$OUT\palette_emit685.exe"
$feed = "$OUT\conptyfeed685.exe"
& $csc /nologo /out:$emit /platform:x64 "$TESTS\palette_emit685.cs" 2>&1 | Out-Null
& $csc /nologo /out:$feed /platform:x64 "$TESTS\conptyfeed610.cs" 2>&1 | Out-Null
if (-not (Test-Path $emit) -or -not (Test-Path $feed)) {
    Write-Host "helper build failed" -ForegroundColor Red
    exit 1
}

# --- the capture harness -----------------------------------------------------
# Host the psmux CLIENT under a real pseudoconsole and read the bytes it
# writes.  That is the only deterministic way to see what the outer terminal
# would have been told.
function Capture-Client($tag, $emitArgs) {
    $sess = "p685$tag"
    & $PSMUX -L $SOCK kill-session -t $sess 2>&1 | Out-Null
    & $PSMUX -L $SOCK new-session -d -s $sess -x 80 -y 24 "$emit $emitArgs" 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $ctrl = "$OUT\$tag.ctrl"
    $cap = "$OUT\$tag.bin"
    Remove-Item $ctrl, $cap -EA SilentlyContinue
    Set-Content $ctrl "" -NoNewline
    $p = Start-Process -FilePath $feed `
        -ArgumentList "`"$ctrl`"", "`"$cap`"", "`"$PSMUX`" -L $SOCK attach-session -t $sess" `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    try { Stop-Process -Id $p.Id -Force -EA Stop } catch {}
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $SOCK kill-session -t $sess 2>&1 | Out-Null
    if (-not (Test-Path $cap)) { return "" }
    $fs = [IO.File]::Open($cap, 'Open', 'Read', 'ReadWrite')
    $buf = New-Object byte[] $fs.Length
    $null = $fs.Read($buf, 0, $buf.Length)
    $fs.Close()
    return [Text.Encoding]::ASCII.GetString($buf)
}

# The SGR sequence the client wrote immediately after a marker.
function Sgr-After($stream, $marker) {
    $i = $stream.IndexOf($marker)
    if ($i -lt 0) { return $null }
    $rest = $stream.Substring($i + $marker.Length)
    $m = [regex]::Match($rest, '^\x1b(\[[0-9;:]*m)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

Write-Host "`n=== Group 1: a pane that sets its palette ===" -ForegroundColor Cyan
$s = Capture-Client "set" "-sec 40"
if ([string]::IsNullOrEmpty($s)) {
    Write-Fail "no client capture at all"
} else {
    $a = Sgr-After $s "MARK_A"
    if ($a -eq "[48;2;0;0;128m") {
        Write-Pass "legacy ESC[44m left the client as ESC$a (#685: was ESC[44m)"
    } else {
        Write-Fail "#685: legacy ESC[44m left the client as ESC$a, expected ESC[48;2;0;0;128m"
    }
    $b = Sgr-After $s "MARK_B"
    if ($b -eq "[48;2;0;0;128m") {
        Write-Pass "indexed ESC[48;5;4m left the client as ESC$b"
    } else {
        Write-Fail "#685: indexed ESC[48;5;4m left the client as ESC$b, expected ESC[48;2;0;0;128m"
    }
    $e = Sgr-After $s "MARK_E"
    if ($e -eq "[46m") {
        Write-Pass "an index the palette does not cover is untouched (ESC$e)"
    } else {
        Write-Fail "index 6 was not in the palette but came out ESC$e, expected ESC[46m"
    }
    $c = Sgr-After $s "MARK_C"
    if ($c -eq "[96m") {
        Write-Pass "an indexed foreground with no entry is untouched (ESC$c)"
    } else {
        Write-Fail "index 14 was not in the palette but came out ESC$c, expected ESC[96m"
    }
    # The client's own startup palette QUERIES (ESC]4;N;?) go to the outer
    # terminal and are expected; a pane palette SET must never be forwarded.
    $sets = ([regex]::Matches($s, "\x1b\]4;[0-9]+;(?!\?)")).Count
    if ($sets -eq 0) {
        Write-Pass "the client forwarded no OSC 4 palette set to the outer terminal"
    } else {
        Write-Fail "the client forwarded $sets OSC 4 palette sets to the outer terminal"
    }
}

Write-Host "`n=== Group 2: a pane that sets nothing is byte for byte as before ===" -ForegroundColor Cyan
$s2 = Capture-Client "none" "-noosc -sec 40"
if ([string]::IsNullOrEmpty($s2)) {
    Write-Fail "no client capture at all"
} else {
    $a2 = Sgr-After $s2 "MARK_A"
    $b2 = Sgr-After $s2 "MARK_B"
    if ($a2 -eq "[44m" -and $b2 -eq "[44m") {
        Write-Pass "a pane with no palette still emits ESC[44m for both forms"
    } else {
        Write-Fail "a pane with no palette emitted ESC$a2 / ESC$b2, expected ESC[44m twice"
    }
}

Write-Host "`n=== Group 3: the other OSC 4 spellings ===" -ForegroundColor Cyan
foreach ($case in @(@("hash", "-hash -sec 40", "#RRGGBB"),
                    @("wide", "-wide -sec 40", "rgb:RRRR/GGGG/BBBB"))) {
    $sx = Capture-Client $case[0] $case[1]
    $ax = Sgr-After $sx "MARK_A"
    if ($ax -eq "[48;2;0;0;128m") {
        Write-Pass "the $($case[2]) form set index 4 (ESC$ax)"
    } else {
        Write-Fail "the $($case[2]) form gave ESC$ax, expected ESC[48;2;0;0;128m"
    }
}
$sm = Capture-Client "multi" "-multi -sec 40"
$am = Sgr-After $sm "MARK_A"
$em = Sgr-After $sm "MARK_E"
if ($am -eq "[48;2;0;0;128m" -and $em -eq "[48;2;0;128;128m") {
    Write-Pass "two pairs in ONE OSC 4 both landed (ESC$am and ESC$em)"
} else {
    Write-Fail "two pairs in one OSC 4 gave ESC$am / ESC$em, expected ESC[48;2;0;0;128m and ESC[48;2;0;128;128m"
}

Write-Host "`n=== Group 4: OSC 104 puts the index back ===" -ForegroundColor Cyan
$sr = Capture-Client "reset" "-reset -sec 40"
$dr = Sgr-After $sr "MARK_D"
if ($dr -eq "[44m") {
    Write-Pass "OSC 104;4 restored index 4 (ESC$dr)"
} else {
    Write-Fail "OSC 104;4 left index 4 as ESC$dr, expected ESC[44m"
}
# A BARE OSC 104 is swallowed by conhost on the ConPTY output path (measured on
# Windows 11 26200: `ESC]104;4 ESC\` arrives, `ESC]104 ESC\` does not), so the
# all-entries reset is covered by the parser test
# crates/vt100-psmux/tests/issue685_osc4_palette.rs rather than here.
Write-Skip "bare OSC 104 is not deliverable through ConPTY; covered by the vt100 test"

Write-Host "`n=== Group 5: the palette does not leak between panes ===" -ForegroundColor Cyan
$sessA = "p685a"
$sessB = "p685b"
& $PSMUX -L $SOCK kill-session -t $sessA 2>&1 | Out-Null
& $PSMUX -L $SOCK new-session -d -s $sessA -x 80 -y 24 "$emit -sec 40" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX -L $SOCK split-window -t $sessA "$emit -noosc -sec 40" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$ctrl = "$OUT\leak.ctrl"; $cap = "$OUT\leak.bin"
Remove-Item $ctrl, $cap -EA SilentlyContinue
Set-Content $ctrl "" -NoNewline
$pl = Start-Process -FilePath $feed `
    -ArgumentList "`"$ctrl`"", "`"$cap`"", "`"$PSMUX`" -L $SOCK attach-session -t $sessA" `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 6
try { Stop-Process -Id $pl.Id -Force -EA Stop } catch {}
Start-Sleep -Milliseconds 400
& $PSMUX -L $SOCK kill-session -t $sessA 2>&1 | Out-Null
if (Test-Path $cap) {
    $fs = [IO.File]::Open($cap, 'Open', 'Read', 'ReadWrite')
    $buf = New-Object byte[] $fs.Length
    $null = $fs.Read($buf, 0, $buf.Length); $fs.Close()
    $sl = [Text.Encoding]::ASCII.GetString($buf)
    # Both panes wrote MARK_A.  The one that set a palette must be RGB and the
    # one that did not must still be ESC[44m, so the two spellings must BOTH
    # appear in the same frame.
    $hasRgb = $sl.Contains("$([char]27)[48;2;0;0;128m")
    $hasIdx = $sl.Contains("$([char]27)[44m")
    if ($hasRgb -and $hasIdx) {
        Write-Pass "in one frame, the palette pane is RGB and its neighbour is still ESC[44m"
    } else {
        Write-Fail "palette leaked or did not apply: rgb=$hasRgb idx=$hasIdx"
    }
} else {
    Write-Fail "no two pane capture"
}

Write-Host "`n=== Group 6: respawn keeps the palette (tmux parity, #708) ===" -ForegroundColor Cyan
# tmux keeps a pane's OSC 4 palette across respawn-pane.  The palette lives on
# the window_pane (wp->palette, set up once in window_add_pane, window.c:1332)
# and the parser only holds a pointer to it (input_init, window.c:1544).  The
# respawn branch of spawn_pane (spawn.c:311-334) frees the parser with
# input_free, which never touches the palette (input.c:904), and calls
# screen_reinit, which does not either; only RIS (input.c:1407), OSC 104
# (input.c:3453) and a pane teardown (colour_palette_free, window.c:1489) empty
# it.  Measured on tmux 3.4 in WSL: a pane sets ESC]4;4;rgb:00/00/80, dies
# under remain-on-exit, `respawn-pane -k` starts a child that sets nothing and
# prints ESC[44m, and the attached client receives ESC[48;2;0;0;128m; the same
# flow without the OSC 4 receives ESC[44m.  psmux matches since #708
# (Screen::reinit_keep_history), so the replacement child's ESC[44m must still
# leave the client as the RGB the first child installed.
$sessR = "p685r"
& $PSMUX -L $SOCK kill-session -t $sessR 2>&1 | Out-Null
# The first child stays ALIVE and sets index 4; `respawn-pane -k` kills it and
# starts a replacement that sets nothing, so any RGB on its MARK_A can only
# come from the palette the first child left on the pane.  (A child that exits on its own takes
# the whole session with it, remain-on-exit being off by default, so there
# would be no pane left to respawn.)
& $PSMUX -L $SOCK new-session -d -s $sessR -x 80 -y 24 "$emit -sec 60" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX -L $SOCK respawn-pane -k -t $sessR "$emit -noosc -sec 40" 2>&1 | Out-Null
Start-Sleep -Seconds 4
$ctrl = "$OUT\respawn.ctrl"; $cap = "$OUT\respawn.bin"
Remove-Item $ctrl, $cap -EA SilentlyContinue
Set-Content $ctrl "" -NoNewline
$pr = Start-Process -FilePath $feed `
    -ArgumentList "`"$ctrl`"", "`"$cap`"", "`"$PSMUX`" -L $SOCK attach-session -t $sessR" `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 6
try { Stop-Process -Id $pr.Id -Force -EA Stop } catch {}
Start-Sleep -Milliseconds 400
& $PSMUX -L $SOCK kill-session -t $sessR 2>&1 | Out-Null
if (Test-Path $cap) {
    $fs = [IO.File]::Open($cap, 'Open', 'Read', 'ReadWrite')
    $buf = New-Object byte[] $fs.Length
    $null = $fs.Read($buf, 0, $buf.Length); $fs.Close()
    $sr2 = [Text.Encoding]::ASCII.GetString($buf)
    $ar = Sgr-After $sr2 "MARK_A"
    if ($ar -eq "[48;2;0;0;128m") {
        Write-Pass "the respawned pane kept the palette like tmux (ESC$ar)"
    } else {
        Write-Fail "the respawned pane lost the palette: ESC$ar, expected ESC[48;2;0;0;128m (tmux keeps wp->palette across respawn)"
    }
} else {
    Write-Skip "respawn capture unavailable"
}

Write-Host "`n=== Group 7: the Far pixel proof (soft) ===" -ForegroundColor Cyan
$far = "C:\Program Files\Far Manager\Far.exe"
if (-not (Test-Path $far)) {
    Write-Skip "Far Manager is not installed; the pixel proof needs it"
} elseif (-not (Get-Command wt.exe -EA SilentlyContinue)) {
    Write-Skip "Windows Terminal is not on PATH; the pixel proof needs it"
} else {
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class Px685T {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint fl, uint to, out IntPtr res);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static List<long> Terminals() {
    var list = new List<long>();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
      if (cn.ToString().IndexOf("CASCADIA", StringComparison.OrdinalIgnoreCase) >= 0) list.Add((long)h);
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static void Close(IntPtr h) { IntPtr r; SendMessageTimeout(h, 0x0010, IntPtr.Zero, IntPtr.Zero, 2, 5000, out r); }
}
"@ -ErrorAction SilentlyContinue

    function Sample-Far($psmuxPane) {
        $before = [Px685T]::Terminals()
        if ($psmuxPane) {
            Start-Process wt.exe -ArgumentList @('-w', '-1', '--', $PSMUX, '-L', $SOCK, 'new-session', '-s', 'p685far', '-x', '120', '-y', '40', $far)
        } else {
            Start-Process wt.exe -ArgumentList @('-w', '-1', '--', $far)
        }
        $h = [IntPtr]::Zero
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            $new = [Px685T]::Terminals() | Where-Object { $before -notcontains $_ }
            if ($new) { $h = [IntPtr]([int64]($new | Select-Object -First 1)); break }
        }
        if ($h -eq [IntPtr]::Zero) { return $null }
        [Px685T]::SetWindowPos($h, [IntPtr]::Zero, 40, 40, 1400, 900, 0x0004) | Out-Null
        Start-Sleep -Milliseconds 600
        [Px685T]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Seconds 7
        $r = New-Object Px685T+RECT
        [Px685T]::GetWindowRect($h, [ref]$r) | Out-Null
        $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
        $hist = @{}
        for ($y = 70; $y -lt $bmp.Height - 20; $y += 3) {
            for ($x = 8; $x -lt $bmp.Width - 8; $x += 3) {
                $c = $bmp.GetPixel($x, $y)
                $k = "#{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
                if ($hist.ContainsKey($k)) { $hist[$k]++ } else { $hist[$k] = 1 }
            }
        }
        $g.Dispose(); $bmp.Dispose()
        [Px685T]::Close($h)
        Start-Sleep -Seconds 3
        if ($psmuxPane) { & $PSMUX -L $SOCK kill-session -t p685far 2>&1 | Out-Null }
        return ($hist.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    }

    $bg = Sample-Far $true
    Write-Host "    Far in a psmux pane: dominant colour $bg"
    if ($bg -eq "#000080") {
        Write-Pass "Far's panel background is the classic #000080, not Campbell #0037DA"
    } elseif ($bg -eq "#0037DA") {
        Write-Fail "#685: Far's panel background is still Campbell #0037DA"
    } else {
        Write-Skip "Far's dominant colour was $bg; the profile or layout differs, no verdict"
    }
}

& $PSMUX -L $SOCK kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM = $savedNoWarm
$env:NO_COLOR = $savedNoColor

Write-Host "`n=== Issue #685 summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
