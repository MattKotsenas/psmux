# Issue #712: `psmux -CC` relay thread panicked on a server line longer than
# 200 bytes whose byte 200 falls inside a multi byte UTF-8 character. The
# client's debug logger sliced the line by bytes, the reader thread died, and
# the process stayed alive but silent: `%end` never arrived and later
# commands were never answered.
#
# This suite drives a real `psmux -CC attach` over pipes, the way an IDE
# integration does, and checks for each glyph class (2, 3 and 4 byte UTF-8,
# byte 200 inside a character and on a boundary):
#   1. `%begin`, the long line byte for byte (raw UTF-8, like tmux's
#      control_write), and `%end` all arrive for `capture-pane -p`
#   2. a following `display-message -p` is answered
#   3. after `kill-server` the -CC client prints exactly one `%exit` line
#      and EXITS within 3 seconds (tmux client.c: print %exit, then exit)
# Plus a stdin EOF case: closing stdin still prints one `%exit` and exits.
#
# Everything runs under a private -L namespace and is cleaned up with
# `psmux -L <ns> kill-server` only.

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -EA Stop).Source
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "psmux: $PSMUX ($(& $PSMUX -V))"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i712_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$nsBase = 'i712_' + [guid]::NewGuid().ToString('N').Substring(0, 6)

function Read-Shared([string]$path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $ms = [System.IO.MemoryStream]::new(); $fs.CopyTo($ms); $fs.Close()
        return , $ms.ToArray()
    } catch { return , [byte[]]@() }
}
function Get-Lines([string]$path) { return @($utf8.GetString((Read-Shared $path)) -split "`n") }
function Count-Prefix([string]$path, [string]$prefix) { return @(Get-Lines $path | Where-Object { $_.StartsWith($prefix) }).Count }
function Wait-Until([scriptblock]$cond, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
    return [bool](& $cond)
}

# Start a -CC client with piped stdio; stdout/stderr are copied raw to files.
function Start-CC([string]$ns, [string]$tag) {
    $out = Join-Path $work "$tag.out"; $err = Join-Path $work "$tag.err"
    $psi = [System.Diagnostics.ProcessStartInfo]::new($PSMUX, "-L $ns -CC attach -t s")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $fo = [System.IO.FileStream]::new($out, 'Create', 'Write', 'ReadWrite', 1)
    $fe = [System.IO.FileStream]::new($err, 'Create', 'Write', 'ReadWrite', 1)
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($fo, 1)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($fe, 1)
    return [pscustomobject]@{ P = $p; Out = $out; Err = $err; Fo = $fo; Fe = $fe; T1 = $t1; T2 = $t2 }
}
function Stop-CC($cc) {
    if (-not $cc.P.HasExited) { try { $cc.P.Kill() } catch {}; $cc.P.WaitForExit(3000) | Out-Null }
    try { $cc.T1.Wait(2000) | Out-Null; $cc.T2.Wait(2000) | Out-Null } catch {}
    $cc.Fo.Close(); $cc.Fe.Close()
}
function Send-CC($cc, [string]$cmd) { $cc.P.StandardInput.Write("$cmd`n"); $cc.P.StandardInput.Flush() }

function New-TestSession([string]$ns, [string]$text) {
    $fix = Join-Path $work "$ns.txt"
    [System.IO.File]::WriteAllText($fix, $text + "`n", $utf8)
    & $PSMUX -L $ns new-session -d -s s -x 320 -y 20
    if (-not (Wait-Until { & $PSMUX -L $ns has-session -t s 2>$null; $LASTEXITCODE -eq 0 } 8000)) { return $null }
    $paneId = (& $PSMUX -L $ns display-message -p -t s '#{pane_id}' | Out-String).Trim()
    & $PSMUX -L $ns send-keys -t s "cls; Get-Content -Encoding utf8 '$fix'" Enter
    $probe = $text.Substring(0, [Math]::Min(12, $text.Length))
    Wait-Until { (& $PSMUX -L $ns capture-pane -p -t s | Out-String).Contains($probe) } 10000 | Out-Null
    return $paneId
}

# name, ascii prefix, glyph (code point), count. Byte 200 = prefix + k*glyphbytes.
$cases = @(
    @{ Name = 'box 3 byte, byte 200 inside';      P = 0; Cp = 0x2500;  C = 100 }
    @{ Name = 'box 3 byte, byte 200 on boundary'; P = 2; Cp = 0x2500;  C = 100 }
    @{ Name = 'cyrillic 2 byte, inside';          P = 1; Cp = 0x0416;  C = 120 }
    @{ Name = 'cjk 3 byte, inside';               P = 1; Cp = 0x4E2D;  C = 90 }
    @{ Name = 'emoji 4 byte, inside';             P = 1; Cp = 0x1F600; C = 60 }
)

$i = 0
foreach ($case in $cases) {
    $i++
    $ns = "${nsBase}_$i"
    $glyph = [char]::ConvertFromUtf32($case.Cp)
    $line = ('a' * $case.P) + ($glyph * $case.C)
    Write-Host "`n[Case $i] $($case.Name) (line is $($utf8.GetByteCount($line)) bytes)" -ForegroundColor Yellow
    $paneId = New-TestSession $ns $line
    if (-not $paneId) { Write-Fail "session did not start"; & $PSMUX -L $ns kill-server 2>$null; continue }
    $cc = Start-CC $ns "case$i"
    try {
        Wait-Until { (Count-Prefix $cc.Out '%session-changed') -gt 0 } 5000 | Out-Null
        $endsBefore = Count-Prefix $cc.Out '%end'
        Send-CC $cc "capture-pane -p -t $paneId -S -"
        $gotEnd = Wait-Until { (Count-Prefix $cc.Out '%end') + (Count-Prefix $cc.Out '%error') -gt $endsBefore } 5000
        if ($gotEnd) { Write-Pass "%end arrived for capture-pane" } else { Write-Fail "%end never arrived for capture-pane" }
        # Byte exact: the raw UTF-8 bytes of the line must appear on stdout as a whole line.
        $raw = Read-Shared $cc.Out
        $needle = $utf8.GetBytes($line + "`n")
        $hay = [System.BitConverter]::ToString($raw); $pin = [System.BitConverter]::ToString($needle)
        if ($hay.Contains($pin)) { Write-Pass "long line arrived byte for byte as raw UTF-8" } else { Write-Fail "long line missing or altered on stdout" }
        Send-CC $cc "display-message -p ANSWER_712"
        if (Wait-Until { (Count-Prefix $cc.Out 'ANSWER_712') -gt 0 } 4000) { Write-Pass "later command answered" } else { Write-Fail "later command NOT answered (channel silent)" }
        # Server goes away: the client must report it and exit, not linger.
        & $PSMUX -L $ns kill-server 2>$null
        $exited = $cc.P.WaitForExit(3000)
        if ($exited) { Write-Pass "-CC client exited within 3 s of kill-server (code $($cc.P.ExitCode))" } else { Write-Fail "-CC client still running 3 s after kill-server" }
        Start-Sleep -Milliseconds 200
        $exits = @(Get-Lines $cc.Out | Where-Object { $_ -match '^%exit' })
        if ($exits.Count -eq 1) { Write-Pass "exactly one %exit line: '$($exits[0])'" } else { Write-Fail "expected one %exit line, got $($exits.Count): $($exits -join ' | ')" }
    } finally {
        Stop-CC $cc
        & $PSMUX -L $ns kill-server 2>$null
    }
    $errText = $utf8.GetString((Read-Shared $cc.Err))
    if ($errText -match 'panicked') { Write-Fail "client panicked: $($errText.Trim())" } else { Write-Pass "no panic on stderr" }
}

# stdin EOF path: closing stdin must still produce one %exit and a prompt exit.
$i++
$ns = "${nsBase}_$i"
Write-Host "`n[Case $i] stdin EOF ends the client with one %exit" -ForegroundColor Yellow
$paneId = New-TestSession $ns 'plain ascii'
if ($paneId) {
    $cc = Start-CC $ns "case$i"
    try {
        Wait-Until { (Count-Prefix $cc.Out '%session-changed') -gt 0 } 5000 | Out-Null
        $cc.P.StandardInput.Close()
        if ($cc.P.WaitForExit(5000)) { Write-Pass "client exited after stdin EOF" } else { Write-Fail "client still running 5 s after stdin EOF" }
        Start-Sleep -Milliseconds 200
        $exits = @(Get-Lines $cc.Out | Where-Object { $_ -match '^%exit' })
        if ($exits.Count -eq 1) { Write-Pass "exactly one %exit line: '$($exits[0])'" } else { Write-Fail "expected one %exit line, got $($exits.Count): $($exits -join ' | ')" }
        & $PSMUX -L $ns has-session -t s 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Pass "session survives the control client leaving" } else { Write-Fail "session died with the control client" }
    } finally {
        Stop-CC $cc
        & $PSMUX -L $ns kill-server 2>$null
    }
} else { Write-Fail "session did not start"; & $PSMUX -L $ns kill-server 2>$null }

Remove-Item -Recurse -Force $work -EA SilentlyContinue
Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
