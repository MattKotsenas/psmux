# Issue #813: control mode
#   * set-buffer and paste-buffer answered `%error unknown command`. tmux runs
#     them (cmd-set-buffer.c, cmd-paste-buffer.c) and announces
#     %paste-buffer-changed / %paste-buffer-deleted.
#   * a failing command did not stop the rest of its line. tmux drops the
#     remaining commands of the list on error (cmd-queue.c cmdq_remove_group
#     after CMD_RETURN_ERROR), and an unknown command is a parse error that
#     runs nothing (control.c control_error: "parse error: ...").
# Plus the smaller differences listed in the issue:
#   * display-message -p '' prints an empty line (cmd-display-message.c).
#   * show-options -v @unset answers %error "invalid option: @unset".
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
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i813_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$ns = 'i813_' + [guid]::NewGuid().ToString('N').Substring(0, 8)

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

$psi = [System.Diagnostics.ProcessStartInfo]::new($PSMUX, "-L $ns -CC new-session -A -s demo")
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$out = Join-Path $work 'cc.out'; $err = Join-Path $work 'cc.err'
$p = [System.Diagnostics.Process]::Start($psi)
$fo = [System.IO.FileStream]::new($out, 'Create', 'Write', 'ReadWrite', 1)
$fe = [System.IO.FileStream]::new($err, 'Create', 'Write', 'ReadWrite', 1)
$t1 = $p.StandardOutput.BaseStream.CopyToAsync($fo, 1)
$t2 = $p.StandardError.BaseStream.CopyToAsync($fe, 1)

# Send one line, wait for $expect blocks, then settle so any extra block
# the line produces is collected too.
function Invoke-CC([string]$line, [int]$expect = 1, [int]$waitMs = 7000, [int]$settleMs = 0) {
    $before = (Get-Blocks $out).Count
    $p.StandardInput.Write("$line`n"); $p.StandardInput.Flush()
    Wait-Until { (Get-Blocks $out).Count -ge $before + $expect } $waitMs | Out-Null
    if ($settleMs -gt 0) { Start-Sleep -Milliseconds $settleMs }
    $all = Get-Blocks $out
    $new = @(); for ($i = $before; $i -lt $all.Count; $i++) { $new += $all[$i] }
    return , $new
}
function Desc($blocks) { return ($blocks | ForEach-Object { "$($_.End)[$($_.Body -join '|')]" }) -join ' ' }
function Pane-Text { return (& $PSMUX -L $ns capture-pane -p -t demo | Out-String) }

try {
    if (-not (Wait-Until { (Get-Lines $out | Where-Object { $_ -match '^%session-changed' }).Count -gt 0 } 10000)) {
        Write-Fail "-CC session did not start"; throw 'no session'
    }
    $pane = ((Invoke-CC "list-panes -F '#{pane_id}'")[0].Body | Select-Object -First 1).Trim()
    Write-Host "pane id: $pane"
    Wait-Until { (Pane-Text).Trim().Length -gt 0 } 10000 | Out-Null
    Start-Sleep -Milliseconds 1500

    Write-Host "`n[1] set-buffer and paste-buffer in control mode" -ForegroundColor Yellow
    $from = (Get-Lines $out).Count - 1
    $r = Invoke-CC "set-buffer -b 'mtpaste' `"echo from-buffer813`""
    if ($r.Count -eq 1 -and $r[0].End -eq 'end' -and $r[0].Body.Count -eq 0) { Write-Pass "set-buffer -> empty %end" } else { Write-Fail "set-buffer -> $(Desc $r)" }
    Wait-Until { (Get-Notes $from) -contains '%paste-buffer-changed mtpaste' } 2000 | Out-Null
    if ((Get-Notes $from) -contains '%paste-buffer-changed mtpaste') { Write-Pass "%paste-buffer-changed mtpaste" } else { Write-Fail "no %paste-buffer-changed mtpaste: $((Get-Notes $from) -join ' / ')" }
    $r = Invoke-CC "show-buffer -b mtpaste"
    if ($r[0].End -eq 'end' -and ($r[0].Body -join '|') -eq 'echo from-buffer813') { Write-Pass "show-buffer -b mtpaste -> 'echo from-buffer813'" } else { Write-Fail "show-buffer -> $(Desc $r)" }

    $from = (Get-Lines $out).Count - 1
    $r = Invoke-CC "paste-buffer -p -d -b 'mtpaste' -t '$pane'"
    if ($r.Count -eq 1 -and $r[0].End -eq 'end' -and $r[0].Body.Count -eq 0) { Write-Pass "paste-buffer -p -d -> empty %end" } else { Write-Fail "paste-buffer -> $(Desc $r)" }
    Wait-Until { (Get-Notes $from) -contains '%paste-buffer-deleted mtpaste' } 2000 | Out-Null
    if ((Get-Notes $from) -contains '%paste-buffer-deleted mtpaste') { Write-Pass "%paste-buffer-deleted mtpaste" } else { Write-Fail "no %paste-buffer-deleted mtpaste: $((Get-Notes $from) -join ' / ')" }
    Invoke-CC "send-keys -t '$pane' Enter" | Out-Null
    if (Wait-Until { (Pane-Text) -match '(?m)^from-buffer813\s*$' } 5000) { Write-Pass "pasted text ran 'echo from-buffer813'" } else { Write-Fail "pasted text did not run in the pane" }
    $r = Invoke-CC "show-buffer -b mtpaste"
    if ($r[0].End -eq 'error' -and ($r[0].Body -join '|') -eq 'no buffer mtpaste') { Write-Pass "-d deleted the buffer" } else { Write-Fail "buffer after -d -> $(Desc $r)" }
    $r = Invoke-CC "paste-buffer -b nosuch813 -t '$pane'"
    if ($r[0].End -eq 'error' -and ($r[0].Body -join '|') -eq 'no buffer nosuch813') { Write-Pass "paste-buffer of a missing buffer -> %error 'no buffer nosuch813'" } else { Write-Fail "paste-buffer missing -> $(Desc $r)" }
    $r = Invoke-CC "set-buffer -b keep813 abc ; set-buffer -a -b keep813 def ; show-buffer -b keep813" 3
    if ($r.Count -eq 3 -and ($r[2].Body -join '|') -eq 'abcdef') { Write-Pass "set-buffer -a appends (abcdef)" } else { Write-Fail "set-buffer -a -> $(Desc $r)" }
    $r = Invoke-CC "set-buffer -b keep813 -n renamed813 ; show-buffer -b renamed813" 2
    if ($r.Count -eq 2 -and $r[0].End -eq 'end' -and ($r[1].Body -join '|') -eq 'abcdef') { Write-Pass "set-buffer -n renames" } else { Write-Fail "set-buffer -n -> $(Desc $r)" }
    $r = Invoke-CC "delete-buffer -b renamed813"
    if ($r[0].End -eq 'end') { Write-Pass "delete-buffer -> %end" } else { Write-Fail "delete-buffer -> $(Desc $r)" }

    Write-Host "`n[2] a failing command stops the rest of its line" -ForegroundColor Yellow
    $r = Invoke-CC "display-message -p 'a' ; kill-pane -t '%99' ; display-message -p 'c-after-runtime-failure'" 2 7000 800
    if ($r.Count -eq 2 -and $r[0].End -eq 'end' -and ($r[0].Body -join '|') -eq 'a' -and $r[1].End -eq 'error' -and ($r[1].Body -join '|') -match "can't find pane: %99") { Write-Pass "runtime failure -> end[a] error[can't find pane: %99], rest skipped" }
    else { Write-Fail "runtime failure -> $(Desc $r)" }
    $r = Invoke-CC "display-message -p 'a' ; bogus-cmd ; display-message -p 'c-after-parse-failure'" 1 7000 800
    if ($r.Count -eq 1 -and $r[0].End -eq 'error' -and ($r[0].Body -join '|') -eq 'parse error: unknown command: bogus-cmd') { Write-Pass "unknown command -> one %error 'parse error: unknown command: bogus-cmd', nothing runs" }
    else { Write-Fail "parse failure -> $(Desc $r)" }
    $r = Invoke-CC "set-buffer -b guard813 x ; kill-pane -t '%99' ; delete-buffer -b guard813" 2 7000 800
    $r2 = Invoke-CC "show-buffer -b guard813"
    if ($r.Count -eq 2 -and ($r2[0].Body -join '|') -eq 'x') { Write-Pass "command after the failure did not run (buffer kept)" } else { Write-Fail "after failure -> $(Desc $r) / $(Desc $r2)" }
    # A line that succeeds runs every command.
    $r = Invoke-CC "display-message -p 'x1' ; display-message -p 'x2' ; display-message -p 'x3'" 3 7000 300
    if ($r.Count -eq 3 -and (($r | ForEach-Object { $_.Body -join '' }) -join ',') -eq 'x1,x2,x3') { Write-Pass "a good line runs all three" } else { Write-Fail "good line -> $(Desc $r)" }
    $r = Invoke-CC "display-message -p 'still-alive'"
    if (($r[0].Body -join '') -eq 'still-alive') { Write-Pass "next line after the failures runs" } else { Write-Fail "next line -> $(Desc $r)" }

    Write-Host "`n[3] smaller differences" -ForegroundColor Yellow
    $r = Invoke-CC "display-message -p ''"
    if ($r[0].End -eq 'end' -and $r[0].Body.Count -eq 1 -and $r[0].Body[0] -eq '') { Write-Pass "display-message -p '' -> one empty line" } else { Write-Fail "display-message -p '' -> $(Desc $r)" }
    $r = Invoke-CC "show-options -v @unset_user_option813"
    if ($r[0].End -eq 'error' -and ($r[0].Body -join '|') -eq 'invalid option: @unset_user_option813') { Write-Pass "show-options -v @unset -> %error invalid option" } else { Write-Fail "show-options -v @unset -> $(Desc $r)" }
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
if ($script:TestsFailed -gt 0) { exit 1 } else { Remove-Item -Recurse -Force $work -EA SilentlyContinue; exit 0 }
