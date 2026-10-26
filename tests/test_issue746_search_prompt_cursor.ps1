# Issue #746: the copy-mode prompts on the status line draw no text cursor.
#
# The search prompt (`/` and `?`, `C-s` and `C-r`) and the copy-mode command
# prompt (`:` for goto line) live in the SERVER, so they reach the client as
# the status message string and nothing else. The cursor index is known on the
# server (`AppState.copy_prompt_back`), and the client knows how to put the
# terminal cursor on a prompt (#741), but the index is not on the wire, so the
# client has nothing to place. Since the line editor landed (discussion #694
# item 8) the keys move a cursor the user cannot see.
#
# tmux has no such split: every copy-mode prompt is a command-prompt
# (key-bindings.c:514 and :515 for search, :530 for goto line), drawn by
# status.c's prompt redraw with the cursor at `ax + start + pcursor - offset`
# (status.c:922 to :948) and settled by server-client.c:1797 to :1808.
#
# GROUND TRUTH: the Windows console cursor of the attached client process
# (GetConsoleScreenBufferInfo.dwCursorPosition and GetConsoleCursorInfo
# .bVisible), read by tests\cursorprobe.cs. The prompt row and the column its
# label ends at are found by scanning the console TEXT, not psmux geometry.
# Keys go through tests\injector.cs.
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

$NS   = "sp-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "sp"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_sp_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$PROBE = Join-Path $TMP "cursorprobe_sp.exe"
$INJ   = Join-Path $TMP "psmux_injector_sp.exe"
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

$CONF = Join-Path $TMP "sp.conf"
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

function Probe {
    $f = Join-Path $TMP ("probe_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
    Start-Process -FilePath $PROBE -ArgumentList "$($script:proc.Id)", "`"$f`"", "5", "80", "1" `
        -Wait -WindowStyle Hidden | Out-Null
    if (-not (Test-Path $f)) { return $null }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $f -Force -EA SilentlyContinue
    return $j
}

# The status row carrying a copy-mode prompt, located by its label. Returns
# @{ Row; Start; After; Line }: the row, the column the label starts at, and
# the column just past the label, which is where an empty prompt's cursor
# belongs.
function Find-StatusPrompt($screen, $label) {
    for ($i = 0; $i -lt $screen.Count; $i++) {
        $line = [string]$screen[$i]
        # The probe reports each row with its trailing blanks removed, so an
        # empty prompt's row ends at the label's own last character. Match on
        # the trimmed label and count the full one, space included, to find
        # where the input starts.
        $at = $line.IndexOf($label.TrimEnd())
        if ($at -ge 0) {
            return @{ Row = $i; Start = $at; After = $at + $label.Length; Line = $line }
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

# What the console holds, for a failure that needs more than a verdict.
function Dump($screen, $rows = 4) {
    $from = [Math]::Max(0, $screen.Count - $rows)
    for ($i = $from; $i -lt $screen.Count; $i++) {
        Write-Info ("row {0}: '{1}'" -f $i, ([string]$screen[$i]).TrimEnd())
    }
}

function Fmt($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }
function InMode { Fmt '#{pane_in_mode}' }

$SEARCH_LABEL = "(search down) "
$GOTO_LABEL   = "(goto line) "
# Four U+3042, which are 4 characters, 8 display columns and 12 UTF-8 bytes.
$WIDE4    = "{U:3042,3042,3042,3042}"
$WIDE4STR = [string]::new([char]0x3042, 4)

# -- Rig --

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

function Enter-CopyMode {
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 800
    return ((InMode) -eq "1")
}

function Leave-CopyMode {
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 500
}

function Open-SearchPrompt {
    if (-not (Keys "/")) { return $null }
    for ($i = 0; $i -lt 10; $i++) {
        $pr = Probe
        $sp = Find-StatusPrompt $pr.screen $SEARCH_LABEL
        if ($sp) { return @{ Probe = $pr; Prompt = $sp } }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# -- Test 1: the empty search prompt puts its cursor right after the label --
Write-Head "Test 1: the empty search prompt owns the cursor"
if (-not (Enter-CopyMode)) {
    Write-Fail "pane did not enter copy mode"
} else {
    $o = Open-SearchPrompt
    if (-not $o) {
        if ($script:InjectorBlocked) { Write-Skip "injector blocked: $($script:InjectorBlocked)" }
        else {
            Write-Fail "the search prompt never appeared on the status line"
            $d = Probe; if ($d) { Dump $d.screen 4; Write-Info "pane_in_mode = $(InMode)" }
        }
    } else {
        $sp = $o.Prompt; $pr = $o.Probe
        Write-Info "status row $($sp.Row), label at col $($sp.Start), input starts at col $($sp.After)"
        Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)) visible $($pr.visible)/$($pr.samples)"
        if ($pr.visible -eq $pr.samples) { Write-Pass "cursor visible in every sample with the prompt open" }
        else { Write-Fail "cursor hidden with the prompt open: visible $($pr.visible)/$($pr.samples)" }
        if ($pr.cursorY -eq $sp.Row -and $pr.cursorX -eq $sp.After) {
            Write-Pass "cursor sits on the status row where the input starts (col $($pr.cursorX))"
        } else {
            Write-Fail "cursor is at ($($pr.cursorX),$($pr.cursorY)), expected ($($sp.After),$($sp.Row)) in the prompt"
        }

        # -- Test 2: typed text moves the cursor by its display width --
        Write-Head "Test 2: four U+3042 move the cursor 8 columns, not 4 or 12"
        if (Keys $WIDE4) {
            $pr = Probe; $sp = Find-StatusPrompt $pr.screen $SEARCH_LABEL
            if ($sp -and $sp.Line.Contains($SEARCH_LABEL + $WIDE4STR)) {
                Write-Pass "the four characters are on the status row"
            } else {
                Write-Fail "typed text not found on the status row: '$($sp.Line)'"
            }
            $rel = $pr.cursorX - $sp.After
            Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns into the input (4 characters, 8 columns, 12 bytes)"
            if ($pr.cursorY -eq $sp.Row -and $rel -eq 8) { Write-Pass "cursor 8 columns in, right after the text" }
            else { Write-Fail "cursor $rel columns in on row $($pr.cursorY), expected 8 on row $($sp.Row)" }

            # -- Test 3: Left moves the cursor back one character --
            Write-Head "Test 3: Left moves back one character, which is two columns"
            if (Keys "{LEFT}") {
                $pr = Probe; $sp = Find-StatusPrompt $pr.screen $SEARCH_LABEL
                $rel = $pr.cursorX - $sp.After
                Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns into the input"
                if ($pr.cursorY -eq $sp.Row -and $rel -eq 6) { Write-Pass "cursor 6 columns in after one Left" }
                else { Write-Fail "cursor $rel columns in, expected 6" }
            } else { Write-Skip "injection not delivered" }

            # -- Test 4: Home puts the cursor at the start of the input --
            Write-Head "Test 4: Home puts the cursor where the input starts"
            if (Keys "{HOME}") {
                $pr = Probe; $sp = Find-StatusPrompt $pr.screen $SEARCH_LABEL
                $rel = $pr.cursorX - $sp.After
                Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns into the input"
                if ($pr.cursorY -eq $sp.Row -and $rel -eq 0) { Write-Pass "cursor at the start of the input" }
                else { Write-Fail "cursor $rel columns in, expected 0" }
            } else { Write-Skip "injection not delivered" }
        } else { Write-Skip "injection not delivered" }

        # -- Test 5: Escape closes the prompt and the status line goes back --
        Write-Head "Test 5: Escape closes the prompt"
        Keys "{ESC}" | Out-Null
        Start-Sleep -Milliseconds 400
        $after = Probe
        if ($null -eq (Find-StatusPrompt $after.screen $SEARCH_LABEL)) { Write-Pass "prompt gone from the status line" }
        else { Write-Fail "prompt still on the status line after Escape" }
    }
    Leave-CopyMode
}

# -- Test 6: the copy-mode command prompt gets a cursor too --
Write-Head "Test 6: the copy-mode (goto line) prompt owns the cursor"
if (-not (Enter-CopyMode)) {
    Write-Fail "pane did not enter copy mode for the goto line prompt"
} else {
    if (Keys ":") {
        $pr = Probe
        $sp = Find-StatusPrompt $pr.screen $GOTO_LABEL
        if (-not $sp) {
            Write-Fail "the (goto line) prompt never appeared on the status line"
            Dump $pr.screen 4
        } else {
            Write-Info "status row $($sp.Row), input starts at col $($sp.After)"
            if ($pr.cursorY -eq $sp.Row -and $pr.cursorX -eq $sp.After) {
                Write-Pass "cursor sits where the input starts (col $($pr.cursorX))"
            } else {
                Write-Fail "cursor is at ($($pr.cursorX),$($pr.cursorY)), expected ($($sp.After),$($sp.Row))"
            }
            if (Keys "12") {
                $pr = Probe; $sp = Find-StatusPrompt $pr.screen $GOTO_LABEL
                $rel = $pr.cursorX - $sp.After
                Write-Info "cursor ($($pr.cursorX),$($pr.cursorY)), $rel columns into the input"
                if ($pr.cursorY -eq $sp.Row -and $rel -eq 2) { Write-Pass "cursor 2 columns in after typing 12" }
                else { Write-Fail "cursor $rel columns in, expected 2" }
            } else { Write-Skip "injection not delivered" }
            Keys "{ESC}" | Out-Null
        }
    } else { Write-Skip "injection not delivered" }
    Leave-CopyMode
}

# -- Cleanup --
Kill-Rig
$defaultAfter = ((& $PSMUX ls 2>&1) -join "`n")
if ($defaultAfter -ne $defaultBefore) { Write-Fail "the default namespace session list changed during the test" }
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed, $($script:Skipped) skipped ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
