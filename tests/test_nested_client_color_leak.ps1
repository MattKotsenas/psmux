# Follow-up to #537: a psmux client attached from inside psmux leaked OSC color
# query REPLIES into the session it attached to, as typed text:
#
#   PS C:\...> ]10;rgb:cccc/cccc/cccc\]11;rgb:0c0c/0c0c/0c0c\]4;0;rgb:...
#   rgb:3b3b/7878/ffff\]4: The term 'rgb:3b3b/7878/ffff\]4' is not recognized...
#
# The nested client issues the OSC 10/11/4 startup burst at its terminal, which
# IS psmux. psmux answers by injecting the replies as console KEY_EVENT records
# on a later server tick, after the client's 500ms drain window has closed (it
# never answers the DA1 sentinel that would end the drain early), so the client's
# input pump reads the leftovers as keystrokes and forwards them to the attached
# session.
#
# Parts:
#   A: control, a plain non nested attach must stay clean (it always did)
#   B: nested attach from a real pane, the long standing path (PSMUX_ALLOW_NESTING)
#   C: nested attach from a display-popup, the #537 path
#   D: the palette still survives one level of nesting (fix must not just mute it)
#   E: Win32 TUI visual verification on a real visible window

$ErrorActionPreference = "Continue"
# PSMUX_TEST_EXE lets an A/B run point the whole suite at one specific build
# (same contract as tests/test_issue626_border_attrs_default.ps1), which is the
# only way to tell a real regression from a stale install.
$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -EA Stop).Source }
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    foreach ($s in @("clkhost","clktgt","clkpop","clktui","clkplain")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\clk*" -Force -EA SilentlyContinue
}

# Returns the garbage found in a session's visible pane, if any.
function Get-LeakedJunk {
    param([string]$Session)
    $cap = (& $PSMUX capture-pane -t $Session -p 2>&1 | Out-String)
    $hits = [regex]::Matches($cap, "rgb:[0-9a-f]{2,4}/[0-9a-f]{2,4}/[0-9a-f]{2,4}")
    return @{
        Junk  = ($hits.Count -gt 0 -or $cap -match "\]10;rgb|\]11;rgb|\]4;\d+;rgb")
        Count = $hits.Count
        Text  = (($cap -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join " / ")
    }
}

function Wait-Attached {
    param([string]$Session, [int]$TimeoutMs = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $a = (& $PSMUX display-message -t $Session -p '#{session_attached}' 2>&1 | Out-String).Trim()
        if ($a -eq "1") { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

Write-Host "`n=== Nested client OSC color reply leak ===" -ForegroundColor Cyan
Cleanup

# A server remembers the last palette a client reported in ~/.psmux/host_colors
# so its spares are born with it (paths::host_colors_file). The planted
# PSMUX_HOST_COLORS below is reported like a measurement, so without this the
# suite left fg=112233 there for every later session on the machine, and a
# terminal that never answers was handed it as its palette. Kept and put back.
$hostColorsFile = Join-Path $psmuxDir "host_colors"
$hostColorsSaved = if (Test-Path -LiteralPath $hostColorsFile) { [IO.File]::ReadAllText($hostColorsFile) } else { $null }

# ── PART A: control, plain attach with no psmux around the client ──────────
Write-Host "`n[Part A] control: plain (non nested) attach stays clean" -ForegroundColor Yellow
& $PSMUX new-session -d -s "clkplain" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "clkplain" "clear" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$plainProc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t","clkplain" -PassThru
Start-Sleep -Seconds 8
$a = Get-LeakedJunk "clkplain"
if (-not $a.Junk) { Write-Pass "plain attach left no escape garbage in the pane" }
else { Write-Fail "control is dirty, the leak is not nesting specific: $($a.Text)" }
try { Stop-Process -Id $plainProc.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX kill-session -t "clkplain" 2>&1 | Out-Null
Start-Sleep -Seconds 2

# ── SETUP for the nested parts: one attached host session ──────────────────
$hostProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","clkhost" -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t "clkhost" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "host session did not start"; exit 1 }

# ── PART B: nested attach from a real pane (PSMUX_ALLOW_NESTING path) ──────
Write-Host "`n[Part B] nested attach from a real pane" -ForegroundColor Yellow
& $PSMUX new-session -d -s "clktgt" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "clktgt" "clear" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

& $PSMUX send-keys -t "clkhost" "`$env:PSMUX_ALLOW_NESTING='1'; & '$PSMUX' attach -t clktgt" Enter 2>&1 | Out-Null
if (Wait-Attached "clktgt") { Write-Pass "nested client attached to the target session" }
else { Write-Fail "nested client never attached, cannot judge the leak" }
Start-Sleep -Seconds 6

$b = Get-LeakedJunk "clktgt"
if (-not $b.Junk) { Write-Pass "no OSC reply garbage typed into the target session" }
else { Write-Fail "LEAK: $($b.Count) rgb replies landed in the target pane: $($b.Text)" }

# The shell in the target must not have been fed a bogus command either.
$capB = (& $PSMUX capture-pane -t "clktgt" -p 2>&1 | Out-String)
if ($capB -notmatch "not recognized as a name of a cmdlet") { Write-Pass "target shell was not fed a bogus command" }
else { Write-Fail "target shell tried to execute leaked escape text" }

& $PSMUX kill-session -t "clktgt" 2>&1 | Out-Null
Start-Sleep -Seconds 3

# ── PART C: nested attach from a display-popup (the #537 path) ─────────────
Write-Host "`n[Part C] nested attach from a display-popup" -ForegroundColor Yellow
& $PSMUX new-session -d -s "clkpop" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "clkpop" "clear" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

Start-Job -ScriptBlock { param($p,$s,$t) & $p display-popup -t $s -E "$p attach -t $t" 2>&1 } `
    -ArgumentList $PSMUX,"clkhost","clkpop" | Out-Null
if (Wait-Attached "clkpop") { Write-Pass "popup client attached to the target session" }
else { Write-Fail "popup client never attached, cannot judge the leak" }
Start-Sleep -Seconds 6

$c = Get-LeakedJunk "clkpop"
if (-not $c.Junk) { Write-Pass "popup attach left no OSC reply garbage in the target" }
else { Write-Fail "LEAK via popup: $($c.Count) rgb replies: $($c.Text)" }

Get-Job | Remove-Job -Force -EA SilentlyContinue
& $PSMUX kill-session -t "clkpop" 2>&1 | Out-Null
Start-Sleep -Seconds 3

# ── PART D: the palette must still cross one level of nesting ──────────────
# The fix must hand the parent's colors down, not merely silence the query.
Write-Host "`n[Part D] colors still reach a nested client" -ForegroundColor Yellow
& $PSMUX kill-session -t "clkhost" 2>&1 | Out-Null
try { Stop-Process -Id $hostProc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\clkhost.*" -Force -EA SilentlyContinue

$env:PSMUX_HOST_COLORS = "fg=112233,bg=445566,dark=0"
$hostProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","clkhost" -PassThru
Start-Sleep -Seconds 5
Remove-Item env:PSMUX_HOST_COLORS -EA SilentlyContinue

$envOut = "$env:TEMP\psmux_colorleak_env.txt"

# D1: a freshly spawned pane carries the parent's palette.
Remove-Item $envOut -Force -EA SilentlyContinue
& $PSMUX new-window -t "clkhost" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "clkhost" "`"[`$env:PSMUX_HOST_COLORS]`" | Set-Content '$envOut'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
$seen = if (Test-Path $envOut) { (Get-Content $envOut -Raw) } else { "" }
if ("$seen" -match "fg=112233" -and "$seen" -match "bg=445566") {
    Write-Pass "freshly spawned pane inherits the parent's real palette"
} else {
    Write-Fail "pane child got '$("$seen".Trim())', expected the parent's fg/bg"
}

# D2: a popup child carries it too. This is the path #537 opened up, so it is
# the one that actually matters for a nested client.
Remove-Item $envOut -Force -EA SilentlyContinue
# Run a script FILE, never an inline command with nested quotes: a popup command
# that fails to parse never spawns, and an empty result then looks like a bug in
# the thing under test.
$dumpHelper = Join-Path $PSScriptRoot "helpers\dump_host_colors.ps1"
Start-Job -ScriptBlock { param($p,$s,$h,$o)
    & $p display-popup -t $s -E "pwsh -NoProfile -File $h $o" 2>&1
} -ArgumentList $PSMUX,"clkhost",$dumpHelper,$envOut | Out-Null
Start-Sleep -Seconds 10
$seenPop = if (Test-Path $envOut) { (Get-Content $envOut -Raw) } else { "" }
if ("$seenPop" -match "fg=112233" -and "$seenPop" -match "bg=445566") {
    Write-Pass "popup child inherits the parent's real palette"
} else {
    Write-Fail "popup child got '$("$seenPop".Trim())', expected the parent's fg/bg"
}
Get-Job | Remove-Job -Force -EA SilentlyContinue

# D3: the top-level client must STILL query its real terminal. Suppressing the
# query one step too eagerly (for example by keying off PSMUX_ACTIVE, which the
# client sets on itself before querying) would kill host-color detection for
# everyone while every leak check above still passed. With nothing planted in
# the environment, a pane child must therefore receive REAL measured colors.
#
# The host client MUST live in a terminal that answers OSC 10/11. A plain
# conhost window from Start-Process never answers (A/B proven: old and fixed
# binaries both measure nothing there), so this part launches inside Windows
# Terminal and is skipped when wt.exe is not installed.
Remove-Item $envOut -Force -EA SilentlyContinue
& $PSMUX kill-session -t "clkhost" 2>&1 | Out-Null
try { Stop-Process -Id $hostProc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Seconds 2
Remove-Item "$psmuxDir\clkhost.*" -Force -EA SilentlyContinue
Remove-Item env:PSMUX_HOST_COLORS -EA SilentlyContinue
# The planted palette above was remembered as this data root's guess; with it
# in place a host client that measured nothing would still hand the pane
# fg=112233 and this check would pass on a dead detector.
Remove-Item -LiteralPath $hostColorsFile -Force -EA SilentlyContinue

$wt = (Get-Command wt.exe -EA SilentlyContinue).Source
if ($wt) {
    Start-Process -FilePath $wt -ArgumentList "new-tab","--",$PSMUX,"new-session","-s","clkhost"
    $hostProc = $null
} else {
    Write-Host "  [SKIP] D3 needs Windows Terminal (conhost never answers OSC 10/11)" -ForegroundColor DarkYellow
    $hostProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","clkhost" -PassThru
}
Start-Sleep -Seconds 5
if ($wt) {
    & $PSMUX new-window -t "clkhost" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX send-keys -t "clkhost" "`"[`$env:PSMUX_HOST_COLORS]`" | Set-Content '$envOut'" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $measured = if (Test-Path $envOut) { (Get-Content $envOut -Raw) } else { "" }
    if ("$measured" -match "fg=[0-9a-f]{6}" -and "$measured" -match "bg=[0-9a-f]{6}" -and "$measured" -notmatch "112233|445566") {
        Write-Pass "top-level client still measures the real terminal ($("$measured".Trim()))"
    } else {
        Write-Fail "host-color detection is dead: pane child got '$("$measured".Trim())' with nothing planted"
    }
}

# NOTE (known, accepted limitation): the session's very FIRST pane is often
# transplanted from the warm pane pool, spawned ahead of time by a different
# server that never saw these colors, so it alone does not carry them. Verified
# directly: with PSMUX_NO_WARM=1 the first pane does carry them. A nested client
# started in a warm first pane simply gets no palette, which costs fidelity and
# not correctness. The leak this suite is about stays fixed there either way,
# which Parts B and C cover.

# ── PART E: Win32 TUI visual verification ─────────────────────────────────
Write-Host "`n[Part E] Win32 TUI visual verification" -ForegroundColor Yellow
$tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","clktui" -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t "clktui" 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: visible session launched" }
else { Write-Fail "TUI: session did not start" }

& $PSMUX new-session -d -s "clktgt" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "clktgt" "clear" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
Start-Job -ScriptBlock { param($p,$s,$t) & $p display-popup -t $s -E "$p attach -t $t" 2>&1 } `
    -ArgumentList $PSMUX,"clktui","clktgt" | Out-Null
$null = Wait-Attached "clktgt"
Start-Sleep -Seconds 5

$e = Get-LeakedJunk "clktgt"
if (-not $e.Junk) { Write-Pass "TUI: popup attach on a real window left the target clean" }
else { Write-Fail "TUI: leak on the real window: $($e.Text)" }

# The host TUI must still be usable while the popup holds a client.
& $PSMUX split-window -v -t "clktui" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panes = (& $PSMUX display-message -t "clktui" -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: host session still responds (split -> 2 panes)" }
else { Write-Fail "TUI: host unresponsive, window_panes='$panes'" }

Get-Job | Remove-Job -Force -EA SilentlyContinue
try { Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue } catch {}
try { Stop-Process -Id $hostProc.Id -Force -EA SilentlyContinue } catch {}
Cleanup
Remove-Item "$env:TEMP\psmux_colorleak_env.txt" -Force -EA SilentlyContinue
if ($null -ne $hostColorsSaved) { [IO.File]::WriteAllText($hostColorsFile, $hostColorsSaved) }
else { Remove-Item -LiteralPath $hostColorsFile -Force -EA SilentlyContinue }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
