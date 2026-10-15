# Issue #827: three control mode differences from tmux.
# 1. #{pane_tabs} was empty. tmux lists the pane's tab stops
#    (format.c format_cb_pane_tabs over wp->base.tabs; screen.c
#    screen_reset_tabs sets one every 8 columns from column 8).
# 2. select-layout with a full layout string from #{window_layout} landed
#    one cell off (29/70 came back 28/71). tmux layout_parse
#    (layout-custom.c) applies the cell sizes exactly.
# 3. copy-mode -t %N from a control client did not enter copy mode. tmux
#    (cmd-copy-mode.c) enters it on the target pane and control clients get
#    %pane-mode-changed on enter and on exit (control-notify.c).
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
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i827_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$ns = 'i827_' + [guid]::NewGuid().ToString('N').Substring(0, 8)

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

    Write-Host "`n[1] #{pane_tabs} lists the tab stops" -ForegroundColor Yellow
    $t = Get-One "display-message -p -t '$p1' '#{pane_width}|#{pane_tabs}'"
    $pw = [int]($t.Split('|')[0])
    $want = (@(for ($c = 8; $c -lt $pw; $c += 8) { $c }) -join ',')
    if ($t -eq "$pw|$want") { Write-Pass "pane_tabs -> '$($t.Split('|')[1])'" } else { Write-Fail "pane_tabs: want '$pw|$want', got '$t'" }

    Write-Host "`n[2] select-layout with a layout string reproduces it exactly" -ForegroundColor Yellow
    Invoke-CC "split-window -h -t '$p1'" | Out-Null
    Start-Sleep -Milliseconds 800
    Invoke-CC "resize-pane -t '$p1' -x 30" | Out-Null
    $lay = Get-One "display-message -p -t '$w' '#{window_layout}'"
    Invoke-CC "select-layout -t '$w' 'even-horizontal'" | Out-Null
    $even = Get-One "display-message -p -t '$w' '#{window_layout}'"
    $r = Invoke-CC "select-layout -t '$w' '$lay'"
    $lay2 = Get-One "display-message -p -t '$w' '#{window_layout}'"
    if ($r.Count -ge 1 -and $r[0].End -eq 'end' -and $lay2 -eq $lay -and $even -ne $lay) { Write-Pass "restored '$lay2'" } else { Write-Fail "saved '$lay', even '$even', restored '$lay2'" }
    $want1 = if ($lay -match '\{(\d+)x') { $Matches[1] } else { '?' }
    $pw1 = Get-One "display-message -p -t '$p1' '#{pane_width}'"
    if ($pw1 -eq $want1) { Write-Pass "pane $p1 width back to $want1" } else { Write-Fail "pane $p1 width $pw1, want $want1" }

    # A nested layout with an odd split, restored from a different arrangement.
    $p2 = Get-One "display-message -p -t '$w' '#{pane_id}'"
    Invoke-CC "split-window -v -t '$p2'" | Out-Null
    Start-Sleep -Milliseconds 800
    Invoke-CC "resize-pane -t '$p2' -y 7" | Out-Null
    Invoke-CC "resize-pane -t '$p1' -x 41" | Out-Null
    $lay = Get-One "display-message -p -t '$w' '#{window_layout}'"
    Invoke-CC "select-layout -t '$w' 'tiled'" | Out-Null
    Invoke-CC "select-layout -t '$w' '$lay'" | Out-Null
    $lay2 = Get-One "display-message -p -t '$w' '#{window_layout}'"
    if ($lay2 -eq $lay) { Write-Pass "nested restored '$lay2'" } else { Write-Fail "nested: saved '$lay', restored '$lay2'" }
    $sizes = (Invoke-CC "list-panes -t '$w' -F '#{pane_id}=#{pane_width}x#{pane_height}'")[0].Body -join ' '
    Write-Host "    panes: $sizes"
    # The pane sizes must be the cells of the layout string.
    $cells = @([regex]::Matches($lay, '(\d+)x(\d+),\d+,\d+,(\d+)') | ForEach-Object { "%$($_.Groups[3].Value)=$($_.Groups[1].Value)x$($_.Groups[2].Value)" })
    $miss = @($cells | Where-Object { $sizes -notmatch [regex]::Escape($_) })
    if ($miss.Count -eq 0) { Write-Pass "pane sizes match the layout cells" } else { Write-Fail "pane sizes '$sizes' miss $($miss -join ',')" }

    Write-Host "`n[3] copy-mode -t from a control client" -ForegroundColor Yellow
    # The target is the active pane here. A -t naming a pane that is not the
    # active one also left the active pane looking in copy mode on the
    # one-shot route before this fix; that per pane mode routing is #828.
    Invoke-CC "select-pane -t '$p1'" | Out-Null
    $from = (Get-Lines $out).Count - 1
    $r = Invoke-CC "copy-mode -t '$p1' ; display-message -p -t '$p1' 'cm-same-line #{pane_in_mode}'"
    $same = if ($r.Count -gt 0) { ($r | ForEach-Object { $_.Body }) -join ' ' } else { '' }
    if ($same.Trim() -eq 'cm-same-line 1') { Write-Pass "same line -> '$($same.Trim())'" } else { Write-Fail "same line -> '$same'" }
    $nx = Get-One "display-message -p -t '$p1' 'cm-next #{pane_in_mode} #{pane_mode}'"
    if ($nx -eq 'cm-next 1 copy-mode') { Write-Pass "next command -> '$nx'" } else { Write-Fail "next command -> '$nx'" }
    $other = Get-One "display-message -p -t '$p2' '#{pane_in_mode}'"
    if ($other -eq '0') { Write-Pass "the other pane $p2 is not in a mode" } else { Write-Fail "other pane $p2 in_mode=$other" }
    Wait-Until { (Get-Notes $from) -contains "%pane-mode-changed $p1" } 2000 | Out-Null
    if ((Get-Notes $from) -contains "%pane-mode-changed $p1") { Write-Pass "%pane-mode-changed $p1 on enter" } else { Write-Fail "no %pane-mode-changed $p1 on enter: $((Get-Notes $from) -join ' / ')" }
    $from = (Get-Lines $out).Count - 1
    $r = Invoke-CC "send-keys -t '$p1' -X cancel"
    if ($r.Count -ge 1 -and $r[0].End -eq 'end') { Write-Pass "send-keys -X cancel ok" } else { Write-Fail "send-keys -X cancel -> $($r[0].End) $($r[0].Body -join ' ')" }
    Wait-Until { (Get-Notes $from) -contains "%pane-mode-changed $p1" } 2000 | Out-Null
    if ((Get-Notes $from) -contains "%pane-mode-changed $p1") { Write-Pass "%pane-mode-changed $p1 on cancel" } else { Write-Fail "no %pane-mode-changed $p1 on cancel: $((Get-Notes $from) -join ' / ')" }
    $nx = Get-One "display-message -p -t '$p1' '#{pane_in_mode}'"
    if ($nx -eq '0') { Write-Pass "after cancel pane_in_mode 0" } else { Write-Fail "after cancel pane_in_mode $nx" }} catch {
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
