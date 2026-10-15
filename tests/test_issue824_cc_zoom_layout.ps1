# Issue #824: in control mode a zoomed window was not reported. After
# `resize-pane -Z`, `%layout-change` carried flags `*` without `Z`, and both
# #{window_layout} and #{window_visible_layout} were the split with the other
# pane squeezed to 2 columns.
#
# tmux: window_zoom (window.c) keeps the real split in saved_layout_root and
# makes layout_root a single cell for the zoomed pane. #{window_layout} dumps
# saved_layout_root when set, #{window_visible_layout} dumps layout_root
# (format.c format_cb_window_layout / format_cb_window_visible_layout), and
# %layout-change sends "#{window_id} #{window_layout} #{window_visible_layout}
# #{window_raw_flags}" (control-notify.c control_window_layout_changed_cb).
#
# Drives a real `psmux -L <ns> -CC new-session -A -s demo` over pipes.
# Private -L namespace, cleaned up with `psmux -L <ns> kill-server` only.

$ErrorActionPreference = 'Continue'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "psmux: $PSMUX ($(& $PSMUX -V))"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i824_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$ns = 'i824_' + [guid]::NewGuid().ToString('N').Substring(0, 8)

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
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 20 }
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
        if ($i -ge $from -and $l -match '^%') { $notes += $l }
    }
    return , $notes
}
# tmux layout_checksum (layout-custom.c).
function Get-LayoutChecksum([string]$s) {
    $csum = 0
    foreach ($c in $s.ToCharArray()) { $csum = (($csum -shr 1) + (($csum -band 1) -shl 15)) -band 0xffff; $csum = ($csum + [int]$c) -band 0xffff }
    return ('{0:x4}' -f $csum)
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

function Invoke-CC([string]$line, [int]$expect = 1, [int]$waitMs = 7000) {
    $before = (Get-Blocks $out).Count
    $p.StandardInput.Write("$line`n"); $p.StandardInput.Flush()
    Wait-Until { (Get-Blocks $out).Count -ge $before + $expect } $waitMs | Out-Null
    $all = Get-Blocks $out
    $new = @(); for ($i = $before; $i -lt $all.Count; $i++) { $new += $all[$i] }
    return , $new
}
function Get-One([string]$line) { $b = Invoke-CC $line; if ($b.Count -gt 0 -and $b[0].Body.Count -gt 0) { return "$($b[0].Body[0])".Trim() }; return '' }
function Invoke-Notes([string]$line, [scriptblock]$until, [int]$waitMs = 3000) {
    $from = (Get-Lines $out).Count - 1
    $r = Invoke-CC $line
    Wait-Until { & $until (Get-Notes $from) } $waitMs | Out-Null
    Start-Sleep -Milliseconds 400
    return [pscustomobject]@{ Blocks = $r; Notes = (Get-Notes $from) }
}

try {
    if (-not (Wait-Until { (Get-Lines $out | Where-Object { $_ -match '^%session-changed' }).Count -gt 0 } 10000)) {
        Write-Fail "-CC session did not start"; throw 'no session'
    }
    $ids = (Get-One "display-message -p '#{window_id} #{pane_id}'") -split ' '
    $w = $ids[0]; $p1 = $ids[1]
    Invoke-CC "split-window -h -t '$p1'" | Out-Null
    Start-Sleep -Milliseconds 800
    $split = Get-One "display-message -p -t '$w' '#{window_layout}'"
    $wsz = Get-One "display-message -p -t '$w' '#{window_width}x#{window_height}'"
    Write-Host "window $w pane $p1 size $wsz split $split"
    if ($split -match '\{') { Write-Pass "split layout $split" } else { Write-Fail "no split layout: '$split'" }

    Write-Host "`n[1] resize-pane -Z sends the split, the zoomed pane alone, and Z" -ForegroundColor Yellow
    $r = Invoke-Notes "resize-pane -Z -t '$p1'" { param($n) ($n | Where-Object { $_ -match '^%layout-change ' }).Count -gt 0 }
    $lc = @($r.Notes | Where-Object { $_ -match '^%layout-change ' })
    $body = "$wsz,0,0,$($p1.TrimStart('%'))"
    $vis = "$(Get-LayoutChecksum $body),$body"
    $want = "%layout-change $w $split $vis *Z"
    if ($lc.Count -ge 1 -and $lc[-1] -eq $want) { Write-Pass "zoom -> '$($lc[-1])'" } else { Write-Fail "zoom: want '$want', got '$($lc -join ' / ')'" }

    $z = Get-One "display-message -p -t '$w' 'zz #{window_zoomed_flag} #{window_layout} #{window_visible_layout}'"
    if ($z -eq "zz 1 $split $vis") { Write-Pass "display-message while zoomed -> '$z'" } else { Write-Fail "display-message while zoomed: want 'zz 1 $split $vis', got '$z'" }
    $lw = Get-One "list-windows -F '#{window_id} #{window_zoomed_flag} #{window_layout} #{window_visible_layout} #{window_flags}'"
    if ($lw -eq "$w 1 $split $vis *Z") { Write-Pass "list-windows while zoomed -> '$lw'" } else { Write-Fail "list-windows while zoomed: want '$w 1 $split $vis *Z', got '$lw'" }
    $pw = Get-One "display-message -p -t '$p1' '#{pane_width}x#{pane_height}'"
    if ($pw -eq $wsz) { Write-Pass "zoomed pane is $pw" } else { Write-Fail "zoomed pane is $pw, want $wsz" }
    # The split made the new pane active; tmux window_zoom makes the zoomed
    # pane (-t) the active one.
    $act = Get-One "display-message -p -t '$w' '#{pane_id}'"
    if ($act -eq $p1) { Write-Pass "zoomed pane $p1 is the active pane" } else { Write-Fail "active pane while zoomed is $act, want $p1" }

    Write-Host "`n[2] unzoom sends the split again without Z" -ForegroundColor Yellow
    $r = Invoke-Notes "resize-pane -Z -t '$p1'" { param($n) ($n | Where-Object { $_ -match '^%layout-change ' }).Count -gt 0 }
    $lc = @($r.Notes | Where-Object { $_ -match '^%layout-change ' })
    $want = "%layout-change $w $split $split *"
    if ($lc.Count -ge 1 -and $lc[-1] -eq $want) { Write-Pass "unzoom -> '$($lc[-1])'" } else { Write-Fail "unzoom: want '$want', got '$($lc -join ' / ')'" }
    $after = Get-One "display-message -p -t '$w' '#{window_zoomed_flag} #{window_layout} #{window_visible_layout}'"
    if ($after -eq "0 $split $split") { Write-Pass "after unzoom -> '$after' (split restored exactly)" } else { Write-Fail "after unzoom: want '0 $split $split', got '$after'" }
} catch {
    if ("$_" -ne 'no session') { Write-Fail "exception: $_" }
} finally {
    & $PSMUX -L $ns kill-server 2>$null
    if (-not $p.WaitForExit(3000)) { try { $p.Kill() } catch {} }
    try { $t1.Wait(2000) | Out-Null; $t2.Wait(2000) | Out-Null } catch {}
    $fo.Close(); $fe.Close()
    if ($script:TestsFailed -gt 0) { Write-Host "`n-CC transcript: $out" }
}

Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
if ($script:TestsFailed -eq 0) { Remove-Item -Recurse -Force $work -EA SilentlyContinue }
exit $script:TestsFailed
