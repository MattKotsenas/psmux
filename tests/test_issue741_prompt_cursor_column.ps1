# Issue #741: the command-prompt cursor was drawn at a BYTE offset, not a
# display column, and in a pane that was not in copy mode the open prompt had
# no cursor at all.
#
# The prompt (prefix then `:`) keeps its cursor as a byte offset into the
# typed text, because the editing keys insert and remove whole characters by
# len_utf8 (#345). The draw added that offset to a screen column, so eight
# U+2500 box drawing characters (24 bytes, 8 columns) put the cursor 16
# columns past the text. And the post draw cursor settle handed the cursor to
# the pane whenever the pane reported one, overriding the prompt, so outside
# copy mode the prompt showed no cursor anywhere.
#
# tmux: status.c prompt redraw computes pcursor = utf8_strwidth(prompt_buffer,
# prompt_index) and scrolls by `offset` so the cursor stays inside the prompt;
# server-client.c server_client_reset_state puts the cursor on
# c->prompt_cursor whenever a prompt is open, and only otherwise on the pane.
#
# GROUND TRUTH: the Windows console cursor of the attached client process
# (GetConsoleScreenBufferInfo.dwCursorPosition and GetConsoleCursorInfo
# .bVisible), read by tests\cursorprobe.cs, which attaches to the client's
# console. That cell is what the user sees blinking. The prompt row and its
# ": " are located by scanning the console TEXT, not by psmux geometry code.
# Keys go through tests\injector.cs (WriteConsoleInput, {U:2500} injects the
# box drawing character as a KEY_EVENT with UnicodeChar set).
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0; $script:Skipped = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:Skipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ((& $PSMUX -V) -join ' ') -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$NS   = "pc741-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "pc"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_741_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$PROBE = Join-Path $TMP "cursorprobe741.exe"
$INJ   = Join-Path $TMP "psmux_injector_741.exe"
if ($csc -and (Test-Path $csc)) {
    & $csc /nologo /optimize /out:$PROBE (Join-Path $PSScriptRoot "cursorprobe.cs") 2>&1 | Out-Null
    & $csc /nologo /optimize /out:$INJ   (Join-Path $PSScriptRoot "injector.cs")    2>&1 | Out-Null
}
if (-not (Test-Path $PROBE) -or -not (Test-Path $INJ)) {
    Write-Fail "could not build tests\cursorprobe.cs or tests\injector.cs (csc.exe unavailable)"
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
. (Join-Path $PSScriptRoot "injector_guard.ps1")

# The default namespace must not change while this runs.
$defaultBefore = ((& $PSMUX ls 2>&1) -join "`n")

function Stop-Opened {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
}

function Kill-Rig {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Stop-Opened
    Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

$CONF = Join-Path $TMP "pc741.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi"
) | Set-Content -Path $CONF -Encoding ASCII

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX -WindowStyle Minimized `
        -ArgumentList "-f",$CONF,"-L",$NS,"new-session","-s",$SESS -PassThru
    $script:Opened += $p.Id
    $portFile = Join-Path $psmuxDir "${NS}__${SESS}.port"
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw).Trim()
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close()
                Start-Sleep -Milliseconds 2500
                return $p
            } catch {}
        }
    }
    return $null
}

# Ground truth console state of the attached client: cursor cell, visibility
# over a few samples, and the text of every row.
function Probe {
    $f = Join-Path $TMP ("probe_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
    Start-Process -FilePath $PROBE -ArgumentList "$($script:proc.Id)", "`"$f`"", "5", "80", "1" `
        -Wait -WindowStyle Hidden | Out-Null
    if (-not (Test-Path $f)) { return $null }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $f -Force -EA SilentlyContinue
    return $j
}

# The command prompt row: a bordered row whose content starts with ": ".
# Returns @{ Row; Colon; Right } (Colon = column of ':', Right = right border)
# or $null when no prompt is on screen.
function Find-Prompt($screen) {
    for ($i = 0; $i -lt $screen.Count; $i++) {
        $line = [string]$screen[$i]
        $m = [regex]::Match($line, "[\u2502|]: ")
        if ($m.Success) {
            $colon = $m.Index + 1
            $right = $line.IndexOf([char]0x2502, $colon)
            if ($right -lt 0) { $right = $line.IndexOf('|', $colon) }
            return @{ Row = $i; Colon = $colon; Right = $right; Line = $line }
        }
    }
    return $null
}

function Keys($k) {
    if (-not (Invoke-GuardedInjector -Injector $INJ -ClientPid $script:proc.Id -Keys $k -RequireDelivery)) {
        return $false
    }
    Start-Sleep -Milliseconds 700
    return $true
}

function Fmt($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }
function InMode { Fmt '#{pane_in_mode}' }

$BOX8 = "{U:2500,2500,2500,2500,2500,2500,2500,2500}"
$BOXSTR = [string]::new([char]0x2500, 8)

# ── Rig ──

Kill-Rig
$script:proc = Start-Attached
if (-not $script:proc) {
    Write-Fail "the attached client never came up"
    Kill-Rig; Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}

$base = Probe
if ($null -eq $base -or $base.error) {
    Write-Fail "cursor probe could not attach to the client console"
    Kill-Rig; Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
Write-Info "console $($base.bufW)x$($base.winBottom - $base.winTop + 1), pane cursor at ($($base.cursorX),$($base.cursorY)) visible $($base.visible)/$($base.samples)"

function Open-Prompt {
    if (-not (Keys "^b{SLEEP:300}:")) { return $null }
    for ($i = 0; $i -lt 10; $i++) {
        $pr = Probe
        $pp = Find-Prompt $pr.screen
        if ($pp) { return @{ Probe = $pr; Prompt = $pp } }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Close-Prompt { Keys "{ESC}" | Out-Null; Start-Sleep -Milliseconds 300 }

# ── Test 1: an open prompt owns the cursor in a pane NOT in copy mode ──
Write-Head "Test 1: normal pane, empty prompt shows its cursor after ': '"
$o = Open-Prompt
if (-not $o) {
    if ($script:InjectorBlocked) { Write-Skip "injector blocked: $($script:InjectorBlocked)" }
    else { Write-Fail "the command prompt never appeared on the console" }
} else {
    $pp = $o.Prompt; $pr = $o.Probe
    Write-Info "prompt row $($pp.Row), ':' at col $($pp.Colon), right border col $($pp.Right)"
    Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)) visible $($pr.visible)/$($pr.samples)"
    if ($pr.visible -eq $pr.samples) { Write-Pass "cursor visible in every sample with the prompt open" }
    else { Write-Fail "cursor hidden with the prompt open: visible $($pr.visible)/$($pr.samples)" }
    if ($pr.cursorY -eq $pp.Row -and $pr.cursorX -eq $pp.Colon + 2) {
        Write-Pass "cursor sits on the prompt row right after ': ' (col $($pr.cursorX))"
    } else {
        Write-Fail "cursor is at ($($pr.cursorX),$($pr.cursorY)), expected ($($pp.Colon + 2),$($pp.Row)) in the prompt"
    }

    # ── Test 2: eight box drawing characters, cursor 8 columns in ──
    Write-Head "Test 2: normal pane, eight U+2500 put the cursor 8 columns past ': '"
    if (Keys $BOX8) {
        $pr = Probe; $pp = Find-Prompt $pr.screen
        if ($pp -and $pp.Line.Contains(": $BOXSTR")) { Write-Pass "the eight box drawing characters are on the prompt row" }
        else { Write-Fail "typed text not found on the prompt row: '$($pp.Line)'" }
        $rel = $pr.cursorX - ($pp.Colon + 2)
        Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns past ': ' (text is 8 columns, 24 bytes)"
        if ($pr.cursorY -eq $pp.Row -and $rel -eq 8) { Write-Pass "cursor at column 8 past ': ', right after the text" }
        else { Write-Fail "cursor $rel columns past ': ' on row $($pr.cursorY), expected 8 on row $($pp.Row)" }
    } else { Write-Skip "injection not delivered" }
    Close-Prompt

    # ── Test 3: closing the prompt hands the cursor back to the pane ──
    Write-Head "Test 3: Esc gives the cursor back to the pane"
    $back = Probe
    if ($null -eq (Find-Prompt $back.screen)) { Write-Pass "prompt closed" } else { Write-Fail "prompt still on screen after Esc" }
    if ($back.cursorX -eq $base.cursorX -and $back.cursorY -eq $base.cursorY -and $back.visible -eq $back.samples) {
        Write-Pass "cursor back at the pane's ($($base.cursorX),$($base.cursorY)), visible"
    } else {
        Write-Fail "cursor at ($($back.cursorX),$($back.cursorY)) visible $($back.visible)/$($back.samples), expected the pane's ($($base.cursorX),$($base.cursorY))"
    }
}

# ── Test 4: in copy mode (where master did show a prompt cursor) ──
Write-Head "Test 4: copy mode pane, eight U+2500 put the cursor 8 columns past ': '"
P copy-mode -t $SESS | Out-Null
Start-Sleep -Milliseconds 800
if ((InMode) -ne "1") { Write-Fail "pane did not enter copy mode" }
else {
    $o = Open-Prompt
    if (-not $o) { Write-Fail "the command prompt never appeared in copy mode" }
    elseif (Keys $BOX8) {
        $pr = Probe; $pp = Find-Prompt $pr.screen
        $rel = $pr.cursorX - ($pp.Colon + 2)
        Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns past ': '"
        if ($pr.cursorY -eq $pp.Row -and $rel -eq 8) { Write-Pass "cursor at column 8 past ': ' (not the 24 byte offset)" }
        else { Write-Fail "cursor $rel columns past ': ' on row $($pr.cursorY), expected 8 on row $($pp.Row)" }
        Close-Prompt
    } else { Write-Skip "injection not delivered" }
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 500
}

# ── Test 5: a long input scrolls and the cursor stays inside the box ──
Write-Head "Test 5: a prompt longer than the box keeps the cursor inside it"
$o = Open-Prompt
if (-not $o) { Write-Fail "the command prompt never appeared" }
else {
    $inner = $o.Prompt.Right - ($o.Prompt.Colon + 2)
    Write-Info "room after ': ' = $inner columns"
    $long = ""
    $n = $inner + 20
    for ($i = 0; $i -lt $n; $i++) { $long += [char](97 + ($i % 26)) }
    if (Keys $long) {
        Start-Sleep -Milliseconds 500
        $pr = Probe; $pp = Find-Prompt $pr.screen
        Write-Info "typed $n characters; cursor ($($pr.cursorX),$($pr.cursorY)), right border col $($pp.Right)"
        Write-Info "row: '$($pp.Line)'"
        if ($pr.cursorY -eq $pp.Row -and $pr.cursorX -gt $pp.Colon + 1 -and $pr.cursorX -lt $pp.Right) {
            Write-Pass "cursor inside the prompt box"
        } else { Write-Fail "cursor ($($pr.cursorX),$($pr.cursorY)) is outside the prompt box" }
        $tail = $long.Substring($long.Length - 10)
        $before = $pp.Line.Substring(0, [Math]::Min($pr.cursorX, $pp.Line.Length))
        if ($before.EndsWith($tail)) { Write-Pass "the last ten typed characters end right at the cursor" }
        else { Write-Fail "the text before the cursor does not end with '$tail': '$before'" }
    } else { Write-Skip "injection not delivered" }
    Close-Prompt
}

# ── Cleanup ──
Kill-Rig
$defaultAfter = ((& $PSMUX ls 2>&1) -join "`n")
if ($defaultAfter -ne $defaultBefore) { Write-Fail "the default namespace session list changed during the test" }
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed, $($script:Skipped) skipped ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
