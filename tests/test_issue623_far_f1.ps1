# Issue #623: Far Manager's F1 opened no help until it was pressed a second time.
#
# Root cause, measured before anything was changed:
#
#   psmux writes F1 to a pane as the three bytes `1b 4f 50` (SS3 P).  ConPTY
#   PARSES that stream and hands the child a real `VK_F1` INPUT_RECORD pair --
#   but only while the pane console has ENABLE_VIRTUAL_TERMINAL_INPUT (VTI,
#   0x0200) OFF.  With VTI ON conhost stops parsing and passes the bytes
#   through verbatim, so the same F1 arrives as the characters ESC, 'O', 'P'.
#
#   `window_ops::ensure_vti` turned VTI ON, permanently, on the first mouse
#   event forwarded to a pane (`mouse` defaults to on), because SGR mouse
#   reports written to the ConPTY input pipe are dropped for a VT-READING app
#   (nvim, vim, opencode) when VTI is off -- that is issue #277.  It did that
#   for every pane, including panes running an app that reads INPUT_RECORDs.
#
#   Far Manager is such an app: measured with GetConsoleMode against the live
#   pane console, Far runs with mode 0x01B8 (WINDOW|MOUSE|INSERT|EXTENDED|
#   AUTO_POSITION), VTI off.  Once psmux flipped it to 0x03B8, the next F1 was
#   destroyed; Far re-applies its own console mode when it wakes to read, which
#   cleared VTI again, so the press AFTER the lost one opened the help.  That
#   is exactly "I need to press it twice".
#
#   A record reader never needed the flip: conhost converts an inbound SGR
#   report into a MOUSE_EVENT record for it precisely BECAUSE VTI is off.
#   Measured with tests/native_mouse_child.cs under a bare pseudoconsole: with
#   VTI off, `ESC[<65;41;11M`, `ESC[<35;41;11M`, `ESC[<0;41;11M` and its
#   release all arrived as MOUSE_EVENT records.  So the fix is to leave a
#   record reader's console mode alone.
#
# Test 1 runs everywhere and uses tests/native_mouse_child.cs as the stand-in
# for Far: a pane app with ENABLE_MOUSE_INPUT set and VTI off.  Test 2 needs a
# real Far Manager install and SKIPS with a clear message when there is none.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } else { (Get-Command psmux -EA Stop).Source }
$SOCK = "i623"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }

$emptyConf = "$env:TEMP\psmux_623_empty.conf"
"" | Set-Content -Path $emptyConf -Encoding ASCII

# --- helper binaries ---------------------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}

# GetConsoleMode against another process's console: the oracle for the whole
# bug.  Inline so this test carries its own instrument.
$modeProbeSrc = @'
using System;using System.Runtime.InteropServices;
class ModeProbe{
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool FreeConsole();
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AttachConsole(uint p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetConsoleMode(IntPtr h,out uint m);
 static int Main(string[] a){
  uint pid=uint.Parse(a[0]);
  FreeConsole();
  if(!AttachConsole(pid)){Console.WriteLine("ATTACH_FAIL");return 2;}
  IntPtr h=CreateFileW("CONIN$",0x80000000u|0x40000000u,3,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)){FreeConsole();Console.WriteLine("CONIN_FAIL");return 3;}
  uint m=0; bool ok=GetConsoleMode(h,out m);
  FreeConsole();
  if(!ok){Console.WriteLine("MODE_FAIL");return 4;}
  Console.WriteLine("MODE 0x{0:X4} VTI={1} MOUSE={2}",m,(m&0x0200)!=0,(m&0x0010)!=0);
  return 0;}}
'@
$modeProbe = "$env:TEMP\psmux_623_modeprobe.exe"
$modeProbeSrc | Set-Content "$env:TEMP\psmux_623_modeprobe.cs" -Encoding UTF8
& $csc /nologo /platform:x64 /out:$modeProbe "$env:TEMP\psmux_623_modeprobe.cs" 2>&1 | Out-Null

$injector    = "$env:TEMP\psmux_623_injector.exe"
$mouseInject = "$env:TEMP\psmux_623_mouseinj.exe"
$nativeChild = "$env:TEMP\psmux_623_nativemouse.exe"
& $csc /nologo /platform:x64 /out:$injector    "$PSScriptRoot\injector.cs"           2>&1 | Out-Null
& $csc /nologo /platform:x64 /out:$mouseInject "$PSScriptRoot\mouse_injector.cs"     2>&1 | Out-Null
& $csc /nologo /platform:x64 /out:$nativeChild "$PSScriptRoot\native_mouse_child.cs" 2>&1 | Out-Null

foreach ($exe in @($modeProbe, $injector, $mouseInject, $nativeChild)) {
    if (-not (Test-Path $exe)) {
        Write-Host "  [FAIL] could not build the C# harnesses (csc at $csc): missing $exe" -ForegroundColor Red
        exit 1
    }
}

function Cleanup-Session($name) {
    & $PSMUX -L $SOCK kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

function Probe-Mode($targetPid) {
    # NOT named $pid: PowerShell variables are case insensitive, so a parameter
    # called $pid shadows the automatic $PID inside the function.
    $out = (& $modeProbe $targetPid 2>&1 | Out-String).Trim()
    return $out
}

# The server's own account of what it did to the pane console.  This is the
# assertion that cannot go stale: the child clears VTI again as soon as it
# wakes to read, so probing the console mode a second later can find the mode
# already healed even though psmux did flip it.  `PSMUX_MOUSE_DEBUG=1` makes
# `ensure_vti_enabled` log every flip it performs, so an EMPTY log is proof the
# flip never happened.  Both need a data root this test owns.
$dataRoot = "$env:TEMP\psmux_623_root"
if (-not (Test-Path $dataRoot)) { New-Item -ItemType Directory -Path $dataRoot | Out-Null }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedMouseDbg = $env:PSMUX_MOUSE_DEBUG
$env:PSMUX_DATA_DIR = $dataRoot
$env:PSMUX_MOUSE_DEBUG = "1"
$mouseLog = Join-Path $dataRoot "mouse_debug.log"
if (Test-Path $mouseLog) { Remove-Item -LiteralPath $mouseLog -Force }

function Vti-Flips() {
    if (-not (Test-Path $mouseLog)) { return @() }
    return @(Get-Content $mouseLog | Where-Object { $_ -match 'ensure_vti_enabled: pid=\d+ mode' })
}
function Mouse-Forwarded() {
    if (-not (Test-Path $mouseLog)) { return @() }
    return @(Get-Content $mouseLog | Where-Object { $_ -match 'inject_mouse_combined' })
}

Write-Host "`n=== Issue #623 Tests: psmux must not disable ConPTY key translation ===" -ForegroundColor Cyan

# =============================================================================
# TEST 1: forwarding the mouse to a record-reading pane leaves VTI OFF
# =============================================================================
Write-Host "`n[Test 1] a mouse event does not flip the pane console into VT input mode" -ForegroundColor Yellow

$sess = "i623_rec"
$childLog = "$env:TEMP\psmux_native_mouse.txt"
if (Test-Path $childLog) { Remove-Item -LiteralPath $childLog -Force }
Cleanup-Session $sess

$client = Start-Process -FilePath $PSMUX -PassThru `
    -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$sess,"-x","100","-y","30","--",$nativeChild
Start-Sleep -Seconds 4

& $PSMUX -L $SOCK has-session -t $sess 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "attached session '$sess' never came up"
} else {
    $panePid = (& $PSMUX -L $SOCK display-message -p -t $sess '#{pane_pid}' 2>&1 | Out-String).Trim()
    $before = Probe-Mode $panePid
    if ($before -notmatch 'MODE 0x') {
        Write-Skip "could not read the pane console mode ($before)"
    } elseif ($before -match 'VTI=True') {
        Write-Skip "pane child already had VT input on ($before), nothing to protect"
    } else {
        Write-Pass "baseline: the pane app reads records ($before)"

        # A wheel notch over the pane: the event that used to trigger the flip.
        & $mouseInject $client.Id down 3 40 10 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        $forwarded = Mouse-Forwarded
        if ($forwarded.Count -eq 0) {
            Write-Skip "psmux forwarded no mouse event at all, nothing to assert"
        } else {
            Write-Pass "psmux forwarded the wheel to the pane ($($forwarded.Count) events)"
            # @() around the call: PowerShell unrolls a one element array on
            # return, and indexing a bare string yields a character.
            $flips = @(Vti-Flips)
            if ($flips.Count -eq 0) {
                Write-Pass "psmux performed no VT-input flip on the record reader's console"
            } else {
                Write-Fail "psmux flipped the pane console into VT input mode (#623 regression): $($flips[0])"
            }
        }

        $after = Probe-Mode $panePid
        if ($after -match 'VTI=False') {
            Write-Pass "after the wheel the pane console still reads records ($after)"
        } else {
            Write-Fail "psmux flipped the pane console into VT input mode ($after) - #623 regression"
        }

        # The wheel must still REACH the app: conhost turns the SGR report into
        # a MOUSE_EVENT record precisely because VTI is off, so the fix must not
        # have cost the pane its mouse.
        $log = if (Test-Path $childLog) { Get-Content $childLog } else { @() }
        if (@($log | Where-Object { $_ -match '^MOUSE ' }).Count -gt 0) {
            Write-Pass "the wheel still reached the record reader ($(@($log | Where-Object { $_ -match '^MOUSE ' }).Count) MOUSE records)"
        } else {
            Write-Fail "no mouse event reached the pane app at all (log: $($log -join ' | '))"
        }
    }
}
if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue }
Cleanup-Session $sess

# =============================================================================
# TEST 2: one F1 opens Far Manager's help (the reported symptom)
# =============================================================================
Write-Host "`n[Test 2] a single F1 opens Far Manager's help inside psmux" -ForegroundColor Yellow

$farCandidates = @(
    "$env:ProgramFiles\Far Manager\Far.exe",
    "${env:ProgramFiles(x86)}\Far Manager\Far.exe",
    "$env:LOCALAPPDATA\Programs\Far Manager\Far.exe"
)
$far = $farCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $far) {
    $cmd = Get-Command far.exe -EA SilentlyContinue
    if ($cmd) { $far = $cmd.Source }
}

if (-not $far) {
    Write-Skip "Far Manager is not installed - install it with 'winget install --id FarManager.FarManager' to run this test"
} else {
    $sess2 = "i623_far"
    Cleanup-Session $sess2
    # Far's default install path has a space in it, and Start-Process joins an
    # -ArgumentList array with spaces WITHOUT quoting, so the path is quoted here.
    $client2 = Start-Process -FilePath $PSMUX -PassThru `
        -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$sess2,"-x","110","-y","30","--","`"$far`""
    Start-Sleep -Seconds 7

    $screen = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
    if ($screen -notmatch '1Help') {
        Write-Fail "Far did not start in the pane (no function key bar on screen)"
    } else {
        Write-Pass "Far is running in the pane"

        $panePid2 = (& $PSMUX -L $SOCK display-message -p -t $sess2 '#{pane_pid}' 2>&1 | Out-String).Trim()

        # Scroll first: this is the event that used to leave the pane console in
        # VT input mode and eat the next key.
        $flipsBefore = @(Vti-Flips).Count
        & $mouseInject $client2.Id down 2 40 10 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        $flipsAfter = @(Vti-Flips)
        if ($flipsAfter.Count -gt $flipsBefore) {
            Write-Fail "psmux flipped Far's console into VT input mode (#623 regression): $($flipsAfter[-1])"
        } else {
            Write-Pass "psmux performed no VT-input flip on Far's console"
        }
        $mode2 = Probe-Mode $panePid2
        if ($mode2 -match 'VTI=False') {
            Write-Pass "Far's console still reads records after the wheel ($mode2)"
        } elseif ($mode2 -match 'MODE 0x') {
            Write-Fail "Far's console was flipped into VT input mode ($mode2) - #623 regression"
        } else {
            Write-Skip "could not read Far's console mode ($mode2)"
        }

        # ONE F1.
        & $injector $client2.Id "{F1}" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $help = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
        if ($help -match 'How to use help' -or $help -match 'Help file index') {
            Write-Pass "ONE F1 opened Far's help"
        } else {
            Write-Fail "Far's help did not open on the first F1 (#623): screen head = $((($help -split "`n") | Select-Object -First 3) -join ' / ')"
        }

        # Esc closes it, and F9 (the menu bar) proves other function keys survive.
        & $injector $client2.Id "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        & $injector $client2.Id "{F9}" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $menu = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
        if ($menu -match 'Commands' -and $menu -match 'Options') {
            Write-Pass "ONE F9 opened Far's menu bar"
        } else {
            Write-Fail "F9 did not open Far's menu bar"
        }
        & $injector $client2.Id "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    if ($client2 -and -not $client2.HasExited) { Stop-Process -Id $client2.Id -Force -EA SilentlyContinue }
    Cleanup-Session $sess2
}

& $PSMUX -L $SOCK kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_MOUSE_DEBUG = $savedMouseDbg

Write-Host "`n=== Issue #623 summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
