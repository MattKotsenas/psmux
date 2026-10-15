# Issue #811 follow up: window notifications for changes that do not come
# from a control client's request. tmux announces %window-add / %window-close
# / %session-window-changed for every one of them (control-notify.c, fired
# from server_destroy_pane, server_kill_window and spawn.c whatever caused
# them):
#   1. a window whose only pane exits on its own (remain-on-exit off)
#   2. a pane process killed from outside, by PID (another window and the
#      current one)
#   3. a window created by a hook, inside a request (after-split-window) and
#      outside one (pane-exited, fired by the dead pane reaper)
#   4. windows created and killed by a key binding in an attached TUI client
#      (keystrokes written into its console with tests\injector.cs)
#
# One -CC client over pipes in a private -L namespace; cleanup with
# `psmux -L <ns> kill-server` only, the TUI client closed by its own PID.

$ErrorActionPreference = 'Continue'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "psmux: $PSMUX ($(& $PSMUX -V))"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i811f_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$ns = 'i811f_' + [guid]::NewGuid().ToString('N').Substring(0, 8)

function Read-Shared([string]$path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $ms = [System.IO.MemoryStream]::new(); $fs.CopyTo($ms); $fs.Close()
        return , $ms.ToArray()
    } catch { return , [byte[]]@() }
}
function Get-Lines([string]$path) { return @($utf8.GetString((Read-Shared $path)) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
function Wait-Until([scriptblock]$cond, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 50 }
    return [bool](& $cond)
}
function Get-Blocks([string]$path) {
    $blocks = @(); $cur = $null
    foreach ($l in (Get-Lines $path)) {
        if ($l -match '^%begin ') { $cur = @{ Body = @(); End = $null }; continue }
        if ($null -ne $cur) {
            if ($l -match '^%(end|error) ') { $cur.End = $Matches[1]; $blocks += [pscustomobject]$cur; $cur = $null; continue }
            if ($l -notmatch '^%[a-z][a-z-]*( |$)') { $cur.Body += $l }
        }
    }
    return , $blocks
}
function Get-Notes([int]$from) {
    $lines = Get-Lines $out; $notes = @(); $in = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^%begin ') { $in = $true; continue }
        if ($in) { if ($l -match '^%(end|error) ') { $in = $false }; continue }
        if ($i -ge $from -and $l -match '^%(window-add|window-close|unlinked-window-close|session-window-changed) ') { $notes += $l }
    }
    return , $notes
}

$psi = [System.Diagnostics.ProcessStartInfo]::new($PSMUX, "-L $ns -CC new-session -A -s demo")
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$out = Join-Path $work 'cc.out'; $err = Join-Path $work 'cc.err'
$p = [System.Diagnostics.Process]::Start($psi)
$fo = [System.IO.FileStream]::new($out, 'Create', 'Write', 'ReadWrite', 1)
$fe = [System.IO.FileStream]::new($err, 'Create', 'Write', 'ReadWrite', 1)
$t1 = $p.StandardOutput.BaseStream.CopyToAsync($fo, 1)
$t2 = $p.StandardError.BaseStream.CopyToAsync($fe, 1)
$tui = $null

function Invoke-CC([string]$line, [int]$expect = 1, [int]$waitMs = 7000) {
    $before = (Get-Blocks $out).Count
    $p.StandardInput.Write("$line`n"); $p.StandardInput.Flush()
    Wait-Until { (Get-Blocks $out).Count -ge $before + $expect } $waitMs | Out-Null
    $all = Get-Blocks $out
    $new = @(); for ($i = $before; $i -lt $all.Count; $i++) { $new += $all[$i] }
    return , $new
}
function Mark { return (Get-Lines $out).Count - 1 }
function One([string]$fmt, [string]$t = '') {
    $tt = if ($t) { "-t '$t' " } else { '' }
    return (((Invoke-CC "display-message -p $tt'$fmt'")[0].Body) -join '').Trim()
}
function Win-Id([string]$name) {
    $ids = ((Invoke-CC "list-windows -F '#{window_id} #{window_name}'")[0].Body) | Where-Object { $_ -match " $name$" } | ForEach-Object { ($_ -split ' ')[0] }
    return ($ids | Select-Object -First 1)
}
function Expect-Note([int]$from, [string]$note, [string]$label, [int]$ms = 15000) {
    if (Wait-Until { (Get-Notes $from) -contains $note } $ms) { Write-Pass "$label -> '$note'" }
    else { Write-Fail "$label -> no '$note' (got: $((Get-Notes $from) -join ' / '))" }
}
function Expect-NoNote([int]$from, [string]$pattern, [string]$label) {
    $bad = @((Get-Notes $from) | Where-Object { $_ -match $pattern })
    if ($bad.Count -eq 0) { Write-Pass $label } else { Write-Fail "$label (got: $($bad -join ' / '))" }
}

try {
    if (-not (Wait-Until { (Get-Lines $out | Where-Object { $_ -match '^%session-changed' }).Count -gt 0 } 10000)) {
        Write-Fail "-CC session did not start"; throw 'no session'
    }
    $sid = One '#{session_id}'
    $w1 = One '#{window_id}'
    Write-Host "session $sid, first window $w1"

    Write-Host "`n[1] the only pane of a window exits on its own" -ForegroundColor Yellow
    $m = Mark
    Invoke-CC "new-window -d -n selfexit 'cmd /c ping -n 4 127.0.0.1 >nul'" | Out-Null
    $wx = Win-Id 'selfexit'
    Expect-Note $m "%window-add $wx" "new-window -d (command)"
    $m = Mark
    Expect-Note $m "%window-close $wx" "its command ended" 20000
    Expect-NoNote $m "window-close $w1" "no close for the surviving $w1"

    Write-Host "`n[2] a pane process killed by PID" -ForegroundColor Yellow
    Invoke-CC "new-window -d -n extkill" | Out-Null
    Start-Sleep -Milliseconds 1500
    $wk = Win-Id 'extkill'
    $ppid = One '#{pane_pid}' $wk
    $m = Mark
    if ($ppid -match '^\d+$') { Stop-Process -Id ([int]$ppid) -Force -EA SilentlyContinue }
    Expect-Note $m "%window-close $wk" "Stop-Process of pane pid $ppid in another window"

    Invoke-CC "new-window -n extcur" | Out-Null
    Start-Sleep -Milliseconds 1500
    $wc = One '#{window_id}'
    $ppid = One '#{pane_pid}' $wc
    $m = Mark
    if ($ppid -match '^\d+$') { Stop-Process -Id ([int]$ppid) -Force -EA SilentlyContinue }
    Expect-Note $m "%window-close $wc" "Stop-Process of the current window's pane"
    Expect-Note $m "%session-window-changed $sid $w1" "current window moves back"

    Write-Host "`n[3] windows created by hooks" -ForegroundColor Yellow
    # The hooks are set over the CLI: control mode set-hook stores a quoted
    # single command argument with its quotes (a separate bug).
    & $PSMUX -L $ns set-hook -g after-split-window 'new-window -d -n hooksplit'
    $m = Mark
    Invoke-CC "split-window -t '$w1'" | Out-Null
    Wait-Until { (Win-Id 'hooksplit') } 5000 | Out-Null
    $wh = Win-Id 'hooksplit'
    Expect-Note $m "%window-add $wh" "after-split-window hook new-window"
    Invoke-CC "set-hook -gu after-split-window" | Out-Null

    & $PSMUX -L $ns set-hook -g pane-exited 'new-window -d -n hookexit'
    $m = Mark
    Invoke-CC "new-window -d -n shortlived 'cmd /c ping -n 2 127.0.0.1 >nul'" | Out-Null
    Wait-Until { (Win-Id 'hookexit') } 20000 | Out-Null
    $we = Win-Id 'hookexit'
    if ($we) { Expect-Note $m "%window-add $we" "pane-exited hook new-window (outside a request)" }
    else { Write-Fail "pane-exited hook never created its window" }
    Invoke-CC "set-hook -gu pane-exited" | Out-Null

    Write-Host "`n[4] key bindings in an attached TUI client" -ForegroundColor Yellow
    $csc = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4*\csc.exe') -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    $inj = Join-Path $work 'injector.exe'
    & $csc /nologo /optimize "/out:$inj" (Join-Path $PSScriptRoot 'injector.cs') 2>&1 | Out-Null
    if (-not (Test-Path $inj)) { Write-Fail "could not build tests\injector.cs" }
    else {
        Invoke-CC "bind -n F7 new-window -d -n keywin" | Out-Null
        Invoke-CC "bind -n F8 kill-window -t :keywin" | Out-Null
        Invoke-CC "bind -n F9 new-window -n keycur" | Out-Null
        $tui = Start-Process -FilePath $PSMUX -ArgumentList '-L', $ns, 'attach', '-t', 'demo' -PassThru
        Start-Sleep -Seconds 3
        $m = Mark
        & $inj $tui.Id '{F7}' | Out-Null
        Wait-Until { (Win-Id 'keywin') } 5000 | Out-Null
        $wb = Win-Id 'keywin'
        if ($wb) { Expect-Note $m "%window-add $wb" "F7 binding new-window -d" } else { Write-Fail "F7 never created keywin (injection did not land?)" }
        $m = Mark
        & $inj $tui.Id '{F8}' | Out-Null
        if ($wb) { Expect-Note $m "%window-close $wb" "F8 binding kill-window" }
        $m = Mark
        & $inj $tui.Id '{F9}' | Out-Null
        Wait-Until { (Win-Id 'keycur') } 5000 | Out-Null
        $wn = Win-Id 'keycur'
        if ($wn) {
            Expect-Note $m "%window-add $wn" "F9 binding new-window"
            Expect-Note $m "%session-window-changed $sid $wn" "F9 binding makes it current"
        } else { Write-Fail "F9 never created keycur" }
    }

    Write-Host "`n[5] nothing announced twice" -ForegroundColor Yellow
    $all = Get-Notes 0
    $dups = @($all | Where-Object { $_ -match 'window-(add|close) ' } | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dups.Count -eq 0) { Write-Pass "no duplicate %window-add / %window-close" } else { Write-Fail "duplicates: $(($dups | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')" }
} catch {
    if ("$_" -ne 'no session') { Write-Fail "exception: $_" }
} finally {
    & $PSMUX -L $ns kill-server 2>$null
    if ($tui -and -not $tui.WaitForExit(3000)) { try { Stop-Process -Id $tui.Id -Force } catch {} }
    if (-not $p.WaitForExit(3000)) { try { $p.Kill() } catch {} }
    try { $t1.Wait(2000) | Out-Null; $t2.Wait(2000) | Out-Null } catch {}
    $fo.Close(); $fe.Close()
    if ($script:TestsFailed -gt 0) { Write-Host "`n-CC transcript: $out" }
}

Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
if ($script:TestsFailed -gt 0) { exit 1 } else { Remove-Item -Recurse -Force $work -EA SilentlyContinue; exit 0 }
