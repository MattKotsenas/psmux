# Issue #226 (full proof): prove that Ctrl+/ vs Ctrl+o is handled
# correctly at every layer of psmux on Windows.
#
# Layers verified:
#   1. Windows console layer: WriteConsoleInput with VK=0xBF + char=0x1F
#      arrives in a crossterm reader as Char('/')+CONTROL, NOT Char('o').
#   2. psmux TUI prefix mode: prefix + Ctrl+/ does NOT trigger the
#      'o' binding (next-pane). It falls through unbound, as it should.
#   3. psmux send-keys path: send-keys C-/ produces 0x1F (^_), not 0x0F (^O).
#      send-keys C-o still produces 0x0F (^O).
#
# Tooling:
#   - examples/key_diag.exe: crossterm reader that logs every key event.
#   - tests/injector.exe (compiled from injector.cs): WriteConsoleInput
#     injector, supports {RAW:vk:ch:ctrl} for arbitrary key records.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

# --- Compile injector (idempotent) ---
$injector = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

# --- Build key_diag if missing ---
$diag = "$PSScriptRoot\..\target\debug\examples\key_diag.exe"
if (-not (Test-Path $diag)) {
    Push-Location "$PSScriptRoot\.."
    cargo build --example key_diag 2>&1 | Out-Null
    Pop-Location
}
if (-not (Test-Path $diag)) {
    Write-Fail "key_diag.exe missing, cannot run layer 1 test"
    exit 1
}

Write-Host "`n=== LAYER 1: Windows console -> crossterm distinguishes Ctrl+/ from Ctrl+o ===" -ForegroundColor Cyan

$diagLog = "$env:TEMP\psmux_key_diag.log"
Remove-Item $diagLog -EA SilentlyContinue
$proc = Start-Process -FilePath $diag -PassThru
Start-Sleep -Seconds 2

# Inject 3 key events with WriteConsoleInput:
#   Ctrl+/  : VK=0xBF, UnicodeChar=0x1F, ctrl=LEFT_CTRL
#   Ctrl+O  : VK=0x4F, UnicodeChar=0x0F, ctrl=LEFT_CTRL
#   q       : exit diag
& $injector $proc.Id "{RAW:BF:1F:0008}{SLEEP:300}{RAW:4F:0F:0008}{SLEEP:300}q" | Out-Null
Start-Sleep -Seconds 2
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

if (-not (Test-Path $diagLog)) {
    Write-Fail "key_diag log not produced"
} else {
    $log = Get-Content $diagLog -Raw
    Write-Host "`n--- key_diag log ---" -ForegroundColor DarkGray
    Write-Host $log -ForegroundColor DarkGray
    if ($log -match "Char\('/'\) = U\+002F mods=\[C\]") {
        Write-Pass "crossterm received Ctrl+/ as Char('/')+CONTROL"
    } else {
        Write-Fail "crossterm did not see Ctrl+/ as Char('/')+CONTROL"
    }
    if ($log -match "Char\('o'\) = U\+006F mods=\[C\]") {
        Write-Pass "crossterm received Ctrl+O as Char('o')+CONTROL"
    } else {
        Write-Fail "crossterm did not see Ctrl+O as Char('o')+CONTROL"
    }
    # The collision claim: does Ctrl+/ ever show up as Char('o')?
    # Count KEY (Press) lines only — each press also emits an EVT Release line.
    $oCount = ([regex]::Matches($log, "(?m)^KEY code=Char\('o'\)")).Count
    $sCount = ([regex]::Matches($log, "(?m)^KEY code=Char\('/'\)")).Count
    if ($oCount -eq 1 -and $sCount -eq 1) {
        Write-Pass "Ctrl+/ and Ctrl+O are DISTINCT events (no collision)"
    } else {
        Write-Fail "Collision detected: Char('o') KEY count=$oCount, Char('/') KEY count=$sCount"
    }
}

Write-Host "`n=== LAYER 2: psmux TUI prefix+Ctrl+/ does NOT trigger next-pane ===" -ForegroundColor Cyan

$sess = "test_issue226_tui_full"
& $PSMUX kill-session -t $sess 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$sess.*" -Force -EA SilentlyContinue
$tui = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$sess -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -v -t $sess 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX select-pane -t "${sess}.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$paneBefore = (& $PSMUX display-message -t $sess -p '#{pane_index}' 2>&1).Trim()
Write-Host "  pane_index BEFORE prefix+Ctrl+/: $paneBefore"

# Inject prefix (Ctrl+B) then Ctrl+/ via WriteConsoleInput
& $injector $tui.Id "^b{SLEEP:300}{RAW:BF:1F:0008}" | Out-Null
Start-Sleep -Seconds 1

$paneAfterSlash = (& $PSMUX display-message -t $sess -p '#{pane_index}' 2>&1).Trim()
Write-Host "  pane_index AFTER  prefix+Ctrl+/: $paneAfterSlash"

if ($paneBefore -eq $paneAfterSlash) {
    Write-Pass "prefix+Ctrl+/ did NOT trigger next-pane (no collision with 'o' binding)"
} else {
    Write-Fail "BUG: prefix+Ctrl+/ moved focus from $paneBefore to $paneAfterSlash (acted like prefix+o)"
}

# Sanity: prefix+o (the actual binding) DOES move focus
& $injector $tui.Id "^b{SLEEP:300}o" | Out-Null
Start-Sleep -Seconds 1
$paneAfterO = (& $PSMUX display-message -t $sess -p '#{pane_index}' 2>&1).Trim()
Write-Host "  pane_index AFTER  prefix+o:      $paneAfterO"
if ($paneAfterO -ne $paneAfterSlash) {
    Write-Pass "prefix+o (the real binding) DOES move focus (sanity check)"
} else {
    Write-Fail "prefix+o did not move focus (sanity check broke)"
}

& $PSMUX kill-session -t $sess 2>&1 | Out-Null
try { Stop-Process -Id $tui.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$sess.*" -Force -EA SilentlyContinue

Write-Host "`n=== LAYER 3: send-keys C-/ vs C-o produce distinct bytes ===" -ForegroundColor Cyan

$sess2 = "test_issue226_sendkeys"
& $PSMUX kill-session -t $sess2 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$sess2.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $sess2
Start-Sleep -Seconds 3

function Probe-Send {
    param([string]$Key)
    & $PSMUX send-keys -t $sess2 'clear' Enter | Out-Null
    Start-Sleep -Milliseconds 700
    & $PSMUX send-keys -t $sess2 $Key | Out-Null
    Start-Sleep -Milliseconds 200
    & $PSMUX send-keys -t $sess2 'TAIL' Enter | Out-Null
    Start-Sleep -Seconds 1
    return (& $PSMUX capture-pane -t $sess2 -p 2>&1 | Out-String)
}

$capO = Probe-Send 'C-o'
$capS = Probe-Send 'C-/'
Write-Host "  C-o capture has ^O? $($capO -match '\^O')"
Write-Host "  C-/ capture has ^_? $($capS -match '\^_')"

if ($capO -match '\^O') { Write-Pass "send-keys C-o emits ^O (0x0F)" }
else { Write-Fail "send-keys C-o did not emit ^O" }

if ($capS -notmatch '\^O') { Write-Pass "send-keys C-/ does NOT emit ^O (bug fixed)" }
else { Write-Fail "BUG: send-keys C-/ still emits ^O" }

if ($capS -match '\^_') { Write-Pass "send-keys C-/ emits ^_ (0x1F) matching tmux" }
else { Write-Fail "send-keys C-/ did not emit ^_ (got: $($capS.Substring([Math]::Max(0,$capS.Length-200))))" }

& $PSMUX kill-session -t $sess2 2>&1 | Out-Null
Remove-Item "$psmuxDir\$sess2.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
