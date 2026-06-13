# Launch-to-visible-window comparison: psmux vs Windows Terminal vs pwsh.
#
# Measures "I launched it, how long until a usable window is on screen", timed
# via window-handle visibility so all three are comparable.
#
# IMPORTANT - controlled Windows Terminal handling:
#   wt.exe is a thin launcher stub; the real window is owned by WindowsTerminal.exe,
#   and ALL wt windows share ONE WindowsTerminal.exe process. There is no `wt close`
#   command. So we NEVER kill WindowsTerminal.exe (that would also kill the terminal
#   hosting this session). Instead we:
#     1. open a NEW window with a unique tab title via:  wt -w -1 new-tab --title <id> --suppressApplicationTitle
#     2. find that specific top-level window by its unique title (EnumWindows)
#     3. close ONLY that window by sending it WM_CLOSE (other windows untouched)
#
#   Because a WindowsTerminal.exe process is always already running (it hosts the
#   caller), the wt number is "new window in the running Terminal" (warm process,
#   new window) - the realistic everyday case. A true cold first-process start of
#   WindowsTerminal cannot be measured in-session without killing the host, so it
#   is intentionally NOT attempted here. psmux and pwsh ARE measured cold (their
#   hosting process is freshly spawned each iteration).
param(
    [int]$Iters = 10,
    [int]$WtIters = 6,
    [string]$Stamp = "manual"
)
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# Win32 helpers: find a visible top-level window by title substring, and close it
# with WM_CLOSE (closes that window only, not the process).
if (-not ("Bench.WinFind" -as [type])) {
Add-Type -Namespace Bench -Name WinFind -MemberDefinition @'
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    public static IntPtr FindByTitle(string needle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString().IndexOf(needle, System.StringComparison.Ordinal) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void CloseWin(IntPtr h) { SendMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); } // WM_CLOSE
'@
}

function Percentile($arr, $pct) {
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    $s = [double[]]($arr | Sort-Object)
    return [math]::Round($s[[Math]::Floor(($pct / 100.0) * ($s.Count - 1))], 1)
}
function Mean($arr) { if ($arr.Count) { [math]::Round(($arr | Measure-Object -Average).Average,1) } else { $null } }

function Kill-By { param([string]$Name) Get-Process $Name -EA SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch {} } }

Write-Host ("=" * 72)
Write-Host "  LAUNCH-TO-VISIBLE-WINDOW COMPARISON"
Write-Host ("  psmux/pwsh iters: {0} (cold)   wt iters: {1} (new window)   stamp: {2}" -f $Iters,$WtIters,$Stamp)
Write-Host ("=" * 72)
$result = @{ stamp=$Stamp; iters=$Iters; wt_iters=$WtIters; cpu=(Get-CimInstance Win32_Processor).Name; targets=@{} }

# ---------------- psmux (COLD: server killed each iteration) ----------------
Write-Host "`n[psmux] cold launch -> visible console window"
$psmuxMs = [System.Collections.ArrayList]::new()
for ($i = 0; $i -lt $Iters; $i++) {
    & $PSMUX kill-server 2>&1 | Out-Null
    Kill-By "psmux"
    Remove-Item "$psmuxDir\wtcmp$i.*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 600
    # psmux console window title is its exe path ("...psmux.exe"); only one psmux
    # exists per iteration (server killed between), so the substring is unambiguous.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","wtcmp$i" | Out-Null
    $hwnd = [IntPtr]::Zero
    while ($sw.ElapsedMilliseconds -lt 8000) { $hwnd = [Bench.WinFind]::FindByTitle("psmux.exe"); if ($hwnd -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 4 }
    $sw.Stop()
    if ($hwnd -ne [IntPtr]::Zero) { [void]$psmuxMs.Add($sw.Elapsed.TotalMilliseconds); Write-Host ("  iter {0}: {1:N0} ms" -f $i,$sw.Elapsed.TotalMilliseconds) }
    else { Write-Host ("  iter {0}: NO WINDOW (timeout)" -f $i) }
    & $PSMUX kill-server 2>&1 | Out-Null
    Kill-By "psmux"
    Start-Sleep -Milliseconds 300
}

# ---------------- Windows Terminal (controlled new window; process NEVER killed) ----------------
$wtCmd = Get-Command wt -EA SilentlyContinue
$wtMs = [System.Collections.ArrayList]::new()
if ($wtCmd) {
    Write-Host "`n[wt] new window in running Terminal -> visible (controlled open/close, no process kill)"
    for ($i = 0; $i -lt $WtIters; $i++) {
        $title = "PSMUXBENCHWT$i"
        # ensure no stale window with this title
        if ([Bench.WinFind]::FindByTitle($title) -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 300 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Start-Process -FilePath $wtCmd.Source -ArgumentList @(
                "-w","-1","new-tab","--title",$title,"--suppressApplicationTitle",
                "pwsh","-NoProfile","-NoExit","-Command","1"
            ) | Out-Null
        } catch { Write-Host ("  iter {0}: launch error: {1}" -f $i,$_.Exception.Message) }
        $hwnd = [IntPtr]::Zero
        while ($sw.ElapsedMilliseconds -lt 15000) {
            $hwnd = [Bench.WinFind]::FindByTitle($title)
            if ($hwnd -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 3
        }
        $sw.Stop()
        if ($hwnd -ne [IntPtr]::Zero) {
            [void]$wtMs.Add($sw.Elapsed.TotalMilliseconds)
            Write-Host ("  iter {0}: {1:N0} ms" -f $i,$sw.Elapsed.TotalMilliseconds)
            # close ONLY this window
            [Bench.WinFind]::CloseWin($hwnd)
            $deadline = [System.Diagnostics.Stopwatch]::StartNew()
            while ($deadline.ElapsedMilliseconds -lt 4000) {
                if ([Bench.WinFind]::FindByTitle($title) -eq [IntPtr]::Zero) { break }
                Start-Sleep -Milliseconds 50
                [Bench.WinFind]::CloseWin([Bench.WinFind]::FindByTitle($title))
            }
        } else { Write-Host ("  iter {0}: NO WINDOW (timeout)" -f $i) }
        Start-Sleep -Milliseconds 300
    }
} else {
    Write-Host "`n[wt] NOT INSTALLED - skipping"
}

# ---------------- pwsh (COLD: fresh process each iteration) ----------------
Write-Host "`n[pwsh] cold launch -> console window"
$pwshMs = [System.Collections.ArrayList]::new()
$pwshExe = (Get-Command pwsh -EA Stop).Source
for ($i = 0; $i -lt $Iters; $i++) {
    # Launch via cmd so 'title' stamps the console window with a unique, collision-free
    # title immediately (before pwsh starts), giving a clean window-visible measurement.
    $t = "BENCHPWSH$i"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c","title $t & `"$pwshExe`" -NoProfile -NoExit -Command 1" | Out-Null
    $hwnd = [IntPtr]::Zero
    while ($sw.ElapsedMilliseconds -lt 8000) { $hwnd = [Bench.WinFind]::FindByTitle($t); if ($hwnd -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 4 }
    $sw.Stop()
    if ($hwnd -ne [IntPtr]::Zero) { [void]$pwshMs.Add($sw.Elapsed.TotalMilliseconds); Write-Host ("  iter {0}: {1:N0} ms" -f $i,$sw.Elapsed.TotalMilliseconds); [Bench.WinFind]::CloseWin($hwnd) }
    else { Write-Host ("  iter {0}: NO WINDOW (timeout)" -f $i) }
    Start-Sleep -Milliseconds 200
}

# ---------------- summary ----------------
function Record($name,$arr,$mode){ $result.targets[$name] = @{ mode=$mode; n=$arr.Count; p50=(Percentile $arr 50); p90=(Percentile $arr 90); min=(Percentile $arr 0); max=(Percentile $arr 100); mean=(Mean $arr) } }
Record "psmux" $psmuxMs "cold-process"
Record "wt"    $wtMs    "new-window-warm-process"
Record "pwsh"  $pwshMs  "cold-process"

Write-Host ""
Write-Host ("=" * 72)
Write-Host "  SUMMARY - launch to visible window (ms)"
Write-Host ("=" * 72)
Write-Host ("  {0,-10} {1,-26} {2,5} {3,7} {4,7} {5,7} {6,7}" -f "target","mode","n","p50","p90","min","max")
Write-Host ("  " + ("-" * 70))
foreach ($k in @("psmux","wt","pwsh")) {
    $t = $result.targets[$k]
    if ($t.n -gt 0) { Write-Host ("  {0,-10} {1,-26} {2,5} {3,7} {4,7} {5,7} {6,7}" -f $k,$t.mode,$t.n,$t.p50,$t.p90,$t.min,$t.max) }
    else { Write-Host ("  {0,-10} {1,-26} {2,5} {3,7}" -f $k,$t.mode,0,"n/a") }
}

$out = "$env:USERPROFILE\.psmux-test-data\metrics\bench_wt_compare-$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content $out -Encoding UTF8
Write-Host "`n  JSON written: $out"

# cleanup (psmux only; WindowsTerminal is never touched)
& $PSMUX kill-server 2>&1 | Out-Null
Kill-By "psmux"
Remove-Item "$psmuxDir\wtcmp*.*" -Force -EA SilentlyContinue
