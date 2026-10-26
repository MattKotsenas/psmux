# Issue #655 (split out of #648 while verifying the per window option store):
# `show-options -w` listed every window scope option, inherited values included,
# and `-wA` listed those and then appended the WHOLE global listing after them.
#
# THE REPORT
#
#     set -w -t s:zero remain-on-exit on
#
#     show -w  -t s:zero   psmux 3.3.8: all 16 window options   tmux: its locals
#     show -w  -t s:one    psmux 3.3.8: all 16 window options   tmux: nothing
#     show -wA -t s:one    psmux 3.3.8: 77 lines, the window    tmux: ONE merged
#                          list then the global list appended         window list
#
# THE ORACLE
#
# Measured on tmux 3.4 under WSL (`tmux -L parity`) before any code was written,
# with both windows created by name:
#
#     show -w  -t s:zero -> 2 lines: automatic-rename off, remain-on-exit on
#     show -w  -t s:one  -> 1 line:  automatic-rename off
#     show -wA -t s:one  -> 55 lines, one merged window scope list, the
#                           inherited entries starred (remain-on-exit* off)
#     show -wA -t s:zero -> 55 lines, remain-on-exit unstarred
#     show -wg           -> 55 lines, the GLOBAL window table, nothing starred,
#                           automatic-rename on and remain-on-exit off
#     show -w            -> the client's current window, so the same 2 lines
#     show -w -v remain-on-exit -t s:zero -> on
#     show -p  -t s:zero -> nothing
#     show -pA -t s:zero -> every pane scope option, starred, remain-on-exit*
#                           taking the WINDOW's on
#
# psmux's window table holds 16 names where tmux's holds 55, so the absolute
# counts differ; the RULE is what this suite pins. `automatic-rename off` is a
# window LOCAL on both windows on tmux and on psmux alike, because both were
# born with `-n` (psmux keeps that in Window::manual_rename, #266).
#
# psmux keeps ONE session option store (there is no per session table), so
# `show -t s` prints the global session listing where tmux prints nothing. That
# is a storage model difference, not this listing bug, and is left alone.
#
# Usage: pwsh -NoProfile -File tests\test_issue655_show_options_window_listing.ps1
#        pwsh -NoProfile -File tests\test_issue655_show_options_window_listing.ps1 -Binary <path>

param([string]$Binary = "")

$ErrorActionPreference = "Continue"

$PSMUX = ""
if ($Binary) { $PSMUX = (Resolve-Path $Binary -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

# A namespace of this suite's own so a parallel run cannot collide with it.
$NS        = "ns655"
$SESSION   = "s"
$PSMUX_DIR = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

# Run psmux with an exact argv (no shell re-tokenizing) and capture rc/out/err.
#
# The call operator, NOT Start-Process: a `Start-Process -NoNewWindow -Wait`
# against a psmux that starts a detached server never returns when this script
# is itself launched with `pwsh -File` and no console of its own, which hung the
# first version of this suite indefinitely.
function Invoke-Psmux([string[]]$ArgList) {
    $full = @('-L', $NS) + $ArgList
    $err = @()
    $raw = (& $PSMUX @full 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $err += "$_"; } else { $_ }
    }) -join "`n"
    $rc = $LASTEXITCODE
    [pscustomobject]@{
        rc    = $rc
        out   = "$raw".Trim()
        err   = ($err -join "`n").Trim()
        lines = @("$raw" -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    }
}

function Wait-SessionReady([string]$Name, [int]$TimeoutMs = 20000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $h = Invoke-Psmux @('has-session', '-t', $Name)
        if ($h.rc -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# Raw TCP straight at the server, bypassing the CLI entirely, so the server
# side listing is measured on its own.
function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $port = (Get-Content "$PSMUX_DIR\${NS}__$Session.port" -Raw).Trim()
        $key  = (Get-Content "$PSMUX_DIR\${NS}__$Session.key" -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $st = $tcp.GetStream()
        $st.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $key")
        if ($rd.ReadLine() -ne "OK") { $tcp.Close(); return @{ ok = $false; err = "AUTH_FAIL" } }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $tcp.Close()
        return @{ ok = $true; resp = ($lines -join "`n"); lines = @($lines | Where-Object { $_.Trim() -ne "" }) }
    } catch { return @{ ok = $false; err = $_.Exception.Message } }
}

$env:PSMUX_NO_WARM = "1"
Remove-Item Env:PSMUX_SESSION_NAME -ErrorAction SilentlyContinue
Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue

Write-Host "`n=== Issue #655: show-options -w prints the window's own table ===" -ForegroundColor Cyan
Write-Info "Binary:    $PSMUX"
Write-Info "Namespace: -L $NS"

Invoke-Psmux @('kill-server') | Out-Null
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------------------
# Setup: the reporter's exact session.
# ---------------------------------------------------------------------------
Invoke-Psmux @('new-session', '-d', '-s', $SESSION, '-n', 'zero') | Out-Null
if (-not (Wait-SessionReady $SESSION)) {
    Write-Fail "session '$SESSION' never came up"
    Invoke-Psmux @('kill-server') | Out-Null
    exit 1
}
Invoke-Psmux @('new-window', '-d', '-t', $SESSION, '-n', 'one') | Out-Null
Start-Sleep -Milliseconds 600
Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:zero", 'remain-on-exit', 'on') | Out-Null
Start-Sleep -Milliseconds 300

# The whole window table, for the counts below.
$WINDOW_TABLE = (Invoke-Psmux @('show-options', '-wg')).lines.Count
Write-Info "window table: $WINDOW_TABLE options"
if ($WINDOW_TABLE -ge 10) { Write-Pass "show -wg lists the whole window table ($WINDOW_TABLE options)" }
else { Write-Fail "show -wg listed only $WINDOW_TABLE options" }

# ---------------------------------------------------------------------------
# Arm 1: `show-options -w -t s:zero` prints the window's OWN table only.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 1] show-options -w -t s:zero (locals only)" -ForegroundColor Yellow

$z = Invoke-Psmux @('show-options', '-w', '-t', "${SESSION}:zero")
Write-Info "lines: $($z.lines.Count) -> $($z.lines -join ' | ')"
if ($z.lines -contains 'remain-on-exit on') { Write-Pass "the local override is listed plain" }
else { Write-Fail "show -w -t s:zero lost the local override: [$($z.out)]" }
if ($z.lines.Count -lt $WINDOW_TABLE) {
    Write-Pass "show -w -t s:zero prints $($z.lines.Count) lines, not the whole $WINDOW_TABLE option table"
} else {
    Write-Fail "BUG #655: show -w -t s:zero still printed the whole table ($($z.lines.Count) lines)"
}
$stray = @($z.lines | Where-Object { $_ -notmatch '^(remain-on-exit|automatic-rename) ' })
if ($stray.Count -eq 0) { Write-Pass "no inherited value leaked into the plain listing" }
else { Write-Fail "BUG #655: inherited values leaked: [$($stray -join ' | ')]" }
if ($z.out -notmatch '\*') { Write-Pass "a plain show -w never emits the * marker" }
else { Write-Fail "the * marker leaked into a plain show -w listing: [$($z.out)]" }
if ($z.rc -eq 0) { Write-Pass "show -w -t s:zero exits 0" } else { Write-Fail "rc=$($z.rc)" }

# ---------------------------------------------------------------------------
# Arm 2: a window with no local values prints nothing.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 2] show-options -w -t s:one (nothing of its own)" -ForegroundColor Yellow

$o = Invoke-Psmux @('show-options', '-w', '-t', "${SESSION}:one")
Write-Info "lines: $($o.lines.Count) -> $($o.lines -join ' | ')"
if ($o.lines -notcontains 'remain-on-exit off' -and $o.out -notmatch '(?m)^remain-on-exit') {
    Write-Pass "the inherited remain-on-exit is ABSENT from the plain listing (tmux parity)"
} else {
    Write-Fail "BUG #655: show -w -t s:one printed an inherited value: [$($o.out)]"
}
if ($o.lines.Count -lt $WINDOW_TABLE) {
    Write-Pass "show -w -t s:one prints $($o.lines.Count) lines, not the whole $WINDOW_TABLE option table"
} else {
    Write-Fail "BUG #655: show -w -t s:one still printed all $($o.lines.Count) window options"
}
if ($o.rc -eq 0) { Write-Pass "show -w -t s:one exits 0 even with nothing to print" }
else { Write-Fail "rc=$($o.rc) err=[$($o.err)]" }

# A window that owns NOTHING at all prints an empty listing.
Invoke-Psmux @('new-window', '-d', '-t', $SESSION) | Out-Null
Start-Sleep -Milliseconds 600
$auto = @(Invoke-Psmux @('list-windows', '-t', $SESSION, '-F', '#{window_index} #{window_name}')).lines |
    Select-Object -Last 1
$autoIdx = ("$auto" -split ' ')[0]
$bare = Invoke-Psmux @('show-options', '-w', '-t', "${SESSION}:$autoIdx")
Write-Info "auto named window ${SESSION}:$autoIdx lines: $($bare.lines.Count) -> $($bare.lines -join ' | ')"
if ($bare.lines.Count -eq 0) { Write-Pass "a window with no locals at all prints NOTHING" }
else { Write-Fail "BUG #655: an untouched window printed [$($bare.out)]" }
Invoke-Psmux @('kill-window', '-t', "${SESSION}:$autoIdx") | Out-Null
Start-Sleep -Milliseconds 400

# ---------------------------------------------------------------------------
# Arm 3: `-wA` is ONE merged window scope list.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 3] show-options -wA (one merged list)" -ForegroundColor Yellow

$ao = Invoke-Psmux @('show-options', '-wA', '-t', "${SESSION}:one")
$az = Invoke-Psmux @('show-options', '-wA', '-t', "${SESSION}:zero")
Write-Info "-wA -t one:  $($ao.lines.Count) lines"
Write-Info "-wA -t zero: $($az.lines.Count) lines"
if ($ao.lines.Count -eq $WINDOW_TABLE) {
    Write-Pass "-wA -t one prints exactly the $WINDOW_TABLE option window table"
} else {
    Write-Fail "BUG #655: -wA -t one printed $($ao.lines.Count) lines for a $WINDOW_TABLE option table"
}
if ($az.lines.Count -eq $WINDOW_TABLE) {
    Write-Pass "-wA -t zero prints exactly the $WINDOW_TABLE option window table"
} else {
    Write-Fail "BUG #655: -wA -t zero printed $($az.lines.Count) lines for a $WINDOW_TABLE option table"
}
if ($ao.out -match '(?m)^remain-on-exit\* off$') { Write-Pass "-A marks the INHERITED value with *" }
else { Write-Fail "-A missing the * inherited marker: [$($ao.out)]" }
if ($az.out -match '(?m)^remain-on-exit on$') { Write-Pass "-A leaves a window LOCAL value unmarked" }
else { Write-Fail "-A marked a local value: [$($az.out)]" }

# The 3.3.8 bug in one assertion: session options must not be appended.
$leaked = @('prefix', 'status-left', 'escape-time', 'default-shell', 'history-limit') |
    Where-Object { $ao.out -match "(?m)^$([regex]::Escape($_))\*? " }
if ($leaked.Count -eq 0) {
    Write-Pass "-wA appends NO session listing (no prefix/status-left/escape-time/default-shell)"
} else {
    Write-Fail "BUG #655: the session listing was appended to -wA: [$($leaked -join ', ')]"
}
# and the listing is the window table, in table order, exactly once each.
$aoNames = @($ao.lines | ForEach-Object { ($_ -split ' ')[0].TrimEnd('*') })
$dupes = @($aoNames | Group-Object | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -eq 0) { Write-Pass "every option appears exactly once under -wA" }
else { Write-Fail "BUG #655: -wA repeated [$($dupes.Name -join ', ')]" }
$gNames = @((Invoke-Psmux @('show-options', '-wg')).lines | ForEach-Object { ($_ -split ' ')[0] })
if (($aoNames -join ',') -eq ($gNames -join ',')) {
    Write-Pass "-wA prints the window table in the same order as -wg"
} else {
    Write-Fail "-wA order [$($aoNames -join ',')] != -wg order [$($gNames -join ',')]"
}

# ---------------------------------------------------------------------------
# Arm 4: `-wg` is the GLOBAL window table, not the current window.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 4] show-options -wg (the global window table)" -ForegroundColor Yellow

$g = Invoke-Psmux @('show-options', '-wg')
if ($g.out -match '(?m)^remain-on-exit off$') {
    Write-Pass "-wg reports the global off, not window zero's local on"
} else {
    Write-Fail "BUG #655: -wg reported the active window's value: [$(($g.lines | Where-Object { $_ -match 'remain-on-exit' }) -join ' | ')]"
}
if ($g.out -notmatch '\*') { Write-Pass "-wg marks nothing: the global table owns every entry" }
else { Write-Fail "the * marker leaked into a -wg listing" }
$gv = (Invoke-Psmux @('show-options', '-wg', '-v', 'remain-on-exit')).out
if ($gv -eq 'off') { Write-Pass "show -wg -v remain-on-exit = off (the global table)" }
else { Write-Fail "BUG #655: show -wg -v remain-on-exit = [$gv], expected off" }

# ---------------------------------------------------------------------------
# Arm 5: `-v <name>` keeps resolving through the parent (#321 must not regress).
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 5] the -v query still resolves" -ForegroundColor Yellow

$vz = (Invoke-Psmux @('show-options', '-w', '-v', 'remain-on-exit', '-t', "${SESSION}:zero")).out
$vo = (Invoke-Psmux @('show-options', '-w', '-v', 'remain-on-exit', '-t', "${SESSION}:one")).out
if ($vz -eq 'on') { Write-Pass "show -w -v remain-on-exit -t zero = on" }
else { Write-Fail "show -w -v -t zero = [$vz]" }
if ($vo -eq 'off') { Write-Pass "show -w -v remain-on-exit -t one = off (resolved, #321)" }
else { Write-Fail "show -w -v -t one = [$vo]" }
$vpbi = (Invoke-Psmux @('show-options', '-w', '-v', 'pane-base-index', '-t', $SESSION)).out
if ($vpbi -ne '') { Write-Pass "libtmux probe show -w -v pane-base-index still answers: $vpbi" }
else { Write-Fail "#321 REGRESSED: show -w -v pane-base-index is empty" }
$vfmt = (Invoke-Psmux @('show-options', '-w', '-v', 'window-status-format', '-t', "${SESSION}:one")).out
if ($vfmt -ne '') { Write-Pass "show -w -v window-status-format still answers on an unset window" }
else { Write-Fail "#321 REGRESSED: show -w -v window-status-format is empty" }

# ---------------------------------------------------------------------------
# Arm 6: an untargeted `-w` from a bare CLI is the session's current window.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 6] untargeted show-options -w" -ForegroundColor Yellow

Invoke-Psmux @('select-window', '-t', "${SESSION}:zero") | Out-Null
Start-Sleep -Milliseconds 300
$u = Invoke-Psmux @('show-options', '-w')
if ($u.out -match '(?m)^remain-on-exit on$') {
    Write-Pass "an untargeted -w reads the current window (zero), same as tmux"
} else {
    Write-Fail "untargeted -w: [$($u.out)]"
}
Invoke-Psmux @('select-window', '-t', "${SESSION}:one") | Out-Null
Start-Sleep -Milliseconds 300
$u2 = Invoke-Psmux @('show-options', '-w')
if ($u2.out -notmatch '(?m)^remain-on-exit') {
    Write-Pass "it follows the current window when that changes to one"
} else {
    Write-Fail "untargeted -w after select-window one: [$($u2.out)]"
}
Invoke-Psmux @('select-window', '-t', "${SESSION}:zero") | Out-Null
Start-Sleep -Milliseconds 300

# ---------------------------------------------------------------------------
# Arm 7: the pane scope prints by the same rule.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 7] show-options -p / -pA" -ForegroundColor Yellow

$p = Invoke-Psmux @('show-options', '-p', '-t', "${SESSION}:zero")
if ($p.lines.Count -eq 0) { Write-Pass "show -p on a pane that owns nothing prints nothing" }
else { Write-Fail "show -p printed [$($p.out)]" }
$pa = Invoke-Psmux @('show-options', '-pA', '-t', "${SESSION}:zero")
Write-Info "-pA lines: $($pa.lines.Count) -> $($pa.lines -join ' | ')"
if ($pa.out -match '(?m)^remain-on-exit\* on$') {
    Write-Pass "-pA adds the inherited remain-on-exit* on, taken from the WINDOW"
} else {
    Write-Fail "BUG #655: show -pA printed [$($pa.out)], expected remain-on-exit* on"
}
Invoke-Psmux @('set-option', '-p', '-t', "${SESSION}:zero", 'remain-on-exit', 'failed') | Out-Null
Start-Sleep -Milliseconds 300
$pl = Invoke-Psmux @('show-options', '-pA', '-t', "${SESSION}:zero")
if ($pl.out -match '(?m)^remain-on-exit failed$' -and $pl.out -notmatch '\*') {
    Write-Pass "a pane LOCAL value is listed plain and not duplicated by -A"
} else {
    Write-Fail "-pA with a pane local: [$($pl.out)]"
}
Invoke-Psmux @('set-option', '-p', '-u', '-t', "${SESSION}:zero", 'remain-on-exit') | Out-Null
Start-Sleep -Milliseconds 300

# ---------------------------------------------------------------------------
# Arm 8: the raw TCP route prints the same thing as the CLI.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 8] raw TCP (the server side listing on its own)" -ForegroundColor Yellow

$t1 = Send-TcpCommand -Session $SESSION -Command "show-options -w -t ${SESSION}:one"
if ($t1.ok) {
    if (@($t1.lines | Where-Object { $_ -match '^remain-on-exit' }).Count -eq 0) {
        Write-Pass "raw TCP show -w -t one omits the inherited value too"
    } else { Write-Fail "raw TCP show -w -t one: [$($t1.resp)]" }
} else { Write-Fail "raw TCP failed: $($t1.err)" }

$t2 = Send-TcpCommand -Session $SESSION -Command "show-options -wA -t ${SESSION}:one"
if ($t2.ok) {
    if ($t2.resp -match '(?m)^remain-on-exit\* off$' -and $t2.resp -notmatch '(?m)^prefix ') {
        Write-Pass "raw TCP show -wA is the merged window list with no session appendix"
    } else { Write-Fail "raw TCP show -wA: $($t2.lines.Count) lines [$($t2.resp)]" }
} else { Write-Fail "raw TCP failed: $($t2.err)" }

$t3 = Send-TcpCommand -Session $SESSION -Command "show-options -wg"
if ($t3.ok) {
    if ($t3.resp -match '(?m)^remain-on-exit off$') {
        Write-Pass "raw TCP show -wg is the global window table"
    } else { Write-Fail "raw TCP show -wg: [$($t3.resp)]" }
} else { Write-Fail "raw TCP failed: $($t3.err)" }

# ---------------------------------------------------------------------------
# Arm 9: the session and server scopes are untouched by this change.
# ---------------------------------------------------------------------------
Write-Host "`n[Arm 9] the other scopes still list what they listed" -ForegroundColor Yellow

$sess = Invoke-Psmux @('show-options', '-t', $SESSION)
$glob = Invoke-Psmux @('show-options', '-g')
if ($sess.lines.Count -gt 0 -and $sess.lines.Count -eq $glob.lines.Count) {
    Write-Pass "the session listing is unchanged ($($sess.lines.Count) lines; psmux has one session store)"
} else {
    Write-Fail "session listing $($sess.lines.Count) lines vs global $($glob.lines.Count)"
}
$srv = Invoke-Psmux @('show-options', '-s')
if ($srv.lines.Count -gt 0 -and $srv.lines.Count -lt $glob.lines.Count) {
    Write-Pass "the server listing is still narrowed to server options ($($srv.lines.Count) lines, #618)"
} else {
    Write-Fail "server listing: $($srv.lines.Count) lines"
}

# ---------------------------------------------------------------------------
# Teardown: this suite's namespace only.
# ---------------------------------------------------------------------------
Invoke-Psmux @('kill-server') | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n$('=' * 62)" -ForegroundColor Cyan
Write-Host "RESULTS  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" `
    -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $script:TestsFailed
